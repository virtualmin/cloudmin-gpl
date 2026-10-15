# Widget-based page builders for Cloudmin.

use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Keep page columns and section defaults in sync with Module Configuration.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-image-choices.pl'));
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-pro-lib.pl'));
# Page builders also run outside the initialized module in rendering tests.
require(File::Basename::dirname(__FILE__).'/lib/Cloudmin/Presets.pm');
no warnings 'once';

our (%text, %config, %access, $module_root_directory, $remote_user);

require(File::Basename::dirname(__FILE__)."/cloudmin-disk-labels.pl");

# show_disk_location(path, [local])
# Keeps full storage filenames available without making them the disk heading.
# local defaults to true; remote paths must not open this host's File Manager.
sub show_disk_location
{
my ($path, $local) = @_;
return '' if (!length($path || ''));
return ui_details({ html => 1, class => 'inline inlined',
	title => html_escape($text{'vm_disk_location'}),
	content => !defined($local) || $local ? show_image_path($path) : ui_tag('tt', html_escape($path)) });
}

# show_network_recovery(data)
# Offers recovery only for a diagnosed failure and an authorized host writer.
sub show_network_recovery
{
my ($data) = @_;
# A token, write grants and a repairable diagnosis are all required.
return '' if (!$data->{'token'} || !can_access('host') || !can_access('manage') ||
	!grep { $_->{'repairable'} } @{$data->{'readiness'}->{'checks'}});
return ui_tag('p', html_escape($text{'check_network_restore_desc'})).
	ui_form_start('index.cgi', 'post').
	ui_hidden('action', 'restore_network_rules').ui_hidden('token', $data->{'token'}).
	ui_action_button($text{'check_network_restore'}, 'primary',
		{type => 'submit', icon => 'refresh', size => 'small'}).ui_form_end();
}

# show_dashboard_page(data)
# Builds dashboard widget HTML from a get_dashboard result hash.
sub show_dashboard_page
{
my ($data) = @_;
my $counts = $data->{'counts'};
my $host = $data->{'host'};
my $ready = $data->{'ready'};
# Compact mode hides healthy host details, but never hides failed requirements
# from host administrators. The same flag controls the host tile's anchor link.
my $show_host = can_access('host') &&
	(($config{'host_details'} || '') ne 'problems' || !$ready);
my @servers = @{$data->{'servers'} || []};

# Attach live configuration to the page, preserving entities in row templates.
my $page = ui_page_assets().ui_tag_start('div', {
	'class' => 'ui_page',
	($data->{'live'} ? ('id' => 'cloudmin-vm-status',
		'data-config' => html_escape($data->{'status_config'})) : ()),
});
# Explain unavailable controls without showing an alert during normal startup.
$page .= ui_tag('div', ui_alert_box($text{'vm_status_controls_paused'},
	'warn', undef, undef, ''),
	{ 'data-vm-status-warning' => 1, hidden => undef })
	if ($data->{'live'});
# Use the stat-tile card shown in ui-demo, with links to page details.
$page .= ui_card({
	'id' => 'cloudmin-overview',
	'title' => $text{'index_overview'},
	'desc' => $text{'index_intro'},
	'body' => ui_stats([
		# Host and job totals are hidden from delegated VM viewers.
		(can_access('host') ? ({ 'value' => $counts->{'hosts'},
		  'icon' => 'server',
		  'label' => $text{'index_hosts'},
		  'desc' => $text{'index_hosts_desc'},
		  'href' => $show_host ? '#cloudmin-host' : undef, 'state' => 'info' }) : ()),
		{ 'value_html' => ui_tag('span', $counts->{'vms'},
		{ 'data-vm-count' => 'vms' }),
		  'icon' => 'terminal',
		  'label' => $text{'index_vms'},
		  'desc' => $text{'index_vms_desc'},
		  'href' => '#cloudmin-machines', 'state' => 'info' },
		{ 'value_html' => ui_tag('span', $counts->{'running'},
		{ 'data-vm-count' => 'running' }),
		  'icon' => 'play',
		  'label' => $text{'index_running'},
		  'desc' => $text{'index_running_desc'},
		  'state' => 'success' },
		(can_access('host') ? ({ 'value_html' => ui_tag('span', $counts->{'jobs'},
		{ 'data-vm-count' => 'jobs' }),
		  'icon' => 'clock',
		  'label' => $text{'index_jobs'},
		  'desc' => $text{'index_jobs_desc'}, 'href' => 'jobs.cgi' }) : ()),
	], { 'min' => '140px' }),
});

# A job-store failure must not look like a healthy empty queue.
$page .= ui_alert_box(html_escape($data->{'job_error'}), 'danger', undef,
	undef, '') if ($data->{'job_error'});
# Combine the host's readiness result with its connection details.
my $host_status = ui_badge(
	$ready ? $text{'index_ready'} : $text{'index_notready'},
	$ready ? 'success' : 'warning',
	{ 'small' => 1, 'rounded' => 1 },
);
my $host_card = ui_card({
	'id' => 'cloudmin-host',
	'title' => $text{'index_host'},
	'desc' => $text{'index_host_desc'},
	'actions' => $host_status,
	'body' => ui_dl([
		[ $text{'index_hostname'}, ui_tag('tt', html_escape(
			$host->{'hostname'} || $text{'index_unknown'})) ],
		[ $text{'index_driver'}, html_escape(
			$host->{'driver'} || $text{'index_unknown'}) ],
		[ $text{'index_uri'}, ui_tag('tt', html_escape(
			$host->{'uri'} || $text{'index_unknown'})) ],
		[ $text{'index_version'},
		  ui_tag('tt', html_escape(
			$host->{'libvirt_version'} ||
			$text{'index_unknown'})) ],
		[ $text{'index_libvirt_services'}, html_escape(
			$text{'index_libvirt_'.
			($host->{'libvirt_layout'} || '')} ||
			$text{'index_unknown'}) ],
		[ $text{'index_hypervisor_version'},
		  ui_tag('tt', html_escape(
			$host->{'hypervisor_version'} ||
			$text{'index_unknown'})) ],
	], { 'wide' => '35%' }),
});

# Show each requirement's result and failure reason separately.
my @requirements = map {
	{
		'title' => $_->{'label'},
		'desc' => $_->{'detail'},
		'badge' => [
			$_->{'ok'} ? $text{'index_check_ok'}
				     : $text{'index_check_failed'},
			$_->{'ok'} ? 'success' : 'warning',
			{ 'small' => 1, 'rounded' => 1 },
		],
		'icon' => $_->{'ok'} ? 'check-circle' : 'warning',
		'state' => $_->{'ok'} ? 'success' : 'warning',
		}
	} @{$data->{'readiness'}->{'checks'}};
my $requirements_card = ui_card({
	'title' => $text{'index_requirements'},
	'desc' => $text{'index_requirements_desc'},
	'body' => ui_list(\@requirements).show_network_recovery($data),
});

# Show permitted host details when requested or when requirements fail.
$page .= ui_grid([
	$host_card,
	$requirements_card,
], { 'min' => '360px' }) if ($show_host);

my $machine_body;
my $empty_machines = !@servers && !$data->{'domain_error'};
# Sortable columns provide a compact inventory when guests are present.
if (@servers || $data->{'live'}) {
	my @rows = map { get_vm_row($_, $data->{'token'}) } @servers;
	# Apply the same column order used by live status row templates.
	my ($heads, $visible, $types) = table_columns(
		'machine_columns', \@rows, 0, $data->{'token'});
	$machine_body = ui_columns_table($heads, 100, $visible, $types,
		0, undef, undef, 1);
	# Keep the table available for live additions without showing empty
	# headers or a theme's generated "no data" row beside the empty-state
	# message.
	$machine_body = ui_tag('div', $machine_body,
		{ 'data-vm-table' => 1, @servers ? () : (hidden => undef) });
	}
# Live updates can also remove the last VM from an initially populated page.
if ($empty_machines || $data->{'live'}) {
	# For delegated users, explain missing assignments and omit the Create action.
	$machine_body = ($machine_body || '').ui_tag('div', ui_empty_state({
		'icon' => 'terminal',
		'title' => $text{'index_none'},
		'desc' => !can_access('host') ? $text{'acl_empty'} : $ready ? text('index_none_desc',
			$host->{'hostname'} || $text{'index_unknown'})
			: $text{'index_none_unready'},
		'actions' => can_access('manage') ? ui_link_button('machine_form.cgi',
		$text{'vm_create'}) : '',
	}), { 'data-vm-empty' => 1, $empty_machines ? () : (hidden => undef) });
	}
# Do not present a discovery failure as an empty inventory.
if ($data->{'domain_error'}) {
	my $error = ui_alert_box(
		text('error_domains',
			html_escape($data->{'domain_error'})), 'danger', undef,
			undef, '');
	$machine_body = ui_tag('div', $error,
		{ 'data-vm-discovery-error' => 1 }).
		($data->{'live'} ? $machine_body || '' : '');
	}

# Show the empty heading once; limit host details and creation to administrators.
$page .= ui_card({
	'id' => 'cloudmin-machines',
	'title' => $empty_machines ? undef : $text{'index_machines'},
	'desc' => $empty_machines || !can_access('host') ? undef : text('index_machines_desc',
		$host->{'hostname'} || $text{'index_unknown'}),
	'actions' => $empty_machines || !can_access('manage') ? undef
	: ui_link('machine_form.cgi', $text{'vm_create_button'}),
	'body' => $machine_body,
});
$page .= ui_page_end();
return $page;
}

# describe_image_check(job)
# Describes disk inspection and the checksum source used for this import.
sub describe_image_check
{
my ($job) = @_;
if (($job->{'source'} || '') eq 'download') {
	# Bundled and custom catalogue entries both declare a checksum source.
	my $algorithm = uc($job->{'checksum_algorithm'} || 'sha256');
	$algorithm =~ s/^SHA(?=\d)/SHA-/;
	return text(($job->{'checksum_source'} || '') eq 'catalogue'
		? 'images_check_catalogue' : 'images_check_vendor', $algorithm);
	}
elsif ($job->{'sha256'}) {
	# Custom imports compare against the checksum supplied in the form.
	return $text{'images_check_supplied'};
	}
# Disk inspection still runs when a custom import has no checksum.
return $text{'images_job_verifying'};
}

# show_image_path(path)
# Shows a file path and links to its allowed File Manager directory when
# available.
sub show_image_path
{
my $path = $_[0] || '';
my $label = ui_tag('tt', html_escape($path));
return $label if ($path !~ m{^/});
my $dir = $path;
$dir =~ s{/[^/]+$}{};
$dir ||= '/';
return show_filemin_directory($dir, $label);
}

# show_filemin_directory(dir, [label])
# Links a local directory within the user's File Manager roots. An optional
# HTML label lets image paths retain their full filename.
sub show_filemin_directory
{
my ($dir, $label) = @_;
$label = ui_tag('tt', html_escape($dir)) if (!defined($label));
# Missing modules, denied access and non-filesystem paths stay plain text.
return $label if ($dir !~ m{^/} || !foreign_available('filemin'));
foreign_require('filemin', 'filemin-lib.pl');
my @allowed = filemin::get_allowed_paths($dir);
foreach my $root (@allowed) {
	# Do not link a directory outside the user's File Manager roots.
	next if (!is_under_directory($root, $dir));
	my $relative = $dir;
	if (@allowed == 1 && $root ne '/') {
		# File Manager resolves relative paths under its sole allowed
		# root. Resolve aliases before making the requested path
		# relative to it.
		$relative = resolve_links($dir);
		my $base = resolve_links($root);
		$relative =~ s{^\Q$base\E}{};
		}
	return ui_link('../filemin/index.cgi?path='.
		urlize($relative || '/'), $label, 'text-link');
	}
return $label;
}

# list_catalogue_columns()
# Defines available columns and their sort types in the table's display order.
sub list_catalogue_columns
{
return (
	{ id => 'name', label => 'images_name', type => 'string' },
	{ id => 'os', label => 'catalogue_os_release', type => 'string' },
	{ id => 'architecture', label => 'catalogue_architecture',
	  type => 'string' },
	{ id => 'format', label => 'image_format', type => 'string' },
	{ id => 'size', label => 'catalogue_download_size', type => 'bytes' },
	{ id => 'checksum', label => 'image_verification', type => 'string' },
	{ id => 'release_date', label => 'catalogue_release_date',
	  type => 'string' },
	{ id => 'end_of_life', label => 'catalogue_end_of_life',
	  type => 'string' },
	{ id => 'origin', label => 'catalogue_origin', type => 'string' },
	{ id => 'state', label => 'index_state', type => 'string' },
	{ id => 'download', label => 'catalogue_download', type => undef },
);
}

# get_catalogue_columns([value])
# Filters a stored column list; missing or invalid settings use all columns.
# value is a comma- or whitespace-separated list of IDs; name always remains.
sub get_catalogue_columns
{
my ($value) = @_;
my @defs = list_catalogue_columns();
my %wanted = map { $_ => 1 } split(/[,\s]+/, $value || '');
my @columns = grep { $wanted{$_->{'id'}} } @defs;
# An empty or unrecognized selection uses the complete default table.
return @defs if (!@columns);
$wanted{'name'} = 1;
return grep { $wanted{$_->{'id'}} } @defs;
}

# catalogue_link(url, [label])
# Shows the full URL, or a compact download button when a label is supplied.
sub catalogue_link
{
my ($url, $label) = @_;
# Optional publisher links should not produce empty anchors.
return '' if (!$url);
return ui_tag('a', defined($label)
	? ui_svg_icon('download').' '.html_escape($label)
	: html_escape($url),
	{ href => $url, target => '_blank', rel => 'noopener noreferrer',
	  defined($label) ? (class => 'ui_link', download => '') : () });
}

# describe_architecture([architecture])
# Returns a short human-readable CPU architecture label.
sub describe_architecture
{
my ($architecture) = @_;
# Translate the common libvirt names to the labels used throughout the
# UI.
return 'x86-64' if (($architecture || '') eq 'x86_64');
return 'ARM64' if (($architecture || '') eq 'aarch64');
return 'ARMv7' if (($architecture || '') eq 'armv7l');
return $architecture || $text{'index_unknown'};
}

# get_vm_row(server, [token])
# Returns a table row from a normalized guest record, escaping its text fields.
# A signed token enables lifecycle controls for callers with write access.
sub get_vm_row
{
my ($server, $token) = @_;
my $state = $server->{'state'} || 'unknown';
# Highlight attention states and give stopped guests a neutral badge.
my %badge_states = (
	'running' => 'success',
	'paused' => 'warning',
	'blocked' => 'warning',
	'shutdown' => 'info',
	'shutoff' => 'neutral',
	'crashed' => 'danger',
	'pmsuspended' => 'warning',
);
# Use visible fallback text for unknown states and missing addresses.
my $state_text = $text{'index_state_'.$state} ||
	$text{'index_state_unknown'};
my $macs = @{$server->{'macs'} || []}
	? join(', ', @{$server->{'macs'}}) : '-';
my @ips = map { ui_tag('tt', html_escape($_->{'address'})) }
	@{$server->{'addresses'} || []};
my $autostart = !defined($server->{'autostart'}) ? $text{'index_unknown'}
	: $text{$server->{'autostart'} ? 'index_yes' : 'index_no'};
my $controls = '';
if ($token && $server->{'uuid'}) {
	# Each row submits one UUID and only the action the user clicked.
	# The boot toggle inherits the widget palette's red off-state color.
	my $form = ui_form_start('index.cgi', 'post', undef,
		'style="display:inline; --ui-toggle-bg:var(--ui-danger)"').
		ui_hidden('id', $server->{'uuid'}).ui_hidden('token', $token);
	# Standard buttons keep Pause styled without link conversion.
	# Initial rows and live templates share these icons and permitted actions.
	my %icons = (start => 'play', shutdown => 'power', reboot => 'refresh',
		suspend => 'pause', resume => 'play');
	my @actions = !$server->{'active'} ? ('start')
		: $state =~ /\A(?:running|blocked)\z/ ? ('shutdown', 'reboot', 'suspend')
		: $state eq 'paused' ? ('resume')
		: ();
	# Keep the controls on one line as live resource values resize the table.
	# Leave the cell empty when the current state has no supported action.
	$controls = ui_tag('div', join('', map {
		$form.ui_hidden('action', $_).
			ui_action_button($text{'vm_control_'.$_}, 'neutral',
				{type => 'submit', size => 'small', icon => $icons{$_}}).
			ui_form_end()
		} @actions), {class => 'ui_cluster', style => 'flex-wrap:nowrap'})
		if (@actions);
	if ($server->{'persistent'} && defined($server->{'autostart'})) {
		# Submit an explicit value for both the on and off toggle
		# states.
		$autostart = $form.ui_hidden('action', 'autostart').
			ui_hidden('enabled', $server->{'autostart'} ? 1 : 0).
			ui_toggle({ 'id' => 'cloudmin-boot-'.$server->{'uuid'},
				'checked' => $server->{'autostart'},
				'state' => 'success',
				'round' => 1,
				'attrs' => {
					'aria-label' => $text{'vm_start_at_boot'}.': '.$server->{'name'},
					'onchange' => 'this.form.elements.enabled.value = this.checked ? 1 : 0; this.form.requestSubmit();',
				} }).ui_form_end();
		}
	}

# Capacities remain readable while the live channel fills in usage
# values.
return [
	$server->{'uuid'}
	? ui_link('machine.cgi?id='.urlize($server->{'uuid'}),
	html_escape($server->{'name'}),
		undef, 'data-vm-id="'.html_escape($server->{'uuid'}).'"')
		: html_escape($server->{'name'}),
	ui_cluster([
		ui_badge($state_text, $badge_states{$state} || 'neutral',
			{ 'small' => 1, 'rounded' => 1 }),
		ui_tag('a', ui_badge($text{'vm_pending_badge'}, 'warning',
			{ small => 1, rounded => 1, icon => 'power' }),
			{ href => 'machine.cgi?id='.urlize($server->{'uuid'} || ''),
			'data-vm-pending-badge' => '',
			(keys %{$server->{'pending'} || {}} ? () : (hidden => undef)) })
		], { gap => '.4em' }),
	@ips ? join('<br>', @ips) : html_escape($text{'index_no_ips'}),
	show_resource_placeholder('cpu', $server->{'vcpus'} || 0),
	show_resource_placeholder('memory',
	nice_size_text(($server->{'memory_kib'} || 0) * 1024)),
	show_resource_placeholder('disk'),
	html_escape($macs),
	$server->{'persistent'} ? $text{'index_yes'} : $text{'index_no'},
	$autostart,
	($token ? $controls : ()),
];
}

# show_resource_placeholder(field, [total]) shows capacity while usage loads.
sub show_resource_placeholder
{
my ($field, $total) = @_;
return ui_tag('span', html_escape(defined($total)
	? text('vm_usage_missing', $total) : $text{'vm_usage_unavailable'}),
	{ 'data-vm-resource' => $field, title => $text{'vm_usage_'.$field} });
}

# nice_size_text([bytes])
# Formats bytes as plain text for widgets that escape their own content.
sub nice_size_text
{
my ($bytes) = @_;
return html_strip(nice_size($bytes || 0));
}

1;
