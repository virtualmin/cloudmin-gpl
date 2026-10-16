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

# show_jobs_page(data)
# Wraps live progress and recovery controls with a connection warning.
sub show_jobs_page
{
my ($data) = @_;
return ui_page_start().ui_tag_start('div', {
	id => 'cloudmin-jobs', 'data-url' => $data->{'refresh_url'},
}).ui_tag('div', ui_alert_box($text{'jobs_updates_unavailable'},
	'warn', undef, undef, ''), { 'data-jobs-warning' => 1, hidden => undef }).
	ui_tag('div', show_jobs_status($data), { 'data-jobs-content' => 1 }).
	ui_tag_end('div').ui_page_end();
}

# show_jobs_status(data)
# Renders a quiet empty state or current job progress using Webmin widgets.
sub show_jobs_status
{
my ($data) = @_;
my $html = join('', map {
	ui_alert_box(html_escape($_), 'danger', undef, undef, '')
	} @{$data->{'errors'} || []});
# A failed store must never look like a successfully loaded empty queue.
if (!@{$data->{'jobs'} || []}) {
	return $html.ui_empty_state({
		icon => @{$data->{'errors'} || []} ? 'warning' : 'check-circle',
		title => $text{@{$data->{'errors'} || []}
			? 'jobs_unavailable' : 'jobs_empty'},
		desc => @{$data->{'errors'} || []} ? undef : $text{'jobs_empty_desc'},
		actions => $data->{'log_url'} ? ui_action_button($text{'log_title'}, 'neutral',
			{ href => $data->{'log_url'}, icon => 'history', size => 'small' }) : undef,
	});
	}
my @rows;
foreach my $job (@{$data->{'jobs'}}) {
	my ($state, $done, $total);
	if ($job->{'type'} eq 'image') {
		# Percentages describe the current transfer, not the whole import.
		$state = $job->{'state'} eq 'verifying' ? describe_image_check($job)
			: $text{'images_job_'.$job->{'state'}} || $job->{'state'};
		($done, $total) = $job->{'state'} eq 'importing'
			? @$job{qw(transferred bytes)}
			: $job->{'state'} eq 'downloading' ? @$job{qw(bytes total)} : ();
		}
	else {
		# VM operations expose their current step without an invented percentage.
		$state = $job->{'state'} eq 'running' && $job->{'phase'}
			? $text{'vm_phase_'.$job->{'phase'}} : undef;
		$state = $text{'vm_phase_start_stopped'}
			if ($job->{'state'} eq 'running' &&
			($job->{'phase'} || '') eq 'start' && !$job->{'start'});
		$state ||= $text{'jobs_state_'.$job->{'state'}} || $job->{'state'};
		$state =~ s/ \.\.$//;
		}
	# Cancellation has no measurable remaining transfer.
	my $cancelling = $job->{'cancel'} &&
		$job->{'state'} !~ /\A(?:complete|failed|cancelled|ready|deleted|interrupted)\z/;
	# Cancellation has no measurable completion fraction while cleanup runs.
	if ($cancelling) {
		$state = $text{'jobs_cancelling'};
		$total = undef;
		}
	my %progress = ( label => $state, indeterminate => !$total );
	$done ||= 0;
	if ($total) {
		# Clamp the display if the source's reported total changed during transfer.
		$done = $total if ($done > $total);
		$progress{'max'} = $total;
		$progress{'value'} = text('jobs_transfer', nice_size_text($done),
			nice_size_text($total), int(100 * $done / $total));
		}
	# Retained failures show their diagnostics beside the recovery controls.
	my $status = $job->{'cleanup_pending'}
		? ui_badge($text{'jobs_cleanup_pending'}, 'warning', { small => 1 }).
			join('', map { ui_tag('div', html_escape($_)) }
				grep { length($_ || '') } @$job{qw(error cleanup_warning audit_warning)})
		: ui_progress($done, \%progress);
	my $name = html_escape($job->{'name'});
	$name = ui_link('progress.cgi?job='.$job->{'id'}, $name)
		if ($job->{'type'} eq 'vm');
	my @controls;
	if ($data->{'can_control'} && $data->{'token'} && !$cancelling) {
		# Wait for cancellation to finish before offering another action.
		# Each button posts only its own action; polling never submits forms.
		my @actions = $job->{'cleanup_pending'}
			? ('recover', $job->{'operation'} eq 'update' ? ('discard') : ())
			: !$job->{'can_cancel'} ? ()
			: $job->{'operation'} eq 'create' ? ('cancel_cleanup', $job->{'software'} ? ('cancel') : ())
			: ('cancel');
		foreach my $action (@actions) {
			push(@controls, ui_form_start('jobs.cgi', 'post').
				ui_hidden('token', $data->{'token'}).ui_hidden('job', $job->{'id'}).
				ui_hidden('type', $job->{'type'}).ui_hidden('action', $action).
				ui_hidden('confirm', 1).
				ui_action_button($text{'jobs_action_'.$action},
				$action eq 'recover' ? 'warning' : $action eq 'discard' ? 'neutral' : 'danger', {
				size => 'small', icon => $action eq 'recover' ? 'refresh' : 'x',
				type => 'submit' }).ui_form_end(undef, undef, 1));
		}
	}
	push(@rows, [ $name,
		$text{'jobs_type_'.$job->{'type'}}, $status,
		make_date($job->{'created'}), ($data->{'can_control'} ? (ui_cluster(\@controls)) : ()) ]);
	}
# Keep column sizing independent of changing transfer sizes and phase labels.
my @columns = map { 'class="cloudmin-job-'.$_.'"' }
	(qw(name type progress started), $data->{'can_control'} ? ('actions') : ());
my $table = ui_columns_start([ $text{'index_name'}, $text{'jobs_type'},
	$text{'jobs_progress'}, $text{'jobs_started'}, ($data->{'can_control'} ? ($text{'jobs_actions'}) : ()) ], 100, 0, \@columns,
	undef, 0, 'cloudmin-jobs-table');
$table .= ui_columns_row($_, \@columns) foreach @rows;
$table .= ui_columns_end();
return $html.ui_p($text{'jobs_desc'}).
	ui_tag('div', $table, { class => 'cloudmin-jobs-scroll' });
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

# get_image_job_status(job)
# Returns translated progress text and byte counts, without private inputs.
sub get_image_job_status
{
my ($job) = @_;
my $state = $job->{'state'};
my $alive = !$job->{'pid'} || kill(0, $job->{'pid'});
# A killed worker cannot keep an import looking active indefinitely.
if ($state !~ /^(?:ready|failed|waiting|deleted)$/ &&
	((!$alive) || time() - $job->{'updated'} > 3700)) {
	$state = 'interrupted';
	}
my $detail = $job->{'error'} || '';
if ($state eq 'ready') {
	# Completed imports name the image and pool,
	# with a legacy volume fallback.
	$detail = text('images_ready_detail',
		$job->{'name'} || storage_volume_label({ name => $job->{'volume'} }), $job->{'pool_name'});
	}
elsif ($state eq 'interrupted') {
	# A dead or stale job needs recovery advice instead of transfer details.
	$detail = $text{'images_interrupted_detail'};
	}
elsif (!$detail) {
	# Preserve recorded failures; otherwise summarize current byte progress.
	$detail = text('images_progress_detail', $job->{'name'},
		$job->{'pool_name'}, nice_size_text($job->{'bytes'}));
	}
# Local captures have no upstream checksum against which to verify the image.
my $checksum = $text{($job->{'source'} || '') eq 'vm' ? 'images_checksum_local'
	: $job->{'verified'} ? 'images_verified'
	: 'images_not_verified'};
return {
	id => $job->{'id'}, state => $state,
	bytes => $job->{'bytes'} || 0, total => $job->{'total'} || 0,
	size => nice_size_text($job->{'bytes'} || 0),
	checksum => $checksum,
	checksum_html => html_escape($checksum),
	label => $state eq 'verifying' ? describe_image_check($job)
		: $text{'images_job_'.$state} || $state,
	detail => $detail,
	percent => $state eq 'importing' && $job->{'bytes'}
		? int(100 * ($job->{'transferred'} || 0) / $job->{'bytes'})
		: $state eq 'downloading' &&
		$job->{'total'} ? int(100 * $job->{'bytes'} / $job->{'total'})
		: $state eq 'ready' ? 100 : undef,
	terminal => $state =~ /^(?:ready|failed|interrupted|deleted)$/ ? 1 : 0,
};
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

# print_image_manager([mode]) displays the inventory, import or catalogue tab.
# mode accepts images, add or catalogue. Omit it to use the saved tab or images.
sub print_image_manager
{
my ($mode) = @_;
our $remote_user;
# Include module help and configuration controls in the Webmin page header.
ui_print_header(
	$text{'images_subtitle'},
	$text{'images_title'},
	'',
	'images',
	1,
	0,
);

# Imports continue independently of the browser. Reloading shows their status.
my $images = get_images_info();
my $jobs = get_image_jobs();
# Read-only views need no token and must not create a signing key or lock.
$images->{'token'} = $jobs->form_token($remote_user) if (!is_readonly_mode());
$images->{'jobs'} = $jobs->list();
# Restore navigation even for read-only viewers, but save only with a token.
$images->{'mode'} = inventory_tab('images', $mode);
$images->{'readonly'} = is_readonly_mode();
print show_images_page($images);
print inventory_tab_script('images', $images->{'token'});

# Retry failed imports through the shared attempt check.
print submission_script();
ui_print_footer('index.cgi', $text{'vm_return'});
}

# show_images_page(data)
# Uses the standard tab, checked-table and form APIs demonstrated by ui-demo.
sub show_images_page
{
my ($data) = @_;
my @jobs = @{$data->{'jobs'} || []};
my $page = ui_page_start();
# Retain catalogue failures above the usable image-management tabs.
$page .= ui_alert_box(html_escape($data->{'error'}), 'danger', undef, undef,
	'') if ($data->{'error'});
$page .= ui_tabs_start([
	[ 'images', $text{'images_tab_images'}, 'images.cgi' ],
	[ 'add', $text{'images_tab_add'}, 'image_form.cgi' ],
	[ 'catalogue', $text{'catalogue_title'}, 'images.cgi?mode=catalogue' ],
], 'mode', ($data->{'mode'} || '') =~ /\A(?:add|catalogue)\z/
	? $data->{'mode'} : 'images', 1);

# Keep all imports, including unfinished downloads, in one checked table.
$page .= ui_tabs_start_tab('mode', 'images');
$page .= ui_tag('div', ui_p(html_escape($text{'images_manage_desc'})),
	{ 'class' => 'vui_ui_block' });
my %volumes = map {
	my $pool = $_;
	map { ($pool->{'id'}.':'.$_->{'name'}) => $_ }
		@{$pool->{'volumes'} || []}
	} @{$data->{'pools'} || []};
my @rows;
foreach my $job (@jobs) {
	my $s = get_image_job_status($job);
	if ($s->{'state'} eq 'ready' &&
		!$volumes{$job->{'pool'}.':'.$job->{'volume'}}) {
		# Completed metadata can outlive a volume removed outside
		# Cloudmin.
		$s->{'label'} = $text{'images_job_missing'};
		}
	# Keep paths and failure details under the expandable image name.
	my $details =
		show_image_path($job->{'volume_path'} || $job->{'volume'});
	# Local captures have no publisher checksum; identify their origin instead.
	$details .= ui_p(html_escape($text{'images_capture_source'}))
		if (($job->{'source'} || '') eq 'vm');
	my $error = $s->{'state'} =~ /^(?:failed|interrupted)$/ ? $s->{'detail'}
		: '';
	# Polling updates the error as text without treating it as HTML.
	$details .= ui_tag('div', ui_tag('span', html_escape($error),
		{ 'data-image-error' => $job->{'id'},
		$error ? () : (hidden => undef) }));
	my $name = ui_details({ html => 1, class => 'inline inlined',
		title => html_escape($job->{'name'}), content => $details });
	my $status = ui_tag('span', html_escape($s->{'label'}),
		{ 'data-image-state' => $job->{'id'},
		  'data-image-active' => $s->{'terminal'} ? 0 : 1 });
	# Stable job IDs let polling update values without replacing selected
	# rows. Read-only users see the inventory without selection controls.
	push(@rows, [
		$data->{'readonly'} ? ''
		: { type => 'checkbox', name => 'job', value => $job->{'id'} },
		$name, $status, html_escape($job->{'pool_name'}),
		html_escape(uc($job->{'format'})),
		ui_tag('span', nice_size($job->{'bytes'} || 0),
			{ 'data-image-size' => $job->{'id'} }),
		make_date($job->{'created'}),
		ui_tag('span', $s->{'checksum_html'},
		{ 'data-image-checksum' => $job->{'id'} }),
	]);
	}
# Filter optional columns while retaining bulk selection and job identity.
my ($image_heads, $image_rows, $image_types) =
	table_columns('image_columns', \@rows, 1);
# Bulk deletion posts the selected job IDs with this page's signed token.
$page .= ui_form_columns_table('delete_images.cgi',
	$data->{'readonly'} ? []
	: [ [ 'delete', $text{'images_delete_button'} ] ],
	$data->{'readonly'} ? 0 : 1,
	undef,
	[ [ 'token', $data->{'token'} ] ],
	$image_heads, 100, $image_rows, $image_types,
	0, undef, $text{'images_saved_none'}, 0, 1);
$page .= ui_tabs_end_tab('mode', 'images');

# Sources share storage and advanced settings, with only relevant fields shown.
$page .= ui_tabs_start_tab('mode', 'add');
$page .= ui_tag('div', ui_p(html_escape($text{'images_add_desc'})),
	{ 'class' => 'vui_ui_block' });
my @pools = @{$data->{'pools'} || []};
# Prefer the configured pool when available; keep the form's choice editable.
my $pool = image_import_pool(\@pools);
# Use the same distribution order as creation and template image selectors.
my @sorted = @{Cloudmin::ImageChoices::sort_images($data->{'images'} || [])};
# Custom entries share a generic icon and follow the bundled distributions.
my @bundled = grep { ($_->{'catalogue_origin'} || '') ne 'custom' } @sorted;
my @custom = grep { ($_->{'catalogue_origin'} || '') eq 'custom' } @sorted;
# Read-only pages show cached sizes without requesting a refresh.
my @options = map { get_image_option({ %$_,
	download_size_refresh => $data->{'readonly'} ? 0
	: $_->{'download_size_refresh'} // 1 })
} (@bundled, @custom);
my $bundled = !grep { ($_->{'catalogue_origin'} || 'bundled') ne 'bundled' }
	@{$data->{'images'} || []};
# Custom entries use administrator-supplied URLs, not the bundled sources.
my $download_note = text($bundled ? 'images_download_note'
	: 'images_catalogue_note',
	ui_tag('a', html_escape($text{'images_sources_link'}), {
		href => 'images.cgi?mode=catalogue',
			id => 'cloudmin-image-sources',
			class => 'text-link' }));
$page .= ui_form_start('setup_image.cgi', 'post', undef,
	'id="cloudmin-image-form"');
$page .= ui_hidden('token', $data->{'token'} || '');
$page .= ui_table_start(undef, 'width=100%', 2);
# Storage pool and image source each span the full form width.
$page .= ui_table_row($text{'images_storage'}, @pools
	? ui_select('pool', $pool, [ map { [ $_->{'id'},
		text('images_pool_option', $_->{'name'},
		nice_size_text($_->{'available'})) ] } @pools ])
	: ui_alert_box(html_escape($data->{'storage_error'} ||
	$text{'images_storage_none'}), 'danger', undef, undef, ''),
	1, undef, undef, 1);
$page .= ui_table_hr();
$page .= ui_table_row($text{'images_installation_type'},
	ui_select('install_type', 'download', [ map {
		[ $_, $text{'images_type_'.$_} ] }
			qw(download url upload local) ]),
	1, undef, undef, 1);
# Show the selected source's controls directly below the source selector.
my @sources = (
	[ 'download', undef, 'id', ui_multi_select_list('id', [], \@options,
		{ search => 1, compact => 1, bulk => 0, count => 0,
		  height => '420px',
		  summary => $text{$bundled ? 'images_bundled_cloud'
		: 'images_cloud'},
		  summary_icon => 'download',
		  empty_label => $text{'images_no_compatible'} }) ],
	[ 'url', $text{'images_url'}, 'url', ui_textbox('url', '', 65).
		ui_tag('span', $text{'images_url_hint'},
			{ style => 'font-size:inherit;opacity:0.66;margin-inline:0.3em' }) ],
	[ 'upload', $text{'images_file'}, 'image_file',
	  ui_upload('image_file', 45) ],
	[ 'local', $text{'images_path'}, 'path', ui_textbox('path', '', 65).
		file_chooser_button('path', 0, @jobs ? 1 : 0) ],
);
foreach my $source (@sources) {
	my ($type, $label, $field, $input) = @$source;
	$page .= ui_table_row($label, $input, defined($label) ? 1 : 2, undef,
		[ 'id="cloudmin-image-'.$type.'"'.
		($type eq 'download' ? '' : ' style="display:none"') ], 1);
	}
$page .= ui_table_end();
# Show a total only after images are selected, without adding a selection count.
$page .= ui_tag('div', '', { id => 'cloudmin-download-total',
	class => 'ui_note', 'aria-live' => 'polite', hidden => undef });
# Hide and disable fields belonging to other image sources.
foreach my $source (@sources) {
	my ($type, $label, $field) = @$source;
	$page .= ui_form_field_state_javascript('install_type', [ $type ],
		[ 'cloudmin-image-'.$type ], [ $field ]);
	}
# Format and digest controls apply to user-supplied image sources.
$page .= ui_tag_start('div', { id => 'cloudmin-custom-options',
	hidden => undef });
# Expansion is configurable; catalogue sources still hide these custom options.
$page .= ui_hidden_table_start($text{'images_advanced'}, 'width=100%', 2,
	'image_advanced', ($config{'image_advanced'} || '') eq '1');
$page .= ui_table_row($text{'image_format'}, ui_select('format', 'qcow2',
	[ [ 'qcow2', 'QCOW2' ], [ 'raw', $text{'images_format_raw'} ],
	  [ 'iso', $text{'images_format_iso'} ] ]));
$page .= ui_table_row($text{'images_sha256'}, ui_textbox('sha256', '', 65));
$page .= ui_hidden_table_end('image_advanced').ui_tag_end('div');
# Start with QCOW2 help; images.js updates it when the format changes.
$page .= ui_tag('p',
	ui_tag('span', $download_note, { id => 'cloudmin-image-note' }).
	ui_tag('span', html_escape(text('images_custom_note', 'QCOW2')),
		{ id => 'cloudmin-image-custom-note', hidden => undef }));
# Show the same administrator cap used by every import source and the browser.
my $maximum = $data->{'max_image_bytes'} || 0;
$page .= ui_note($maximum ? text('images_limit_note', nice_size_text($maximum))
	: $text{'images_space_note'});
# Browser uploads display transfer progress before opening the job's progress
# page.
$page .= ui_tag('div', ui_tag('span', '', { id => 'cloudmin-image-error', role => 'alert',
	hidden => undef }));
$page .= ui_tag('div', ui_progress(0, { label => $text{'images_uploading'} }),
	{ id => 'cloudmin-upload-progress', hidden => undef });
# Read-only users can review the sources but cannot start an import.
$page .= ui_form_end(@pools &&
	!$data->{'readonly'} ? [ [ undef, $text{'images_download'}, undef, 0,
	'id="cloudmin-image-submit"' ] ] : []);
$page .= ui_tabs_end_tab('mode', 'add');
$page .= ui_tabs_start_tab('mode', 'catalogue');
# The image table is wrapped in a form only when it has rows, which moves the
# catalogue form's position in document.forms used by its selection links.
$data->{'catalogue_formno'} = @rows ? 2 : 1;
$page .= show_catalogue_page($data);
$page .= ui_tabs_end_tab('mode', 'catalogue').ui_tabs_end(1);

# Supply translated help and progress labels to the browser's import controls.
my %labels = (id => 'cloudmin-image-labels', hidden => undef);
foreach my $key (qw(download import start_error poll_error choose_file
		   custom_note iso_note format_raw
		   upload_limit download_estimate download_partial
		   download_unknown download_size_unknown download_size_hint)) {
	$labels{'data-'.($key =~ s/_/-/gr)} = html_escape($text{'images_'.$key});
	}
$labels{'data-max-bytes'} = $maximum;
$labels{'data-upload-limit'} = html_escape($maximum
	? text('images_upload_limit', nice_size_text($maximum))
	: $text{'images_upload_empty'});
$page .= ui_tag('div', '', \%labels).
	ui_tag('script', '', { src => 'images.js?'.
		((stat(($module_root_directory || '.').'/images.js'))[9] || 0) }).ui_page_end();
return $page;
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

# show_catalogue_page(data)
# Lists catalogue_entries from data with links and bulk controls. The caller
# applies the configured architecture filter before passing the entries here.
sub show_catalogue_page
{
my ($data) = @_;
my $readonly = $data->{'readonly'};
my @columns = get_catalogue_columns($data->{'catalogue_columns'});
my $page = ui_tag('div', ui_p(html_escape($text{'catalogue_desc'})),
	{ class => 'vui_ui_block' });
my @rows;
foreach my $entry (@{$data->{'catalogue_entries'} || []}) {
	my $key = $entry->{'catalogue_key'};
	my $name = ui_tag('a', html_escape($entry->{'name'}),
		{ href => 'edit_catalog_image.cgi?key='.urlize($key) });
	# Catalogue metadata describes availability, not a completed checksum
	# check.
	my $checksum = html_escape($text{$entry->{'checksum_url'}
		? 'catalogue_checksum_available'
		: 'catalogue_checksum_unavailable'});
	# Keep external downloads together without expanding long URLs in the
	# table.
	my $downloads = join(' ', grep { length } (
		catalogue_link($entry->{'url'}, $text{'images_name'}),
		catalogue_link($entry->{'checksum_url'},
		$text{'image_verification'})));
	# Preserve the byte count for numeric sorting across MiB and GiB values.
	my $bytes = $entry->{'download_size_bytes'};
	my %cells = (
		name => $name,
		os => html_escape($entry->{'os'}.' '.$entry->{'release'}),
		architecture => html_escape(
			describe_architecture($entry->{'architecture'})),
		format => html_escape(uc($entry->{'format'})),
		checksum => $checksum,
		size => { type => 'string', value => $bytes
			? ui_tag('span', html_escape(nice_size_text($bytes)),
				{ 'data-filesize-bytes' => $bytes,
				  title => $text{'images_download_size_hint'} })
			: $text{'catalogue_unknown'},
			td => 'data-order="'.($bytes || -1).'"' },
		release_date => html_escape($entry->{'release_date'} || ''),
		end_of_life => html_escape($entry->{'end_of_life'} || ''),
		origin => $text{'catalogue_origin_'.
		$entry->{'catalogue_origin'}},
		state => $text{$entry->{'enabled'} ? 'catalogue_enabled'
		: 'catalogue_disabled'},
		download => $downloads,
	);
	push(@rows,
		[ $readonly ? ''
		: { type => 'checkbox', name => 'key', value => $key },
		  map { $cells{$_->{'id'}} } @columns ]);
	}
# Preserve column order and omit editing controls for read-only users.
$page .= ui_form_columns_table('catalogue.cgi', $readonly ? [] : [
	[ 'enable', $text{'catalogue_enable'} ],
	[ 'disable', $text{'catalogue_disable'} ],
	[ 'delete', $text{'catalogue_delete_button'} ],
], !$readonly,
$readonly ? []
: [ [ 'edit_catalog_image.cgi?new=1', $text{'catalogue_add_button'} ] ],
	[ [ 'token', $data->{'token'} || '' ] ],
	[ '', map { $text{$_->{'label'}} } @columns ],
	100, \@rows, [ undef, map { $_->{'type'} } @columns ],
	0, undef, $text{'catalogue_none'}, $data->{'catalogue_formno'} // 2, 1);
return $page;
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

# show_catalogue_form(entry, new, token, [error], [readonly])
# Builds the standard Webmin editor for one image architecture and its URLs.
sub show_catalogue_form
{
my ($entry, $new, $token, $error, $readonly) = @_;
if ($readonly) {
	# Supplied entries and read-only sessions expose details without an
	# editor.
	my $page = ui_table_start(undef, 'width=100%', 2);
	$page .= ui_table_row($text{'catalogue_origin'},
		$text{'catalogue_origin_'.$entry->{'catalogue_origin'}});
	foreach my $field (qw(name vendor os release architecture)) {
		# Omit metadata the publisher has not supplied.
		next if (!defined($entry->{$field}) || $entry->{$field} eq '');
		$page .= ui_table_row($text{'catalogue_'.$field},
			html_escape($field eq 'architecture'
			? describe_architecture($entry->{$field})
			: $entry->{$field}));
		}
	# Detail views expose the publisher URLs so users can inspect the
	# sources.
	foreach my $pair ([ 'url', 'catalogue_image_url' ],
		[ 'checksum_url', 'catalogue_checksum_url' ],
		[ 'checksum_algorithm', 'catalogue_checksum_algorithm' ],
		[ 'format', 'image_format' ],
		[ 'source_url', 'catalogue_source_url' ],
		[ 'status', 'catalogue_status' ],
		[ 'firmware', 'catalogue_firmware' ],
		[ 'release_date', 'catalogue_release_date' ],
		[ 'end_of_life', 'catalogue_end_of_life' ]) {
		my ($field, $label) = @$pair;
		# Unknown metadata must not appear as an empty detail row.
		next if (!defined($entry->{$field}) || $entry->{$field} eq '');
		my $value = $entry->{$field};
		# Status keys need translated labels, unlike publisher metadata.
		$value = $text{'catalogue_status_'.$value} || $value
			if ($field eq 'status');
		# Uppercase technical abbreviations for display only.
		$value = uc($value)
			if ($field =~ /\A(?:checksum_algorithm|format|firmware)\z/);
		$page .= ui_table_row($text{$label}, $field =~ /url\z/
			? catalogue_link($value) : html_escape($value));
		}
	# Disk capacity and transfer size remain separate quantities in the
	# details.
	$page .= ui_table_row($text{'catalogue_min_disk'},
		$entry->{'min_disk_bytes'}
		? html_escape(($entry->{'min_disk_bytes'} / 1024**3).' GiB')
		: $text{'catalogue_unknown'});
	$page .= ui_table_row($text{'images_download_size'},
		$entry->{'download_size_bytes'}
		? html_escape(nice_size_text($entry->{'download_size_bytes'}))
		: $text{'catalogue_unknown'});
	foreach my $field (qw(cloud_init guest_agent)) {
		# Unknown support differs from a publisher's explicit negative
		# answer.
		next if (!defined($entry->{$field}));
		$page .= ui_table_row($text{'catalogue_'.$field},
			$text{$entry->{$field} ? 'index_yes' : 'index_no'});
		}
	return $page.ui_table_end();
	}
my $page = $error
	? ui_alert_box(html_escape($error), 'danger', undef, undef, '') : '';
# Custom entries retain their ID and architecture across edits.
$page .= ui_form_start('save_catalog_image.cgi', 'post');
$page .= ui_hidden('token', $token || '').ui_hidden('new', $new ? 1 : 0);
$page .= ui_hidden('id', $entry->{'id'});
$page .= ui_table_start(undef, 'width=100%', 2);
foreach my $field (qw(name vendor os release)) {
	$page .= ui_table_row($text{'catalogue_'.$field},
		ui_textbox($field, $entry->{$field} || '', 60));
	}
$page .= ui_table_row($text{'catalogue_architecture'}, $new
	? ui_textbox('architecture', $entry->{'architecture'} || '', 20)
	: html_escape(describe_architecture($entry->{'architecture'})).
	  ui_hidden('architecture', $entry->{'architecture'}));
# Keep format, download URL and digest settings together for custom assets.
$page .= ui_table_row($text{'image_format'},
	ui_select('format', $entry->{'format'} || 'qcow2',
	[ [ 'qcow2', 'QCOW2' ], [ 'raw', $text{'images_format_raw'} ],
	  [ 'iso', $text{'images_format_iso'} ] ]));
foreach my $field (qw(url checksum_url)) {
	$page .= ui_table_row($text{$field eq 'url' ? 'catalogue_image_url'
		: 'catalogue_checksum_url'},
		ui_textbox($field, $entry->{$field} || '', 80));
	}
$page .= ui_table_row($text{'catalogue_checksum_algorithm'},
	ui_select('checksum_algorithm',
	$entry->{'checksum_algorithm'} || 'sha256',
	[ [ 'sha256', 'SHA-256' ], [ 'sha512', 'SHA-512' ] ]));
$page .= ui_table_end();
$page .= ui_hidden_table_start($text{'images_advanced'}, 'width=100%', 2,
	'catalogue_advanced', 0);
# Optional metadata controls support grouping and guest compatibility checks.
$page .= ui_table_row($text{'catalogue_source_url'},
	ui_textbox('source_url', $entry->{'source_url'} || '', 80));
$page .= ui_table_row($text{'catalogue_status'},
	ui_select('status', $entry->{'status'} || 'supported',
	[ map { [ $_, $text{'catalogue_status_'.$_} ] }
	qw(recommended supported older) ]));
foreach my $field (qw(release_date end_of_life)) {
	$page .= ui_table_row($text{'catalogue_'.$field},
		ui_textbox($field, $entry->{$field} || '', 12, 0, 10,
		'placeholder="YYYY-MM-DD"'));
	}
my $disk = exists($entry->{'min_disk_gib'}) ? $entry->{'min_disk_gib'}
	: ($entry->{'min_disk_bytes'} || 0) / 1024**3;
# Preserve the Unknown selection when redisplaying a submitted form.
$disk = '' if ($entry->{'min_disk_gib_def'});
$page .= ui_table_row($text{'catalogue_min_disk'},
	ui_opt_textbox('min_disk_gib', $disk || '', 10,
	$text{'catalogue_unknown'}).' GiB');
$page .= ui_table_row($text{'catalogue_firmware'},
	ui_select('firmware', $entry->{'firmware'} || '',
	[ [ '', $text{'catalogue_unspecified'} ], [ 'bios', 'BIOS' ],
	  [ 'uefi', 'UEFI' ],
	  [ 'uefi-or-bios', 'UEFI or BIOS' ] ]));
$page .= ui_table_row($text{'catalogue_cloud_init'},
	ui_yesno_radio('cloud_init', $entry->{'cloud_init'} ? 1 : 0));
$page .= ui_table_row($text{'catalogue_guest_agent'},
	ui_yesno_radio('guest_agent', $entry->{'guest_agent'} ? 1 : 0));
$page .= ui_hidden_table_end('catalogue_advanced');
$page .= ui_form_end($readonly ? [] : [ [ undef,
	$text{$new ? 'catalogue_create' : 'catalogue_save'} ] ]);
return $page;
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

# get_image_option(image, [today])
# Returns a grouped download choice with compact metadata. today defaults to
# the current UTC date, in YYYY-MM-DD form.
sub get_image_option
{
my ($image, $today) = @_;
my @date = gmtime();
$today ||= sprintf('%04d-%02d-%02d', $date[5]+1900, $date[4]+1, $date[3]);
my $end = $image->{'end_of_life'} || '';
my $dated = $end =~ /^\d{4}-\d{2}-\d{2}$/;
my $expired = $dated && $end lt $today;
my %support_states = ( recommended => 'success', supported => 'warning',
	older => 'danger' );
# A known expired date takes precedence over stale catalogue recommendations.
my $status = $expired ? 'older' : $image->{'status'} || 'supported';
# Unrecognized publisher status must still have a defined badge palette.
$status = 'supported' if (!exists($support_states{$status}));
# Download bytes describe the transferred file, not the guest disk capacity.
my @metadata = ({
	label => $image->{'download_size_bytes'}
		? nice_size_text($image->{'download_size_bytes'})
		: $text{'images_download_size_unknown'},
	icon => 'download', title => $text{'images_download_size_hint'},
	state => $support_states{$status},
});
# The toolbar identifies bundled images; label custom entries separately.
push(@metadata, { label => $text{'catalogue_origin_custom'}, icon => 'edit' })
	if (($image->{'catalogue_origin'} || '') eq 'custom');
# Only real catalogue dates may claim support has ended; older is not EOL.
if ($dated) {
	my $key = $expired ? 'images_support_ended' : 'images_support_until';
	my $title = text($key, $end);
	# Distinguish an estimated support date from a confirmed publisher date.
	$title .= '. '.$text{'images_support_planned'}
		if ($image->{'end_of_life_planned'});
	push(@metadata, { label => text($key, substr($end, 0, 4)),
		title => $title, icon => $expired ? 'warning' : 'clock',
		state => $support_states{$status} });
	}
else {
	# Rolling releases need updates, but have no fixed support deadline.
	my $rolling = ($image->{'release'} || '') eq 'rolling';
	push(@metadata,
		{ label => $text{$rolling ? 'images_support_rolling'
		: 'images_support_unknown'},
		  title => $text{$rolling ? 'images_support_rolling_hint'
		: 'images_support_unknown'},
		  icon => 'clock', state => $support_states{$status} });
	}
# Pass the logo and download data to the browser; custom entries share a group.
return { value => $image->{'id'}, label => $image->{'name'}, status => $status,
	attrs => { 'data-download-id' => $image->{'id'},
		'data-image-icon' => get_image_icon($image),
		'data-download-bytes' => $image->{'download_size_bytes'} || '',
		'data-download-refresh' =>
			$image->{'download_size_refresh'} // 1 },
	group => { label => ($image->{'catalogue_origin'} || '') eq 'custom'
		? $text{'catalogue_origin_custom'} : get_image_group($image) },
	metadata => \@metadata };
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

# get_action_log_url([vm])
# Returns the action-log URL, optionally filtered by the selected guest's name.
sub get_action_log_url
{
my ($vm) = @_;
my $url = '/webminlog/search.cgi?uall=1&mall=0&module=server-manager'.
	'&tall=1&fall=1&no_return=1&nmod=server-manager&search_title='.
	urlize($text{$vm ? 'log_vm_title' : 'log_title'});
# Webmin searches the formatted description, just as Virtualmin does.
$url .= '&desc='.urlize($vm->{'name'}).'&search_sub_title='.
	urlize(html_escape($vm->{'name'})) if ($vm);
return $url;
}

# get_menu_items(servers, selected, readonly, terminal_available,
#                [log_available])
# Places selected-guest actions above a divider and host-wide tools below it.
# servers must already be filtered by VM assignments. terminal_available is
# accepted for compatibility; authorized connection pages explain missing tools.
# log_available defaults to false; logs also require host administrator access.
sub get_menu_items
{
my ($servers, $selected, $readonly, $terminal, $log) = @_;
my ($vm) = grep { $_->{'uuid'} eq ($selected || '') } @$servers;
$vm ||= $servers->[0];
my $base = '/server-manager';
# Include the title for frame navigation and the format flag for newer renderers.
my @items = ({ type => 'title', id => 'title', desc => $text{'index_title'} },
	{ format => 'new' }, { type => 'hr' });
# Host managers can create a guest even when their inventory is empty.
if (!$readonly && can_access('manage')) {
	push(@items, { type => 'item', format => 'link-new',
		desc => $text{'vm_create'}, link => "$base/machine_form.cgi" },
		{ type => 'hr' });
	}
# Show only permitted controls for the selected guest.
if ($vm) {
	my $id = urlize($vm->{'uuid'});
	push(@items, { type => 'menu', name => 'sid', cgi => '',
		value => $vm->{'uuid'}, onchange => "$base/machine.cgi?id=",
		menu => [ map { [ $_->{'uuid'}, html_escape($_->{'name'}),
			'title="'.html_escape($_->{'name'}).'"' ] }
			@$servers ] },
		{ type => 'item', desc => $text{'vm_details'},
		  link => "$base/machine.cgi?id=$id" });
	# Route users without host access straight to the password-reset form.
	push(@items, { type => 'item', desc => $text{'vm_edit'},
		link => "$base/edit_machine.cgi?id=$id".
			(can_access('manage') ? '' : '&password_reset=1') })
		if (!$readonly && (can_access('manage') || can_access('password', $vm->{'uuid'})));
	push(@items, { type => 'item', desc => $text{'snapshots_title'},
		link => "$base/snapshots.cgi?id=$id" }) if (can_access('host'));
	# Any permitted access method shows Remote Access; read-only mode hides it.
	# The page checks each tab's permission separately.
	push(@items, { type => 'item', desc => $text{'console_title'},
		link => "$base/remote_access.cgi?id=$id" }) if (!$readonly &&
		(can_access('terminal', $vm->{'uuid'}) || can_access('console', $vm->{'uuid'}) ||
			(defined(&can_vm_webmin) && can_vm_webmin($vm->{'uuid'}))));
	# Log searches can reveal host activity beyond assigned guests.
	push(@items, { type => 'item', desc => $text{'log_vm_title'},
		link => get_action_log_url($vm) }) if ($log && can_access('host'));
	}
# Separate guest actions from host tools; an empty host already has a divider.
push(@items, { type => 'hr' }) if ($vm);
foreach my $entry ([index => 'left_overview'], [images => 'left_images'],
	[storage => 'left_storage'], [networks => 'net_title'],
	[snapshots => 'snapshots_all'], [backups => 'backups_title'], [jobs => 'index_jobs']) {
	# Delegated users get an overview of assigned VMs without links to host tools.
	next if ($entry->[0] ne 'index' && !can_access('host'));
	push(@items, { type => 'item', desc => $text{$entry->[1]},
		link => "$base/$entry->[0].cgi" });
	}
push(@items, { type => 'item', desc => $text{'log_title'},
	link => get_action_log_url() }) if ($log && can_access('host'));
# Reuse Virtualmin's category and the header's module configuration permissions.
push(@items, { type => 'cat', id => 'global_setting', desc => $text{'left_settings'},
	members => [
		(!$access{'noconfig'} && !$config{'noprefs'} ? ({ type => 'item',
			desc => $text{'left_config'}, link => '/config.cgi?server-manager' }) : ()),
		map { {type => 'item', desc => $text{$_->[1]}, link => "$base/$_->[0].cgi"} }
		[edit_newtmpl => 'presets_templates'], [edit_newplan => 'presets_plans'],
		(defined(&cloudmin_pro) && cloudmin_pro() ? (['pro/license' => 'license_title']) : ())] })
	if (can_access('host'));
return @items;
}

# submission_script() loads shared retry handling for background job forms.
sub submission_script
{
# Let the active theme render errors inserted after an asynchronous check.
return ui_tag('template', ui_alert_box(
    ui_tag('span', '', { 'data-submission-message' => 1 }),
    'danger', undef, undef, ''), { id => 'cloudmin-submission-alert' }).
    ui_tag('script', '', { src => get_webprefix().'/server-manager/submission.js?'.
    ((stat(($module_root_directory || '.').'/submission.js'))[9] || 0) });
}

# show_vm_resource_input_styles()
# Size resource and username fields to their contents, with room by unit menus.
sub show_vm_resource_input_styles
{
my $fields = ':is(#vm-create-form, #vm-edit-form) input';
return ui_tag('style', $fields.':is([data-vm-resource], [data-vm-autosize]) { '.
	'field-sizing:content; width:auto !important; min-width:30px !important; max-width:100%; '.
	'box-sizing:border-box; padding-inline:0.6em !important; } '.
	$fields.'[data-vm-resource] { text-align:center !important; } '.
	$fields.'[data-vm-resource="size"] { padding-inline:0.6em 0.7em !important; } '.
	'#vm-create-form .vm-resource-hint { font-size:inherit; opacity:0.66; margin-inline:0.3em; } '.
	'#vm-create-form .cloudmin-vm-image-picker select { field-sizing:content; '.
	'width:auto !important; min-width:0; max-width:100%; } '.
	'#vm-create-form .cloudmin-vm-image-picker > a { margin:0 !important; }');
}

# check_vm_username(username)
# Matches the account names accepted by VM creation.
sub check_vm_username
{
my ($username) = @_;
return defined($username) && !ref($username) &&
	$username =~ /\A[a-z_][a-z0-9_-]{0,31}\z/ &&
	$username !~ /\A(?:daemon|bin|sys|nobody|sshd)\z/;
}

# get_vm_form_defaults(config)
# Supplies built-in fallbacks and presentation preferences for creation forms.
sub get_vm_form_defaults
{
my ($config) = @_;
my %defaults = map { %{(Cloudmin::Presets::builtin_presets($_))[0]->{'settings'}} }
	qw(template plan);
return { %defaults,
	show_description => ($config->{'machine_show_description'} || '') eq '1' ? 1 : 0,
	show_template_description => ($config->{'machine_show_template_description'} || '') =~ /\A[12]\z/
		? 0 + $config->{'machine_show_template_description'} : 0,
	generate_password => ($config->{'machine_generate_password'} || '') eq '1' ? 1 : 0,
};
}

# preset_description(record) returns the display description of a saved preset.
sub preset_description
{
my ($record) = @_;
# Translate shipped descriptions, falling back to the stored text.
return $text{'presets_description_'.$record->{'description_default'}} || $record->{'description'}
	if ($record->{'description_default'});
# Keep descriptions entered by the user exactly as saved.
return $record->{'description'};
}

# vm_download_label([image]) describes a pending download, with its size if known.
# Missing, imported or already downloaded images return an empty label.
sub vm_download_label
{
my ($image) = @_;
# Only an uncached catalogue image needs a download notice.
return '' if (!$image || !$image->{'catalogue_id'} || $image->{'downloaded'});
return $image->{'download_size_bytes'}
	? text('vm_image_download_size', nice_size_text($image->{'download_size_bytes'}))
	: $text{'vm_image_download_needed'};
}

# vm_size_bytes(values, field, base) converts a displayed allocation to bytes.
# values holds the amount and optional field_units byte multiplier; base is
# the byte multiplier used when units are absent. Invalid input yields 0.
sub vm_size_bytes
{
my ($values, $field, $base) = @_;
my $units = $values->{$field.'_units'} || $base;
my $amount = $values->{$field};
return defined($amount) && length($amount) <= 32 &&
	$amount =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ &&
	(grep { $units eq int(1024**$_) } 0..5) ? $amount * $units : 0;
}

# get_vm_image_choices(images)
# Groups catalogue releases by distribution, then imports and local captures.
sub get_vm_image_choices
{
my ($images) = @_;
my $catalogue = Cloudmin::ImageChoices::sort_images([grep { !$_->{'unavailable'} && $_->{'catalogue_id'} } @$images]);
my $imports = Cloudmin::ImageChoices::sort_images([grep { !$_->{'unavailable'} && !$_->{'catalogue_id'} && ($_->{'source'} || '') ne 'vm' } @$images]);
my $captures = Cloudmin::ImageChoices::sort_images([grep { !$_->{'unavailable'} && !$_->{'catalogue_id'} && ($_->{'source'} || '') eq 'vm' } @$images]);
# Keep source tags for browser filtering and pool details for explicit imports.
# Missing references remain ungrouped and have no size or pool details.
# Store any download notice on the option for the summary to display.
return [ map { [ $_->{'id'}, $_->{'name'}.
	($_->{'catalogue_id'} || $_->{'unavailable'} ? '' : ' ('.nice_size_text($_->{'virtual_size'}).'; '.$_->{'pool_name'}.')'),
	'data-vm-image-source="'.(($_->{'format'} || '') eq 'iso' ? 'iso' : 'cloud').'"'.
	(vm_download_label($_) ne '' ? ' data-vm-download="'.html_escape(vm_download_label($_)).'"' : ''),
	$_->{'unavailable'} ? '' : $_->{'catalogue_id'} || ($_->{'source'} || '') eq 'vm'
		? get_image_group($_) : $text{'vm_image_imports'} ] }
	(@$catalogue, @$imports, @$captures, grep { $_->{'unavailable'} } @$images) ];
}

# get_vm_form_images(options, [selected]) combines catalogue and custom imports.
# Keep imports referenced by templates, including ones selected in the browser.
sub get_vm_form_images
{
my ($options, $selected) = @_;
my @catalogue = @{$options->{'catalogue_images'} || []};
my %referenced = map { ($_->{'settings'}->{'image'} || '') => 1 }
	@{$options->{'presets'}->{'template'}->{'entries'} || []};
$referenced{$selected} = 1 if ($selected);
# Hide redundant cached downloads unless a template still uses their import ID.
my @imports = grep {
	my $import = $_;
	$referenced{$import->{'id'}} || !grep {
		Cloudmin::Images::matches_download($import,
			Cloudmin::Images::catalogue_request({%$_, id => $_->{'catalogue_id'}}, {}))
	} @catalogue
} @{$options->{'images'} || []};
return [@catalogue, @imports];
}

# show_software_script(field, values, [disabled]) renders a guest script source.
# field is before_script or after_script; disabled defaults to false.
sub show_software_script
{
my ($field, $values, $disabled) = @_;
my $preview = !Cloudmin::Software::has_scripts();
# Keep saved scripts visible for review even when advertisements are hidden.
return '' if ($preview && !show_pro_features() && !Cloudmin::Software::uses_scripts($values));
$disabled ||= $preview;
# Infer the source for older records that have no explicit mode.
my $mode = $values->{$field.'_mode'} || ($values->{$field.'_path'} ? 'file'
	: $values->{$field} ? 'inline' : 'none');
my $inputs = ui_radio($field.'_mode', $mode,
	[map { [$_, $text{'vm_script_'.$_}] } qw(none file inline)], $disabled);
# Reuse Virtualmin's Jailkit styling: muted choices with an inline Pro link.
if ($preview) {
	$inputs = ui_tag('span', $inputs, {'data-pro-disabled' => 'setup-scripts-elem'}).
		pro_feature_badge('setup-scripts');
}
# The chooser reads a host path; both sources run only inside the guest.
foreach my $source (qw(file inline)) {
	my $inactive = $disabled || $mode ne $source;
	my $control = $source eq 'file'
		? ui_textbox($field.'_path', $values->{$field.'_path'}, 60, $inactive).
			($disabled ? '' : file_chooser_button($field.'_path', 0))
		: ui_textarea($field, $values->{$field}, 6, 75, undef, $inactive);
	$inputs .= ui_tag('div', $control, {'data-vm-script-source' => $source,
		$preview ? ('data-pro-disabled' => 'setup-scripts-elem') : (),
		$mode ne $source ? (hidden => undef) : ()});
}
# The fieldset excludes preview inputs from submission. The help label stays
# outside it so the option name and help link remain readable.
$inputs = pro_feature_preview($inputs) if ($preview);
return ui_table_row(hlink($text{'vm_'.$field}, 'machine_'.$field),
	ui_tag('div', $inputs, {'data-vm-script' => $field,
		$disabled ? ('data-vm-readonly' => 1) : ()}), 1,
	$preview ? ['data-pro-disabled="cell"'] : undef, undef, 1);
}

# show_software_settings(values, [disabled], [creation], [base])
# Shows setup in execution order. creation renders the resolved package list
# without inheritance controls; show_license_rows supplies license inputs.
# base identifies Default Template, which cannot inherit its package list.
# All flags default to false for an editable non-default template.
sub show_software_settings
{
my ($values, $disabled, $creation, $base) = @_;
my $preview = !Cloudmin::Software::has_scripts();
my $page = show_software_script('before_script', $values, $disabled);
# Clearing saved scripts remains available in GPL, without silently dropping them.
if ($preview && !$creation && Cloudmin::Software::uses_scripts($values)) {
	$page .= ui_table_row('', ui_checkbox('clear_setup_scripts', 1,
		$text{'pro_scripts_clear'}, 0, undef, $disabled), 3);
}
my $packages;
if ($creation) {
	# Creation receives the resolved package list and permits per-guest edits.
	$packages = ui_textarea('packages', $values->{'packages'}, 3, 75, undef, $disabled);
}
else {
	# Saving other software options must not turn inheritance into None.
	my $mode = exists($values->{'packages'}) ? (length($values->{'packages'}) ? 'list' : 'none')
		: $base ? 'none' : 'inherit';
	my @choices = (['none', $text{'vm_packages_none'}], ['list', $text{'vm_packages_list'}]);
	unshift(@choices, ['inherit', $text{'presets_inherit'}]) if (!$base);
	$packages = ui_radio('packages_mode', $mode, \@choices, $disabled).
		ui_tag('div', ui_textarea('packages', $values->{'packages'}, 3, 75, undef,
			$disabled || $mode ne 'list'), {'data-vm-package-list' => 1,
			$mode ne 'list' ? (hidden => undef) : ()});
	$packages = ui_tag('div', $packages, {'data-vm-packages' => 1,
		$disabled ? ('data-vm-readonly' => 1) : ()});
}
$page .= ui_table_row(hlink($text{'vm_packages'}, 'machine_packages'),
	$packages, 1, undef, undef, 1);
if (virtualmin_enabled()) {
	# Render installer controls and their divider only while enabled.
	$page .= ui_table_hr();
	my @choices = (
	 ['software', [['none', $text{'vm_software_none'}], ['virtualmin-gpl', 'Virtualmin GPL'], ['virtualmin-pro', 'Virtualmin Pro']]],
	 ['virtualmin_bundle', [['LAMP', 'Apache'], ['LEMP', 'Nginx']]],
	 ['virtualmin_type', [['full', $text{'vm_software_full'}], ['mini', $text{'vm_software_mini'}]]],
	 ['virtualmin_postgres', [['0', $text{'no'}], ['1', $text{'yes'}]]],
	 ['virtualmin_ssl', [['1', $text{'yes'}], ['0', $text{'no'}]]],
	 ['webmin_register', [['1', $text{'yes'}], ['0', $text{'no'}]]]);
	# Only the host's root login may choose to save a guest login in Servers Index.
	$page .= join('', map {
	 my ($field, $choices) = @$_;
	 ui_table_row(hlink($field eq 'software' ? 'Virtualmin' : $text{'vm_'.$field}, 'machine_'.$field), ui_select($field,
	  $values->{$field} // $choices->[0]->[0], $choices, 1, 0, 0, $disabled),
	  undef, undef, $field eq 'software' ? [] : ['data-vm-virtualmin="1"'.
	    ($disabled ? ' data-vm-readonly="1"' : '')]);
	} grep { $_->[0] ne 'webmin_register' || ($remote_user || '') eq 'root' } @choices);
}
# Add a divider only when both the installer section and final script are shown.
$page .= ui_table_hr()
	if (virtualmin_enabled() &&
		(!$preview || show_pro_features() || Cloudmin::Software::uses_scripts($values)));
return $page.show_software_script('after_script', $values, $disabled);
}

# show_license_rows() renders Virtualmin Pro credentials for one creation.
# License credentials belong to this request, never to a template, and the
# browser shows the rows only while Virtualmin Pro is selected.
sub show_license_rows
{
# Omit credentials along with the installer when host policy disables it.
return '' if (!virtualmin_enabled());
my $page = '';
foreach my $field (qw(virtualmin_serial virtualmin_key)) {
	$page .= ui_table_row(hlink($text{'vm_'.$field}, 'machine_'.$field),
		ui_textbox($field, '', 15, 0, undef, 'autocomplete="off"'),
		undef, undef, ['data-vm-license="1"']);
}
return $page;
}

# show_vm_summary(values, images, networks)
# Summarizes current form values using the available image and network records.
# The browser updates these chips when the user changes presets or fields.
sub show_vm_summary
{
my ($values, $images, $networks) = @_;
my ($image) = grep { $_->{'id'} eq ($values->{'image'} || '') } @$images;
my ($network) = grep { $_->{'key'} eq ($values->{'network'} || '') } @$networks;
my $installer = ($values->{'install_source'} || '') eq 'iso';
my $software = $installer ? 'none' : $values->{'software'} || 'none';
my $setup;
if ($software =~ /\Avirtualmin-/) {
	# Use template naming for the edition, web server and optional PostgreSQL.
	$setup = Cloudmin::Presets::template_name($values, {});
	}
else {
	# Distinguish scripts from packages alone; installer ISOs skip guest setup.
	$setup = $text{!$installer && Cloudmin::Software::enabled($values)
		? (Cloudmin::Software::uses_scripts($values) ? 'vm_summary_setup' : 'vm_summary_packages') : 'vm_summary_none'};
	}
# Show current allocations and omit guest addressing for installer media.
my @chips = (
	[ 'image', $image ? $image->{'name'} : '', 'info' ],
	[ 'download', vm_download_label($image), 'warning' ],
	[ 'resources', text('vm_summary_resources', $values->{'cpus'} // '',
		nice_size_text(vm_size_bytes($values, 'memory_mib', 1024**2)),
		nice_size_text(vm_size_bytes($values, 'disk_gib', 1024**3))), 'success' ],
	[ 'network', !$network ? '' : $installer ? $network->{'name'}
		: text('vm_summary_network', $network->{'name'},
			$text{($values->{'address_mode'} || 'dhcp') eq 'static'
				? 'vm_summary_static' : 'vm_summary_dhcp'}), 'neutral' ],
	[ 'software', $setup, $software =~ /\Avirtualmin-/ ? 'info' : 'neutral' ],
);
# Keep empty chips hidden but available for later browser updates.
return ui_tag('div', ui_cluster([ map { ui_chip($_->[1], { state => $_->[2],
	attrs => { 'data-vm-chip' => $_->[0], $_->[1] eq '' ? (hidden => 'hidden') : () } }) } @chips ],
	{ gap => '8px' }), { 'data-vm-summary' => 1 });
}

# software_script() loads shared visibility rules after full or theme navigation.
sub software_script
{
# Theme table styles must not override the visibility set by setup controls.
return ui_tag('style', '[data-vm-virtualmin][hidden], [data-vm-script-source][hidden], [data-vm-package-list][hidden], '.
	'[data-vm-cloud-init][hidden], [data-vm-license][hidden], [data-vm-installer][hidden], '.
	'[data-vm-source-empty][hidden], [data-vm-chip][hidden], [data-vm-template-note][hidden], '.
	'#vm_keys_row[hidden], #vm_password_row[hidden], #vm_hostname_row[hidden] '.
	'{ display:none !important; } '.
	# Line the checkbox up with the input above it instead of the cell edge.
	'[data-vm-hostname-toggle] { margin: 3px 0 0 1.5px; }').
	ui_tag('script', '', { src => get_webprefix().'/server-manager/machine_software.js?'.
	(stat("$module_root_directory/machine_software.js"))[9] }).
	ui_tag('script', 'window.cloudminSoftwareInit?.();');
}

# show_vm_form(options, input, token, [generated_password])
# Shows editable preset defaults, with identity and credentials in open details.
# Module Configuration selects which optional sections start open.
# input may be undef; submitted fields override defaults, except credentials.
# generated_password defaults to blank and is used only on a fresh form.
sub show_vm_form
{
my ($options, $input, $token, $generated_password) = @_;
my %values = %{$input || {}};
# Keep presentation preferences separate from the selected preset settings.
my $form_defaults = { %{get_vm_form_defaults({})},
	%{$options->{'form_defaults'} || {}} };
my $caps = $options->{'capabilities'} || {};
my @images;
my @pools = @{$options->{'pools'} || []};
my @networks = @{$options->{'networks'} || []};
my $presets = { %{$options->{'presets'} || {}} };
# Render named defaults even in callers without persisted preset data. The
# protected base fills gaps even when a different preset is selected as default.
my %base;
foreach my $kind (qw(template plan)) {
	$presets->{$kind} ||= { default => Cloudmin::Presets::default_id(),
		entries => [Cloudmin::Presets::builtin_presets($kind, $caps->{'cpus'})] };
	my ($record) = grep { $_->{'id'} eq Cloudmin::Presets::default_id() }
		@{$presets->{$kind}->{'entries'}};
	@base{keys %{$record->{'settings'}}} = values %{$record->{'settings'}} if ($record);
}
# Saved defaults affect initial display only. API callers choose IDs explicitly.
foreach my $kind (qw(template plan)) {
	my $data = $presets->{$kind} || { entries => [], default => '' };
	$values{$kind} = $data->{'default'} if (!length($values{$kind} || ''));
	# Disabled records remain in API choices only to explain stale selections.
	my ($record) = grep { $_->{'id'} eq $values{$kind} && !$_->{'disabled'} } @{$data->{'entries'}};
	if ($record) {
		# Fill omitted fields from the selected preset without replacing input.
		foreach my $field (keys %{$record->{'settings'}}) {
			$values{$field} = $record->{'settings'}->{$field} if (!exists($values{$field}));
			}
		}
	}
@images = @{get_vm_form_images($options, $values{'image'} || $base{'image'})};
my ($default_pool) = grep { $_->{'name'} eq 'default' } @pools;
my ($default_network) = grep { $_->{'name'} eq 'default' } @networks;
# Prefer the selected or base image, then an available cloud image before ISO.
my ($selected_image) = grep { $_->{'id'} eq ($values{'image'} || $base{'image'} || '') } @images;
$selected_image ||= (grep { ($_->{'format'} || '') ne 'iso' } @images)[0] || $images[0];
my %defaults = (software => 'none', virtualmin_bundle => 'LAMP', virtualmin_type => 'full',
	virtualmin_postgres => '0', virtualmin_ssl => '1', webmin_register => '1', image => ($selected_image || {})->{'id'} || '',
	install_source => (($selected_image || {})->{'format'} || '') eq 'iso' ? 'iso' : 'cloud',
	pool => ($default_pool || $pools[0] || {})->{'id'},
	network => ($default_network || $networks[0] || {})->{'key'},
	cpus => $form_defaults->{'cpus'},
	memory_mib => $form_defaults->{'memory_mib'},
	disk_gib => $form_defaults->{'disk_gib'}, username => $form_defaults->{'username'},
	auth_type => $form_defaults->{'auth_type'}, firmware => 'auto',
	start => $form_defaults->{'start'}, autostart => $form_defaults->{'autostart'}, %base);
foreach my $field (keys %defaults) {
	# Preserve explicit empty values so defaults cannot hide invalid input.
	$values{$field} = $defaults{$field} if (!exists($values{$field}));
	}
# Host policy overrides inherited and submitted choices in the initial summary.
$values{'software'} = 'none' if (!virtualmin_enabled());
my $page = ui_page_start();
if (!@images) {
	# Keep the setup action visible when neither catalogue entries nor imports
	# are available.
	$page .= ui_empty_state({
		'icon' => 'download',
		'title' => $text{'vm_no_images'},
		'desc' => $text{'vm_no_images_desc'},
		'actions' => ui_link_button('image_form.cgi',
		$text{'images_tab_add'}),
	});
	return $page.ui_page_end();
	}
if (!@pools || !@networks) {
	# Explain missing prerequisites before presenting an unusable submit
	# button.
	$page .= ui_alert_box($text{!@pools ? 'vm_no_pools'
		: 'vm_no_networks'}, 'warn', undef, undef, '');
	return $page.ui_page_end();
	}
$page .= ui_p($text{'vm_create_desc'});
# Use a streaming URL so the theme displays progress during downloads.
$page .= ui_form_start('setup_machine.cgi', 'post', undef, 'id="vm-create-form"');
# Avoid a control named action, which hides form.action from the theme.
$page .= ui_hidden('token', $token).ui_hidden('vm_operation', 'create');
# Presets fill the same form; manual edits keep the chosen template and plan.
my ($base_image) = grep { $_->{'id'} eq ($base{'image'} || '') } @images;
my %preset_defaults = (ssh_keys => '', address_mode => 'dhcp',
	gateway4 => '', gateway6 => '', dns => '', %defaults,
	install_source => $base{'install_source'} ||
		((($base_image || $images[0])->{'format'} || '') eq 'iso' ? 'iso' : 'cloud'));
# Send translated summary labels and descriptions with the presets.
my %labels = map { $_ => $text{'vm_summary_'.$_} }
	qw(resources network dhcp static none setup packages virtualmin postgres gpl pro apache nginx);
my %descriptions = map { $_->{'id'} => preset_description($_) }
	@{$presets->{'template'}->{'entries'} || []};
# Attribute helpers normalize whitespace, so keep script contents in JSON text.
# Escaping '<' also prevents a pasted script from closing this HTML element.
my $preset_json = convert_to_json({ %$presets, defaults => \%preset_defaults,
	labels => \%labels, descriptions => \%descriptions }, 0, 0);
$preset_json =~ s/</\\u003c/g;
$page .= ui_tag('script', $preset_json, { type => 'application/json', 'data-vm-presets' => '1' });
# Missing template resources must remain visible and fail normal validation.
foreach my $entry (['image', \@images, 'id'], ['pool', \@pools, 'id'], ['network', \@networks, 'key']) {
	my ($field, $items, $key) = @$entry;
	if ($values{$field} && !grep { $_->{$key} eq $values{$field} } @$items) {
		# Keep a removed resource selected so submission explains what
		# needs repair.
		push(@$items, {$key => $values{$field}, name => text('presets_unavailable', $values{$field}),
			unavailable => 1, format => $values{'install_source'} eq 'iso' ? 'iso' : 'qcow2'});
		}
	}
$page .= show_vm_resource_input_styles();
# Keep identity, credentials and preset selectors in the initially open section.
$page .= ui_hidden_table_start($text{'vm_step_details'}, 'width=100%', 2,
	'vm_details', 1);
# Use the VM name as hostname unless a separate hostname is requested.
my $hostname_set = $values{'hostname_set'} ||
	length($values{'hostname'} || '') ? 1 : 0;
$page .= ui_table_row($text{'vm_name'},
	ui_textbox('name', $values{'name'}, 45).
	ui_tag('div', ui_checkbox('hostname_set', 1, $text{'vm_hostname_set'},
		$hostname_set), { 'data-vm-hostname-toggle' => 1, 'data-vm-cloud-init' => 1 }));
# A blank separate hostname also falls back to the virtual machine name.
$page .= ui_table_row($text{'vm_hostname'},
	ui_textbox('hostname', $values{'hostname'}, 45, undef, undef,
	'placeholder="'.html_escape($text{'vm_hostname_placeholder'}).'"'),
	undef, undef, [ "id='vm_hostname_row' data-vm-cloud-init='1'".
		($hostname_set ? '' : ' hidden') ]);
if ($form_defaults->{'show_description'} ||
	length($values{'description'} || '')) {
	# Keep a supplied description editable even when hidden by default.
	$page .= ui_table_row($text{'vm_description'},
		ui_textarea('description', $values{'description'}, 3, 65));
	}
# Only a fresh form may receive a generated password; never echo submitted ones.
$generated_password = ''
	if (!$form_defaults->{'generate_password'} || $values{'action'});
# Show generated passwords directly, including in themes without a reveal button.
my $password_input = $form_defaults->{'generate_password'} ? \&ui_textbox : \&ui_password;
my $password = $password_input->('password', $generated_password || '', 30, 0, undef,
	'data-password autocomplete="new-password"');
# The browser shows whichever credential rows the login method uses.
$page .= ui_table_row($text{'vm_password'}, $password, undef, undef,
	[ "id='vm_password_row' data-vm-cloud-init='1'" ]);
$page .= ui_table_row($text{'vm_ssh_keys'},
	ui_textarea('ssh_keys', $values{'ssh_keys'}, 4, 75),
	undef, undef, [ "id='vm_keys_row' data-vm-cloud-init='1'" ]);
if ($options->{'cloud_init_error'}) {
	# Installer creation remains available when cloud-init tools are missing.
	$page .= ui_table_row(undef, ui_note(html_escape($options->{'cloud_init_error'}), 0), 2);
	}
$page .= ui_table_hr();
my $template_note = '';
if ($form_defaults->{'show_template_description'}) {
	# Keep the selected display mode available for browser updates.
	my ($template) = grep { $_->{'id'} eq ($values{'template'} || '') }
		@{$presets->{'template'}->{'entries'} || []};
	my $description = $template ? (preset_description($template) // '') : '';
	$description = '' if ($form_defaults->{'show_template_description'} == 1 &&
		$template && lc($description) eq lc($template->{'name'}));
	$template_note = ui_tag('div', ui_note(ui_tag('span', html_escape($description),
		{ 'data-vm-template-desc' => 1 }), 0),
		{ 'data-vm-template-note' => $form_defaults->{'show_template_description'},
		  $description eq '' ? (hidden => undef) : () });
}
# Offer only templates that the host's installation policy allows.
$page .= ui_table_row($text{'presets_template'},
	ui_select('template', $values{'template'}, [ map { [$_->{'id'}, $_->{'name'}] }
		grep { !$_->{'disabled'} } @{$presets->{'template'}->{'entries'} || []} ]).$template_note);
# Show allocations in plan labels before the user opens Resources.
$page .= ui_table_row($text{'presets_plan'},
	ui_select('plan', $values{'plan'}, [ map { [ $_->{'id'},
		text('vm_plan_option', $_->{'name'}, $_->{'settings'}->{'cpus'},
			nice_size_text($_->{'settings'}->{'memory_mib'} * 1024**2),
			nice_size_text($_->{'settings'}->{'disk_gib'} * 1024**3)) ] }
		@{$presets->{'plan'}->{'entries'} || []} ]));
$page .= show_license_rows();
# Put the missing-source warning in details so it is visible on initial load.
my $source = ($values{'install_source'} || 'cloud') eq 'iso' ? 'iso' : 'cloud';
my $source_empty = !grep { (($_->{'format'} || '') eq 'iso' ? 'iso' : 'cloud') eq $source } @images;
$page .= ui_table_row(undef, show_vm_summary(\%values, \@images, \@networks).
	ui_tag('div', ui_note($text{'vm_source_empty'}, 0),
		{ 'data-vm-source-empty' => 1, $source_empty ? () : (hidden => undef) }), 2);
$page .= ui_hidden_table_end('vm_details');
# Optional sections start open only when selected in Module Configuration.
$page .= ui_hidden_table_start($text{'presets_image'}, 'width=100%', 2,
	'vm_image', section_open('machine_create_sections', 'image'));
$page .= ui_table_row($text{'vm_install_source'},
	ui_select('install_source', $values{'install_source'}, [
		[ 'cloud', $text{'vm_source_cloud'} ], [ 'iso', $text{'vm_source_iso'} ] ]));
$page .= ui_table_row($text{'vm_image'},
	ui_cluster([
		show_image_select('image', $values{'image'}, get_vm_image_choices(\@images), 0, 1),
		ui_action_button($text{'vm_manage_images'}, 'neutral', {
			href => 'images.cgi', icon => 'hard-drive',
			attrs => { 'data-vm-manage-images' => 1 } })
	], { class => 'cloudmin-vm-image-picker', gap => 'var(--gap-content, 10px)' }));
# Show installer guidance when an ISO is the source.
$page .= ui_table_row('',
	ui_tag('div', ui_note($text{'vm_iso_desc'}, 0), { 'data-vm-installer' => 1 }),
	1, undef, undef, 1);
my ($selected_pool) = grep { $_->{'id'} eq ($values{'pool'} || '') } @pools;
# Match the browser's first option when the submitted pool is no longer listed.
$selected_pool ||= $pools[0];
# disk_hint(pool) formats the current free-space hint for a pool.
my $disk_hint = sub {
	# The pool's current free space is a guide; creation rechecks it on submit.
	return defined($_[0]->{'available'})
		? text('vm_disk_available', nice_size_text($_[0]->{'available'})) : '';
	};
# Keep the pool beside the image and update the disk capacity hint on changes.
$page .= ui_table_row($text{'images_storage'},
	ui_select('pool', $values{'pool'}, [ map {
	[ $_->{'id'},
	  text('images_pool_option', $_->{'name'},
		nice_size_text($_->{'available'})),
	  'data-vm-available="'.html_escape($disk_hint->($_)).'"' ]
	} @pools ], undef, undef, undef, undef,
	q{onchange="this.form.querySelector('[data-vm-capacity=disk_gib]').textContent = this.selectedIndex < 0 ? '' : this.options[this.selectedIndex].getAttribute('data-vm-available') || '';"}));
$page .= ui_hidden_table_end('vm_image');
# Show the plan's allocations as editable fields; the server validates them.
$page .= ui_hidden_table_start($text{'vm_step_resources'}, 'width=100%', 2,
	'vm_resources', section_open('machine_create_sections', 'resources'));
$page .= ui_table_row($text{'vm_cpus'},
	ui_textbox('cpus', $values{'cpus'}, 2, undef, undef, 'data-vm-resource').
	($caps->{'cpus'} ? ui_tag('span', text('vm_cpus_range', $caps->{'cpus'}),
		{ class => 'vm-resource-hint' }) : ''));
foreach my $size ([ 'memory_mib', 1024**2 ], [ 'disk_gib', 1024**3 ]) {
	# Webmin's size widget selects readable units from the entered byte count.
	my ($field, $base) = @$size;
	my $bytes = vm_size_bytes(\%values, $field, $base) || '';
	# Memory shows installed host capacity; disks use the selected pool's space.
	my $hint = $field eq 'memory_mib'
		? ($caps->{'memory_kib'} ? text('vm_memory_range',
			nice_size_text($caps->{'memory_kib'} * 1024)) : '')
		: $disk_hint->($selected_pool);
	$page .= ui_table_row($text{'vm_'.$field},
		ui_bytesbox($field, $bytes, 4, 0, 'data-vm-resource="size"', $base).
		ui_tag('span', $hint, { class => 'vm-resource-hint',
			'data-vm-capacity' => $field, 'aria-live' => 'polite' }));
	}
$page .= ui_hidden_table_end('vm_resources');
# Hide the whole Access accordion in ISO mode. Credentials render in details.
$page .= ui_hidden_table_start($text{'vm_step_access'},
	'width=100% data-vm-cloud-init="1"', 2,
	'vm_access', section_open('machine_create_sections', 'access'));
$page .= ui_table_row($text{'vm_username'},
	ui_textbox('username', $values{'username'}, 30, undef, undef, 'data-vm-autosize'));
$page .= ui_table_row($text{'vm_auth_type'},
	ui_select('auth_type', $values{'auth_type'},
	[ map { [ $_, $text{'vm_auth_'.$_} ] } qw(keys password both) ]));
$page .= ui_hidden_table_end('vm_access');
# Hide the whole Software accordion in ISO mode. Only Module Configuration
# decides whether it starts open; selecting a template leaves it as rendered.
$page .= ui_hidden_table_start($text{'vm_software'},
	'width=100% data-vm-cloud-init="1"', 2,
	'vm_software', section_open('machine_create_sections', 'software'));
$page .= show_software_settings(\%values, 0, 1);
$page .= ui_hidden_table_end('vm_software');
$page .= ui_hidden_table_start($text{'vm_network'}, 'width=100%', 2,
	'vm_network', section_open('machine_create_sections', 'network'));
# DHCP is the initial choice; static inputs appear only when requested.
$page .= ui_table_row($text{'vm_network'},
	ui_select('network', $values{'network'}, [ map {
	[ $_->{'key'}, $_->{'name'}.' ('.($_->{'forward'} || $_->{'type'}).')' ]
	} @networks ]));
my @static = map { [ $text{'vm_'.$_}, ui_textbox($_, $values{$_}, 45,
	undef, undef, $_ =~ /\A(?:gateway4|gateway6|dns)\z/
		? 'placeholder="'.html_escape($text{'vm_optional'}).'"' : '') ] }
	qw(ipv4 gateway4 ipv6 gateway6 dns);
# ISO installs still need a NIC; only guest addressing is hidden.
$page .= ui_table_row($text{'vm_address_mode'},
	ui_select_switch('address_mode', $values{'address_mode'} || 'dhcp', [
	{ value => 'dhcp', label => $text{'vm_dhcp'}, fields => [] },
	{ value => 'static', label => $text{'vm_static'}, fields => \@static },
], { id => 'cloudmin-vm-addresses' }), undef, undef,
	[ 'data-vm-cloud-init="1"' ]);
$page .= ui_table_row($text{'vm_mac'}, ui_textbox('mac', $values{'mac'}, 45,
	undef, undef,
	'placeholder="'.html_escape($text{'vm_mac_placeholder'}).'"'));
$page .= ui_hidden_table_end('vm_network');
# Put firmware and startup settings in the last section.
$page .= ui_hidden_table_start($text{'vm_boot_options'}, 'width=100%', 2,
	'vm_boot', section_open('machine_create_sections', 'boot'));
$page .= ui_table_row($text{'catalogue_firmware'},
	ui_select('firmware', $values{'firmware'}, [
	[ 'auto', $text{'vm_auto'} ],
	map { [ $_, $_ eq 'efi' ? 'UEFI' : 'BIOS' ] }
	@{$caps->{'firmware'} || []} ]));
$page .= ui_table_row($text{'vm_autostart'},
	ui_yesno_radio('autostart', $values{'autostart'}));
$page .= ui_table_row($text{'vm_start'},
	ui_yesno_radio('start', $values{'start'}));
$page .= ui_hidden_table_end('vm_boot');
$page .= ui_form_end([ [ undef, $text{'vm_create'} ] ]);
# Initialize the form after theme navigation as well as full page loads.
# Repeated calls leave existing selections intact.
$page .= software_script().ui_tag('script', '', { src => get_webprefix().'/server-manager/machine_create.js?'.
	(stat("$module_root_directory/machine_create.js"))[9] }).
	ui_tag('script', 'window.cloudminVmCreateInit?.();');
return $page.ui_page_end();
}

# show_vm_power_controls(vm, [token], [shutdown_requested])
# Keeps common power actions visible and puts secondary actions in a menu.
# Power actions need a signed token; force actions open their confirmation page.
sub show_vm_power_controls
{
my ($vm, $token, $shutdown_requested) = @_;
# Render every permitted state group so live updates can switch them in place.
my $running = $vm->{'active'} && $vm->{'state'} =~ /\A(?:running|blocked)\z/
	&& !$shutdown_requested;
my %visible = (start => !$vm->{'active'} && $vm->{'state'} eq 'shutoff',
	running => $running, paused => $vm->{'state'} eq 'paused',
	active => $vm->{'active'}, cycle => $running && scalar(keys %{$vm->{'pending'} || {}}));
my @controls;
my @more;
# Keep Start and Resume in the same position as Reboot and Shut down.
if ($token && can_access('power', $vm->{'uuid'})) {
	my %actions = (start => ['success', 'play'],
		reboot => ['info', 'refresh'], shutdown => ['neutral', 'power'],
		resume => ['success', 'play']);
	foreach my $group (['start', 'start'], ['running', 'reboot', 'shutdown'], ['paused', 'resume']) {
		my ($state, @actions) = @$group;
		# Separate forms submit only the chosen action with its signed token.
		push(@controls, ui_tag('div', join('', map {
			ui_form_start('machine.cgi', 'post', undef, 'style="display:inline"').
			ui_hidden('id', $vm->{'uuid'}).ui_hidden('token', $token).
			ui_hidden('action', $_).
			ui_action_button($text{'vm_control_'.$_}, $actions{$_}->[0],
				{ type => 'submit', size => 'small', icon => $actions{$_}->[1] }).
			ui_form_end(undef, undef, 1)
			} @actions),
			{ 'data-vm-'.$state => 1, class => 'ui_cluster', style => '--ui-gap:0.5em',
			  ($visible{$state} ? () : (hidden => undef)) }));
		}
	}
# Menu submit buttons share a signed form and submit only their own action.
foreach my $action ([suspend => 'power', 'running', 'pause'],
	[power_cycle => 'manage', 'cycle', 'power']) {
	my ($name, $grant, $state, $icon) = @$action;
	next if (!$token || !can_access($grant, $vm->{'uuid'}));
	push(@more, { label => $text{'vm_control_'.$name}, icon => $icon,
		type => 'submit', name => 'action', value => $name,
		disabled => !$visible{$state},
		attrs => { 'data-vm-'.$state => 1,
			($visible{$state} ? () : (hidden => undef, 'aria-disabled' => 'true')) } });
	}
# Force actions need their own permission and open a confirmation page.
if ($token && can_access('force', $vm->{'uuid'})) {
	foreach my $action (qw(force_off reset)) {
		push(@more, { label => $text{'vm_control_'.$action}, icon => 'power',
			state => 'danger', href => 'machine.cgi?id='.urlize($vm->{'uuid'}).'&'.$action.'=1',
			attrs => { 'data-vm-active' => 1,
				($visible{'active'} ? () : (hidden => undef, 'aria-disabled' => 'true')) } });
		}
	}
# Backups, clones and captures copy guest data and require host write access.
if (can_access('host') && !is_readonly_mode()) {
	push(@more, { label => $text{'backup_action'}, icon => 'download', href => 'backup_form.cgi?id='.urlize($vm->{'uuid'}) });
	push(@more, { label => $text{'vm_clone'}, icon => 'copy',
		href => 'clone_machine_form.cgi?id='.urlize($vm->{'uuid'}) });
	# The capture page explains the Pro requirement and disables its GPL form.
	push(@more, { label => $text{'vm_image_action'}, icon => 'hard-drive',
		href => 'image_machine_form.cgi?id='.urlize($vm->{'uuid'}) })
		if (-r "$module_root_directory/pro/VMImages.pm" || show_pro_features());
	}
# Keep an initially empty menu in the page when a later state can enable it.
if (@more) {
	my $menu = ui_dropdown('', \@more,
		{ size => 'small', id => 'vm-more-actions-menu', icon => 'ellipsis',
		  caret => 0, title => $text{'vm_control_more'} });
	# Navigation alone needs no token; power entries share this signed POST form.
	$menu = ui_form_start('machine.cgi', 'post', undef, 'id="vm-more-actions-form"').
		ui_hidden('id', $vm->{'uuid'}).ui_hidden('token', $token).
		$menu.ui_form_end(undef, undef, 1) if ($token);
	push(@controls, ui_tag('div', $menu, { 'data-vm-more' => 1,
		((grep { !$_->{'attrs'} || !exists($_->{'attrs'}->{'hidden'}) } @more) ? () : (hidden => undef)) }));
	}
return ui_cluster(\@controls, { gap => '0.5em' });
}

# show_vm_details(vm, [token], [shutdown_requested])
# Shows configuration, live usage, guest health and attached storage/network
# devices. A token enables permitted controls; a pending shutdown hides repeats.
sub show_vm_details
{
my ($vm, $token, $shutdown_requested) = @_;
my $unknown = $text{'vm_usage_unavailable'};
# escape(value) escapes guest text and supplies a missing-value label.
my $escape = sub { html_escape(defined($_[0]) &&
	length($_[0]) ? $_[0] : $unknown) };
my $page = ui_page_assets();
my $controls = show_vm_power_controls($vm, $token, $shutdown_requested);
# Group power and connection health above the three resource summaries.
my @signals = map {
	my ($field, $icon) = @$_;
	my $status = ui_tag('span', $escape->($field eq 'power'
		? $text{'index_state_'.$vm->{'state'}} ||
		$vm->{'state'} : $text{'vm_status_checking'}),
		{ 'data-vm-field' => $field });
	ui_list([{ title => $text{'vm_status_'.$field}, icon => $icon,
		desc_html => $field eq 'power'
			? ui_cluster([$status, $controls], { gap => '0.5em' }) : $status }]);
	} ([power => 'power'], [agent => 'server'], [ssh => 'terminal']);
foreach my $item ([vm_cpus => 'cpu', 'gear', $vm->{'vcpus'}],
	[vm_memory_mib => 'memory', 'server',
	 nice_size_text(($vm->{'memory_kib'} || 0) * 1024)],
	[vm_disks => 'disk', 'hard-drive']) {
	push(@signals,
		ui_list([{ title => $text{$item->[0]}, icon => $item->[2],
		desc_html =>
			show_resource_placeholder($item->[1], $item->[3]) }]));
	}
# Keep the main identity and connection details in one compact card.
my @details = (
	[ $text{'vm_name'},
	  ui_tag('span', $escape->($vm->{'name'}),
	{ 'data-vm-field' => 'name' }) ],
	[ $text{'vm_guest_os'},
	  ui_tag('span', $text{'vm_status_checking'},
	{ 'data-vm-guest' => 'os' }) ],
	[ $text{'vm_start_at_boot'}, ui_tag('span',
		defined($vm->{'autostart'})
		? $text{$vm->{'autostart'} ? 'index_yes' : 'index_no'}
		: $unknown,
		{ 'data-vm-field' => 'autostart' }) ]);
my @addresses = map { $_->{'address'}.' ('.$_->{'source'}.')' }
	@{$vm->{'addresses'} || []};
push(@details, [ $text{'vm_addresses'}, ui_tag('span',
	$escape->(@addresses ? join(', ', @addresses)
	: $text{'vm_status_checking'}), { 'data-vm-field' => 'addresses' }) ]);
# An omitted description should not leave an empty identity row.
push(@details, [ $text{'vm_description'}, $escape->($vm->{'description'}) ])
	if (length($vm->{'description'} || ''));
$page .= show_vm_pending_banner($vm);
$page .= ui_tag('div', ui_card({ body => ui_dl(\@details, { cols => 2 }) }).
	ui_card({ id => 'cloudmin-vm-summary',
	body => ui_grid(\@signals, { cols => 3 }) }), {
	class => 'ui_page', id => 'cloudmin-vm-status', 'data-vm-details' => 1,
	($shutdown_requested ? ('data-vm-shutdown-requested' => 1) : ()),
	'data-config' => html_escape(get_status_config($vm)) });
# Resource usage stays above the expandable detail sections.
$page .= ui_table_start($text{'vm_resources'}, 'width=100%', 2,
	[ 'width=30%', undef ]);
foreach my $field (qw(memory_used disk_used disk_read disk_write network_rx
		      network_tx)) {
	$page .= ui_table_row($text{'vm_'.$field},
		show_resource_placeholder($field));
	}
$page .= ui_table_end();
# Disk sources are escaped text; no graphics passwords or raw XML are rendered.
my @disks = map {
	my $disk = $_;
	[ $escape->(vm_disk_label($disk)), $escape->($disk->{'device'}),
	  show_disk_location($disk->{'path'} ||
		join('/', grep { defined($_) } @{$disk}{qw(pool volume)}), 0),
	  (map { $escape->($_) } @{$disk}{qw(bus format)}),
	  (map { ui_tag('span', $unknown,
		{ 'data-vm-disk' => $disk->{'target'},
		  'data-disk-field' => $_ }) } qw(capacity physical)),
	  $text{$disk->{'readonly'} ? 'index_yes' : 'index_no'} ]
	} @{$vm->{'disks'} || []};
$page .= ui_hidden_table_start($text{'vm_disks'}, 'width=100%', 2, 'vm_disks',
	section_open('machine_detail_sections', 'disks'));
$page .= ui_table_row(undef, ui_columns_table(
	[ map { $text{$_} }
	qw(vm_delete_disk_name vm_interface_type vm_disk_source vm_disk_bus
	   vm_disk_format vm_disk_capacity vm_disk_physical vm_disk_readonly) ],
	100, \@disks), 2);
$page .= ui_hidden_table_end('vm_disks');
# Interface definitions remain visible even before guest addresses
# arrive.
my @interfaces = map { my $nic = $_;
	[ map { $escape->($nic->{$_}) } qw(mac type source model target) ] }
	@{$vm->{'interfaces'} || []};
$page .= ui_hidden_table_start($text{'vm_interfaces'}, 'width=100%', 2,
	'vm_interfaces', section_open('machine_detail_sections', 'interfaces'));
$page .= ui_table_row(undef, @interfaces ? ui_columns_table(
	[ map { $text{$_} }
	qw(index_macs vm_interface_type vm_disk_source vm_interface_model
	   vm_interface_target) ],
	100, \@interfaces) : ui_note($text{'vm_interfaces_empty'}, 0), 2);
$page .= ui_hidden_table_end('vm_interfaces');
# Hide the table and its hint until the guest agent supplies filesystem rows.
$page .= ui_hidden_table_start($text{'vm_filesystems'}, 'width=100%', 2,
	'vm_filesystems', section_open('machine_detail_sections', 'filesystems'));
$page .= ui_table_row(undef,
	ui_tag('div', ui_note($text{'vm_filesystems_hint'}, 0).
	ui_columns_table([ map { $text{$_} }
	qw(vm_disk_target vm_filesystem_mount vm_filesystem_type
	   vm_filesystem_size vm_filesystem_used) ],
		100, []), { 'data-vm-filesystems' => 1, hidden => undef }).
	ui_tag('div', ui_note(ui_tag('span',
		$text{$vm->{'active'} ? 'vm_filesystems_checking' :
		'vm_filesystems_stopped'}, { 'data-vm-filesystems-message' => 1 }), 0),
	{ 'data-vm-filesystems-warning' => 1 }), 2);
$page .= ui_hidden_table_end('vm_filesystems');
# Less-used hardware and guest identity fields belong in the last accordion.
$page .= ui_hidden_table_start($text{'vm_hardware'}, 'width=100%', 2,
	'vm_hardware', section_open('machine_detail_sections', 'hardware'), [ 'width=30%', undef ]);
foreach my $pair ([vm_uuid => $vm->{'uuid'}],
	[catalogue_architecture =>
		describe_architecture($vm->{'architecture'})],
	[vm_machine => $vm->{'machine'}],
	[vm_cpu_mode => $vm->{'cpu_mode'}],
	[vm_cpu_model => $vm->{'cpu_model'}],
	[vm_graphics => $vm->{'graphics'}->{'type'}],
	[vm_memory_max => nice_size_text(($vm->{'max_memory_kib'} ||
	$vm->{'memory_kib'} || 0) * 1024)],
	[catalogue_firmware => ($vm->{'firmware'} || '') eq 'efi' ? 'UEFI'
	: 'BIOS']) {
	$page .= ui_table_row($text{$pair->[0]}, $escape->($pair->[1]));
	}
$page .= ui_table_row($text{'index_persistent'}, ui_tag('span',
	$text{$vm->{'persistent'} ? 'index_yes' : 'index_no'},
	{ 'data-vm-field' => 'persistent' }));
foreach my $field (qw(hostname kernel)) {
	$page .= ui_table_row($text{'vm_guest_'.$field},
		ui_tag('span', $text{'vm_status_checking'},
		{ 'data-vm-guest' => $field }));
	}
$page .= ui_hidden_table_end('vm_hardware');
return $page;
}

# show_vm_clone_form(source, token) renders source choices with a signed token.
# Credentials stay visible and optional settings start collapsed. Clone preset
# resolution excludes installation media and software setup.
sub show_vm_clone_form
{
our %config;
my ($source, $token) = @_;
my $options = $source->{'options'};
my $presets = $source->{'presets'};
# Template access defaults combine with the source's current resource sizes.
my $defaults = get_presets()->resolve({template => $presets->{'template'}->{'default'}}, 'clone');
my %values = (username => 'cloudmin', auth_type => 'password', ssh_keys => '',
	address_mode => 'dhcp', host_ssh_key => ($config{'machine_host_ssh_key'} // '1'), %$defaults,
	cpus => $source->{'cpus'}, memory_mib => $source->{'memory_mib'},
	disk_gib => $source->{'disks'}->[0]->{'bytes'}/1024**3);
$values{'pool'} ||= $source->{'pool'};
$values{'network'} ||= $source->{'network'};
$values{'start'} //= 1;
$values{'autostart'} //= 0;
my $page = ui_page_start().ui_p($text{'vm_clone_desc'}).
	ui_form_start('clone_machine.cgi', 'post', undef, 'id="vm-clone-form"').
	ui_hidden('id', $source->{'id'}).ui_hidden('revision', $source->{'revision'}).
	ui_hidden('token', $token).ui_hidden('vm_operation', 'clone');
my $data = convert_to_json({presets => $presets, defaults => \%values}, 0, 0);
# Prevent template text from closing the JSON script element.
$data =~ s/</\\u003c/g;
$page .= ui_tag('script', $data, {type => 'application/json', 'data-clone-presets' => 1});
$page .= ui_hidden_table_start($text{'vm_step_details'}, 'width=100%', 2, 'clone_details', 1);
# The separate hostname stays opt-in, including for templates requiring an FQDN.
$page .= ui_table_row($text{'vm_name'}, ui_textbox('name', '', 45).
	ui_tag('div', ui_checkbox('hostname_set', 1, $text{'vm_hostname_set'}, 0),
		{ 'data-vm-hostname-toggle' => 1 }));
$page .= ui_table_row($text{'vm_hostname'}, ui_textbox('hostname', '', 45),
	undef, undef, ['data-clone-hostname hidden']);
$page .= ui_table_row($text{'vm_password'}, ui_password('password', '', 30, 0, undef,
	'autocomplete="new-password"'), undef, undef, ['data-clone-password']);
$page .= ui_table_row($text{'vm_ssh_keys'}, ui_textarea('ssh_keys', $values{'ssh_keys'}, 4, 75),
	undef, undef, ['data-clone-keys']);
# Clone forms follow the same template policy as creation and API requests.
$page .= ui_table_row($text{'presets_template'}, ui_select('template', $presets->{'template'}->{'default'},
	[map { [$_->{'id'}, $_->{'name'}] } grep { !$_->{'disabled'} } @{$presets->{'template'}->{'entries'}}]));
$page .= ui_table_row($text{'presets_plan'}, ui_select('plan', '',
	[['', $text{'vm_clone_source_resources'}], map { [$_->{'id'}, $_->{'name'}] } @{$presets->{'plan'}->{'entries'}}]));
$page .= ui_hidden_table_end('clone_details');
# Copy mode and license acknowledgments apply to the source, not its template.
$page .= ui_hidden_table_start($text{'vm_clone_source'}, 'width=100%', 2, 'clone_source', 0);
$page .= ui_table_row($text{'vm_clone_source'}, html_escape($source->{'name'}));
$page .= ui_table_row($text{'vm_clone_mode'}, ui_select('clone_mode', 'prepared',
	[['prepared', $text{'vm_clone_prepared'}], ['unchanged', $text{'vm_clone_unchanged'}]]));
$page .= ui_table_row(undef, ui_checkbox('confirm_unchanged', 1, $text{'vm_clone_confirm_unchanged'}, 0),
	2, undef, ['data-clone-unchanged hidden']);
$page .= ui_table_row(undef, ui_checkbox('confirm_license', 1, $text{'vm_clone_license'}, 0), 2);
$page .= ui_table_row($text{'vm_pool'}, ui_select('pool', $values{'pool'} || '',
	[map { [$_->{'id'}, $_->{'name'}.' ('.nice_size_text($_->{'available'}).')'] } @{$options->{'pools'}}]));
if ($source->{'active'}) {
	# Running sources require either guest-agent preparation or clean shutdown.
	$page .= ui_table_row($text{'vm_clone_consistency'}, ui_select('shutdown', 0,
		[[0, $text{'vm_clone_agent'}], [1, $text{'vm_clone_shutdown'}]]));
}
if ($source->{'nvram'}) {
	# Live sources default to fresh variables; stopped sources can copy them.
	$page .= ui_table_row($text{'vm_clone_nvram'}, ui_select('nvram_mode', $source->{'active'} ? 'fresh' : 'copy',
		[['copy', $text{'vm_clone_nvram_copy'}], ['fresh', $text{'vm_clone_nvram_fresh'}]]));
}
$page .= ui_hidden_table_end('clone_source');
# Resource overrides retain byte-unit controls used by the creation form.
$page .= ui_hidden_table_start($text{'vm_step_resources'}, 'width=100%', 2, 'clone_resources', 0);
$page .= ui_table_row($text{'vm_cpus'}, ui_textbox('cpus', $values{'cpus'}, 4));
foreach my $size (['memory_mib', 1024**2], ['disk_gib', 1024**3]) {
	$page .= ui_table_row($text{'vm_'.$size->[0]}, ui_bytesbox($size->[0], $values{$size->[0]}*$size->[1], 4, 0, undef, $size->[1]));
}
$page .= ui_hidden_table_end('clone_resources');
# Prepared copies can replace user access and create a separate managed key.
$page .= ui_hidden_table_start($text{'vm_step_access'}, 'width=100%', 2, 'clone_access', 0);
$page .= ui_table_row($text{'vm_username'}, ui_textbox('username', $values{'username'}, 30));
$page .= ui_table_row($text{'vm_auth_type'}, ui_select('auth_type', $values{'auth_type'},
	[map { [$_, $text{'vm_auth_'.$_}] } qw(password keys both)]));
$page .= ui_table_row($text{'vm_host_ssh_key'}, ui_select('host_ssh_key', $values{'host_ssh_key'},
	[[1, $text{'index_yes'}], [0, $text{'index_no'}]]));
$page .= ui_hidden_table_end('clone_access');
# Share the address switch so DHCP hides the static-only fields.
$page .= ui_hidden_table_start($text{'vm_network'}, 'width=100%', 2, 'clone_network', 0);
$page .= ui_table_row($text{'vm_network'}, ui_select('network', $values{'network'} || '',
	[map { [$_->{'key'}, $_->{'name'}] } @{$options->{'networks'}}]));
my @static = map { [$text{'vm_'.$_}, ui_textbox($_, $values{$_}, 45)] } qw(ipv4 gateway4 ipv6 gateway6 dns);
$page .= ui_table_row($text{'vm_address_mode'}, ui_select_switch('address_mode', $values{'address_mode'}, [
	{value => 'dhcp', label => $text{'vm_dhcp'}, fields => []},
	{value => 'static', label => $text{'vm_static'}, fields => \@static}], {id => 'clone-addresses'}));
$page .= ui_hidden_table_end('clone_network');
# The browser forces both startup options off for copies without preparation.
$page .= ui_hidden_table_start($text{'vm_boot_options'}, 'width=100%', 2, 'clone_boot', 0);
foreach my $field (qw(start autostart)) {
	$page .= ui_table_row($text{$field eq 'start' ? 'vm_start' : 'vm_autostart'},
		ui_select($field, $values{$field}, [[1, $text{'index_yes'}], [0, $text{'index_no'}]]));
}
$page .= ui_hidden_table_end('clone_boot');
$page .= ui_form_end([[undef, $text{'vm_clone_button'}]]);
# Reuse form styling and initialize clone controls after theme navigation too.
$page .= software_script().ui_tag('script', '', {src => get_webprefix().'/server-manager/machine_clone.js?'.
	(stat("$module_root_directory/machine_clone.js"))[9]}).
	ui_tag('script', 'window.cloudminVmCloneInit?.();');
return $page.ui_page_end();
}

# select_theme_server(vm)
# Selects the displayed guest through Webmin's optional theme hook.
sub select_theme_server
{
my ($vm) = @_;
theme_select_server(get_theme_server($vm))
	if (defined(&theme_select_server));
}

# notify_theme_save(vm, action)
# Refreshes the theme's guest list after an action such as 'create' or 'delete'.
sub notify_theme_save
{
my ($vm, $action) = @_;
theme_post_save_server(get_theme_server($vm), $action)
	if (defined(&theme_post_save_server));
}

# get_theme_server(vm)
# Converts a guest record to the id and host keys that theme hooks read.
sub get_theme_server
{
my ($vm) = @_;
return { 'id' => $vm->{'uuid'}, 'host' => $vm->{'name'} };
}

# print_vm_change_result(job_id, operation, [uuid])
# Shows warnings for a matching completed job; deletion refreshes navigation.
# When uuid is supplied, feedback must belong to that guest.
sub print_vm_change_result
{
my ($id, $operation, $uuid) = @_;
# Ordinary page visits have no completed edit to report.
return if (!$id);
# Status access is restricted to the current user; stale links add no feedback.
my $job = eval { call_vm_api(1, 'status', { job => $id }); };
return if (!$job || $job->{'state'} ne 'complete' ||
	$job->{'operation'} ne $operation ||
	(defined($uuid) && $job->{'uuid'} ne $uuid));
# Only deletion changes the guest list; ordinary saves keep the current menu.
notify_theme_save($job, 'delete') if ($operation eq 'delete');
# Live attachment changes can leave the guest using its old IP configuration.
print ui_alert_box($text{'vm_network_changed'}, 'warn', undef, undef, '')
	if ($job->{'network_changed'} && ($job->{'scope'} || '') eq 'live');
# Cleanup and audit failures remain visible even when the edit succeeded.
foreach my $key (qw(cleanup_warning audit_warning)) {
	print ui_alert_box(html_escape($job->{$key}), 'warn', undef, undef, '')
		if ($job->{$key});
	}
}

# vm_edit_form_start(settings, token, action, [extra], [form_id])
# Binds one operation to the guest UUID and the configuration shown to the user.
sub vm_edit_form_start
{
my ($s, $token, $action, $extra, $form_id) = @_;
return ui_form_start('edit_machine.cgi', 'post', undef,
	$form_id ? 'id="'.quote_escape($form_id).'"' : undef).
	join('', map { ui_hidden($_->[0], $_->[1]) }
	[ id => $s->{'id'} ], [ revision => $s->{'revision'} ],
	[ token => $token ], [ action => $action ], @{$extra || []});
}

# show_vm_password_reset_form(vm, token)
# Renders the reset form with an editable username and signed token.
sub show_vm_password_reset_form
{
my ($vm, $token) = @_;
# Suggest the creation account; guests without that metadata need a username.
my $username = ($vm->{'cloudmin'} || {})->{'username'} || '';
# Never refill the password field from a previous submission.
return ui_page_start().ui_note($text{'vm_password_reset_help'}).
	ui_form_start('edit_machine.cgi', 'post', undef, 'id="vm-password-reset-form"').
	ui_hidden('id', $vm->{'uuid'}).ui_hidden('token', $token).
	ui_hidden('action', 'reset_password').
	ui_table_start(undef, 'width=100%', 2).
	ui_table_row($text{'vm_password_username'}, ui_textbox('username', $username, 30, 0, undef,
		'autocomplete="off" required')).
	ui_table_row($text{'vm_password_new'}, ui_password('password', '', 30, 0, undef,
		'data-password autocomplete="new-password" required')).
	ui_table_end().ui_form_end([[undef, $text{'vm_password_reset'}]]).ui_page_end();
}

# show_vm_force_off_form(vm, token, [return_to], [action])
# Confirms emergency power-off or hard reset without changing the guest on GET.
# action defaults to force_off; return_to defaults to the VM details page.
sub show_vm_force_off_form
{
my ($vm, $token, $return_to, $action) = @_;
$action = ($action || '') eq 'reset' ? 'reset' : 'force_off';
$return_to = ($return_to || '') eq 'edit_machine' ? 'edit_machine' : 'machine';
return ui_page_start().
	ui_alert_box(text('vm_control_'.$action.'_warning', '<tt>'.html_escape($vm->{'name'}).'</tt>'),
		'warn', undef, undef, '').
	ui_form_start('machine.cgi', 'post', undef, 'id="vm-force-off-form"').
	ui_hidden('id', $vm->{'uuid'}).ui_hidden('token', $token).
	ui_hidden('action', $action).ui_hidden('confirm', 1).
	ui_hidden('return', $return_to).
	ui_form_end([[undef, $text{'vm_control_'.$action.'_button'}]]).ui_page_end();
}

# vm_pending_fields()
# Defines display order and labels for pending resource and network changes.
sub vm_pending_fields
{
return ([cpus => 'vm_cpus'], [cpu_limit => 'vm_cpu_limit'],
	[memory_mib => 'vm_memory_mib'], [memory_limit_mib => 'vm_memory_limit'],
	[boot => 'vm_boot_first'], [bootmenu => 'vm_boot_menu'],
	[networks => 'vm_interfaces']);
}

# vm_boot_labels(vm)
# Shares localized boot and network labels between rendering and live updates.
sub vm_boot_labels
{
my ($vm) = @_;
# Full settings carry disk records; status updates
# carry only target-to-role maps.
my %roles = (%{$vm->{'disk_roles'} || {}},
	map { $_->{'target'} => $_->{'role'} || (($_->{'device'} || '') eq 'cdrom' ? 'cdrom' : 'disk') }
	@{$vm->{'disks'} || []});
return { roles => { map { $_ => $text{'vm_disk_role_'.$_} }
	qw(system data seed disk cdrom) }, disks => \%roles,
	kinds => { hd => $text{'vm_disks'}, cdrom => $text{'vm_disk_role_cdrom'},
	fd => $text{'vm_boot_floppy'}, network => $text{'vm_boot_network'}, bridge => $text{'net_bridge'},
	interface => $text{'vm_boot_network'}, disk => $text{'vm_disk_role_disk'} } };
}

# vm_boot_label(device, labels)
# Uses known disk roles; legacy boot classes retain descriptive generic names.
sub vm_boot_label
{
my ($device, $labels) = @_;
my $kind = $device->{'device'} || 'disk';
my $target = $device->{'target'};
if ($kind eq 'disk' && $target) {
	# Per-device boot entries retain the guest
	# target after the friendly role.
	return ($labels->{'roles'}->{$labels->{'disks'}->{$target} || 'disk'} ||
		$labels->{'roles'}->{'disk'}).' ('.$target.')';
	}
return ($labels->{'kinds'}->{$kind} || $kind).($target ? ' ('.$target.')' : '');
}

# vm_pending_value(field, value, [boot_labels])
# Formats running or saved values; callers escape the returned text.
# Omitted boot_labels uses generic disk and network labels.
sub vm_pending_value
{
my ($field, $value, $labels) = @_;
# Memory settings arrive in MiB; display them using Webmin's size formatting.
return nice_size_text($value * 1024**2) if ($field =~ /memory/);
# Render the boot-menu flag with the same translated values as the form.
return $text{$value ? 'index_yes' : 'index_no'} if ($field eq 'bootmenu');
if ($field eq 'networks') {
	# Stable MACs distinguish multiple interfaces without exposing host tap names.
	$labels ||= vm_boot_labels({});
	return join(', ', map { $_->{'mac'}.': '.$labels->{'kinds'}->{$_->{'type'}}.
		' '.$_->{'source'} } @$value) || $text{'vm_software_none'};
}
if ($field eq 'boot') {
	# Preserve libvirt's reported order, including
	# legacy device-class entries.
	return join(' → ', map { vm_boot_label($_, $labels || vm_boot_labels({})) } @$value) || $text{'vm_boot_default'};
	}
return $value;
}

# vm_header_status(vm, [pending_only])
# Groups subtitle badges; console pages omit the guest's power state.
# pending_only defaults to false; true keeps only the saved-change badge.
sub vm_header_status
{
my ($vm, $pending_only) = @_;
my $state = $vm->{'state'} || ($vm->{'active'} ? 'running' : 'shutoff');
return ui_tag('span',
	($pending_only ? '' : ui_badge($text{'index_state_'.$state}, $state eq 'running' ? 'success' : 'neutral',
		{ dot => 1, rounded => 1, small => 1, class => 'vm-pending-state' })).
	ui_tag('span', ui_badge($text{'vm_pending_badge'}, 'warning',
		{ icon => 'power', rounded => 1, small => 1 }),
		{ 'data-vm-header-pending' => '',
		(keys %{$vm->{'pending'} || {}} ? () : (hidden => undef)) }),
	{ class => 'ui_page vm-header-status' });
}

# vm_power_cycle_button(vm, token, [return_to])
# Keeps power cycling beside the other controls in a separate signed POST form.
# The button requires host management and a token; return_to defaults to details.
sub vm_power_cycle_button
{
my ($vm, $token, $return_to) = @_;
return '' if (!$token || !can_access('manage'));
my $state = $vm->{'state'} || ($vm->{'active'} ? 'running' : 'shutoff');
return ui_form_start('machine.cgi', 'post', undef,
	'id="vm-power-cycle-form"'.(keys %{$vm->{'pending'} || {}} &&
		$state =~ /\A(?:running|blocked)\z/ ? '' : ' hidden')).
	ui_hidden('id', $vm->{'uuid'} || $vm->{'id'}).ui_hidden('token', $token).
	ui_hidden('action', 'power_cycle').
	ui_hidden('return', ($return_to || '') eq 'edit_machine' ? 'edit_machine' : 'machine').
	# Match the controls in the editor footer or compact details row.
	(($return_to || '') eq 'edit_machine' ? ui_submit($text{'vm_control_power_cycle_button'}) :
		ui_action_button($text{'vm_control_power_cycle'}, 'warning',
			{ type => 'submit', size => 'small', icon => 'power' })).
	ui_form_end(undef, undef, 1);
}

# show_vm_pending_styles()
# Shares subtitle badge spacing with pages that do not show a pending alert.
sub show_vm_pending_styles
{
return ui_page_assets().ui_tag('link', undef, { rel => 'stylesheet', href => get_webprefix().'/server-manager/machine_pending.css?'.
	(stat("$module_root_directory/machine_pending.css"))[9] });
}

# show_vm_pending_banner(vm)
# Renders supplied running/saved differences above the editor or VM details.
sub show_vm_pending_banner
{
my ($vm) = @_;
my $pending = $vm->{'pending'} || {};
my $count = scalar(keys %$pending);
my $boot_labels = vm_boot_labels($vm);
# Send the same value labels to the browser for subsequent status updates.
my $labels = { one => $text{'vm_pending_one'}, many => $text{'vm_pending_many'},
	values => $text{'vm_pending_values'}, yes => $text{'index_yes'}, no => $text{'index_no'},
	boot_default => $text{'vm_boot_default'}, boot_labels => $boot_labels,
	none => $text{'vm_software_none'} };
my $rows = join('', map {
	my ($field, $label) = @$_;
	my $entry = $pending->{$field};
	# Keep hidden rows in the DOM so status updates
	# can reveal new differences.
	ui_tag('div', ui_tag('span', html_escape($text{$label}), { class => 'vm-pending-label' }).
		ui_tag('span', $entry ? html_escape(text('vm_pending_values',
			map { vm_pending_value($field, $entry->{$_}, $boot_labels) } qw(running saved))) : '',
			{ 'data-pending-values' => '', class => 'vm-pending-values' }),
		{ 'data-pending-field' => $field, ($entry ? () : (hidden => undef)) })
	} vm_pending_fields());
my $body = ui_tag('div',
	ui_tag('strong', html_escape($count == 1 ? $text{'vm_pending_one'} : text('vm_pending_many', $count)),
		{ 'data-pending-title' => '' }).
	ui_tag('div', $rows, { class => 'vm-pending-changes' }).
	ui_tag('p', html_escape($text{'vm_pending_explain'}), { class => 'vm-pending-explain' }),
	{ class => 'vm-pending-content' });
# Let the standard warning alert supply colors; this page owns its inner layout.
return show_vm_pending_styles().
	ui_tag('div',
		ui_alert($body, 'warning', ['fa-power-off', '', 1],
			{ class => 'vm-pending-alert' }),
		{ class => 'ui_page vm-pending', 'data-vm-pending-banner' => '',
		'data-pending-config' => html_escape(convert_to_json($labels)),
		($count ? () : (hidden => undef)), role => 'status', 'aria-live' => 'polite' }).
	ui_tag('script', '', { src => get_webprefix().'/server-manager/machine_pending.js?'.(stat("$module_root_directory/machine_pending.js"))[9] });
}

# show_vm_delete_disk_form(settings, token, disk)
# Confirms permanent deletion using the editor's signed, revision-bound form.
sub show_vm_delete_disk_form
{
my ($s, $token, $disk) = @_;
my $volume = $disk->{'volume_info'};
return ui_alert_box($text{'vm_delete_disk_desc'}, 'danger', undef, undef, '').
	vm_edit_form_start($s, $token, 'delete_disk',
		[[ target => $disk->{'target'} ], [ vm_edit_tabs => 'disks' ]]).
	ui_table_start($text{'vm_delete_disk_title'}, 'width=100%', 2).
	ui_table_row($text{'vm_delete_disk_name'}, html_escape(vm_disk_label($disk)).
		show_disk_location($volume->{'path'} || $volume->{'name'})).
	ui_table_end().ui_form_end([[undef, $text{'delete'}]]);
}

1;
