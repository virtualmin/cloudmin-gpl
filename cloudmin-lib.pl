# Versioned controller entry points for the VM UI and API.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
no warnings 'once';
use Digest::SHA qw(sha256_hex);
use WebminCore qw(convert_to_json);
use MIME::Base64 ();
our (%config, %text, $module_root_directory, $module_var_directory,
	$remote_user);
require "$module_root_directory/lib/Cloudmin/Jobs.pm";
require "$module_root_directory/lib/Cloudmin/VMs.pm";
require "$module_root_directory/lib/Cloudmin/VMManage.pm";
require "$module_root_directory/cloudmin-presets-lib.pl";
require "$module_root_directory/cloudmin-webmin-lib.pl";

# get_snapshot_manager()
# Snapshot jobs share the VM journal and honor the module's read-only ACL.
sub get_snapshot_manager
{
require "$module_root_directory/lib/Cloudmin/Snapshots.pm";
return Cloudmin::Snapshots->new(jobs => get_vm_jobs(),
	images => get_image_jobs(), readonly => is_readonly_mode(),
	adapter => sub { get_libvirt(!is_readonly_mode()) });
}

# get_vm_manager()
# Shares the creation journal and inventory with VM management.
sub get_vm_manager
{
return Cloudmin::VMManage->new(jobs => get_vm_jobs(),
	images => get_image_jobs(), adapter => sub { get_libvirt(1) });
}

# get_clone_service() shares creation's workers, inventory and private journal.
sub get_clone_service
{
require "$module_root_directory/lib/Cloudmin/Clones.pm";
return Cloudmin::Clones->new(%{get_vm_service()});
}

# get_vm_image_service() loads the Pro capture service only when installed.
sub get_vm_image_service
{
die "Creating images from virtual machines requires Cloudmin Pro\n"
	if (!-r "$module_root_directory/pro/VMImages.pm");
require "$module_root_directory/pro/VMImages.pm";
return Cloudmin::VMImages->new(%{get_vm_service()});
}

# run_vm_job(id)
# Dispatches stored requests without trusting a caller's operation type.
sub run_vm_job
{
my ($id) = @_;
my $job = get_vm_jobs()->get($id) || die "Job not found\n";
# Backup and restore jobs share the VM journal and reservations.
if (($job->{'request'}->{'operation'} || '') =~ /\A(?:backup|backup_inspect|restore)\z/) {
	require "$module_root_directory/cloudmin-backups-lib.pl";
	return get_backup_service()->run($id);
}
# Captures share clone cleanup but publish through the Pro image service.
return get_vm_image_service()->run($id)
	if (($job->{'request'}->{'operation'} || '') eq 'capture_image');
# Clone recovery must restore the source before cleaning up its destination.
return get_clone_service()->run($id)
	if (($job->{'request'}->{'operation'} || '') eq 'clone');
return get_snapshot_manager()->run($id)
	if (($job->{'request'}->{'operation'} || '') =~ /\Asnapshot_/);
return $job->{'request'}->{'operation'}
	? get_vm_manager()->run($id) : get_vm_service()->run($id);
}

# get_vm_jobs()
# Returns the private SQLite job store with Webmin locks and audit callbacks.
sub get_vm_jobs
{
# log(action, type, id, details) uses Webmin's existing audit log.
return Cloudmin::Jobs->new(directory => "$module_var_directory/vm-jobs",
	# Recheck at durable submission too; workers resume existing jobs unchanged.
	admit => sub { require_cloudmin_license() if (defined(&require_cloudmin_license)); },
	lock_file => \&lock_data_file,
	unlock_file => \&unlock_data_file, test_lock => \&test_lock,
	# host_guard() blocks resource changes while bridge recovery is pending.
	host_guard => sub {
		return if (!-f "$module_var_directory/networking/bridge.json");
		require "$module_root_directory/cloudmin-network-lib.pl";
		die "Wait for the pending bridge change to finish\n" if (get_host_network()->pending());
		},
	log => sub { webmin_log(@_); });
}

# get_vm_service()
# Creates a VM service with connections opened when needed.
sub get_vm_service
{
# adapter() creates a writable adapter; host_memory() returns available bytes.
return Cloudmin::VMs->new(jobs => get_vm_jobs(),
	images => get_image_jobs(), catalogue => get_image_catalogue(),
	adapter => sub { get_libvirt(1) },
	ssh_keys => get_ssh_keys(),
	# Enforce installer policy in shared preparation, including CLI/API calls.
	virtualmin_enabled => virtualmin_enabled(),
	# register_webmin(job, address) runs after pinned SSH confirms installation.
	# It completes accepted creation even if the license has since expired.
	register_webmin => sub { register_vm_webmin($_[0], $_[1], 1) },
	host_memory => sub {
		foreign_require('proc', 'proc-lib.pl');
		my (undef, $available) = proc::get_memory_info();
		return $available * 1024;
		});
}

# get_api_machines(input) summarizes guests the caller may view.
# input is a request hash; its optional id is an exact UUID or guest name.
sub get_api_machines
{
my ($input) = @_;
my $id = $input->{'id'};
# Validate the selector's type and length before loading inventory.
die "Invalid virtual machine selector\n" if (defined($id) &&
	(ref($id) || !length($id) || length($id) > 255));
# Report inventory errors and check permissions before reading guest details.
my @servers = list_managed_servers_sorted();
die "$main::cloudmin_last_error\n" if ($main::cloudmin_last_error);
@servers = grep { can_access('view', $_->{'uuid'}) } @servers;
if (defined($id)) {
	# Never reveal whether an inaccessible guest exists.
	@servers = grep { $_->{'uuid'} eq $id || $_->{'name'} eq $id } @servers;
	die "Virtual machine not found\n" if (!@servers);
	die "Ambiguous virtual machine name; use its UUID\n" if (@servers != 1);
}
# Skip resource and address lookups when no guests are visible.
return [] if (!@servers);
# Batch resource statistics for only the guests the caller may view.
my $adapter = get_libvirt();
my $stats = $adapter->get_resource_stats([map { $_->{'uuid'} } @servers]);
require "$module_root_directory/lib/Cloudmin/Metrics.pm";
my $metrics = Cloudmin::Metrics->new();
my $jobs = get_vm_jobs();
my @result;
# Build an explicit public record instead of exposing libvirt or job internals.
foreach my $server (@servers) {
	my $uuid = $server->{'uuid'};
	my $sample = $metrics->sample($server, $stats->{$uuid} || {}, 0, time());
	# Load creation metadata only from a valid job ID.
	my $meta = $server->{'cloudmin'} || {};
	my $job = ($meta->{'job'} || '') =~ /\A[a-f0-9]{32}\z/
		? $jobs->get($meta->{'job'}) : undef;
	# Imported metadata must not disclose another guest's creation record.
	$job = undef if ($job && ($job->{'request'}->{'uuid'} || '') ne $uuid);
	# Normalize power states and units; unknown disk capacity stays null.
	my %row = (id => $uuid, name => $server->{'name'},
		state => $server->{'state'} =~ /\A(?:running|blocked)\z/ ? 'running'
			: $server->{'state'} eq 'paused' ? 'paused' : 'stopped',
		cpus => 0 + $server->{'vcpus'}, memory_mib => $server->{'memory_kib'}/1024,
		disk_gib => defined($sample->{'disk_capacity_bytes'})
			? $sample->{'disk_capacity_bytes'}/1024**3 : undef,
		addresses => [get_server_addresses($server)],
		autostart => $server->{'autostart'} ? \1 : \0);
	# Read the creation time only from a matching job.
	$row{'created'} = 0 + $job->{'created'} if ($job && $job->{'created'});
	# Expose attached preset names without disclosing their settings.
	my $presets = Cloudmin::Presets->new(directory => $main::module_config_directory,
		# access(writing) checks this guest's view grant for preset reads.
		access => sub { require_access('view', $uuid) });
	# Omit preset names that can no longer be resolved.
	foreach my $kind (qw(template plan)) {
		my $key = $meta->{$kind} || ($job ? $job->{'request'}->{$kind} : '');
		next if (!$key);
		my $preset = eval { $presets->get($kind, $key) };
		$row{$kind} = $preset->{'name'} if ($preset);
	}
	push(@result, \%row);
}
# Exact selectors return one object; the unfiltered endpoint returns an array.
return defined($id) ? $result[0] : \@result;
}

# generate_random_password()
# Uses 144 bits from the OS random source without storing the plaintext
# password.
sub generate_random_password
{
return substr(MIME::Base64::encode_base64(pack('H*',
	Cloudmin::Images::generate_id()), ''), 0, 24);
}

# get_vm_password_hash(jobs, input, [password])
# Hashes a new password with Webmin, or loads the hash retained for this form.
# Returns undef for ISO installs and key-only cloud accounts.
sub get_vm_password_hash
{
my ($jobs, $input, $password) = @_;
# Installer credentials are entered inside the guest, never retained here.
return undef if (($input->{'install_source'} || '') =~ /\A\s*iso\s*\z/);
# Key-only accounts have no password to hash or recover from this form.
return undef if (($input->{'auth_type'} || 'keys') eq 'keys');
# Do not interpret an unknown authentication mode as password access.
die "Select an authentication method\n"
	if (($input->{'auth_type'} || '') !~ /\A(?:password|both)\z/);
my $id = substr(sha256_hex('vm-create:'.Cloudmin::Attempts::key(@$input{qw(token attempt)})), 0, 32);
my $username = $input->{'username'} || '';
$username =~ s/^\s+|\s+$//g;
if (defined($password) && length($password)) {
	# Do not trim passwords or impose a complexity rule on the initial
	# account.
	die "Enter a password of up to 1024 characters without line breaks\n"
		if (ref($password) || length($password) > 1024 ||
		$password =~ /[\x00\r\n]/);
	foreign_require('useradmin', 'user-lib.pl');
	my $salt = '$6$rounds=500000$'.
		substr(Cloudmin::Images::generate_id(), 0, 16).'$';
	# JSON decodes Unicode; crypt expects the same UTF-8 bytes as SSH login.
	utf8::encode($password) if (utf8::is_utf8($password));
	my $hash = useradmin::encrypt_sha512($password, $salt);
	# Reject crypt failures instead of storing a disabled or
	# malformed hash.
	die "Password hashing is unavailable on this host\n"
		if ($hash !~ /\A\$6\$rounds=500000\$[a-f0-9]{16}\$[.\/A-Za-z0-9]{86}\z/);
	$jobs->save_credential($id, $remote_user, $username, $hash);
	return $hash;
	}
my $hash = $jobs->credential($id, $remote_user, $username);
# A reused form can omit plaintext only after retaining a matching hash.
die "Enter an initial password\n" if (!$hash);
return $hash;
}

1;
