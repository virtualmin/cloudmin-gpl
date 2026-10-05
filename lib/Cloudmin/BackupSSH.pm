package Cloudmin::BackupSSH;

# OpenSSH verifies transfers; this module supplies trusted entries and approvals.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use Digest::SHA qw(sha256_hex sha256_base64);
use MIME::Base64 qw(decode_base64);
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/SSHKeys.pm');
our $directory;
our @known_files = ('/etc/ssh/ssh_known_hosts', ((getpwuid(0))[7] || '/root').'/.ssh/known_hosts');

# host(target) validates and normalizes the OpenSSH known_hosts lookup name.
sub host
{
my ($t) = @_;
die "Enter a valid SSH server and port\n" if (($t->{'host'} || '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9.:-]*\z/ ||
	($t->{'port'} || 22) !~ /\A\d+\z/ || ($t->{'port'} || 22) > 65535);
return ($t->{'port'} || 22) == 22 ? lc($t->{'host'}) : '['.lc($t->{'host'}).']:'.(0+$t->{'port'});
}

# path(target) identifies approvals shared by schedules and restored archives.
sub path
{
die "SSH backup trust directory is not configured\n" if (!$directory);
return $directory.'/'.sha256_hex(host($_[0]));
}

# entries(file, host) delegates hashed names, patterns and markers to OpenSSH.
sub entries
{
my ($file, $host) = @_;
# An absent trust file is normal; a failed lookup must not look like no trust.
return () if (!-e $file);
open(my $fh, '-|', 'ssh-keygen', '-F', $host, '-f', $file) or die "Cannot read SSH known hosts\n";
my @lines = grep { !/^#/ && /\S/ } <$fh>;
close($fh);
# ssh-keygen exits with 1 for no match; other failures need attention.
die "Cannot read SSH known hosts\n" if ($? && $? != 256);
chomp(@lines);
return @lines;
}

# known(target) uses approved replacements while retaining external revocations.
sub known
{
my ($t) = @_;
my $host = host($t);
my @system = map { entries($_, $host) } @known_files;
my $file = path($t);
# An explicit replacement supersedes old ordinary entries, but not revocations.
return [@system] if (!-e $file);
return [entries($file, $host), grep { /^\@revoked\s/ } @system];
}

# key(line) extracts the algorithm and public key from a known_hosts entry.
sub key
{
my ($line) = @_;
return $line =~ /(?:^|\s)((?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+) [A-Za-z0-9+\/=]+)(?:\s|$)/ ? $1 : '';
}

# fingerprints(lines) formats public SHA256 fingerprints without key comments.
sub fingerprints
{
my ($lines) = @_;
return [map { my ($type, $bytes) = split(/ /, key($_));
	$type.' SHA256:'.sha256_base64(decode_base64($bytes)) } grep { key($_) } @$lines];
}

# digest(lines) binds approval to the exact displayed keys and previous trust.
sub digest { return sha256_hex(join("\n", sort @{$_[0]})); }

# scan(target) runs only inside the isolated, network-enabled host-key worker.
sub scan
{
my ($t) = @_;
my $host = host($t);
require(dirname(__FILE__).'/WorkerTasks.pm');
# Scanning discovers candidate public keys; it does not authenticate the server.
my $output = Cloudmin::WorkerTasks::command('ssh-keyscan', '-T', '5', '-p', $t->{'port'} || 22,
	'-t', 'ed25519,ecdsa,rsa', lc($t->{'host'}));
my %keys = map { my $key = key($_); $key ? ($host.' '.$key => 1) : () } split(/\n/, $output);
die "The SSH server did not provide a host key\n" if (!keys(%keys));
return {keys => [sort keys %keys]};
}

# check(target) compares observed keys with existing trust without accepting any.
sub check
{
my ($t) = @_;
host($t);
my $observed = Cloudmin::Worker->new()->run('backup_host_key', {host => $t->{'host'}, port => $t->{'port'} || 22})->{'keys'};
my $known = known($t);
# Reject revoked keys before considering any ordinary trusted-key match.
my %observed = map { key($_) => 1 } @$observed;
die "The SSH server's host key is revoked. Update this host's SSH trust configuration before connecting.\n"
	if (grep { /^\@revoked\s/ && $observed{key($_)} } @$known);
# Certificate-authority entries are not direct matches for scanned host keys.
my @trusted = grep { !/^\@/ } @$known;
return {status => (grep { $observed{key($_)} } @trusted) ? 'trusted' : @$known ? 'changed' : 'unknown',
	host => host($t), old => fingerprints($known), current => fingerprints($observed),
	previous => digest($known), proposed => digest($observed), keys => $observed};
}

# approve(target, previous_digest, proposed_digest) saves only the reviewed keys.
sub approve
{
my ($t, $previous, $proposed) = @_;
# Rescan on approval so an old confirmation cannot accept a newly changed key.
my $state = check($t);
die "The SSH host keys changed again. Check the fingerprints and try again.\n"
	if (($previous || '') ne $state->{'previous'} || ($proposed || '') ne $state->{'proposed'});
# Serialize trust updates and recheck the previous state after taking the lock.
Cloudmin::SSHKeys->new($directory)->check_directory(1);
sysopen(my $lock, "$directory/.lock", O_RDWR|O_CREAT|O_NOFOLLOW, 0600) or die "Cannot lock SSH host trust\n";
flock($lock, LOCK_EX) or die "Cannot lock SSH host trust\n";
die "SSH host trust changed. Check the fingerprints and try again.\n" if (digest(known($t)) ne $previous);
# Publish a complete private trust file; never edit system known_hosts entries.
my ($fh, $temp) = tempfile('.known-XXXXXXXX', DIR => $directory, UNLINK => 1);
print($fh join("\n", @{$state->{'keys'}})."\n") && close($fh) or die "Cannot save SSH host trust\n";
rename($temp, path($t)) or die "Cannot save SSH host trust\n";
return {status => 'trusted', host => $state->{'host'}};
}

1;
