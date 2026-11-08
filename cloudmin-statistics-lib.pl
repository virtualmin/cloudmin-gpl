# Statistics configuration, authorized reads, charts and service installation.
use strict;
use warnings;
use Time::HiRes ();
our (%config, %text, $module_root_directory, $module_var_directory,
     $module_config_directory, $config_directory, $var_directory,
     $root_directory,
     $cloudmin_statistics_runtime);
require "$module_root_directory/lib/Cloudmin/Statistics.pm";

# statistics_settings() resolves bounded host settings for each collector tick.

sub statistics_settings
{
return { recording => ($config{statistics_recording} // 1) ? 1 : 0,
	 interval => config_number('statistics_interval'),
	 guest_interval => config_number('statistics_guest_interval'),
	 budget => config_number('statistics_budget') * 1024 * 1024,
	 uplinks => $config{statistics_uplinks} || '',
	 retention => { 0 => config_number('statistics_raw_hours') * 3600,
			60 => config_number('statistics_minute_days') * 86400,
			300 => config_number('statistics_five_days') * 86400,
			3600 => config_number('statistics_hour_days') * 86400 } };
}

# statistics_latest() reads fresh collector values without sampling libvirt.

sub statistics_latest
{
return Cloudmin::Statistics::latest(statistics_runtime_directory(),
				    Time::HiRes::time());
}

# statistics_runtime_directory() keeps live readings independent of history disk
# space. Tests supply a private directory. Systemd creates the
# host's runtime directory.

sub statistics_runtime_directory
{
return $cloudmin_statistics_runtime || '/run/cloudmin-statistics';
}

# statistics_integer(input, key, default, min, max) validates query bounds.

sub statistics_integer
{
my ($input, $key, $default, $min, $max) = @_;
my $value = $input->{$key};
# An omitted option uses its default. Explicit values must be bounded integers.
return $default unless defined($value);
die "Invalid statistics $key\n" if ref($value) || $value !~ /\A\d{1,12}\z/ ||
	$value < $min || $value > $max;
return 0 + $value;
}

# call_statistics_api(action, input) checks scope before reading any metrics.

sub call_statistics_api
{
my ($action, $input) = @_;
my $id = $input->{id};
# Exports and requests without a VM ID expose host data to administrators only.
if ($action eq 'statistics_export' || !defined($id) || $id eq 'host') {
	require_access('host');
	}
# Guest reads require an exact UUID and the current view grant.
else {
	die "Invalid statistics VM ID\n" if ref($id) || $id !~
		/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i;
	require_access('view', $id);
	}
# Open history read-only. Live values remain usable if the database fails.
my $store =
	eval { Cloudmin::Statistics->new(directory => $module_var_directory) };
my $history_error = $@;
# Exports need stored summaries and cannot fall back to the live cache.
if ($action eq 'statistics_export') {
	die $history_error unless $store;
	my $step = statistics_integer($input, 'step', 60, 60, 3600);
	my $limit = statistics_integer($input, 'limit', 500, 1, 1000);
	die "Invalid statistics cursor\n" if ref($input->{cursor}) ||
		length($input->{cursor} || '') > 80;
	return $store->export($step, $input->{cursor}, $limit);
	}
# Ignore cached live readings when collection is disabled.
my $enabled = statistics_enabled();
my $latest = $enabled ? statistics_latest() : { };
# Choose one authorized owner and a bounded chart window.
my $host = !defined($id) || $id eq 'host';
my $owner = $host
	? ($latest->{host_id} || ($store ? $store->{meta}->{host_id} : undef) ||
	   'host')
	: lc($id);
my $now = time();
my $to = statistics_integer($input, 'to', $now, 1, $now + 60);
my $from = statistics_integer($input, 'from', $to - 3600, 0, $to - 1);
die "Invalid statistics range\n" if $to - $from > 366 * 86400;
# Bound output size and reject structured or oversized device identifiers.
my $points = statistics_integer($input, 'points', 600, 60, 1200);
my $entity = $input->{entity};
die "Invalid statistics device\n" if defined($entity) &&
	(ref($entity) || length($entity) > 160);
# Retain the database error for diagnostics while allowing empty history.
my $result = $store
	? eval { $store->query($owner, $from, $to, $points, $entity) }
	: undef;
my $history_available = $result && $store->{db} ? 1 : 0;
$history_error ||= $@;
if (!$result) {
	# A broken history file must not hide live charts or
	# trigger another writer.
	my $empty = bless { }, 'Cloudmin::Statistics';
	$result = $empty->query($owner, $from, $to, $points, $entity);
	}
# Attach only the requested owner's fresh values and collection status.
$result->{live} = $host ? $latest->{host} : $latest->{vms}->{$owner};
$result->{recording} = $enabled && statistics_settings()->{recording} ? 1 : 0;
$result->{history_available} = $history_available;
$result->{collector} =
	{ map { $_ => $latest->{$_} } qw(checked_at interval stale) };
$result->{collector}->{enabled} = $enabled ? 1 : 0;
# Host diagnostics may contain host paths. Delegates receive only availability.
my $error = $history_error || $latest->{error};
$result->{collector}->{error} = $host
	? $error
	: $error ? $text{statistics_collection_error} : undef;
$result->{collector}->{available} = $latest->{checked_at} && !$latest->{stale}
	? 1
	: 0;
return $result;
}

# show_statistics(owner) renders statistics for 'host' or a VM UUID. Webmin
# widgets provide the toolbar, cards and headline slots. statistics.js fills the
# values and draws the charts with Webmin's shared uPlot build.

sub show_statistics
{
my ($owner) = @_;
my $host = $owner eq 'host';
my $prefix = get_webprefix();
# Pass translated labels and shared asset URLs to the page controller.
my %labels =
	map { $_ => $text{"statistics_$_"} } qw(loading unavailable disabled empty
	filesystems_empty no_device error all cpu memory disk network filesystems
	load load_1 load_5 load_15 cpu_wait waiting pools pools_empty vcpus_allocated
	memory_allocated
	total used read write receive transmit avg peak_at of cpus cpu1
	samples updated recording_off gap_collector gap_agent gap_blank
	change_up change_down change_none used_space allocated_space last last_hour
	between custom_invalid event_count events_count
	mount_usage seconds minutes hour hours day days);
# Host traffic describes uplinks, while guest traffic describes virtual NICs.
$labels{network} = $text{statistics_host_network} if ($host);
my $settings = { owner => $owner, api => "$prefix/server-manager/api.cgi",
		 assets => "$prefix/unauthenticated/js/", css =>
								  "$prefix/unauthenticated/css/",
		 labels => \%labels };
# Preset periods apply immediately. The last option opens the custom range.
my $period =
	ui_tag('span', $text{statistics_range},
	       { class => 'cloudmin-statistics-label' }).
	ui_segmented('statistics_range', 3600,
		     [ map { [ $_->[0], $text{"statistics_$_->[1]"} ] }
		       [ 3600, '1h' ], [ 21600, '6h' ], [ 86400, '24h' ],
		       [ 604800, '7d' ],
		       [ 2592000, '30d' ], [ 'custom', 'custom' ] ],
		     { class => 'cloudmin-statistics-periods' }).
	ui_tag('span', ui_cluster([
		custom_moment_inputs('statistics_from',
				     $text{statistics_from}),
		ui_tag('span', '&ndash;', { 'aria-hidden' => 'true' }),
		custom_moment_inputs('statistics_to',
				     $text{statistics_to}),
		ui_action_button($text{statistics_apply}, 'primary',
				 { icon => '',
				   class => 'cloudmin-statistics-apply' }) ]),
	       { class => 'cloudmin-statistics-custom', hidden => undef });
# The device filter appears only when the period has several disks or NICs.
# Device names label the choices. The field label is for screen readers.
my $tools = ui_tag('label',
		   ui_select('statistics_device', '', [ [ '',
							  $text{statistics_all} ] ],
			     undef, undef, undef, undef,
			     "aria-label='".quote_escape($text{statistics_device})."'"),
		   { class => 'cloudmin-statistics-device ui_select_inline',
		     hidden =>
			     undef }).
	    ui_tag('span',
		   ui_tag('span', '',
			  { class => 'cloudmin-statistics-status',
			    role => 'status',
			    'aria-live' => 'polite' }).
		   # The line below the status counts down to the next refresh.
		   ui_tag('span',
			  ui_tag('span', '',
				 {
					 class => 'cloudmin-statistics-countdown-fill' }),
			  { class => 'cloudmin-statistics-countdown',
			    'aria-hidden' =>
				    'true', hidden => undef }),
		   { class => 'cloudmin-statistics-freshness' });
my $toolbar = ui_tag('div',
		     ui_tag('div', $period,
			    { class => 'cloudmin-statistics-period' }).
		     ui_tag('div', $tools,
			    { class => 'cloudmin-statistics-tools' }),
		     { class => 'cloudmin-statistics-toolbar' });
# chart(name, series) builds a card with a headline slot. Charts with several
# series have a legend under the title.
my $chart = sub {
	my ($name, $series) = @_;
	my $legend = join('', map {
		ui_tag('span',
		       ui_tag('i', '',
			      { class => 'cloudmin-statistics-dot '.
					 'cloudmin-statistics-dot-'.($_ + 1) }).$series->[$_],
		       { class => 'cloudmin-statistics-key' })
		} 0 .. $#$series);
	# Reserve current-value slots and a capacity bar for memory.
	my $headline = ui_tag('div',
			      ui_tag('strong', '&ndash;',
				     { class => 'cloudmin-statistics-value' }).
			      ui_tag('span', '',
				     { class => 'cloudmin-statistics-detail' }).
			      ($name eq 'memory'
				      ? ui_tag('div',
					       ui_tag('div', '',
						      { class => 'cloudmin-statistics-bar-fill' }),
					       { class => 'cloudmin-statistics-bar',
						 'aria-hidden' => 'true' })
				      : ''),
			      { class => 'cloudmin-statistics-headline' });
	# Keep chart containers stable while JavaScript updates their readings.
	return ui_card({ title => $labels{$name},
			 desc_html => @$series > 1 ? $legend : undef,
			 actions => $headline,
			 body => ui_tag('div',
					ui_tag('p', $text{statistics_loading},
					       { class => 'cloudmin-statistics-empty' }),
					{
						class => 'cloudmin-statistics-plot cloudmin-statistics-plot-loading',
						'data-chart' => $name }),
			 class =>
				 "cloudmin-statistics-chart cloudmin-statistics-chart-$name" });
	};
# Guests also show how long their vCPUs waited for the host.
my @cards = ( $chart->('cpu', $host
	? [ $labels{cpu} ]
	: [ $labels{cpu}, $labels{cpu_wait} ]),
	# Load averages are a host reading; libvirt does not see inside guests.
	      ($host
		      ? $chart->('load',
				 [ $labels{load_1}, $labels{load_5},
				   $labels{load_15} ])
		      : ()),
	      $chart->('memory', [ $labels{used}, $labels{total} ]),
	      $chart->('disk', [ $labels{read}, $labels{write} ]),
	      $chart->('network', [ $labels{receive}, $labels{transmit} ]) );
# Hosts read as one column of wide rows; guests as a grid of compact cards.
my $charts = $host
	? ui_stack(\@cards, { class => 'cloudmin-statistics-charts' })
	: ui_grid(\@cards, { cols => 2,
			     class => 'cloudmin-statistics-charts' });
# Guest filesystems are current usage bars, not a flat line over the period;
# hosts list their storage pools the same way. A sentence under the title
# describes the change over the selected period.
my $filesystems = ui_card({ title => $host
	? $labels{pools}
	: $labels{filesystems},
			    desc_html =>
				    ui_tag('span', '',
					   { class => 'cloudmin-statistics-change' }),
			    body => ui_tag('div',
					   ui_tag('p',
						  $text{statistics_loading},
						  { class => 'cloudmin-statistics-empty' }),
					   { class => 'cloudmin-statistics-mounts' }),
			    class => 'cloudmin-statistics-filesystems'.($host
				    ? ' cloudmin-statistics-pools'
				    : '') });
# Hide the event timeline until the selected period has events.
my $changes = ui_tag('div', ui_card({ title => $text{statistics_events},
				      desc_html =>
					      ui_tag('span', '',
						     { class => 'cloudmin-statistics-events-summary' }),
				      body =>
					      ui_tag('ol', '',
						     { class => 'ui_feed cloudmin-statistics-events',
						       role => 'list' }) }),
		     { class => 'cloudmin-statistics-changes',
		       hidden => undef });
my $panel = ui_tag('div', $toolbar.
		   ui_tag('div', '',
			  { class => 'cloudmin-statistics-notice',
			    role => 'status' }).
		   $charts.$filesystems.$changes,
		   { class => 'cloudmin-statistics '.($host
			   ? 'cloudmin-statistics-host'
			   : 'cloudmin-statistics-vm'),
		     'data-statistics' => convert_to_json($settings) });
# Version module assets by modification time so deployed fixes bypass caches.
return ui_page_start({ class => 'cloudmin-statistics-page' }).
       ui_tag('link', undef,
	      { rel => 'stylesheet', href =>
					     "$prefix/server-manager/statistics.css?".
					     (stat("$module_root_directory/statistics.css"))[9] }).
       $panel.
       ui_tag('script', '',
	      { src =>
			"$prefix/server-manager/statistics.js?".
			(stat("$module_root_directory/statistics.js"))[9] }).
       ui_page_end();
}

# custom_moment_inputs(prefix, label) returns themed text boxes that the browser
# shows as a date picker and a quarter-hour time picker. A theme that ships its
# own calendar replaces the date picker from statistics.js.

sub custom_moment_inputs
{
my ($prefix, $label) = @_;
my $date = ui_textbox(
	"${prefix}_date", '', 10, 0, undef,
	"aria-label='".quote_escape($label)."' autocomplete='off'");
my $time = ui_textbox("${prefix}_time", '', 8, 0, undef,
		      "aria-label='".quote_escape($label).
		      "' step='900' autocomplete='off'");
# Themes decide the text box markup and its quoting; only the types change.
$date =~ s/\btype=(["'])text\1/type=$1date$1/;
$time =~ s/\btype=(["'])text\1/type=$1time$1/;
return $date.$time;
}

# statistics_unit(config, var, root, module, perl) fills the service template.
# The first four arguments are directories. Perl is the interpreter path. This
# only renders text, without installing or starting the service.

sub statistics_unit
{
my ($config, $var, $root, $module, $perl) = @_;
# quote(value) escapes one systemd argument and rejects line injection.
my $quote = sub {
	my $v = shift;
	die "Invalid service path\n" if $v =~ /[\r\n\0]/;
	$v =~ s/(["\\])/\\$1/g;
	$v =~ s/%/%%/g;
	return '"'.$v.'"';
	};
# Quote complete assignments and avoid Webmin's built-in template variables.
my %values = (
	service_config => $quote->("WEBMIN_CONFIG=$config"),
	service_var => $quote->("WEBMIN_VAR=$var"),
	service_perllib => $quote->("PERLLIB=$root"),
	service_perl => $quote->($perl),
	service_collector => $quote->("$module/statistics-collector.pl") );
# Read the bundled template before substituting the quoted paths.
my $data =
	read_file_contents(
		"$module_root_directory/cloudmin-statistics.service.in");
die "Cannot read statistics service template\n" unless defined($data) &&
	length($data);
return substitute_template($data, \%values);
}

# set_statistics_service_enabled(enabled, [restart]) controls collection.
# Enabled starts collection. Restart defaults to false and is used for upgrades.

sub set_statistics_service_enabled
{
my ($enabled, $restart) = @_;
# Service changes require root on Linux.
die "Manage statistics on the Linux host as root\n" unless $^O eq 'linux' &&
	$< == 0;
foreign_require('systemd');
my $name = 'cloudmin-statistics.service';
my $path = systemd::get_unit_root($name)."/$name";
# Recreate a missing file without replacing administrator masks or links.
write_statistics_service($name, $path) if (!-e $path && !-l $path);
my ($ok, $error);
# Enable startup at boot, then start collection or restart it for an upgrade.
if ($enabled) {
	($ok, $error) = systemd::enable_unit($name);
	die "Cannot enable statistics service: $error\n" unless $ok;
	($ok, $error) = $restart
		? systemd::restart_unit($name)
		: systemd::start_unit($name);
	die "Cannot start statistics service: $error\n" unless $ok;
	}
# Stop collection now and prevent it from returning after a reboot.
else {
	($ok, $error) = systemd::stop_unit($name);
	die "Cannot stop statistics service: $error\n" unless $ok;
	($ok, $error) = systemd::disable_unit($name);
	die "Cannot disable statistics service: $error\n" unless $ok;
	}
}

# write_statistics_service(name, path) writes the named unit through Webmin.
# Path is its destination from get_unit_root(), used to set permissions. The
# caller must check that it is missing or owned by Cloudmin.

sub write_statistics_service
{
my ($name, $path) = @_;
my $data = statistics_unit($config_directory, $var_directory,
			   $root_directory, $module_root_directory,
			   get_perl_path());
# Webmin validates and writes the unit, then reloads systemd.
my ($ok, $error) = systemd::create_system_unit($name, $data);
die "Cannot install statistics service: $error\n" unless $ok;
set_ownership_permissions(0, 0, 0644, $path);
}

# install_statistics_service([remove]) manages the collector through Webmin. A
# true remove uninstalls it. Omitting remove installs or updates it.

sub install_statistics_service
{
my ($remove) = @_;
# Installation and removal require root on Linux.
die "Install statistics on the Linux host as root\n" unless $^O eq 'linux' &&
	$< == 0;
foreign_require('systemd');
my $name = 'cloudmin-statistics.service';
# Preserve administrator links, masks and files without our ownership marker.
my $path = systemd::get_unit_root($name)."/$name";
my $exists = -e $path;
die "Cloudmin statistics service is managed outside Cloudmin\n" if -l $path ||
	($exists && (
		!-f $path || (read_file_contents($path) || '') !~
		/^# Cloudmin statistics; installed by server-manager\/postinstall\.pl$/m));
my ($ok, $error);
# Stop the writer before disabling and deleting its owned service file.
if ($remove) {
	return unless $exists;
	set_statistics_service_enabled(0);
	($ok, $error) = systemd::delete_system_unit($name, $path);
	die "Cannot remove statistics service: $error\n" unless $ok;
	}
# Install the current template and apply the saved collection switch.
else {
	write_statistics_service($name, $path);
	# Restart enabled collectors so upgrades take effect immediately.
	set_statistics_service_enabled(statistics_enabled(), 1);
	}
}

1;
