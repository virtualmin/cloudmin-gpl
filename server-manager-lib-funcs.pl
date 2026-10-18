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
