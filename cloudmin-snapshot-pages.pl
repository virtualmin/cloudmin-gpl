# Snapshot pages use native activity feeds, cards and action buttons.
use strict;
use warnings;
use POSIX ();
use File::Basename ();
use Cwd ();
# Share column definitions with Module Configuration.
require(
	Cwd::abs_path(File::Basename::dirname(__FILE__).
		      '/cloudmin-config-lib.pl'));
our (%text, %config);

# snapshot_url(uuid, [view], [snapshot]) Encodes native snapshot names,
# including names created by other tools.
sub snapshot_url
{
my ($uuid, $view, $snapshot) = @_;
return 'snapshots.cgi?id='.urlize($uuid).
       ($view ? '&view='.urlize($view) : '').
       (defined($snapshot) ? '&snapshot='.urlize($snapshot) : '');
}

# snapshot_mode(snapshot) Shows whether the guest was stopped, prepared, or
# explicitly left unprepared.
sub snapshot_mode
{
my ($snapshot) = @_;
my $mode = $snapshot->{'mode'} || 'external';
return ui_badge($text{'snapshots_mode_'.$mode} ||
		$text{'snapshots_mode_external'},
		$mode eq 'prepared'
			? 'success'
			: $mode eq 'unprepared' ? 'warning' : 'neutral',
		{ small => 1 });
}

# snapshot_size(snapshot) Reports saved file allocation without implying that
# deleting it frees this size.
sub snapshot_size
{
my ($snapshot) = @_;
return defined($snapshot->{'allocation'})
	? ui_tag('span', nice_size($snapshot->{'allocation'}),
		 { title => $text{'snapshots_size_help'} })
	: '&mdash;';
}

# snapshot_actions(snapshot, token, [unavailable], [from_all]) Opens the
# standard review pages from either history or the host inventory.
sub snapshot_actions
{
my ($snapshot, $token, $unavailable, $from_all) = @_;
return '' if (!$token || !$snapshot->{'managed'} || $unavailable);
my @actions;
foreach my $action ( 'restore', 'delete' ) {
	my $blocked = $snapshot->{'pending'} ||
		      ($action eq 'delete' && $snapshot->{'delete_blocked'});
	push(@actions,
	     ui_action_button($text{'snapshots_action_'.$action},
			      $action eq 'restore' ? 'info' : 'danger', {
				      icon => $action eq 'restore'
					      ? 'refresh'
					      : 'trash', size => 'small',
				      href => snapshot_url($snapshot->{'uuid'},
							   $action,
							   $snapshot->{'id'}).($from_all
								   ? '&from=all'
								   : ''),
				      disabled => $blocked,
				      title => $snapshot->{'pending'}
					      ? $text{'snapshots_recovery'}
					      : $blocked
						      ? $text{'snapshots_delete_children'}
						      : $text{'snapshots_'.$action} }));
	}
return ui_cluster(\@actions, { class => 'cloudmin-snapshot-actions' });
}

# snapshot_form(data, token, action, [snapshot]) Binds a standard submit form to
# the rendered guest and history revision.
sub snapshot_form
{
my ($data, $token, $action, $snapshot) = @_;
return ui_form_start('snapshots.cgi', 'post').ui_hidden('id',
							$data->{'guest'}->{'uuid'}).
       ui_hidden('token', $token).ui_hidden('revision',
					    $data->{'revision'}).
       ui_hidden('action', $action).($snapshot
	       ? ui_hidden('snapshot', $snapshot->{'id'})
	       : '');
}

# show_snapshot_create(data, token, input) Keeps prepared snapshots live and
# offers clean shutdown when the agent is absent.
sub show_snapshot_create
{
my ($data, $token, $input) = @_;
my $html = ui_tag('p', html_escape($text{'snapshots_create_help'}));
my ($after_button, $alerts) = ( '', '' );
# Suggest the host's current date and time only when opening a new form.
# Preserve submitted names, including an empty name after validation fails.
my $label = exists($input->{'label'}) || $input->{'action'}
	? ($input->{'label'} // '')
	: POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime());
$html .= snapshot_form($data, $token, 'snapshot_create').
	 ui_table_start($text{'snapshots_create'}, undef, 2).
	 ui_table_row($text{'snapshots_name'},
		      ui_textbox('label', $label, 45, 0, 80)).
	 ui_table_row($text{'snapshots_notes'},
		      ui_textarea('description', $input->{'description'} || '',
				  3, 60,
				  undef, 0,
				  'placeholder="'.
				  quote_escape($text{'snapshots_optional'}).
				  '"'));
# Only running guests need a choice about filesystem preparation.
if ($data->{'guest'}->{'active'}) {
	if ($data->{'preparation_available'}) {
		# A working agent keeps normal snapshots live,
		# with no shutdown option.
		$html .= ui_hidden('mode', 'prepared');
		}
	else {
		# Default to a clean shutdown; keep an unchecked choice
		# after validation fails.
		my $shutdown = exists($input->{'shutdown'}) ||
			       $input->{'action'}
				       ? ($input->{'shutdown'} ? 1 : 0)
				       : 1;
		$html .= ui_hidden('mode', $shutdown
			? 'prepared'
			: 'unprepared').ui_hidden('restart', 1);
		$alerts =
			ui_alert(html_escape(
				$text{'snapshots_agent_unavailable'}),
				 'warning', [ 'fa-exclamation-triangle', '',
					      1 ]).
			ui_alert(
				html_escape(
					$text{'snapshots_unprepared_warning'}),
				'danger', [ 'fa-bolt', '', 1 ],
				{ id => 'snapshot-unprepared-warning',
				  role => 'alert', ($shutdown
					  ? ( hidden => undef )
					  : ()) });
		# The native submit row groups the shutdown choice with Create
		# snapshot. Unchecking explicitly requests an unprepared
		# snapshot; no automatic fallback.
		$after_button = ui_tag('span', ui_checkbox('shutdown', 1,
							   $text{'snapshots_shutdown_create'}, $shutdown,
							   q{onchange="this.form.elements.mode.value = this.checked ? 'prepared' : 'unprepared'; document.getElementById('snapshot-unprepared-warning').hidden = this.checked;"}),
				       { class => 'cloudmin-snapshot-restart',
					 title =>
						 $text{'snapshots_preparation_help'} });
		}
	}
# Stopped guests need no freeze or temporary shutdown option.
else {
	$html .= ui_table_row(undef,
			      html_escape($text{'snapshots_stopped_help'}), 2);
	}
$html .= ui_table_end().$alerts.ui_form_end([ [ '', $text{'snapshots_create'},
						$after_button ] ]);
return $html;
}

# show_snapshot_review(data, token, snapshot, action, input) Destructive restore
# and snapshot removal each have their own confirmation.
sub show_snapshot_review
{
my ($data, $token, $snapshot, $action, $input) = @_;
my $key = $action eq 'restore' ? 'snapshots_restore' : 'snapshots_delete';
my @hidden = ( [ id => $data->{'guest'}->{'uuid'} ], [ token => $token ],
	       [ revision => $data->{'revision'} ],
	       [ action => 'snapshot_'.$action ],
	       [ snapshot => $snapshot->{'id'} ], [ view => $action ],
	       [ confirm => 1 ] );
# Keep host-wide actions in their original navigation context.
push(@hidden, [ from => 'all' ]) if (($input->{'from'} || '') eq 'all');
my $details =
	ui_text_color(ui_tag('tt', html_escape($snapshot->{'label'})),
		      'danger');
my $after_button;
if ($action eq 'restore') {
	# Confirm shutdown together with restore; starting
	# afterward is optional.
	push(@hidden, [ shutdown => 1 ]) if ($data->{'guest'}->{'active'});
	# Default from the saved state only on first opening. Unchecked boxes
	# are absent from submitted forms, so a failed
	# submission must keep them off.
	my $restart = exists($input->{'restart'}) || $input->{'action'}
		? ($input->{'restart'} ? 1 : 0)
		: (($snapshot->{'state'} ||
		    '') =~ /\A(?:running|blocked|disk-snapshot)\z/ ? 1 : 0);
	$details .= ui_alert(html_escape($text{$data->{'guest'}->{'active'}
		? 'snapshots_restore_shutdown'
		: 'snapshots_restore_stopped'}),
			     'info', [ 'fa-info-circle', '', 1 ]);
	# The standard submit row keeps this choice beside the restore button.
	$after_button = ui_tag('span',
			       ui_checkbox('restart', 1,
					   $text{'snapshots_restore_start'},
					   $restart),
			       { class => 'cloudmin-snapshot-restart' });
	}
return ui_confirmation_form('snapshots.cgi', $text{$key.'_confirm'},
			    \@hidden, [ [ undef, $text{$key}, $after_button ] ],
			    $details);
}

# show_snapshot_history(data, token) Shows chronological history, with explicit
# ancestry for branches and restores.
sub show_snapshot_history
{
my ($data, $token) = @_;
my %rows = map { $_->{'id'} => $_ } @{$data->{'snapshots'}};
my (@events, $current);
foreach my $row (reverse @{$data->{'snapshots'}}) {
	my @badges = (snapshot_mode($row));
	push(@badges,
	     ui_badge($text{'snapshots_current_parent'}, 'info',
		      { small => 1, icon => 'check' })) if ($row->{'current'});
	push(@badges,
	     ui_badge($text{'snapshots_recovery'}, 'warning', { small => 1 }))
		if ($row->{'pending'});
	# The theme formats dates as HTML; only user-supplied
	# text needs escaping.
	my $date =
		ui_tag('span', make_date($row->{'created'}),
		       { class => 'cloudmin-snapshot-date' });
	my $size = defined($row->{'allocation'})
		? ui_tag('span', ui_svg_icon('hard-drive').
			 snapshot_size($row),
			 { class => 'cloudmin-snapshot-size' })
		: '';
	# Keep notes separate from date, allocation and branch metadata.
	my $parent = $rows{$row->{'parent'} || ''};
	my $ancestry = $parent
		? ui_tag('span', text('snapshots_based_on',
				      ui_tag('a',
					     html_escape($parent->{'label'}),
					     { href => '#snapshot-'.
						       urlize($parent->{'id'}) })))
		: '';
	# Hide notes only in this view; keep the saved descriptions.
	my $notes = ($config{'snapshot_notes'} // 1) eq '1' &&
		    $row->{'description'}
			    ? ui_tag('p', html_escape($row->{'description'}),
				     { class => 'cloudmin-snapshot-notes' })
			    : '';
	my $details = ui_tag('div',
			     ui_tag('div',
				    ui_tag('strong',
					   html_escape($row->{'label'})).join('',
									      @badges), { class => 'cloudmin-snapshot-name' }).
			     ui_tag('div', $date.$size.$ancestry,
				    { class => 'cloudmin-snapshot-meta' }).$notes,
			     { class => 'cloudmin-snapshot-details' });
	push(@events,
	     { text_html =>
		       ui_tag('div',
			      $details.snapshot_actions($row, $token,
							$data->{'unavailable'}),
			      { id => 'snapshot-'.urlize($row->{'id'}),
				class => 'cloudmin-snapshot-entry'.
					 ($row->{'current'}
						 ? ' cloudmin-snapshot-current'
						 : '') }),
	       state => $row->{'pending'}
		       ? 'warning'
		       : $row->{'current'} ? 'info' : undef });
	$current = $row if ($row->{'current'});
	}
# The working state is always distinct from saved disks. Name its parent even
# when a newer snapshot exists on another branch.
my $working = ui_tag('strong', html_escape($text{'snapshots_you_are_here'}));
$working .= ui_tag('span', text('snapshots_based_on',
				ui_tag('a', html_escape($current->{'label'}),
				       { href => '#snapshot-'.urlize($current->{'id'}) })))
	if ($current);
push(@events,
     { text_html =>
	       ui_tag('div', $working,
		      { class => 'cloudmin-snapshot-working' }) });
return ui_feed(\@events, { class => 'cloudmin-snapshot-feed' });
}

# show_snapshots_overview(data, token) Combines host totals with direct review
# actions for each saved snapshot.
sub show_snapshots_overview
{
my ($data, $token) = @_;
my @snapshots = @{$data->{'snapshots'}};
my $pending =
	$data->{'recovery_count'} // scalar(grep { $_->{'pending'} } @snapshots);
my $html = ui_stats([
	{ value => scalar(@snapshots), label => $text{'snapshots_total'},
	  desc => $text{'snapshots_total_desc'}, icon => 'clock',
	  state => 'info' },
	{ value => scalar(grep { $_->{'count'} } @{$data->{'guests'}}),
	  label => $text{'snapshots_vm_count'},
	  desc => $text{'snapshots_vm_count_desc'}, icon =>
							    'server' },
	{ value => $pending, label => $text{'snapshots_recovery'},
	  desc => $text{'snapshots_recovery_desc'},
	  icon => $pending ? 'warning' : 'check-circle', state =>
								 $pending ? 'warning' : 'success' },
], { class => 'cloudmin-snapshot-summary', shape => 'square' });
if (@snapshots) {
	# A failed creation may need recovery without having
	# native metadata yet.
	my %pending_guests = (map { $_ => 1 } @{$data->{'pending_guests'} ||
		[ ]});
	$pending_guests{$_->{'uuid'}} =
		1 foreach grep { $_->{'pending'} } @snapshots;
	my @rows = map { [
		ui_tag('a', html_escape($_->{'label'}),
		       { href => snapshot_url($_->{'uuid'}) }),
		ui_tag('a', html_escape($_->{'vm'}),
		       { href => 'machine.cgi?id='.urlize($_->{'uuid'}) }),
		make_date($_->{'created'}), snapshot_size($_),
		snapshot_mode($_),
		$_->{'pending'}
			? ui_badge($text{'snapshots_recovery'}, 'warning',
				   { small => 1 })
			: html_escape($text{$_->{'current'}
				? 'snapshots_current_parent'
				: 'snapshots_saved'}),
		($token
			? (
				snapshot_actions($_, $token,
						 $pending_guests{$_->{'uuid'}},
						 1))
			: ())
	] } @snapshots;
	# Filter headings, values and sort types together to keep them aligned.
	my ($heads, $visible, $types) =
		table_columns('snapshot_columns', \@rows);
	# Column preferences never hide permitted review
	# actions or add denied ones.
	if ($token) {
		push(@$heads, $text{'snapshots_actions'});
		push(@$types, undef);
		push(@{$visible->[$_]}, $rows[$_]->[6]) foreach 0 .. $#rows;
		}
	$html .= ui_columns_table($heads, 100, $visible, $types, 0, undef,
				  undef, 1);
	}
return $html;
}

# show_snapshots_page(data, token, input, [error]) Keeps host inventory, guest
# history and action reviews in one navigable page.
sub show_snapshots_page
{
my ($data, $token, $input, $error) = @_;
return ui_alert_box(html_escape($data->{'error'}), 'warn')
	if ($data->{'error'});
my $html = $error ? ui_alert_box(html_escape($error), 'danger') : '';
$html .= ui_alert_box(html_escape(join("\n", @{$data->{'errors'}})), 'warn')
	if (@{$data->{'errors'} || [ ]});
my $intro =
	ui_tag('div', html_escape($text{'snapshots_intro'}),
	       { class => 'cloudmin-snapshot-intro' });
return $html.$intro.show_snapshots_overview($data, $token)
	if (!$data->{'guest'});
my $guest = $data->{'guest'};
my $view = $input->{'view'} || (($input->{'action'} || '') eq 'snapshot_create'
	? 'create'
	: '');
# Explain disabled operations while leaving saved history visible.
if ($data->{'unavailable'}) {
	$html .= ui_alert_box(html_escape($data->{'unavailable'}), 'warn');
	}
# Creation controls are available only to writers with an eligible guest.
if ($token && !$data->{'unavailable'} && $view eq 'create') {
	return $html.show_snapshot_create($data, $token, $input);
	}
# Resolve review links against current history rather than trusting URL labels.
if ($token && !$data->{'unavailable'} && $view =~ /\A(?:restore|delete)\z/) {
	my ($snapshot) =
		grep { $_->{'id'} eq ($input->{'snapshot'} ||
				      '') } @{$data->{'snapshots'}};
	return $html.ui_alert_box($text{'snapshots_missing'}, 'warn', undef,
				  undef,
				  '') if (!$snapshot || !$snapshot->{'managed'});
	# The current snapshot cannot be deleted while it remains a parent.
	return $html.ui_alert_box($text{'snapshots_delete_children'}, 'warn',
				  undef, undef, '')
		if ($view eq 'delete' && $snapshot->{'delete_blocked'});
	return $html.show_snapshot_review($data, $token, $snapshot, $view,
					  $input);
	}
$html .= $intro;
my @actions;
# Offer creation beside the history only when the controller permits it.
push(@actions,
     ui_action_button($text{'snapshots_create'}, 'info',
		      { href => snapshot_url($guest->{'uuid'}, 'create'),
			icon => 'plus', size =>
						'normal' }))
	if ($token && !$data->{'unavailable'});
return $html.ui_card({ title => $text{'snapshots_history'}, class =>
								    'cloudmin-snapshot-history',
		       actions => @actions ? ui_cluster(\@actions) : undef,
		       body => @{$data->{'snapshots'}}
			       ? show_snapshot_history($data, $token)
			       : ui_empty_state({ icon => 'clock', title =>
									   $text{'snapshots_none'}, desc =>
													    $text{'snapshots_none_vm'} }) });
}

1;
