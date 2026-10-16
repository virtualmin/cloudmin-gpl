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

1;
