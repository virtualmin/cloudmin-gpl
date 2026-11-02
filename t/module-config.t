use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
# Load page helpers against the sibling Webmin without initializing the host.
our (%config, %in, %text, $root_directory, $module_root_directory);
$root_directory = $CloudminTest::webmin_root;
$module_root_directory = "$Bin/..";
# Supply the size labels normally loaded by Webmin's initialization.
@WebminCore::text{qw(nice_size_MiB nice_size_GiB nice_size_PiB)} = qw(MiB GiB PiB);
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
# Exercise real widgets and size parsing while skipping module CGI setup.
require "$Bin/../cloudmin-pages.pl";
require "$Bin/../cloudmin-status-lib.pl";
require "$Bin/../lib/Cloudmin/VMs.pm";
$INC{'server-manager-lib.pl'} = 1;
require "$Bin/../config_info.pl";

# Existing hosts keep their installer until an administrator disables it.
ok(virtualmin_enabled(), 'Virtualmin installation defaults to enabled');
{
	local $config{'virtualmin_enabled'} = 0;
	ok(!virtualmin_enabled(), 'Virtualmin installation can be disabled');
	# Render inherited Pro choices to ensure host policy hides the whole group.
	ui_table_start(undef, 'width=100%', 4);
	my $form = show_software_settings({software => 'virtualmin-pro', packages => 'jq'}, 0, 1);
	unlike($form, qr/name="(?:software|virtualmin_[^"]+|webmin_register)"/,
		'installer and registration controls are absent');
	like($form, qr/name="packages"/, 'packages stay available without Virtualmin');
	unlike($form, qr/<hr\b/, 'creation has no installer dividers when Virtualmin is disabled');
	# Templates and license fields follow the same host policy.
	$form = show_software_settings({packages => 'jq'}, 0, 0, 1);
	unlike($form, qr/<hr\b/, 'template software has no installer dividers when Virtualmin is disabled');
	is(show_license_rows(), '', 'disabled installation has no license inputs');
	ui_table_end();
}

# Each configured table keeps headings, sort types and object IDs aligned.
foreach my $key (qw(machine_columns image_columns network_columns
	storage_pool_columns storage_volume_columns backup_columns
	backup_schedule_columns snapshot_columns)) {
	my @all = view_fields($key);
	my @ids = map { $_->[0] } @all;
	is_deeply([map { $_->[0] } view_selection($key, undef)],
		\@ids, "$key shows all columns when absent");
	is_deeply([map { $_->[0] } view_selection($key, 'unknown')],
		\@ids, "$key falls back safely for unknown saved fields");
	local $config{$key} = $ids[-1].','.$ids[-1].',unknown';
	# Unknown and repeated IDs must not shift cells or their leading checkbox.
	my @selected = view_selection($key);
	my $checkbox = {type => 'checkbox', value => 'original-object'};
	my ($heads, $rows, $types) = table_columns($key,
		[[$checkbox, @ids]], 1, 'token');
	is_deeply($rows->[0], [$checkbox, map { $_->[0] } @selected],
		"$key keeps selected values in canonical order with the original checkbox");
	is(scalar(@$heads), scalar(@{$rows->[0]}), "$key headings align");
	is(scalar(@$types), scalar(@$heads), "$key sort types align");
	%in = ($key.'_'.$ids[-1] => 1, $key.'_unknown' => 1);
	# Saving restores required fields omitted by disabled checkbox controls.
	is(parse_cloudmin_fields('', '', 15, 'cloudmin_fields', $key),
		join(',', map { $_->[0] } @selected), "$key parser saves known choices");
	my $html = show_cloudmin_fields($config{$key}, '', 15, 'cloudmin_fields', $key);
	like($html, qr/name="${key}_name"[^>]*checked[^>]*disabled/,
		"$key identity is checked and cannot be unchecked");
}

# OS and MAC choices use the same editor and row filtering as other columns.
{
	local $config{'machine_columns'} = 'name,state,os,ips';
	my $html = show_cloudmin_fields($config{'machine_columns'}, '', 15,
		'cloudmin_fields', 'machine_columns');
	like($html, qr/name="machine_columns_os"[^>]*checked/,
		'operating system is selectable in the existing column editor');
	unlike($html, qr/name="machine_columns_macs"[^>]*checked/,
		'MAC addresses can be hidden independently');
	my $row = get_vm_row({name => 'guest', state => 'running',
		addresses => [{address => '192.0.2.1'}], macs => ['52:54:00:00:00:01']});
	my ($heads, $rows) = table_columns('machine_columns', [$row]);
	is_deeply($heads, [@text{qw(index_name index_state index_os index_ips)}],
		'OS heading follows the selected column order');
	like($rows->[0]->[2], qr/data-vm-guest="os"/,
		'OS cell reuses the guest status field');
	like($rows->[0]->[3], qr/192\.0\.2\.1/, 'IP address stays in its named column');
	unlike(join('', @{$rows->[0]}), qr/52:54:00:00:00:01/, 'hidden MAC has no cell');
	my $live = convert_from_json(get_overview_status_config('signed-token'));
	is_deeply($live->{'columns'}, [qw(name state os ips)],
		'live updates follow the OS column selection');
	foreach my $template (values %{$live->{'rows'}}) {
		is(scalar(@$template), 4, 'new rows keep the selected column count');
		like($template->[2], qr/data-vm-guest="os"/, 'new rows receive live OS text');
	}
}

# Reduced live templates must use the same schema as the first HTML table.
{
	local $config{'machine_columns'} = 'name,state,autostart,controls';
	my $live = convert_from_json(get_overview_status_config('signed-token'));
	is_deeply($live->{'columns'}, [qw(name state autostart controls)],
		'live updates receive column IDs rather than fixed offsets');
	foreach my $row (values %{$live->{'rows'}}) {
		is(scalar(@$row), 4, 'every power-state template uses the reduced layout');
		like($row->[2], qr/name="enabled"/, 'boot policy stays in the named column');
	}
	# Compare initial and live control tags; HTML attribute order can vary.
	foreach my $state (qw(running paused shutoff)) {
		my $row = get_vm_row({uuid => '00000000-0000-0000-0000-000000000000',
			state => $state, active => $state ne 'shutoff'}, 'signed-token');
		is_deeply([$live->{'rows'}->{$state}->[3] =~ /<(div|form|button)\b/g],
			[$row->[10] =~ /<(div|form|button)\b/g],
			"$state controls keep the initial tag structure");
	}
	my $readonly = convert_from_json(get_overview_status_config());
	is_deeply($readonly->{'columns'}, [qw(name state autostart)],
		'no token omits controls even when configured');
	unlike(join('', @{$readonly->{'rows'}->{'running'}}), qr/<form\b/,
		'read-only templates cannot acquire controls through configuration');
}

# Creation and detail sections stay collapsed without an explicit selection.
is_deeply([map { $_->[0] } view_selection('machine_create_sections', undef)],
	[], 'optional creation sections default to collapsed');
is_deeply([map { $_->[0] } view_fields('machine_create_sections')],
	[qw(image resources access software network boot)],
	'creation offers the image, resources, access, software, network and boot sections');
is_deeply([view_selection('machine_create_sections', '')], [],
	'an empty selection closes all optional creation sections');
is_deeply([view_selection('machine_detail_sections', undef)], [],
	'detail sections stay collapsed by default');
# Backup forms retain their open sections, but an explicit empty set closes all.
is_deeply([map { $_->[0] } view_selection('backup_sections', undef)],
	[qw(doms dest)], 'backup forms retain their two expanded sections by default');
is_deeply([view_selection('backup_sections', '')], [],
	'an explicit empty backup selection closes every section');
# Forged section names cannot add unknown values to the saved setting.
%in = (machine_create_sections_network => 1, machine_create_sections_fake => 1);
is(parse_cloudmin_fields('', '', 15, 'cloudmin_fields', 'machine_create_sections'),
	'network', 'only known sections can be expanded');

# Validation rejects unsafe timer values.
{
	no warnings 'redefine';
	# error(message) turns Webmin validation failures into catchable assertions.
	local *main::error = sub { die $_[0] };
	foreach my $key (qw(bridge_confirm_timeout)) {
		my ($default, $min, $max) = number_setting($key);
		my $parser = \&parse_cloudmin_number;
		# Form validation rejects bad input; runtime reads use safe defaults.
		foreach my $value ('', 0, -1, $min - 1, $max + 1, '1.5', '1e3', "180\nInjected=1") {
			%in = ($key => $value);
			ok(!eval { $parser->('', $key, 15, '', $key); 1 },
				"$key rejects invalid input");
			is(config_number($key, $value), $default,
				"$key has a safe fallback for hand-edited settings");
		}
		# Both boundaries and the default remain valid without explicit size units.
		foreach my $value ($min, $default, $max) {
			%in = ($key => $value);
			is($parser->('', $key, 15, '', $key),
				$value, "$key accepts its valid limits");
		}
	}
}
# Creation preferences no longer duplicate template or plan settings.
my $defaults = get_vm_form_defaults({vm_default_cpus => 8,
	vm_default_memory => 512, vm_default_disk => 100,
	vm_default_start => 0, vm_default_autostart => 0, vm_username => 'olduser'});
is_deeply([@$defaults{qw(cpus memory_mib disk_gib start autostart username)}],
	[2, 2048, 20, 1, 1, 'cloudmin'], 'old module settings cannot override the presets');
my $html = show_cloudmin_number(undef, '', 15, 'cloudmin_number', 'bridge_confirm_timeout');
like($html, qr/type="number"/, 'timeout uses a numeric input');
like($html, qr/step="1"/, 'timeout accepts integers');

# Import preferences select only offered pools and keep Automatic as fallback.
{
	no warnings qw(redefine once);
	my @pools = map { {id => $_ x 8 . '-1111-2222-3333-444444444444',
		name => $_ eq 'a' ? 'default' : 'extra', type => 'dir'} } qw(a b);
	# get_storage_info() supplies fixture pools without contacting libvirt.
	local *main::get_storage_info = sub { {pools => \@pools} };
	# error(message) makes configuration validation failures catchable.
	local *main::error = sub { die $_[0] };
	# Runtime choices fall back within the caller's offered pools.
	is(image_import_pool(\@pools, ''), $pools[0]->{'id'}, 'Automatic selects the default pool');
	is(image_import_pool(\@pools, $pools[1]->{'id'}), $pools[1]->{'id'}, 'preferred pool is selected');
	is(image_import_pool(\@pools, 'gone'), $pools[0]->{'id'}, 'missing pool falls back to Automatic');
	is(image_import_pool([$pools[1]], ''), $pools[1]->{'id'}, 'Automatic uses the first pool without default');
	is(image_import_pool([], ''), '', 'no eligible pool gives no destination');
	# New choices require supported pools; old choices can outlive them.
	%in = (image_pool => $pools[1]->{'id'});
	is(parse_image_pool(''), $pools[1]->{'id'}, 'pool selection accepts a file-backed pool');
	local $pools[1]->{'type'} = 'logical';
	ok(!eval { parse_image_pool(''); 1 }, 'unsupported new pool selection is rejected');
	is(parse_image_pool($pools[1]->{'id'}), $pools[1]->{'id'}, 'unavailable old selection can be retained');
	# Reject malformed IDs while allowing the user to clear the preference.
	%in = (image_pool => "invalid\ninjected=1");
	ok(!eval { parse_image_pool(''); 1 }, 'invalid pool identifiers are rejected');
	%in = (image_pool => '');
	is(parse_image_pool($pools[0]->{'id'}), '', 'Automatic clears the preferred pool');
}

# Config labels and their tooltips use exactly the same titles.
open(my $info, '<', "$Bin/../config.info") or die $!;
while (<$info>) {
	my ($key, $label) = /^([^=]+)=([^,]+)/;
	# Category headings have no individual configuration tooltips.
	next if (!$key || $key =~ /^line\d+$/);
	my $help = "$Bin/../help/config_$key.html";
	# Check existing help without requiring a tooltip for every setting.
	next if (!-f $help);
	open(my $file, '<', $help) or die $!;
	local $/;
	my $content = <$file>;
	like($content, qr/<header>\Q$label\E<\/header>/, "$key help title matches its setting");
	like($content, qr/<footer>/, "$key help has a footer");
}
done_testing();
