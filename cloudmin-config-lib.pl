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

# section_open(key, section)
# Returns whether section starts expanded under the named configuration key.
sub section_open
{
my ($key, $section) = @_;
return scalar(grep { $_->[0] eq $section } view_selection($key)) ? 1 : 0;
}

# image_import_pool(pools, [saved]) selects an eligible import destination.
# pools contains active file-backed pools. saved is the preferred pool UUID;
# omit it to read Module Configuration. Unavailable choices use the pool named
# default, then the first offered pool. An empty list returns an empty string.
sub image_import_pool
{
my ($pools, $saved) = @_;
# An explicit empty choice requests automatic selection instead of the setting.
$saved = $config{'image_pool'} if (@_ < 2);
# Resolve preferences only against pools that the caller can offer for imports.
my ($chosen) = grep { $_->{'id'} eq ($saved || '') } @$pools;
my ($default) = grep { $_->{'name'} eq 'default' } @$pools;
return ($chosen || $default || $pools->[0] || {})->{'id'} || '';
}

# table_columns(key, rows, [selection_column], [token])
# Returns matching heading, row and sort-type arrays for the selected columns.
# rows must use view_fields() order. Set selection_column to preserve
# a leading checkbox cell; it defaults to false. Without token, omit VM actions.
sub table_columns
{
my ($key, $rows, $selection, $token) = @_;
my @all = view_fields($key);
# Checkbox cells precede the configured columns and keep their original IDs.
my %index = map { $all[$_]->[0] => $_ + ($selection ? 1 : 0) } 0..$#all;
# A display preference cannot add VM controls when the page has no token.
my @fields = grep { $key ne 'machine_columns' || $_->[0] ne 'controls' || $token }
	view_selection($key);
# Use one index list for every row so hidden fields cannot shift their meaning.
my @indices = (($selection ? 0 : ()), map { $index{$_->[0]} } @fields);
my @rows = map { [ @{$_}[@indices] ] } @$rows;
our %text;
return ([($selection ? '' : ()), map { $text{$_->[1]} } @fields],
	\@rows, [($selection ? undef : ()), map { $_->[2] || 'string' } @fields]);
}

# number_setting(key)
# Returns the default, minimum and maximum for a numeric setting named by key.
# The bridge confirmation timeout is measured in seconds.
sub number_setting
{
my ($key) = @_;
my %settings = (
	# Leave time for bridge application, whose service allows up to 90 seconds.
	bridge_confirm_timeout => [180, 120, 900],
);
# Reject unknown keys rather than accepting values without known bounds.
die "Unknown numeric setting: $key\n" if (!$settings{$key});
return @{$settings{$key}};
}

# config_number(key, [value])
# Returns a valid saved number or the setting's default.
# Omit value to read %config; explicit undef returns the setting's default.
sub config_number
{
my ($key, $value) = @_;
# Read the global setting only when the caller has not supplied a value.
$value = $config{$key} if (@_ < 2);
my ($default, $min, $max) = number_setting($key);
return defined($value) && !ref($value) && $value =~ /\A\d{1,10}\z/ &&
	$value >= $min && $value <= $max ? 0 + $value : $default;
}

1;
