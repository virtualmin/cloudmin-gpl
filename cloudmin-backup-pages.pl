use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Use the same column and section definitions as Module Configuration.
require(
	Cwd::abs_path(File::Basename::dirname(__FILE__).
		      '/cloudmin-config-lib.pl'));
require(
	Cwd::abs_path(File::Basename::dirname(__FILE__).
		      '/cloudmin-pro-lib.pl'));
our (%text, $remote_user, $module_root_directory);

# show_backup_destination(prefix, [target]) groups fields by destination
# provider. prefix separates each selector's input names. target defaults to
# local backups under /var/backups/cloudmin; saved secrets are never
# echoed into the form.
sub show_backup_destination
{
my ($prefix, $target) = @_;
$target ||= { mode => 'local', path => '/var/backups/cloudmin' };
my @options;
# Offer disabled Pro previews when enabled. Always retain a saved unavailable
# provider so editing its schedule cannot silently select a different target.
my %installed = map { $_ => 1 } Cloudmin::BackupTransport::modes();
my @preview =
	grep { !$installed{$_} && (show_pro_features() ||
				   $target->{'mode'} eq $_) }
	qw(gcs azure bb dropbox drive);
foreach my $mode ( Cloudmin::BackupTransport::modes(), @preview ) {
	my $preview = !$installed{$mode};
	my @fields = $mode eq 'local'
		? qw(path)
		: $mode eq 'ssh'
			? qw(host port path authentication)
			: $mode eq 's3'
				? qw(bucket path access secret session_token region endpoint ca_file)
				: $mode eq 'azure'
					? qw(bucket path account subscription secret)
					: $mode eq 'bb'
						? qw(bucket path access secret)
						: $mode eq 'gcs'
							? qw(bucket path project access secret refresh_token)
							: qw(path project access secret refresh_token);
	my @inputs;
	foreach my $field (@fields) {
		# Each selector has distinct field names; hidden
		# providers cannot override it.
		my $name = $prefix.'_'.$mode.'_'.$field;
		my $value = $target->{'mode'} eq $mode ? $target->{$field} : '';
		my $input;
		if ($field eq 'authentication') {
			# Show one credential method; the parser
			# discards the unused method.
			my $ssh = $target->{'mode'} eq 'ssh' ? $target : { };
			$input = ui_select_switch($name, $ssh->{'key_file'}
				? 'key'
				: 'password', [
					{ value => 'password',
					  label => $text{'backup_field_password'}, fields => [
						  [ undef,
						    show_backup_input($prefix,
								      $mode,
								      'user',
								      $ssh->{'user'}) ],
						  [ undef,
						    show_backup_input($prefix,
								      $mode,
								      'password',
								      $ssh->{'password'}) ] ] },
					{ value => 'key',
					  label => $text{'backup_field_key_file'}, fields => [ [ undef,
												 show_backup_input($prefix, $mode, 'key_file', $ssh->{'key_file'}) ] ] },
				]);
			}
		# Ordinary destination fields share sizing, defaults
		# and secret handling.
		else {
			$input =
				show_backup_input($prefix, $mode, $field,
						  $value);
			}
		# Keep labels above inputs and disable fields for
		# unavailable providers.
		push(@inputs, [ undef, ui_field(undef,
						ui_tag('span',
						       $preview
							       ? pro_feature_preview($input, 'cloud-backups')
							       : $input,
						       { style => 'max-width:100%' }),
						{ for => $name,
						  label_html => hlink($text{'backup_field_'.
									    $field}, 'backup_field_'.$field) }) ]);
		}
	push(@options,
	     { value => $mode, label =>
				       $text{'backup_mode_'.$mode}.
				       ($preview ? ' (Pro)' : ''),
	       fields => \@inputs });
	}
# Stacked labels stay level when the authentication control occupies two lines.
my $switch = ui_select_switch($prefix.'_mode', $target->{'mode'}, \@options,
			      { class => 'cloudmin-backup-destination' });
# The common widget has no per-option disabling API; disable only Pro options.
foreach my $mode (@preview) {
	$switch =~ s{(<option\b[^>]*\bvalue=["']\Q$mode\E["'])}{$1 disabled}g;
	}
# Explain unavailable destinations only while their previews are present.
return $switch.(@preview
	? ui_note($text{'pro_tip_cloud-backups'}.' '.
		  pro_feature_badge('cloud-backups'), 0)
	: '').
       ui_tag('style',
	      '.cloudmin-backup-destination .ui_select_switch_field { align-items: flex-start; }
		.cloudmin-backup-destination [data-ui-switch-value] { border: 0; padding: 0; }');
}

# show_backup_input(prefix, mode, field, [value]) renders a sized destination
# input. Optional connection settings use the standard
# default/custom radio controls.
sub show_backup_input
{
my ($prefix, $mode, $field, $value) = @_;
my $name = $prefix.'_'.$mode.'_'.$field;
my %sizes = ( host => 25, port => 5, user => 25, password => 25,
	      key_file => 25, region => 18, bucket => 25, account => 25,
	      project =>
		      25 );
my $size = $sizes{$field} || 40;
my $hint = $field eq 'user' || $field eq 'password'
	? 'placeholder="'.quote_escape($text{'backup_field_'.$field}).
	   '" aria-label="'.quote_escape($text{'backup_field_'.$field}).
	   '"'
	: $field eq 'session_token'
		? 'placeholder="'.quote_escape($text{'backup_optional'}).'"'
		: '';
my %defaults =
	( port => '22', region => 'us-east-1', endpoint => '', ca_file => '' );
# Default/custom choices prevent hidden custom values overriding defaults.
if (exists($defaults{$field})) {
	return ui_opt_textbox($name, ($value // '') eq $defaults{$field}
		? ''
		: $value,
			      $size, $text{'backup_default_'.$field},
			      $text{'backup_custom'});
	}
if ($field eq 'key_file' || ($field eq 'path' && $mode eq 'local')) {
	# These paths belong to this host, so offer Webmin's file chooser.
	return ui_filebox($name, $value, $size, undef, undef, undef,
			  $field eq 'path');
	}
if ($field =~ /\A(?:password|secret|session_token|refresh_token)\z/) {
	# Never echo saved credentials or offer password
	# generation for remote logins.
	my $input = ui_password($name, '', $size, 0, undef,
				'autocomplete="new-password" data-password-meter-skip '.
				$hint);
	# Offer explicit clearing only when there is a saved secret to replace.
	$input .= ui_note($text{'backup_keep_secret'}, 0).
		  ui_checkbox($name.'_clear', 1, $text{'backup_clear_secret'},
			      0) if (length($value || ''));
	return $input;
	}
return ui_textbox($name, $value, $size, undef, undef, $hint);
}

# parse_backup_target(input, prefix) reads only the currently selected provider.
sub parse_backup_target
{
my ($in, $prefix) = @_;
my $mode = $in->{$prefix.'_mode'} || '';
my $target =
	{ mode => $mode, map { $_ => $in->{$prefix.'_'.$mode.'_'.$_} // '' }
	  qw(path host port user password key_file bucket access secret session_token endpoint region ca_file account subscription project refresh_token
	password_clear secret_clear session_token_clear refresh_token_clear) };
foreach my $field (qw(port region endpoint ca_file)) {
	# Disabled controls may still be submitted by themes;
	# honor the default choice.
	$target->{$field} = ''
		if ($in->{$prefix.'_'.$mode.'_'.$field.'_def'});
	}
# Read only the selected SSH authentication method.
if ($mode eq 'ssh') {
	my $auth = $in->{$prefix.'_ssh_authentication'} || 'password';
	die "Select password or private key authentication\n"
		if ($auth !~ /\A(?:password|key)\z/);
	if ($auth eq 'key') {
		# Do not retain an old saved password when
		# changing to a private key.
		$target->{'password'} = ''; $target->{'password_clear'} = 1;
		$target->{'user'} ||= 'root';
		}
	# Password login must not accidentally use a hidden,
	# previously selected key.
	else {
		$target->{'key_file'} = '';
		}
	}
return $target;
}

# show_backup_time(schedule) shows only the fields for the selected recurrence.
sub show_backup_time
{
my ($s) = @_;
my @options;
foreach my $frequency (qw(hourly daily weekly monthly yearly)) {
	my $prefix = 'schedule_'.$frequency.'_';
	my @fields;
	# Calendar fields precede the time, with no day selector
	# for hourly or daily.
	foreach my $field ( $frequency eq 'weekly' ? ('weekday') : (),
			    $frequency eq 'yearly' ? ('month') : (),
			    $frequency eq 'monthly' || $frequency eq 'yearly'
				    ? ('day')
				    : () ) {
		my @choices = $field eq 'weekday'
			? map { [ $_, $text{'backup_day_'.$_} ] } 0 .. 6
			: $field eq 'month'
				? map { [ $_,
					  $text{'backup_month_'.$_} ] } 1 .. 12
				: map { [ $_, $_ ] } 1 .. 31;
		push(@fields,
		     [ undef,
		       ui_field($text{'backup_'.$field},
				ui_select($prefix.$field, $s->{$field},
					  \@choices),
				{ for => $prefix.$field }) ]);
		}
	# Hourly runs need only minutes; other recurrences share
	# the hour/minute row.
	my $minute =
		ui_select($prefix.'minute', $s->{'minute'},
			  [ map { [ $_, sprintf('%02d', $_) ] } 0 .. 59 ],
			  undef, undef, undef, undef,
			  'aria-label="'.quote_escape($text{'backup_minute'}).
			  '"');
	my $time = $frequency eq 'hourly'
		? $minute
		: ui_cluster([ ui_select($prefix.'hour', $s->{'hour'},
					 [ map { [ $_, sprintf('%02d',
							       $_) ] } 0 .. 23 ],
					 undef, undef,
					 undef, undef,
					 'aria-label="'.
					 quote_escape($text{'backup_hour'}).'"'),
			       ':', $minute ], { gap => '0.4em' });
	push(@fields, [ undef, ui_field($text{$frequency eq 'hourly'
		? 'backup_minute'
		: 'backup_time'}, $time,
					{ for => $prefix.
						 ($frequency eq 'hourly' ? 'minute' : 'hour') }) ]);
	push(@options,
	     { value => $frequency, label => $text{'backup_'.$frequency},
	       fields => \@fields });
	}
return ui_select_switch('frequency', $s->{'frequency'}, \@options,
			{ class => 'cloudmin-backup-schedule' }).
       ui_tag('style',
	      '.cloudmin-backup-schedule [data-ui-switch-value] { border: 0; padding: 0; }');
}

# parse_backup_time(input) reads the controls belonging to
# the chosen recurrence.
sub parse_backup_time
{
my ($in) = @_;
my $frequency = $in->{'frequency'} || '';
return { frequency => $frequency,
	 map { $_ =>
		$in->{'schedule_'.$frequency.'_'.
		      $_} } qw(hour minute weekday day month) };
}

# show_backup_retention(days) groups retention choices without an inline note.
sub show_backup_retention
{
my ($days) = @_;
# Retention stores elapsed days; month and year choices mean 30 and 365 days.
my @groups =
	( [ 'days', 1, 6 ], [ 'weeks', 7, 4 ], [ 'months', 30, 12 ], [ 'years',
								       365,
								       10 ] );
my $options = ui_tag('option', html_escape($text{'backup_disabled'}),
		     { value => 0, !$days ? ( selected => undef ) : () });
foreach my $group (@groups) {
	my ($unit, $factor, $max) = @$group;
	my $choices =
		join('',
		     map { ui_tag('option',
				  html_escape(text('backup_retention_'.($_ == 1
					  ? substr($unit, 0, -1)
					  : $unit), $_)),
				  { value => $_ * $factor,
				    $days == $_ * $factor
					    ? ( selected => undef )
					    : () }) } 1 .. $max);
	$options .= ui_tag('optgroup', $choices,
			   { label => $text{'backup_'.$unit} });
	}
return ui_tag('select', $options,
	      { class => 'ui_select', name => 'purge', id => 'purge' });
}

# backup_schedule_label(schedule) describes the saved recurrence in the list.
sub backup_schedule_label
{
my ($s) = @_;
my $f = $s->{'frequency'};
my $time = sprintf('%02d:%02d', $s->{'hour'}, $s->{'minute'});
return text('backup_when_'.$f,
	    $f eq 'hourly'
		    ? (sprintf('%02d', $s->{'minute'}))
		    : $f eq 'weekly'
			    ? ( $text{'backup_day_'.$s->{'weekday'}}, $time )
			    : $f eq 'monthly'
				    ? ( $s->{'day'}, $time )
				    : $f eq 'yearly'
					    ? ( $text{'backup_month_'.$s->{'month'}},
						$s->{'day'},
						$time )
					    : ($time));
}

# show_backup_form(input, token) presents machines,
# destination, options and time.
sub show_backup_form
{
my ($in, $token) = @_;
# Editing must load the requested schedule rather than silently creating one.
my ($s) = grep { $_->{'id'} eq ($in->{'sched'} || '') } @{backup_schedules()};
die "Backup schedule not found\n" if ($in->{'sched'} && !$s);
# New forms select all guests unless opened for one guest, with daily defaults.
$s ||= { all => $in->{'id'} ? 0 : 1,
	 guests => $in->{'id'} ? [ $in->{'id'} ] : [ ],
	 hour => 2, minute => 0,
	 frequency => 'daily', weekday => 0, day => 1, month => 1,
	 shutdown => 0,
	 compression => 1, enabled => 1, purge => 0 };
my $scheduled = $in->{'new'} || $in->{'sched'};
my @domains = @{get_libvirt()->list_domains(1)};
my $html = ui_page_start().ui_p($text{'backup_intro'}).
	   ui_form_start($scheduled ? 'backup_sched.cgi' : 'backup.cgi',
			 'post').ui_hidden('token', $token).
	   ui_hidden('attempt', substr(Cloudmin::Images::generate_id(), 0, 32));
$html .= ui_hidden('sched', $s->{'id'}) if ($s->{'id'});
# Display preferences control expansion without changing saved backup options.
$html .= ui_hidden_table_start($text{'backup_machines'}, 'width=100%', 2,
			       'doms', section_open('backup_sections', 'doms'));
# The shared list owns the mode selector and hides choices for
# all-machine backups.
$html .= ui_table_row(hlink($text{'backup_machines'}, 'backup_machines'),
		      ui_multi_select_list('guests', $s->{'guests'},
					   [ map { [ $_->{'uuid'},
						     $_->{'name'} ] } @domains ],
					   { modes => { name => 'all',
							value => $s->{'all'},
							hide => [ 1 ],
							options => [ [ 1,
								       $text{'backup_all'} ],
								     [ 0,
								       $text{'backup_selected'} ] ] },
					     empty_label => $text{'index_none'} }));
$html .= ui_table_row(hlink($text{'backup_description'}, 'backup_description'),
		      ui_textbox('description', $s->{'description'},
				 55)) if ($scheduled);
$html .= ui_hidden_table_end('doms');
# Keep destination and preparation controls shared by manual and scheduled jobs.
$html .= ui_hidden_table_start($text{'backup_destination'}, 'width=100%', 2,
			       'dest', section_open('backup_sections', 'dest')).
	 ui_table_row(hlink($text{'backup_destination'}, 'backup_destination'),
		      show_backup_destination('dest0', $s->{'target'}), 1,
		      undef,
		      undef,
		      1).ui_hidden_table_end('dest');
$html .= ui_hidden_table_start($text{'backup_options'}, 'width=100%', 2, 'opts',
			       section_open('backup_sections', 'opts')).
	 ui_table_row(hlink($text{'backup_consistency'}, 'backup_consistency'),
		      ui_select('shutdown', $s->{'shutdown'},
				[ [ 0, $text{'backup_agent'} ],
				  [ 1, $text{'backup_shutdown'} ] ])).
	 ui_table_row(hlink($text{'backup_compression'}, 'backup_compression'),
		      ui_yesno_radio('compression', $s->{'compression'})).
	 ui_hidden_table_end('opts');
if ($scheduled) {
	# The schedule follows Virtualmin's enabled/time/retention grouping.
	$html .= ui_hidden_table_start($text{'backup_schedule'}, 'width=100%',
				       2, 'sched',
				       section_open('backup_sections',
						    'sched')).
		 ui_table_row(hlink($text{'backup_enabled'}, 'backup_enabled'),
			      ui_yesno_radio('enabled', $s->{'enabled'})).
		 ui_table_row(hlink($text{'backup_frequency'},
				    'backup_frequency'), show_backup_time($s)).
		 ui_table_row(hlink($text{'backup_retention'},
				    'backup_retention'),
			      show_backup_retention($s->{'purge'})).
		 ui_hidden_table_end('sched');
	}
$html .= ui_form_end([ [ $scheduled ? 'save' : undef,
			 $text{$scheduled ? 'backup_save' : 'backup_now'} ],
		       $s->{'id'}
			       ? ([ 'delete', $text{'backup_delete_schedule'} ])
			       : () ]).ui_page_end();
# Only SSH trust needs a browser check; input errors use the form handler.
return $html.backup_host_script();
}

# show_restore_form(input, token) selects an archive or
# confirms verified contents.
sub show_restore_form
{
my ($in, $token) = @_;
my $html = ui_page_start();
# The second stage displays the manifest from the completed inspection job.
if ($in->{'inspection'}) {
	my $job = get_vm_jobs()->get($in->{'inspection'}) ||
		  die "Backup inspection not found\n";
	die "Wait for backup inspection to finish\n"
		if ($job->{'state'} ne 'complete' ||
		    ($job->{'request'}->{'operation'} ||
		     '') ne 'backup_inspect');
	my $m = $job->{'resources'}->{'manifest'};
	# Match the restore controller's file and LVM destination choices.
	my @pools =
		grep { $_->{'active'} &&
			Cloudmin::Libvirt::disk_pool($_->{'type'}) } @{
				get_libvirt()->list_storage_pools(1)};
	$html .= ui_p($text{'restore_review'}).ui_form_start('restore.cgi',
							     'post').ui_hidden('token', $token).
		 ui_hidden('attempt',
			   substr(Cloudmin::Images::generate_id(), 0,
				  32)).ui_hidden('inspection', $job->{'id'}).
		 ui_hidden_table_start($text{'restore_contents'}, 'width=100%',
				       2, 'contents', 1).
		 ui_table_row(hlink($text{'vm_name'}, 'restore_name'),
			      ui_tag('tt', html_escape($m->{'name'}))).
		 ui_table_row(hlink($text{'restore_uuid'}, 'restore_uuid'),
			      ui_tag('tt', html_escape($m->{'uuid'}))).
		 ui_table_row(hlink($text{'restore_disks'}, 'restore_disks'),
			      scalar(@{$m->{'disks'}})).
		 ui_table_row(hlink($text{'restore_pool'}, 'restore_pool'),
			      ui_select('pool', '',
					[ map { [ $_->{'uuid'},
						  $_->{'name'} ] } @pools ])).
		 ui_table_row(undef,
			      ui_checkbox('confirm', 1,
					  $text{'restore_confirm'}, 0),
			      2).
		 ui_hidden_table_end('contents').ui_form_end([ [ undef,
								 $text{'restore_now'} ] ]);
	}
# First download and inspect; no guest resources are created by this form stage.
else {
	$html .= ui_p($text{'restore_intro'}).ui_form_start('restore.cgi',
							    'post').ui_hidden('token', $token).
		 ui_hidden('attempt',
			   substr(Cloudmin::Images::generate_id(), 0,
				  32)).
		 ui_hidden_table_start($text{'restore_source'},
				       'width=100%', 2, 'source', 1);
	# A listed backup identifies its private destination
	# through a record ID.
	if ($in->{'backup'}) {
		my $r = get_backup_service()->record($in->{'backup'}) ||
			die "Backup not found\n";
		$html .= ui_hidden('backup', $r->{'id'}).
			 ui_table_row(
				 hlink($text{'restore_source'},
				       'restore_source'),
				 ui_tag('tt', html_escape($r->{'filename'})).
				 ' &mdash; '.
				 ui_tag('tt',
					html_escape($r->{'destination'})));
		}
	# External archives need an explicit source and a
	# filename within that source.
	else {
		$html .= ui_table_row(hlink($text{'restore_source'},
					    'restore_source'),
				      show_backup_destination('src'), 1,
				      undef,
				      undef, 1).
			 ui_table_row(hlink($text{'restore_filename'},
					    'restore_filename'),
				      ui_textbox('filename', '',
						 60),
				      1, undef, undef, 1);
		}
	$html .= ui_hidden_table_end('source').ui_form_end([ [ undef,
							       $text{'restore_inspect'} ] ]);
	}
# The trust script also resolves destinations from saved archive IDs.
return $html.ui_page_end().backup_host_script();
}

# backup_host_script() confirms unknown or replaced SSH keys before submission.
sub backup_host_script
{
return ui_tag('script', '',
	      { src => get_webprefix().'/server-manager/backup-host-key.js?'.
		       (
			       (
				       stat($module_root_directory.
					    '/backup-host-key.js'))[9] || 0) });
}

# show_backup_list(token) lists archives and schedules with explicit actions.
sub show_backup_list
{
my ($token) = @_;
my @backups = grep { !$_->{'deleted'} } @{get_backup_service()->inventory()};
my @schedules = @{backup_schedules()};
# Read-only viewers see inventory but receive no mutation controls.
my $actions = $token
	? ui_cluster([
		ui_action_button($text{'backup_now'}, 'primary',
				 { icon => 'archive',
				   href => 'backup_form.cgi' }),
		ui_action_button($text{'backup_add_schedule'}, 'neutral',
				 { icon => 'clock',
				   href => 'backup_form.cgi?new=1' }),
		ui_action_button($text{'restore_title'}, 'neutral',
				 { icon => 'refresh',
				   href => 'restore_form.cgi' }),
	])
	: '';
my @rows;
# Archive rows expose destination labels, never private transport settings.
foreach my $row (@backups) {
	my $buttons = $token
		? ui_cluster([
			ui_action_button($text{'backup_restore'}, 'info',
					 { icon => 'refresh', size => 'small',
					   href =>
						   'restore_form.cgi?backup='.$row->{'id'} }),
			ui_form_start('delete_backup.cgi',
				      'post').ui_hidden('token',
							$token).ui_hidden('backup', $row->{'id'}).
			ui_action_button($text{'backup_delete'}, 'danger',
					 { icon => 'trash', size => 'small',
					   type => 'submit' }).ui_form_end(),
		])
		: '';
	push(@rows,
	     [ ui_tag('strong', html_escape($row->{'name'})),
	       make_date($row->{'created'}),
	       ui_tag('tt', html_escape($row->{'destination'})),
	       nice_size($row->{'size'}), $buttons ]);
	}
# Apply data-column preferences before appending any permitted actions.
my ($heads, $visible, $types) = table_columns('backup_columns', \@rows);
# Keep permitted actions available regardless of the selected data columns.
if ($token) {
	push(@$heads, '');
	push(@$types, 'string');
	push(@{$visible->[$_]}, $rows[$_]->[4]) foreach 0 .. $#rows;
	}
# Use full-width tables when populated and actionable empty states otherwise.
my $archives =
	ui_card({ id => 'cloudmin-backup-archives', title =>
							    $text{'backup_archives'},
		  actions => @rows ? ui_badge(scalar(@rows), 'neutral') : '',
		  body => @rows
			  ? ui_columns_table($heads, 100, $visible, $types, 0,
					     undef,
					     undef, 1)
			  : ui_empty_state({ icon => 'archive', title =>
									$text{'backup_empty'}, desc =>
												       $text{'backup_empty_help'} }) });
# Summaries show recurrence and state without rendering saved credentials.
@rows =
	map { [ ui_link(
		'backup_form.cgi?sched='.$_->{'id'},
		html_escape($_->{'description'} || $text{'backup_schedule'})),
		ui_tag('tt', html_escape(
			Cloudmin::BackupTransport::label($_->{'target'}))),
		$_->{'all'} ? $text{'backup_all'} : scalar(@{$_->{'guests'}}),
		ui_badge($text{$_->{'enabled'}
			? 'backup_active'
			: 'backup_disabled'},
			 $_->{'enabled'} ? 'success' : 'neutral',
			 { small => 1 }),
		html_escape(backup_schedule_label($_)) ] } @schedules;
# Schedule columns have separate settings; description and status stay visible.
($heads, $visible, $types) = table_columns('backup_schedule_columns',
					   \@rows);
my $schedules =
	ui_card({ id => 'cloudmin-backup-schedules', title =>
							     $text{'backup_schedules'},
		  desc => @rows ? $text{'backup_schedule_timezone'} : undef,
		  actions => @rows ? ui_badge(scalar(@rows), 'neutral') : '',
		  body => @rows
			  ? ui_columns_table($heads, 100, $visible,
					     $types, 0,
					     undef,
					     undef, 1)
			  : ui_empty_state({ icon => 'clock', title =>
								      $text{'backup_schedules_empty'}, desc =>
													       $text{'backup_schedules_empty_help'} }) });
return ui_page_start().ui_stack([ $actions, $archives,
				  $schedules ]).ui_page_end();
}

1;
