# Shared display settings for pages and Module Configuration.
use strict;
use warnings;
our %config;

# virtualmin_enabled() checks whether new guests may install Virtualmin.
sub virtualmin_enabled
{
return ($config{'virtualmin_enabled'} // '1') ne '0';
}

# view_fields(key)
# Returns field definitions for a column or section setting named by key.
# Entries contain an ID, language key, optional sort type and required flag.
sub view_fields
{
my ($key) = @_;
# Column order must match the complete rows built by the page helpers.
my %fields = (
	machine_columns => [
		['name', 'index_name', 'string', 1],
		['state', 'index_state', 'string', 1],
		['ips', 'index_ips'], ['cpu', 'index_vcpus'],
		['memory', 'index_memory'], ['disk', 'vm_disks'],
		['macs', 'index_macs'], ['persistent', 'index_persistent'],
		['autostart', 'vm_start_at_boot'], ['controls', 'vm_controls']],
	image_columns => [
		['name', 'images_name', 'string', 1],
		['state', 'storage_state', 'string', 1],
		['pool', 'images_storage'], ['format', 'image_format'],
		['size', 'images_size', 'bytes'], ['created', 'images_created'],
		['checksum', 'image_verification']],
	# Host inventory tables require their identity links, but not status columns.
	network_columns => [
		['name', 'net_name', 'string', 1], ['mode', 'net_mode'],
		['state', 'net_status'], ['connection', 'net_connection'],
		['guests', 'net_guests']],
	storage_pool_columns => [
		['name', 'storage_pool', 'string', 1], ['state', 'storage_state'],
		['volumes', 'storage_volume_count', 'number'],
		['space', 'storage_space', 'bytes'], ['autostart', 'storage_autostart']],
	storage_volume_columns => [
		['name', 'storage_name', 'string', 1], ['directory', 'storage_directory'],
		['pool', 'storage_pool'], ['type', 'storage_type'],
		['used_by', 'storage_used_by'], ['capacity', 'storage_virtual_size', 'bytes'],
		['allocation', 'storage_allocated', 'bytes']],
	# Keep identities, schedule state and snapshot position visible.
	backup_columns => [
		['name', 'vm_name', 'string', 1], ['created', 'backup_created', 'date'],
		['destination', 'backup_destination'], ['size', 'backup_size', 'bytes']],
	backup_schedule_columns => [
		['name', 'backup_description', 'string', 1],
		['destination', 'backup_destination'], ['machines', 'backup_machines'],
		['state', 'backup_status', 'string', 1], ['schedule', 'backup_schedule']],
	snapshot_columns => [
		['name', 'snapshots_name', 'string', 1], ['guest', 'vm_name', 'string', 1],
		['created', 'snapshots_created', 'date'], ['size', 'snapshots_size', 'bytes'],
		['preparation', 'snapshots_preparation'],
		['position', 'snapshots_position', 'string', 1]],
	# Section choices affect expansion only; none removes a section from a page.
	machine_create_sections => [
		['image', 'presets_image'], ['resources', 'vm_step_resources'],
		['access', 'vm_step_access'], ['software', 'vm_software'],
		['network', 'vm_network'], ['boot', 'vm_boot_options']],
	machine_detail_sections => [
		['disks', 'vm_disks'], ['interfaces', 'vm_interfaces'],
		['filesystems', 'vm_filesystems'], ['hardware', 'vm_hardware']],
	backup_sections => [
		['doms', 'backup_machines'], ['dest', 'backup_destination'],
		['opts', 'backup_options'], ['sched', 'backup_schedule']],
);
# Reject unknown settings so caller mistakes cannot silently hide fields.
die "Unknown display setting: $key\n" if (!$fields{$key});
return @{$fields{$key}};
}

# view_selection(key, [value])
# Returns selected definitions in display order, retaining required columns.
# Omit value to read %config; explicit undef selects the built-in defaults.
# Empty section selections close every section without removing its controls.
sub view_selection
{
my ($key, $value) = @_;
# An explicit value lets the configuration editor render unsaved choices.
$value = $config{$key} if (@_ < 2);
my @fields = view_fields($key);
my $sections = $key =~ /_sections\z/;
# Backup forms open machine and destination sections; other sections collapse.
# Tables show all columns unless the administrator selects a smaller set.
my $default = $key eq 'backup_sections' ? 'doms,dest' :
	$sections ? '' : join(',', map { $_->[0] } @fields);
# Use defaults for missing or structured values; preserve empty section lists.
$value = $default if (!defined($value) || ref($value));
my %wanted = map { $_ => 1 } split(/[,\s]+/, $value);
# Show all columns if none of the saved column IDs is valid.
%wanted = map { $_ => 1 } split(/,/, $default)
	if (!$sections && !grep { $wanted{$_->[0]} } @fields);
# Walk definitions to discard unknown IDs and duplicates without reordering.
return grep { $wanted{$_->[0]} || $_->[3] } @fields;
}

1;
