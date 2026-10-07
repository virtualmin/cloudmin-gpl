package Cloudmin::License;

# License decisions are separate from Webmin pages and running VM workers.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW LOCK_EX);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use Time::Local qw(timegm);
use WebminCore qw(convert_to_json convert_from_json);

# new(class, directory => path, file => path, host => ID,
#     request => callback, [now => callback], [replace => callback])
# request(host, key) returns the license API's text response. now defaults
# to the system clock; tests supply a clock without changing the host time.
# replace(serial, key) optionally updates repository credentials with the file.
# directory holds the private cache; file holds the credentials.
sub new
{
my ($class, %args) = @_;
die "License storage is not configured\n" if (!$args{'directory'} || !$args{'file'} || !$args{'host'});
$args{'now'} ||= sub { time() };
return bless \%args, $class;
}

# read_private(path, [allow_read]) reads an owned regular file without symlinks.
# allow_read defaults to false. When true, allow group and world reads, but no writes.
# Cache files remain owner-only. Missing files return undef; unsafe files and
# I/O failures throw.
sub read_private
{
my ($path, $allow_read) = @_;
# An absent file is normal on a fresh host; a dangling symlink is an error.
return undef if (!-e $path && !-l $path);
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die "Cannot read license storage\n";
my @st = stat($fh);
# Check the opened file so replacing the path cannot evade ownership checks.
die "License storage must be private and owned by the current user\n"
    if (!-f $fh || $st[4] != $< || ($st[2] & ($allow_read ? 0022 : 0077)) || $st[7] > 16384);
local $/;
my $value = <$fh>;
close($fh) or die "Cannot close license storage\n";
return $value // '';
}

# write_private(path, value) atomically replaces one owner-only state file.
sub write_private
{
my ($path, $value) = @_;
my ($dir) = $path =~ m{\A(.+)/[^/]+\z};
my ($fh, $temp) = tempfile('.license-XXXXXX', DIR => $dir, UNLINK => 0);
my $ok = eval {
    chmod(0600, $temp) or die "Cannot protect license storage\n";
    print {$fh} $value or die "Cannot write license storage\n";
    close($fh) or die "Cannot close license storage\n";
    rename($temp, $path) or die "Cannot save license storage\n";
    1;
};
my $error = $@;
# Failed replacements must not leave temporary credential files behind.
unlink($temp) if (!$ok);
die $error if (!$ok);
}

# credentials(self) reads the existing Cloudmin license format, never a shell.
sub credentials
{
my ($self) = @_;
my $raw = read_private($self->{'file'}, 1);
return {} if (!defined($raw));
# Parse only the two credential assignments, including old quoted values.
my %values;
foreach my $line (split(/\r?\n/, $raw)) {
    next if ($line !~ /\A(SerialNumber|LicenseKey)=(.*?)\s*\z/);
    my ($name, $value) = ($1, $2);
    $value =~ s/\A["'](.*)["']\z/$1/;
    $values{$name} = $value;
}
return { serial => $values{'SerialNumber'}, key => $values{'LicenseKey'} };
}

# validate_credentials(serial, key) rejects malformed inputs without echoing them.
sub validate_credentials
{
my ($serial, $key) = @_;
die "Enter a valid license serial number and key\n"
    if (!defined($serial) || ref($serial) || $serial !~ /\A[0-9]{1,32}\z/ ||
        !defined($key) || ref($key) || $key !~ /\A[A-Za-z0-9_-]{8,256}\z/);
}

# binding(self, credentials) ties cached decisions to this host and license.
sub binding
{
my ($self, $credentials) = @_;
return sha256_hex(join("\0", 'license/client-v2:cloudmin', $self->{'host'},
    map { $credentials->{$_} // '' } qw(serial key)));
}

# expiry(date) returns the UTC instant after the last licensed calendar day.
sub expiry
{
my ($date) = @_;
# Reject malformed dates before asking Time::Local to validate the calendar day.
return undef if (($date || '') !~ /\A(\d{4})-(\d{2})-(\d{2})\z/);
my ($y, $m, $d) = ($1, $2, $3);
return undef if ($y < 1970 || $y > 9998);
my $time = eval { timegm(0, 0, 0, $d, $m-1, $y) };
return $@ ? undef : $time + 86400;
}

# parse(response) reads expiry, allowances, host use and renewal information.
# Developer codes allow extra hosts; zero means unlimited for either allowance.
# Unknown responses never become a valid license or disclose server output.
sub parse
{
my ($response) = @_;
return { state => 'unavailable' } if (!defined($response) || ref($response) || length($response) > 4096);
# A verified response for the other product cannot use offline grace.
return { state => 'invalid' } if ($response =~ /\A(?:OK|EXP)\s[^\r\n]*\sproduct=virtualmin\s*\z/);
# Only the complete Cloudmin response can supply new terms and host counts.
if ($response =~ /\A(OK|EXP)\s+(\d{4}-\d{2}-\d{2})\s+(\d+)\s+(\d+)\s+(\d+)\s+([01])\s+([NDTQPHY])(?:\s+(\d+))?\s+product=cloudmin\s*\z/) {
    my ($code, $date, $limit, $max, $used, $renew, $allowance, $subscription) =
        ($1, $2, $3, $4, $5, $6, $7, $8);
    my $expires = expiry($date);
    return { state => 'unavailable' } if (!defined($expires));
    my %hosts = (D => 2, T => 3, Q => 4, P => 5, H => 6, Y => 0);
    # A special allowance can increase the base limit, never reduce it.
    $max = $allowance eq 'Y' ? 0 : $max && ($hosts{$allowance} || 0) > $max
        ? $hosts{$allowance} : $max;
    return { state => $code eq 'EXP' ? 'expired' : 'valid', expiry => $date,
        expires => $expires, vm_limit => 0+$limit,
        max_hosts => 0+$max, used_hosts => 0+$used, auto_renew => 0+$renew,
        allowance => $allowance,
        defined($subscription) ? (subscription => $subscription) : () };
}
# Explicit rejection ends grace; unknown replies count as failed checks.
return { state => 'invalid' } if ($response =~ /\AERR Invalid host or serial number\s*\z/);
return { state => 'unavailable' };
}

# load(self, credentials) verifies cached state before trusting its timestamps.
# Missing, edited or copied state requires a new successful server check.
sub load
{
my ($self, $credentials) = @_;
my $state = eval {
    my $secret = read_private("$self->{directory}/seal");
    my $raw = read_private("$self->{directory}/status");
    die "No cache\n" if (!$secret || !$raw);
    my $envelope = convert_from_json($raw);
    die "Invalid cache\n" if (ref($envelope) ne 'HASH' || ref($envelope->{'data'}) ||
        hmac_sha256_hex($envelope->{'data'} // '', $secret) ne ($envelope->{'mac'} // ''));
    my $data = convert_from_json($envelope->{'data'});
    # A valid seal alone does not authorize another host, key or API version.
    die "Different license\n" if (ref($data) ne 'HASH' ||
        ($data->{'binding'} || '') ne $self->binding($credentials));
    $data;
};
# Discard unusable cache data and let the caller request fresh verification.
return $state || {};
}

# save(self, state) seals the cache with a separate private random key.
sub save
{
my ($self, $state) = @_;
my $path = "$self->{directory}/seal";
my $secret = read_private($path);
if (!$secret) {
    # OS randomness avoids deriving the cache seal from public host properties.
    open(my $random, '<', '/dev/urandom') or die "Cannot generate license cache key\n";
    read($random, $secret, 32) == 32 or die "Cannot generate license cache key\n";
    close($random);
    write_private($path, $secret);
}
my $data = convert_to_json($state, 0, 1, 1);
write_private("$self->{directory}/status", convert_to_json({data => $data,
    mac => hmac_sha256_hex($data, $secret)}, 0, 1));
}

1;
