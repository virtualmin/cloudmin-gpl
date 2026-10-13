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

1;
