package Cloudmin::BackupTransport;

# Local files stay private. Remote clients run in the existing network worker.
use strict;
use warnings;
no warnings 'once';
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use WebminCore qw(convert_to_json);
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/BackupSSH.pm');
my $PRO_HELPERS = dirname(__FILE__).'/../../pro/BackupCloud.pm';

# has_pro_providers() checks for the installed Cloudmin Pro transfer helpers.
sub has_pro_providers
{
return -r $PRO_HELPERS;
}

# modes() lists destinations supported by the installed edition.
sub modes
{
return (qw(local ssh s3), has_pro_providers() ? qw(gcs azure bb dropbox drive) : ());
}

# saved_target(target, [previous]) retains blank credentials only for this provider.
# Explicit clearing lets administrators remove an optional token or password.
sub saved_target
{
my ($target, $previous) = @_;
die "Select a backup destination\n" if (ref($target) ne 'HASH');
my %target = %$target;
foreach my $field (qw(password secret session_token refresh_token)) {
	my $clear = delete($target{$field.'_clear'});
	die "Invalid credential choice\n" if (defined($clear) && $clear !~ /\A[01]?\z/);
	# Explicit clearing takes priority over the saved-secret fallback.
	if ($clear) { $target{$field} = ''; }
	# Reuse blanks only within the same provider, never after a provider
	# switch.
	elsif (!length($target{$field} // '') && $previous && ($previous->{'mode'} || '') eq ($target{'mode'} || '')) {
		$target{$field} = $previous->{$field} // '';
	}
}
return validate(\%target);
}

# validate(target, [restoring]) checks destination fields without contacting it.
# The optional restoring flag is accepted by the service callback; validation
# is identical for backup and restore.
sub validate
{
my ($t, $restoring) = @_;
die "Select a backup destination\n" if (ref($t) ne 'HASH');
my %t = %$t;
die "Select a supported backup destination\n" if (($t{'mode'} || '') !~ /\A(?:local|ssh|s3|gcs|azure|bb|dropbox|drive)\z/);
# Enforce the same edition boundary for forms, schedules, APIs and workers.
die "This backup destination requires Cloudmin Pro\n" if (!grep { $_ eq $t{'mode'} } modes());
# Bound all fields before constructing client requests or command arguments.
foreach my $key (keys %t) {
	die "Invalid backup destination field\n" if (ref($t{$key}) || length($t{$key} // '') > 16384 || ($t{$key} // '') =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/);
}
die "Enter a backup directory or cloud folder\n" if (!defined($t{'path'}) || length($t{'path'}) > 2048 || $t{'path'} =~ /[\r\n]/);
# Filesystem destinations need an absolute directory without parent traversal.
if ($t{'mode'} eq 'local' || $t{'mode'} eq 'ssh') {
	die "Enter an absolute backup directory\n" if ($t{'path'} !~ m{\A/} || $t{'path'} =~ m{(?:\A|/)\.\.(?:/|\z)});
}
# SSH connection arguments and SFTP paths must be literal values.
if ($t{'mode'} eq 'ssh') {
	die "Enter a valid SSH server, username and port\n" if (($t{'host'} || '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9.:-]*\z/ ||
		($t{'user'} || '') !~ /\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z/ || ($t{'port'} || '22') !~ /\A\d+\z/ || ($t{'port'} || 22) > 65535);
	$t{'port'} ||= 22;
	Cloudmin::BackupSSH::host(\%t);
	die "Enter an SSH password or private key file\n" if (!$t{'password'} && !$t{'key_file'});
	die "SSH backup directories cannot contain wildcard characters\n" if ($t{'path'} =~ /[*?\[\]]/);
}
# Object stores separate the bucket or container from the object path.
if ($t{'mode'} =~ /\A(?:s3|gcs|azure|bb)\z/) {
	die "Enter a bucket or container name\n" if (($t{'bucket'} || '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,222}\z/);
}
# Cloud providers require explicit credentials rather than host account
# defaults.
if ($t{'mode'} !~ /\A(?:local|ssh)\z/) {
	die "Enter the cloud account's access and secret credentials\n"
		if (!$t{'secret'} || ($t{'mode'} ne 'azure' && !$t{'access'}));
	die "Enter an OAuth refresh token\n" if ($t{'mode'} =~ /\A(?:gcs|drive|dropbox)\z/ && !$t{'refresh_token'});
	die "Enter an Azure storage account\n" if ($t{'mode'} eq 'azure' && ($t{'account'} || '') !~ /\A[a-z0-9]{3,24}\z/);
}
# Custom S3 endpoints cannot embed credentials, paths or insecure HTTP.
die "Use an HTTPS S3 endpoint without credentials or a path\n" if ($t{'endpoint'} &&
	$t{'endpoint'} !~ m{\Ahttps://[a-zA-Z0-9][a-zA-Z0-9.:-]*\z});
die "Enter a region name\n" if ($t{'region'} && $t{'region'} !~ /\A[a-zA-Z0-9-]+\z/);
# Remote folders are literal paths; never allow command or traversal syntax.
die "Invalid remote backup folder\n" if ($t{'mode'} ne 'local' && ($t{'path'} =~ /[\r\n"\\]/ || $t{'path'} =~ m{(?:\A|/)\.\.(?:/|\z)}));
$t{'path'} =~ s{/+\z}{} if ($t{'path'} ne '/');
return \%t;
}

# preflight(target, restoring) checks tools and storage before stopping a guest.
sub preflight
{
my ($t, $restoring) = @_;
$t = validate($t, $restoring);
if ($t->{'mode'} eq 'local') {
	# Backup may create a private destination; restore requires an existing
	# one.
	make_path($t->{'path'}, {mode => 0700}) if (!$restoring && !-e $t->{'path'} && !-l $t->{'path'});
	my @st = lstat($t->{'path'});
	die "Select an existing private backup directory\n" if (!@st || !-d _ || -l _ || ($st[2] & 0022));
}
# Check command-line dependencies before guest preparation or worker startup.
my @tools = $t->{'mode'} eq 's3' ? ('aws') : $t->{'mode'} eq 'azure' ? ('az') :
	$t->{'mode'} eq 'ssh' ? ('sftp', 'ssh-keygen', 'ssh-keyscan', $t->{'password'} && !$t->{'key_file'} ? ('sshpass') : ()) : ();
foreach my $tool (@tools) { die "Install $tool on this host for the selected backup destination\n" if (!WebminCore::has_command($tool)); }
Cloudmin::BackupSSH::require_trusted($t) if ($t->{'mode'} eq 'ssh');
# B2 packages use different executable names across distributions.
if ($t->{'mode'} eq 'bb') {
	die "Install the Backblaze B2 command on this host\n" if (!grep { WebminCore::has_command($_) } qw(b2 b2-linux backblaze-b2));
}
}

# label(target) names a destination without displaying credentials.
sub label
{
my ($t) = @_;
# Local paths need no protocol prefix; remote labels identify their endpoint.
return $t->{'path'} if ($t->{'mode'} eq 'local');
return 'SSH: '.$t->{'host'}.':'.$t->{'path'} if ($t->{'mode'} eq 'ssh');
return uc($t->{'mode'}).': '.($t->{'bucket'} || '').'/'.$t->{'path'};
}

# transfer(operation, target, filename, local_file, [worker_options]) transfers one
# fixed archive. Remote options provide cancellation and worker journalling.
sub transfer
{
my ($op, $t, $name, $local, $opts) = @_;
$t = validate($t, $op eq 'get');
die "Invalid backup filename\n" if (($name || '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,199}\.tar(?:\.gz)?\z/);
die "Unknown backup transfer operation\n" if ($op !~ /\A(?:put|get|delete)\z/);
if ($t->{'mode'} eq 'local') {
	# A single private directory works for local disks and mounted NFS storage.
	my $dir = $t->{'path'};
	die "The backup directory does not exist\n" if (!-d $dir || -l $dir);
	my @st = stat($dir);
	die "The backup directory must not be writable by other users\n" if ($st[2] & 0022);
	my $path = "$dir/$name";
	if ($op eq 'put') {
		# A repeated upload must not overwrite an already published
		# archive.
		die "A backup with this filename already exists\n" if (-e $path || -l $path);
		# Copy inside a private directory so an existing partial file or symlink
		# cannot redirect the privileged write. Link publishes without replacing.
		my $stage = tempdir('.cloudmin-XXXXXXXX', DIR => $dir, CLEANUP => 0);
		my $temp = "$stage/archive";
		eval { Cloudmin::Worker::copy_file($local, $temp, -s $local);
			link($temp, $path) or die "Cannot publish backup archive\n"; unlink($temp) or die "Cannot remove backup transfer file\n";
			rmdir($stage) or die "Cannot remove backup staging directory\n"; 1 }
			or do { my $e = $@; unlink($temp); rmdir($stage); die $e; };
	}
	# Bound local downloads by available staging space too.
	elsif ($op eq 'get') { Cloudmin::Worker::copy_file($path, $local, Cloudmin::Worker::free_space(dirname($local))-256*1024**2); }
	# Deleting an already absent local archive is idempotent.
	else { unlink($path) or die "Cannot delete backup archive\n" if (-e $path || -l $path); }
	return;
}
# Only uploads need the input archive copied into the isolated worker.
my %files;
$files{'archive'} = $local if ($op eq 'put');
foreach my $field (qw(key_file ca_file)) {
	# Only administrator-selected credential files cross into the worker.
	next if (!$t->{$field});
	die "Select an absolute credential file path\n" if ($t->{$field} !~ m{\A/});
	$files{$field eq 'key_file' ? 'ssh-key' : 'ca.pem'} = $t->{$field};
}
my $limit = Cloudmin::Worker::free_space(dirname($local))-256*1024**2;
my %contents;
if ($t->{'mode'} eq 'ssh') {
	# Give the isolated client only this server's trusted entries.
	my $known = Cloudmin::BackupSSH::known($t);
	die "SSH host key is unknown. Open the backup or restore form to approve its fingerprints.\n" if (!@$known);
	$contents{'known-hosts'} = join("\n", @$known)."\n";
}
Cloudmin::Worker->new()->run('backup_transfer', {operation => $op, target => $t,
	filename => $name, limit => $limit}, files => \%files, contents => \%contents,
	($op eq 'get' ? (output => $local) : ()), %{$opts || {}});
}

1;
