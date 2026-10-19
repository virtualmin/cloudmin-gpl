# Public Cloudmin functions backed by the configured libvirt connection.
# Optional adapters default to a new read-only Cloudmin::Libvirt object.

use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
no warnings 'once';
use List::Util qw(sum);
use POSIX qw(uname);

our (%config, %text);
our ($cloudmin_last_error, $module_root_directory, $module_var_directory,
	$module_config_directory, $remote_user);

require "$module_root_directory/lib/Cloudmin/Libvirt.pm";
require "$module_root_directory/lib/Cloudmin/SSHKeys.pm";
require "$module_root_directory/lib/Cloudmin/ImageCatalog.pm";
require "$module_root_directory/lib/Cloudmin/Images.pm";
require "$module_root_directory/cloudmin-image-sizes.pl";

# get_image_jobs()
# Keeps persistent image jobs outside the web-accessible module directory.
sub get_image_jobs
{
return Cloudmin::Images->new(
	directory => "$module_var_directory/image-jobs",
	uri => $config{'libvirt_uri'},
	max_bytes => Cloudmin::Images::import_limit_bytes($config{'image_max_size'}),
	lock_file => \&lock_data_file,
	unlock_file => \&unlock_data_file,
	test_lock => \&test_lock,
	# log(action, type, object, [params]) retains this module's log context.
	log => sub { webmin_log(@_) },
	disk_free => \&get_free_disk_space,
	# pool_lock(uuid, callback, [creating]) serializes image storage changes
	# with pool stop and guest disk changes.
	pool_lock => sub {
		my ($uuid, $callback, $creating) = @_;
		return get_vm_jobs()->lock('create-host', sub {
			# New reservations require an active destination pool.
			if ($creating) {
				my $pool = get_libvirt()->connect()->get_storage_pool_by_uuid($uuid);
				die "The selected storage pool is no longer active\n" if (!$pool->is_active());
				}
			return $callback->();
			});
		},
);
}

# get_free_disk_space(directory)
# Returns available bytes on the directory's filesystem through Webmin's mount
# API.
sub get_free_disk_space
{
my ($directory) = @_;
local $main::error_must_die = 1;
foreign_require('mount', 'mount-lib.pl');
my ($mountpoint, undef, $type) = mount::filesystem_for_dir($directory);
# Do not mistake an unknown filesystem for unlimited staging space.
die "Cannot find the image staging filesystem.\n" if (!defined($mountpoint));
my (undef, $free) = mount::disk_space($type, $mountpoint);
# The mount API reports KiB; reject missing values before converting to bytes.
die "Cannot determine free staging space.\n"
	if (!defined($free) || $free !~ /\A\d+\z/);
return $free * 1024;
}

# lock_data_file(file, [readonly], [forcefile], [nodiff])
# Takes a Webmin lock for job stores and catalogue files, reporting failures as
# exceptions. Webmin's file locking can be turned off or limited to chosen
# directories in its configuration; without a real lock, workers and requests
# would no longer exclude each other, so that setting is an error here.
sub lock_data_file
{
my ($file, @options) = @_;
die "Changes are disabled in read-only mode\n" if (is_readonly_mode());
die "Cloudmin needs Webmin file locking enabled for $file\n"
	if (!can_lock_file($file));
local $main::error_must_die = 1;
return lock_file($file, @options);
}

# unlock_data_file(file)
# Releases the Webmin lock and removes its expired exit-cleanup entry, so this
# CGI cannot later unlink a lock acquired by a background worker or new request.
sub unlock_data_file
{
my ($file) = @_;
unlock_file($file);
my $lockfile = translate_filename($file).'.lock';
@main::temporary_files = grep { $_ ne $lockfile } @main::temporary_files;
}

# start_image_imports(input)
# Validates a complete batch before queuing it; each selection is idempotent.
sub start_image_imports
{
my ($input) = @_;
# Refuse read-only and delegated callers before token validation or job creation.
die "$text{'image_ereadonly'}\n" if (is_readonly_mode());
require_access('manage');
my $jobs = get_image_jobs();
$jobs->check_token($remote_user, $input->{'token'});
# A download batch has catalogue IDs; custom imports use one empty slot.
my @ids = ($input->{'install_type'} || '') eq 'download'
	? grep { length } split(/[\r\n\0]+/, $input->{'id'} || '') : ('');
@ids = unique(@ids);
# Bound the selection before preparing any import or starting a worker.
die "$text{'images_enone'}\n" if (!@ids);
die "Select at most 16 images at a time.\n" if (@ids > 16);
my @requests = map { prepare_image_import({ %$input, id => $_ }) } @ids;
# Repeated attempts return the same jobs; locks serialize repeated starts.
my $attempts = Cloudmin::Attempts::image_attempts($input);
my @records;
foreach my $i (0..$#requests) {
	my $job = $jobs->create($remote_user, $input->{'token'}, $requests[$i],
		$ids[$i], $attempts->{$ids[$i]});
	push(@records, $job);
	# Completed imports and uploads still waiting for data need no worker.
	$jobs->start($job->{'id'}) if ($job->{'state'} eq 'queued');
	}
return \@records;
}

# prepare_image_import(input)
# Resolves trusted catalogue metadata and current storage before any write.
sub prepare_image_import
{
my ($input) = @_;
my $data = get_images_info();
my ($pool) = grep { $_->{'id'} eq ($input->{'pool'} || '') }
	@{$data->{'pools'}};
# A stale form cannot select a pool that is no longer writable by this flow.
die "$text{'image_epool'}\n" if (!$pool);
my $source = $input->{'install_type'} || '';
my $request = { source => $source, pool => $pool->{'id'},
	pool_name => $pool->{'name'}, slug => 'image' };
if ($source eq 'download') {
	# Use the enabled catalogue entry, from Cloudmin or the custom
	# catalogue.
	my $image = get_available_server_image($input->{'id'});
	# Reject removed, disabled or host-incompatible catalogue selections.
	die "$text{'image_enotfound'}\n" if (!$image);
	$request = Cloudmin::Images::catalogue_request($image, $pool);
	}
else {
	# Custom images require a declared format and may include a checksum.
	die "$text{'image_etype'}\n" if ($source !~ /\A(?:url|local|upload)\z/);
	$request->{'format'} = $input->{'format'} || 'qcow2';
	# ISO imports skip disk inspection but still verify any supplied checksum.
	die "$text{'image_eformat'}\n"
		if ($request->{'format'} !~ /\A(?:qcow2|raw|iso)\z/);
	my $digest = $input->{'sha256'} || '';
	$digest =~ s/^\s+|\s+$//g;
	# An optional user digest must be a complete SHA-256 value.
	die "$text{'image_echecksum'}\n"
		if ($digest && $digest !~ /\A[a-fA-F0-9]{64}\z/);
	$request->{'sha256'} = lc($digest);
	my $name;
	if ($source eq 'url') {
		# Validate the download address and derive a display name from
		# its path.
		$request->{'url'} =
			Cloudmin::Images::validate_url($input->{'url'});
		($name) = $request->{'url'} =~ m{/([^/?]+)(?:\?.*)?$};
		}
	elsif ($source eq 'local') {
		# The worker later opens this regular host file without root
		# privileges.
		my $path = $input->{'path'} || '';
		die "$text{'image_epath'}\n"
			if ($path !~ m{\A/} || $path =~ /[\x00-\x1f]/);
		$request->{'path'} = $path;
		($name) = $path =~ m{([^/]+)$};
		}
	else {
		# Upload bytes arrive separately; the form must identify the
		# chosen file.
		$name = $input->{'filename'};
		die "$text{'image_eupload'}\n" if (!$name);
		}
	$name ||= 'Custom image';
	# Browser filenames are display text, never destination paths.
	$name =~ s{.*[\\/]}{};
	$request->{'name'} = substr($name, 0, 200);
	}
return $request;
}

# get_image_catalogue()
# Combines the Cloudmin catalogue with the custom catalogue in module
# configuration.
sub get_image_catalogue
{
return Cloudmin::ImageCatalog->new(
	'path' => "$module_root_directory/catalog/images.json",
	custom_path => "$module_config_directory/image-catalogue.json",
	lock_file => \&lock_data_file,
	unlock_file => \&unlock_data_file,
	# log(action, type, object, [params]) keeps audits in this module.
	log => sub { webmin_log(@_) },
);
}

# prepare_catalogue_entry(input, catalogue)
# Validates editor fields while retaining metadata not exposed by the form.
sub prepare_catalogue_entry
{
my ($input, $catalogue) = @_;
my $architecture = Cloudmin::ImageCatalog::normalize_architecture($input->{'architecture'});
my $id = $input->{'id'} || '';
# IDs are stable catalogue keys rather than arbitrary filenames.
die "Invalid catalogue ID\n"
	if (length($id) > 96 || $id !~ /\A[a-z0-9][a-z0-9._-]*\z/);
my $existing = $input->{'new'} ? undef
	: $catalogue->find_entry($id.':'.$architecture);
# Editing must not silently recreate an entry removed since the form loaded.
die "Catalogue entry no longer exists\n" if (!$input->{'new'} && !$existing);
my $entry = { %{$existing || {}}, id => $id, architecture => $architecture };
# Preserve hidden metadata while limiting the editable text fields.
foreach my $field (qw(name vendor os release url checksum_url source_url status checksum_algorithm firmware
		release_date end_of_life)) {
	my $value = $input->{$field} || '';
	$value =~ s/^\s+|\s+$//g;
	# URLs need more room than labels, but neither may contain control
	# bytes.
	die "Invalid catalogue field $field\n"
		if ($value =~ /[\x00-\x1f]/ || length($value) >
		($field =~ /url\z/ ? 4096 : 200));
	$entry->{$field} = $value;
	}
$entry->{'source_url'} ||= $entry->{'url'};
$entry->{'format'} = $input->{'format'} || '';
# An estimate for the old file does not describe a replacement URL.
delete($entry->{'download_size_bytes'})
	if ($existing && $entry->{'url'} ne $existing->{'url'});
# Catalogue imports always fetch a checksum file before inspecting the image.
Cloudmin::Images::validate_url($entry->{$_}) for qw(url checksum_url source_url);
my $disk = $input->{'min_disk_gib_def'} ? 0 : $input->{'min_disk_gib'} || 0;
# Store a bounded byte count; zero means no stated minimum.
die "Enter a valid minimum disk size in GiB\n"
	if ($disk !~ /\A\d+(?:\.\d+)?\z/ || $disk > 16 * 1024);
$entry->{'min_disk_bytes'} = int($disk * 1024**3);
$entry->{$_} = $input->{$_} ? 1 : 0 for qw(cloud_init guest_agent);
return $entry;
}

# save_catalogue_form(input)
# Validates raw editor fields within the privileged backend before saving them.
sub save_catalogue_form
{
# Catalogue entries affect the host; VM assignments grant no editing access.
require_access('host');
my ($input) = @_;
my $catalogue = get_image_catalogue();
return $catalogue->save_entry(prepare_catalogue_entry($input, $catalogue),
	$input->{'new'});
}

# get_host_image_architecture()
# Returns the normalized architecture used to filter bootable VM images.
sub get_host_image_architecture
{
my (undef, undef, undef, undef, $machine) = uname();
return Cloudmin::ImageCatalog::normalize_architecture($machine);
}

# list_available_server_images([architecture], [catalogue])
# Returns enabled catalogue images for the requested architecture.
# Defaults to the local architecture and configured catalogue.
sub list_available_server_images
{
my ($architecture, $catalogue) = @_;
# An omitted architecture means the local host, not every catalogue entry.
$architecture = get_host_image_architecture() if (!defined($architecture));
$catalogue ||= get_image_catalogue();
return @{$catalogue->list_images($architecture)};
}

# get_available_server_image(id, [architecture], [catalogue])
# Returns one compatible catalogue image by its stable ID.
# Defaults to the local architecture and configured catalogue.
sub get_available_server_image
{
my ($id, $architecture, $catalogue) = @_;
# Keep single-image lookup consistent with the host's image picker.
$architecture = get_host_image_architecture() if (!defined($architecture));
$catalogue ||= get_image_catalogue();
return $catalogue->find_image($id, $architecture);
}

# get_images_info([query], [architecture], [catalogue])
# Collects filtered catalogue records and summary counts for the images page. An
# omitted query lists all host-compatible images from the configured catalogue.
sub get_images_info
{
my ($query, $architecture, $catalogue) = @_;
# Default the picker to the local host. Catalogue filtering is independent.
$architecture = get_host_image_architecture() if (!defined($architecture));
$catalogue ||= get_image_catalogue();
my ($records, $entries, $total, $error);
# A catalogue failure must still leave the storage and import form usable.
my $ok = eval {
	$records = $catalogue->search_images($query, $architecture);
	$total = $catalogue->image_count();
	$entries = $catalogue->list_entries();
	# Default to the host architecture for display. This filter leaves saved
	# entries and the picker unchanged.
	if (($config{'catalogue_host_arch'} // 1) eq '1') {
		my $host_arch = get_host_image_architecture();
		$entries = [grep { $_->{'architecture'} eq $host_arch } @$entries];
		}
	1;
	};
# Retain the failure for display without passing an undefined image list on.
$error = error_message($@) if (!$ok);
$records ||= [];
# Render cached estimates immediately; browser requests refresh stale entries.
my $sizes = get_image_sizes();
foreach my $entry (@$records, @{$entries || []}) {
	my $size = $sizes->get($entry);
	$entry->{'download_size_bytes'} = $size->{'bytes'};
	$entry->{'download_size_refresh'} = $size->{'refresh'};
	}
my $storage = get_storage_info();
# File images can be uploaded to these libvirt file-backed pool types.
my @pools = grep {
	$_->{'active'} && ($_->{'type'} || '') =~ /\A(?:dir|fs|netfs)\z/
	} @{$storage->{'pools'} || []};

return {
	'images' => $records,
	'catalogue_entries' => $entries || [],
	'catalogue_columns' => $config{'catalogue_columns'},
	'max_image_bytes' => Cloudmin::Images::import_limit_bytes($config{'image_max_size'}),
	'error' => $error,
	'architecture' => $architecture,
	'pools' => \@pools,
	'storage_error' => $storage->{'error'},
	'counts' => {
		'catalogue' => $total || 0,
		'compatible' => scalar(@$records),
		'recommended' => scalar(grep {
			($_->{'status'} || '') eq 'recommended'
			} @$records),
	},
};
}

# get_ssh_keys()
# Stores guest login keys separately from administrator SSH identities.
sub get_ssh_keys
{
return Cloudmin::SSHKeys->new("$module_var_directory/vm-ssh-keys");
}

# get_libvirt([writable])
# Returns a new adapter for the configured libvirt URI. Inventory pages use the
# default read-only connection. Pass a true value for calls that libvirt
# refuses on read-only connections, such as guest-agent address queries.
sub get_libvirt
{
my ($writable) = @_;
require "$module_root_directory/lib/Cloudmin/VMStartup.pm";
require "$module_root_directory/lib/Cloudmin/SerialLog.pm";
return Cloudmin::Libvirt->new(
	'uri' => $config{'libvirt_uri'} || 'qemu:///system',
	'readonly' => $writable ? 0 : 1,
	# Native serial logs belong only to this local hypervisor.
	'serial_log' => (!$config{'libvirt_uri'} || $config{'libvirt_uri'} eq 'qemu:///system')
		? Cloudmin::SerialLog->new() : undef,
	# Startup memory belongs to this host, not a remote libvirt connection.
	'startup' => (!$config{'libvirt_uri'} || $config{'libvirt_uri'} eq 'qemu:///system')
		? Cloudmin::VMStartup->new("$module_var_directory/vm-startup") : undef,
	# on_remove(uuid, job_id) removes only this creation's local access records.
	'on_remove' => sub {
		require "$module_root_directory/cloudmin-webmin-lib.pl";
		remove_vm_webmin(@_);
		get_ssh_keys()->remove(@_);
		},
);
}

# list_managed_servers([skip-completion], [adapter])
# Returns guest hash references visible under the current ACL; skip-completion
# is unused. The optional adapter replaces the configured libvirt connection.
# On failure, returns an empty list and sets cloudmin_last_error.
sub list_managed_servers
{
my ($nocomplete, $adapter) = @_;
$adapter ||= get_libvirt();
my $servers = eval { $adapter->list_domains() };
# Keep the list return type and expose the lookup error separately.
if (!$servers) {
	$cloudmin_last_error = error_message($@);
	return ();
	}
# A successful empty inventory must not retain an earlier lookup error.
$cloudmin_last_error = undef;
# Apply assignments here so theme and legacy callers share the same inventory.
return grep { can_access('view', $_->{'uuid'}) } @$servers;
}

# list_managed_servers_sorted([mode], [skip-completion], [adapter])
# Returns guests sorted by name, ignoring case. Mode and skip-completion are
# accepted for existing callers but do not change discovery or sorting.
sub list_managed_servers_sorted
{
my ($mode, $nocomplete, $adapter) = @_;
return sort {
	lc($a->{'name'}) cmp lc($b->{'name'})
	} list_managed_servers($nocomplete, $adapter);
}

# get_managed_server(id, [adapter])
# Finds one libvirt guest by UUID or name; returns undef on no match or failure.
sub get_managed_server
{
my ($id, $adapter) = @_;
# Skip discovery when the caller has supplied no usable identifier.
return undef if (!defined($id) || $id eq '');
my ($server) = grep {
	$_->{'id'} eq $id || $_->{'name'} eq $id
	} list_managed_servers(0, $adapter);
return $server;
}

# get_managed_server_by(key, value, [adapter])
# Matches a scalar inventory field. Returns all matches in list context or the
# first match in scalar context; no match or a lookup error returns no record.
sub get_managed_server_by
{
my ($key, $value, $adapter) = @_;
my @servers = grep {
	defined($_->{$key}) && $_->{$key} eq $value
	} list_managed_servers(0, $adapter);
return wantarray ? @servers : $servers[0];
}

# get_server_ip(server)
# Returns discovered IPv4 addresses in list context, or the first in scalar
# context. Loads addresses only when the supplied inventory lacks them.
sub get_server_ip
{
my ($server) = @_;
my @ips = grep { !/:/ } get_server_addresses($server);
return wantarray ? @ips : $ips[0];
}

# get_server_ip6(server)
# Returns discovered IPv6 addresses in list context, or the first in scalar
# context, for callers such as Virtualmin's address allocation checks.
sub get_server_ip6
{
my ($server) = @_;
my @ips = grep { /:/ } get_server_addresses($server);
return wantarray ? @ips : $ips[0];
}

# get_server_addresses(server)
# Shares one address lookup between the IPv4 and IPv6 helpers. Ordinary menu
# inventory stays cheap because it does not call these helpers.
sub get_server_addresses
{
my ($server) = @_;
# A stale or externally supplied record must not bypass the current VM scope.
return () if (!can_access('view', $server->{'uuid'} || $server->{'id'}));
if (!exists($server->{'addresses'})) {
	# Inventory omits addresses; fetch them on demand and retain the result
	# in this caller's record. A deleted guest has no current addresses.
	my $vm = $server->{'id'}
		? get_libvirt(1)->get_domain($server->{'id'}) : undef;
	$server->{'addresses'} = $vm ? $vm->{'addresses'} : [];
	}
return map { $_->{'address'} } @{$server->{'addresses'} || []};
}

# get_server_mac(server)
# Reads Cloudmin's mac_addresses field, or the libvirt macs array.
# Returns the first address in scalar context, or all in list context.
sub get_server_mac
{
my ($server) = @_;
my @macs = defined($server->{'mac_addresses'})
	? split(/\s+/, $server->{'mac_addresses'})
	: @{$server->{'macs'} || []};
return wantarray ? @macs : $macs[0];
}

# check_server_status(server, [regen], [skipinfo], [time], [adapter])
# Refreshes the supplied hash in place and returns whether libvirt marks it
# active. Regen, skipinfo, and time are accepted but unused.
sub check_server_status
{
my ($server, $regen, $skipinfo, $time, $adapter) = @_;
my $fresh = get_managed_server($server->{'id'}, $adapter);
# Missing guests and lookup failures leave the old record unchanged.
return 0 if (!$fresh);
%$server = %$fresh;
return $server->{'active'} ? 1 : 0;
}

# validate_server(server)
# Returns error messages for a missing UUID, missing name, or unknown state.
# This checks the supplied record, not whether the guest can be managed safely.
sub validate_server
{
my ($server) = @_;
my @errors;
# A record without a UUID cannot support stable guest lookup.
push(@errors, $text{'validate_euuid'}) if (!$server->{'uuid'});
# Require a name for display and name-based lookup.
push(@errors, $text{'validate_ename'}) if (!$server->{'name'});
# Treat missing state data like an explicitly unknown state.
push(@errors, $text{'validate_estate'})
	if (($server->{'state'} || '') eq 'unknown');
return @errors;
}

# can_host_kvm([server])
# Accepts an omitted host or a record marked this/libvirt. Checks the record
# type only, not the host's KVM capabilities or address.
sub can_host_kvm
{
my ($server) = @_;
# Callers without a host record mean the configured host.
return 1 if (!$server);
return ($server->{'manager'} || '') =~ /^(this|libvirt)$/ ? 1 : 0;
}

# check_kvm_host_software([server], [adapter])
# Returns undef when the local KVM/libvirt host is ready, or an error message.
sub check_kvm_host_software
{
my ($server, $adapter) = @_;
# Reject host records outside the local-host convention.
return $text{'check_remote'}
	if ($server && !can_host_kvm($server));
# Return the first readiness error, or undef when every check passed.
my $readiness = check_host_readiness($adapter);
my ($failed) = grep { !$_->{'ok'} } @{$readiness->{'checks'}};
return $failed ? $failed->{'detail'} : undef;
}

# list_kvm_instances([host], [adapter])
# Returns an array reference of guest records, or an error string on failure.
# Host is an optional record checked by can_host_kvm, not a connection address.
sub list_kvm_instances
{
my ($host, $adapter) = @_;
# Reject unsupported host record types before opening a connection.
return $text{'check_remote'} if ($host && !can_host_kvm($host));
$adapter ||= get_libvirt();
my $domains = eval { $adapter->list_domains() };
# Return discovery failures as text, not an empty guest list.
return error_message($@) if (!$domains);
# Legacy host lookups expose the same assigned guests as the main inventory.
return [grep { can_access('view', $_->{'uuid'}) } @$domains];
}

# list_available_managed_servers_sorted()
# Supplies visible guests, sorted by name, for theme default-server settings.
sub list_available_managed_servers_sorted
{
return list_managed_servers_sorted();
}

# can_action([server|servers], [action]) implements the theme permission hook.
# Host administration and unknown legacy actions require an administrator.
# Returns (ok, error) in list context or ok in scalar context. Omitted arguments
# check host access; view accepts one server record or an array of records.
sub can_action
{
my ($servers, $action) = @_;
my $ok = can_access('host');
# Delegated users must be allowed to view every guest in the requested list.
if ($servers && ($action || '') eq 'view') {
	my @servers = ref($servers) eq 'ARRAY' ? @$servers : ($servers);
	$ok = !grep { !can_access('view', $_->{'uuid'} || $_->{'id'}) } @servers;
	}
return wantarray ? ($ok ? 1 : 0, $ok ? undef : $text{'acl_denied'}) : $ok;
}

# get_parent_server(server)
# Returns the host system record that runs a guest, or undef without a guest.
# Webmin's LVM module compares its id with '0', Cloudmin 9's ID for the system
# running Cloudmin itself. Every Cloudmin 10 guest runs on this host.
sub get_parent_server
{
my ($server) = @_;
# A missing guest record has no host system.
return undef if (!$server);
return { 'id' => '0', 'host' => get_system_hostname(), 'manager' => 'this' };
}

# type_kvm_list_disk_devices(server, [adapter]) returns guest block-device paths.
# Webmin's LVM module uses this hook to identify attached logical volumes.
sub type_kvm_list_disk_devices
{
my ($server, $adapter) = @_;
$adapter ||= get_libvirt();
my $domain = $adapter->find_domain($server->{'uuid'} || $server->{'id'});
return () if (!$domain);
my %paths;
# Include both current and next-boot attachments so Webmin sees pending use.
foreach my $flags (0, 2) {
	my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description($flags));
	foreach my $source ($doc->findnodes('/domain/devices/disk/source/@dev')) {
		my $path = $source->getValue();
		$paths{$path} = 1;
		# Webmin displays /dev/VG/LV while libvirt uses /dev/mapper aliases.
		my $record = eval { Cloudmin::LVM::device($path) };
		$paths{$record->{'lv_path'}} = 1 if ($record);
		}
	}
return sort keys %paths;
}

# list_storage_pools([adapter])
# Returns pool records from libvirt, or an empty list after a lookup failure.
sub list_storage_pools
{
my ($adapter) = @_;
$adapter ||= get_libvirt();
my $pools = eval { $adapter->list_storage_pools(1) };
# Keep list context and expose the lookup error through the shared variable.
if (!$pools) {
	$cloudmin_last_error = error_message($@);
	return ();
	}
$cloudmin_last_error = undef;
return @$pools;
}

# get_server_kvm_instance(server, [adapter])
# Looks up a fresh guest record by id, falling back to name if id is absent.
sub get_server_kvm_instance
{
my ($server, $adapter) = @_;
return get_managed_server($server->{'id'} || $server->{'name'}, $adapter);
}

# check_host_readiness([adapter])
# Checks the local KVM device and configured libvirt service without changes.
# Returns check results and any host details, not a full VM-creation preflight.
sub check_host_readiness
{
my ($adapter) = @_;
$adapter ||= get_libvirt();
my @checks;

# Identify missing Perl bindings before attempting a libvirt connection.
my $module_error = $adapter->module_error();
push(@checks, {
	'id' => 'perl',
	'label' => $text{'check_perl'},
	'ok' => $module_error ? 0 : 1,
	'detail' => $module_error
		? $text{'check_perl_fail'}.' '.$module_error
		: $text{'check_perl_ok'},
});

# This device check applies to the machine running the Cloudmin module.
my $has_kvm = -c '/dev/kvm' ? 1 : 0;
push(@checks, {
	'id' => 'kvm',
	'label' => $text{'check_kvm'},
	'ok' => $has_kvm,
	'detail' => $has_kvm
		? $text{'check_kvm_ok'} : $text{'check_kvm_fail'},
});

# Reuse the binding error rather than connecting without Sys::Virt.
my $probe = $module_error ? {
	'ok' => 0,
	'error' => $module_error,
} : $adapter->probe();
push(@checks, {
	'id' => 'connection',
	'label' => $text{'check_connection'},
	'ok' => $probe->{'ok'} ? 1 : 0,
	'detail' => $probe->{'ok'}
		? $text{'check_connection_ok'}
		: text('error_libvirt', $probe->{'error'}),
});

my $host;
# Fetch host details only after the connection has opened successfully.
if ($probe->{'ok'}) {
	$host = eval { $adapter->get_host_info() };
	# Treat unreadable host metadata as a connection check failure.
	if (!$host) {
		$probe = { 'ok' => 0, 'error' => error_message($@) };
		$checks[-1]->{'ok'} = 0;
		$checks[-1]->{'detail'} =
			text('error_libvirt', $probe->{'error'});
		}
	}

# A working libvirt connection may still use an unsupported hypervisor.
my $is_qemu = $host && uc($host->{'driver'} || '') eq 'QEMU';
push(@checks, {
	'id' => 'driver',
	'label' => $text{'check_driver'},
	'ok' => $is_qemu ? 1 : 0,
	'detail' => $is_qemu
		? $text{'check_driver_ok'} : $text{'check_driver_fail'},
});

my $pools;
my $storage_error;
# A successful QEMU connection may still lack the storage daemon or pools.
if ($probe->{'ok'} && $is_qemu) {
	$pools = eval { $adapter->list_storage_pools(0) };
	# Expose discovery errors separately from a valid empty pool list.
	$storage_error = error_message($@) if (!$pools);
	}
my $active_pools = $pools
	? scalar(grep { $_->{'active'} } @$pools) : 0;
my $storage_detail = !$probe->{'ok'} || !$is_qemu
	? $text{'check_storage_wait'}
	: $storage_error
		? text('error_storage', $storage_error)
		: !@$pools
			? $text{'check_storage_none'}
			: !$active_pools
				? $text{'check_storage_inactive'}
				: text('check_storage_ok', $active_pools);
push(@checks, {
	'id' => 'storage',
	'label' => $text{'check_storage'},
	'ok' => $active_pools ? 1 : 0,
	'detail' => $storage_detail,
});

# An active network may lose its runtime rules after a firewall restart.
# Use the creation preflight here too, including in compact overview mode.
if ($probe->{'ok'} && $is_qemu && $adapter->uri() eq 'qemu:///system') {
	require "$module_root_directory/lib/Cloudmin/NetworkPreflight.pm";
	my $networks = eval { Cloudmin::NetworkPreflight::report($adapter) };
	if ($networks) {
		# Preserve individual diagnoses so only repairable failures
		# offer recovery.
		push(@checks, map { +{ %$_, id => 'network:'.($_->{'id'} || $_->{'name'}),
			label => text('check_network', $_->{'name'}) } } @$networks);
	}
	else {
		# A failed probe is not evidence of a healthy or empty network
		# inventory.
		push(@checks, { id => 'network', label => $text{'check_networks'}, ok => 0,
			detail => error_message($@) });
	}
}

# Require all checks to pass and retain each result for the UI.
my $ready = !grep { !$_->{'ok'} } @checks;
return {
	'ready' => $ready ? 1 : 0,
	'checks' => \@checks,
	'probe' => $probe,
	'host' => $host,
	'pools' => $pools,
};
}

# get_storage_info()
# Collects storage-pool and volume totals for the host overview and checks.
sub get_storage_info
{
my $adapter = get_libvirt();
my $pools = eval { $adapter->list_storage_pools(1) };
my $error = $pools ? undef : error_message($@);
$pools ||= [];

# Totals cover active pools because inactive pools have no current capacity.
my @active = grep { $_->{'active'} } @$pools;
return {
	'pools' => $pools,
	'error' => $error,
	'counts' => {
		'pools' => scalar(@$pools),
		'active' => scalar(@active),
		'volumes' => sum(0,
			map { $_->{'volume_count'} || 0 } @active),
		'capacity' => sum(0, map { $_->{'capacity'} || 0 } @active),
		'available' => sum(0,
			map { $_->{'available'} || 0 } @active),
	},
};
}

# error_html(message) escapes backend text and links known navigation advice.
sub error_html
{
my $html = html_escape($_[0]);
# Only this fixed destination becomes markup; backend content stays escaped.
$html =~ s{\bSystem -&gt; Settings -&gt; License Manager\b}
	{ui_link(get_webprefix().'/server-manager/pro/license.cgi',
		'System &rarr; Settings &rarr; License Manager')}ge;
return $html;
}

# error_message(error)
# Normalizes thrown errors before they are shown or returned to a caller.
sub error_message
{
my ($error) = @_;
return Cloudmin::Libvirt::error_message($error)
	if (ref($error) && eval { $error->can('message') });
my $message = defined($error) ? "$error" : '';
$message =~ s/\s+$//;
$message =~ s/\s+at\s+\S+\s+line\s+\d+\.?$//;
$message =~ s/\s+/ /g;
return $message || 'Unknown error';
}

1;
