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

1;
