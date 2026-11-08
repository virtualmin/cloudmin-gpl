use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;
our (%text, %config, $root_directory);
$root_directory = $CloudminTest::webmin_root;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
$WebminCore::text{'nice_size_MiB'} = 'MiB';
require "$Bin/../cloudmin-snapshot-pages.pl";
my $guest = { uuid => 'fixture', name => 'Guest <one>', active => 0,
	      count => 2 };
my $data =
	{ guest => $guest, guests => [ $guest ], errors => [ ],
	  revision => 'revision',
	  snapshots => [
		  { id => 'new', label => 'New <snapshot>', description =>
								    '<script>bad()</script>', uuid => 'fixture',
		    vm =>
			    $guest->{'name'}, created => 1700000100,
		    parent => 'old',
		    current => 0, managed => 1, mode => 'stopped',
		    state =>
			    'shutoff', allocation => 1048576 },
		  { id => 'old', label => 'Before update',
		    uuid => 'fixture',
		    vm =>
			    $guest->{'name'}, created => 1700000000,
		    current => 1,
		    managed => 1, mode => 'prepared',
		    state => 'disk-snapshot' },
	  ] };
my $html = show_snapshots_page($data, 'token', { });
like($html, qr/\bui_feed\b/, 'per-guest history uses the shared activity feed');
is(scalar(() = $html =~ /class="[^\"]*\bui_card\b/g), 1,
   'history has one card around the whole feed');
is(scalar(() = $html =~ /class="[^\"]*\bui_feed_item\b/g), 3,
   'each snapshot and the working state have a feed entry');
like($html, qr/New &lt;snapshot&gt;/, 'snapshot labels escaped');
unlike($html, qr/<script>bad/, 'notes cannot inject markup');
like($html, qr/You are here/, 'current VM state is distinct from saved state');
like($html, qr/Parent of current state/,
     'restored parent is marked even when it is older');
like($html, qr/Based on <a[^>]+>Before update<\/a>/,
     'branch ancestry names its actual parent');
like($html,
     qr/cloudmin-snapshot-working[^>]*>.*Based on <a[^>]+>Before update<\/a>/s,
     'working state names its parent instead of implying the newest snapshot is current');
like($html, qr/view=restore/, 'stopped guest offers restore');
like($html, qr/view=delete/, 'snapshot removal goes to a review');
unlike(show_snapshots_page($data, '', { }),
       qr/view=(create|restore|delete)|<form/,
       'read-only views expose no mutation controls');
# Hidden descriptions remain saved, and reduced tables retain essential context.
{
	local $config{'snapshot_notes'} = 0;
	my $history = show_snapshot_history($data, 'token');
	unlike($history, qr/cloudmin-snapshot-notes|bad\(\)/,
	       'notes can be hidden from history');
	like($history, qr/Parent of current state|Based on/,
	     'hidden notes preserve ancestry');
	is($data->{'snapshots'}->[0]->{'description'}, '<script>bad()</script>',
	   'hidden notes remain saved');
	# Identity and position columns remain visible regardless of settings.
	local $config{'snapshot_columns'} = 'name,size';
	my ($heads, $rows, $types);
	no warnings qw(redefine once);
	# ui_columns_table(@args) captures headings, rows and sort types.
	local *main::ui_columns_table =
		sub { ($heads, $rows, $types) = @_[0, 2, 3]; return ''; };
	show_snapshots_overview($data, 'token');
	is_deeply(
		$heads,
		[
			@text{qw(snapshots_name vm_name snapshots_size snapshots_position snapshots_actions)} ],
		'snapshot columns preserve identities, position and permitted actions');
	is(scalar(@{$rows->[0]}), scalar(@$heads),
	   'reduced snapshot rows align with headings');
	# Display preferences never grant actions to a read-only viewer.
	show_snapshots_overview($data, '');
	is(scalar(@$heads), 4, 'read-only snapshot list has no action column');
	}
{
	local $guest->{'active'} = 1;
	$html = show_snapshots_page($data, 'token', { });
	like($html, qr/view=restore/,
	     'running guests retain a discoverable restore action');
	$html = show_snapshots_page($data, 'token', { view => 'create' });
	like($html, qr/name=['"]mode['"][^>]*value=['"]prepared/,
	     'live creation requires preparation');
	like($html, qr/Shut down before taking snapshot/,
	     'clean shutdown is available without an agent');
	like($html,
	     qr/<input\b(?=[^>]*name=['"]shutdown['"])(?=[^>]*\schecked(?:\s|=|>))[^>]*>/,
	     'clean shutdown is selected on first opening');
	like($html, qr/type=['"]submit[^>]*>.*name=['"]shutdown/s,
	     'shutdown choice follows the standard create submit');
	like($html, qr/class="[^"]*alert-warning/,
	     'missing agent explanation is an orange alert');
	like($html,
	     qr/<div\b(?=[^>]*id="snapshot-unprepared-warning")(?=[^>]*hidden)[^>]*>/,
	     'power-loss warning is initially hidden');
	my $unchecked =
		show_snapshots_page($data, 'token',
				    { action => 'snapshot_create' });
	like($unchecked, qr/name=['"]mode['"][^>]*value=['"]unprepared/,
	     'an unchecked choice after validation requests an unprepared snapshot');
	unlike($unchecked,
	       qr/<input\b(?=[^>]*name=['"]shutdown['"])(?=[^>]*\schecked(?:\s|=|>))[^>]*>/,
	       'validation does not silently enable shutdown again');
	like($unchecked, qr/class="[^"]*alert-danger/,
	     'unprepared snapshot explains power loss in a red alert');
	$html =
		show_snapshots_page({ %$data, preparation_available => 1 },
				    'token',
				    { view => 'create' });
	unlike($html, qr/name=['"]shutdown/,
	       'prepared snapshots do not offer downtime');
	like($html, qr/<textarea\b[^>]*placeholder="Optional"/,
	     'notes show Optional as a placeholder');
	unlike($html, qr/\bVM\b|Guest preparation/,
	       'creation uses full virtual machine wording and a clear method label');
	$html =
		show_snapshots_page($data, 'token',
				    { view => 'restore', snapshot => 'old' });
	like($html, qr/name=['"]shutdown['"][^>]*value=['"]1/,
	     'running restore confirms clean shutdown');
	like($html, qr/Start the virtual machine after restoring/,
	     'restore lets the user choose whether to start');
	}
$html =
	show_snapshots_page($data, 'token', { view => 'restore',
					      snapshot => 'old' });
like($html, qr/Changes made since this snapshot will be discarded/,
     'restore explains data loss');
like($html, qr/name=['"]confirm['"][^>]*value=['"]1/,
     'confirmation is a separate signed POST');
like($html, qr/type=['"]submit/, 'confirmation uses a standard submit');
like($html, qr/ui_confirmation/, 'restore uses the shared confirmation helper');
{
	# The saved power state drives the initial choice,
	# regardless of current power.
	my $checked =
		qr/<input\b(?=[^>]*\bname=['"]restart['"])(?=[^>]*\bchecked\b)[^>]*>/;
	foreach my $active ( 0, 1 ) {
		local $guest->{'active'} = $active;
		like(show_snapshots_page($data, 'token',
					 { view => 'restore',
					   snapshot => 'old' }),
		     $checked,
		     "live snapshot defaults to starting when current power is $active");
		unlike(show_snapshots_page($data, 'token',
					   { view => 'restore',
					     snapshot => 'new' }),
		       $checked,
		       "stopped snapshot defaults to staying stopped when current power is $active");
		}
	foreach my $state ( 'running', 'blocked', '' ) {
		local $data->{'snapshots'}->[1]->{'state'} = $state;
		my $review =
			show_snapshots_page($data, 'token',
					    { view => 'restore',
					      snapshot => 'old' });
		$state
			? like($review, $checked,
			       "$state snapshots default to starting")
			: unlike($review, $checked,
				 'unknown saved power does not default to starting');
		}
	foreach my $input ( { restart => 0 },
			    { action => 'snapshot_restore' } ) {
		unlike(show_snapshots_page($data, 'token',
					   { view => 'restore',
					     snapshot => 'old', %$input }),
		       $checked,
		       'an unchecked restart choice survives redisplay');
		}
	like(show_snapshots_page($data, 'token',
				 { view => 'restore', snapshot => 'new',
				   action => 'snapshot_restore',
				   restart => 1 }),
	     $checked,
	     'an explicit start choice overrides a stopped snapshot');
	}
$html =
	show_snapshots_page($data, 'token', { view => 'delete',
					      snapshot => 'old' });
like($html, qr/ui_confirmation/, 'delete uses the shared confirmation helper');
unlike($html,
       qr/Save a point in time|Snapshot History|Create Snapshot|All Snapshots/,
       'confirmation only shows the selected action');
unlike(show_snapshots_page($data, 'token', { }), qr/All Snapshots|ui_card_foot/,
       'history has no overview shortcut or empty action footer');
{
	local $data->{'snapshots'}->[1]->{'delete_blocked'} = 1;
	$html =
		show_snapshots_page($data, 'token',
				    { view => 'delete', snapshot => 'old' });
	like($html, qr/Delete the child snapshots/,
	     'unsupported current-parent deletion explains the next step');
	unlike($html, qr/ui_confirmation|<form/,
	       'unsupported deletion offers no submit form');
	$html = show_snapshots_page($data, 'token', { });
	like($html, qr/aria-disabled="true"/,
	     'unavailable deletion is disabled in history');
	like($html, qr/view=restore/,
	     'the same snapshot can still be restored');
	}
$html =
	show_snapshots_page({ %$data, unavailable => '<blocked>' }, 'token',
			    { view => 'create' });
like($html, qr/&lt;blocked&gt;/, 'unsupported hosts explain why');
unlike($html, qr/<form/, 'unavailable operations cannot be submitted from UI');
$html = show_snapshots_page({ %$data, guest => undef }, 'token', { });
like($html, qr/data-sortable=['"]1/,
     'host overview uses standard sortable tables');
like($html, qr/Virtual machines with snapshots/,
     'host overview includes VM totals');
like($html, qr/snapshots.cgi\?id=fixture/,
     'host overview links to each VM history');
like($html, qr/Virtual machine name/,
     'VM identity remains in the main snapshot table');
unlike($html,
       qr/snapshot_guests|cloudmin-snapshot-guests|hiddenopener_|<details/,
       'host overview has no separate VM section or accordion');
like($html, qr/Allocated size/, 'host table includes disk allocation');
like($html, qr/1 MiB/, 'known allocation uses standard size formatting');
like($html, qr/not the space freed/,
     'allocation tooltip explains shared storage');
like($html,
     qr/snapshots.cgi\?id=fixture&amp;view=restore&amp;snapshot=new&amp;from=all/,
     'host restore opens the selected snapshot confirmation directly');
like($html,
     qr/snapshots.cgi\?id=fixture&amp;view=delete&amp;snapshot=new&amp;from=all/,
     'host delete opens the selected snapshot confirmation directly');
unlike(show_snapshots_page({ %$data, guest => undef }, '', { }),
       qr/view=(restore|delete)|>Actions</,
       'read-only host inventory omits actions');
{
	local $data->{'snapshots'}->[0]->{'managed'} = 0;
	unlike(show_snapshots_page({ %$data, guest => undef }, 'token', { }),
	       qr/view=(restore|delete)&amp;snapshot=new/,
	       'externally managed snapshots have no mutation controls');
	}
{
	local $data->{'snapshots'}->[0]->{'pending'} = 1;
	unlike(show_snapshots_page({ %$data, guest => undef }, 'token', { }),
	       qr/view=(restore|delete)/,
	       'recovery blocks host actions for every snapshot of the affected guest');
	}
{
	my $pending =
		show_snapshots_page({ %$data, guest => undef,
				      recovery_count => 1,
				      pending_guests => [ 'fixture' ] },
				    'token',
				    { });
	unlike($pending, qr/view=(restore|delete)/,
	       'failed preparation blocks host actions without native snapshot markers');
	}
{
	# Chronological feeds cannot lose orphaned or cyclic external records.
	local $data->{'snapshots'}->[1]->{'parent'} = 'new';
	my $feed = show_snapshot_history($data, 'token');
	is(scalar(() = $feed =~ /class="[^\"]*\bcloudmin-snapshot-entry\b/g), 2,
	   'cyclic parent metadata does not omit or duplicate snapshots');
	}
foreach my $from ( 'all', 'https://other.example/' ) {
	my $review =
		show_snapshots_page($data, 'token',
				    { view => 'restore', snapshot => 'new',
				      from => $from });
	$from eq 'all'
		? like($review, qr/name=['"]from['"][^>]*value=['"]all/,
		       'host review preserves its return context')
		: unlike($review, qr/name=['"]from['"]/,
			 'arbitrary return destinations are ignored');
	}
is(snapshot_size({ allocation => undef }), '&mdash;',
   'unknown sizes do not pretend to be zero');
{
	# Date widgets include sorting markup; callers must retain it.
	no warnings 'redefine';
	local *main::make_date =
		sub {
			'<span data-filesize-bytes="1700000000">14/11/2023</span>' };
	foreach my $guest_view ( 1, 0 ) {
		my $page = show_snapshots_page({ %$data, guest => $guest_view
			? $guest
			: undef }, 'token', { });
		like($page,
		     qr/<span data-filesize-bytes="1700000000">14\/11\/2023<\/span>/,
		     'formatted date HTML survives in '.($guest_view
			     ? 'history'
			     : 'overview'));
		unlike($page, qr/&lt;span/,
		       'date markup is not printed as text');
		}
	}
$html =
	show_snapshots_page({ snapshots => [ ], guests => [ { %$guest,
		count => 0 } ],
			      errors => [ ] }, 'token', { });
unlike($html, qr/No snapshots yet|ui_empty/,
       'zero total replaces the redundant host empty state');
is(scalar(() = $html =~ /class="[^"]*\bui_stat_square\b/g), 3,
   'empty overview retains all three summary cards');
like($html, qr/Total snapshots/, 'zero snapshot total is clearly labelled');
done_testing();
