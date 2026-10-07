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

1;
