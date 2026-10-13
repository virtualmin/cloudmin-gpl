# Snapshot pages use native activity feeds, cards and action buttons.
use strict;
use warnings;
use POSIX ();
use File::Basename ();
use Cwd ();
# Share column definitions with Module Configuration.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
our (%text, %config);

# snapshot_url(uuid, [view], [snapshot])
# Encodes native snapshot names, including names created by other tools.
sub snapshot_url
{
my ($uuid, $view, $snapshot) = @_;
return 'snapshots.cgi?id='.urlize($uuid).
	($view ? '&view='.urlize($view) : '').
	(defined($snapshot) ? '&snapshot='.urlize($snapshot) : '');
}

# snapshot_mode(snapshot)
# Shows whether the guest was stopped, prepared, or explicitly left unprepared.
sub snapshot_mode
{
my ($snapshot) = @_;
my $mode = $snapshot->{'mode'} || 'external';
return ui_badge($text{'snapshots_mode_'.$mode} || $text{'snapshots_mode_external'},
	$mode eq 'prepared' ? 'success' : $mode eq 'unprepared' ? 'warning' : 'neutral', { small => 1 });
}

# snapshot_size(snapshot)
# Reports saved file allocation without implying that deleting it frees this size.
sub snapshot_size
{
my ($snapshot) = @_;
return defined($snapshot->{'allocation'}) ?
	ui_tag('span', nice_size($snapshot->{'allocation'}), { title => $text{'snapshots_size_help'} }) : '&mdash;';
}

# snapshot_actions(snapshot, token, [unavailable], [from_all])
# Opens the standard review pages from either history or the host inventory.
sub snapshot_actions
{
my ($snapshot, $token, $unavailable, $from_all) = @_;
return '' if (!$token || !$snapshot->{'managed'} || $unavailable);
my @actions;
foreach my $action ('restore', 'delete') {
	my $blocked = $snapshot->{'pending'} || ($action eq 'delete' && $snapshot->{'delete_blocked'});
	push(@actions, ui_action_button($text{'snapshots_action_'.$action}, $action eq 'restore' ? 'info' : 'danger', {
		icon => $action eq 'restore' ? 'refresh' : 'trash', size => 'small',
		href => snapshot_url($snapshot->{'uuid'}, $action, $snapshot->{'id'}).($from_all ? '&from=all' : ''),
		disabled => $blocked, title => $snapshot->{'pending'} ? $text{'snapshots_recovery'}
			: $blocked ? $text{'snapshots_delete_children'} : $text{'snapshots_'.$action} }));
	}
return ui_cluster(\@actions, { class => 'cloudmin-snapshot-actions' });
}

# snapshot_form(data, token, action, [snapshot])
# Binds a standard submit form to the rendered guest and history revision.
sub snapshot_form
{
my ($data, $token, $action, $snapshot) = @_;
return ui_form_start('snapshots.cgi', 'post').ui_hidden('id', $data->{'guest'}->{'uuid'}).
	ui_hidden('token', $token).ui_hidden('revision', $data->{'revision'}).
	ui_hidden('action', $action).($snapshot ? ui_hidden('snapshot', $snapshot->{'id'}) : '');
}

# show_snapshot_create(data, token, input)
# Keeps prepared snapshots live and offers clean shutdown when the agent is absent.
sub show_snapshot_create
{
my ($data, $token, $input) = @_;
my $html = ui_tag('p', html_escape($text{'snapshots_create_help'}));
my ($after_button, $alerts) = ('', '');
# Suggest the host's current date and time only when opening a new form.
# Preserve submitted names, including an empty name after validation fails.
my $label = exists($input->{'label'}) || $input->{'action'}
	? ($input->{'label'} // '') : POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime());
$html .= snapshot_form($data, $token, 'snapshot_create').
	ui_table_start($text{'snapshots_create'}, undef, 2).
	ui_table_row($text{'snapshots_name'}, ui_textbox('label', $label, 45, 0, 80)).
	ui_table_row($text{'snapshots_notes'}, ui_textarea('description', $input->{'description'} || '', 3, 60,
		undef, 0, 'placeholder="'.quote_escape($text{'snapshots_optional'}).'"'));
# Only running guests need a choice about filesystem preparation.
if ($data->{'guest'}->{'active'}) {
	if ($data->{'preparation_available'}) {
		# A working agent keeps normal snapshots live, with no shutdown option.
		$html .= ui_hidden('mode', 'prepared');
		}
	else {
		# Default to a clean shutdown; keep an unchecked choice after validation fails.
		my $shutdown = exists($input->{'shutdown'}) || $input->{'action'}
			? ($input->{'shutdown'} ? 1 : 0) : 1;
		$html .= ui_hidden('mode', $shutdown ? 'prepared' : 'unprepared').ui_hidden('restart', 1);
		$alerts = ui_alert(html_escape($text{'snapshots_agent_unavailable'}),
			'warning', ['fa-exclamation-triangle', '', 1]).
			ui_alert(html_escape($text{'snapshots_unprepared_warning'}),
			'danger', ['fa-bolt', '', 1], { id => 'snapshot-unprepared-warning',
				role => 'alert', ($shutdown ? (hidden => undef) : ()) });
		# The native submit row groups the shutdown choice with Create snapshot.
		# Unchecking explicitly requests an unprepared snapshot; no automatic fallback.
		$after_button = ui_tag('span', ui_checkbox('shutdown', 1,
			$text{'snapshots_shutdown_create'}, $shutdown,
			q{onchange="this.form.elements.mode.value = this.checked ? 'prepared' : 'unprepared'; document.getElementById('snapshot-unprepared-warning').hidden = this.checked;"}),
			{ class => 'cloudmin-snapshot-restart', title => $text{'snapshots_preparation_help'} });
		}
	}
# Stopped guests need no freeze or temporary shutdown option.
else {
	$html .= ui_table_row(undef, html_escape($text{'snapshots_stopped_help'}), 2);
	}
$html .= ui_table_end().$alerts.ui_form_end([['', $text{'snapshots_create'}, $after_button]]);
return $html;
}

1;
