use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;
our (%text, $root_directory);
$root_directory = $CloudminTest::webmin_root;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if /^([^=]+)=(.*)$/; }
close($lang);
require "$Bin/../cloudmin-network-pages.pl";

# Repeated NICs and a VM shared between a network and bridge count only once.
my $guest = { uuid => 'vm-one', name => 'guest <one>', active => 0 };
my $other = { uuid => 'vm-two', name => 'guest two', active => 1 };
my $network = { uuid => 'net-one', name => 'default <network>', active => 1,
		persistent => 1, autostart => 1, forward => 'nat',
		bridge => 'virbr0',
		addresses => [ '192.168.122.1/24' ], ranges => [ ], guests =>
									    [ $guest, $guest ],
		uplink => '', revision => 'revision' };
my $idle = { %$network, uuid => 'net-two', name => 'private', active => 0,
	     forward => 'isolated', bridge => 'virbr1', guests => [ ] };
my $bridge = { name => 'br <lan>', bridge => 1, active => 1,
	       ports => [ 'eth0' ],
	       addresses => [ ], guests => [ $guest, $other ], persistent => 1,
	       mac =>
		       '' };
my $data = { networks => [ $network, $idle ], bridges => [ $bridge ],
	     supported => 0,
	     interfaces => [ { name => 'virbr0', bridge => 1 }, $bridge ] };
my $html = show_network_overview($data);
my @counts = $html =~ /ui_stat_value[^>]*>.*?<\/svg>\s*(\d+)\s*<\/span>/sg;
is_deeply(
	\@counts, [ 2, 1, 1, 2 ],
	'totals distinguish active networks, separate bridges and unique attached VMs');
is(scalar(() = $html =~ /\bui_stat_square\b/g), 4,
   'all four tiles use square corners');
like($html, qr/default &lt;network&gt;/, 'network name is escaped');
like($html, qr/br &lt;lan&gt;/, 'bridge name is escaped');
like($html, qr/guest &lt;one&gt;/, 'guest name is escaped');
like($html, qr/networks.cgi\?tab=networks(?:&amp;|&)selected=net(?:-|%2D)one/,
     'network opens its own detail card');
like($html, qr/networks.cgi\?tab=bridges(?:&amp;|&)selected=br%20%3Clan%3E/i,
     'bridge link encodes its name');
is(scalar(() = $html =~ /machine.cgi\?id=vm(?:-|%2D)one/g), 2,
   'shared guest appears once in each relevant table row');
like($html, qr/No virtual machines attached/,
     'unused network is described clearly');
unlike($html, qr/<form\b/, 'overview has no mutation controls');

# Landing, explicit tabs and form return targets use different defaults.
is(network_page_tab(''), 'overview', 'overview is the landing tab');
is(network_page_tab('invalid'), 'overview',
   'invalid tab falls back to overview');
for my $tab (qw(overview networks bridges interfaces)) {
	is(network_page_tab($tab), $tab, 'explicit '.$tab.' tab accepted');
	}
like(network_form('create', 'token'), qr/name="tab"[^>]*value="networks"/,
     'network changes return to networks');
like(network_form('bridge_review', 'token'), qr/name="tab"[^>]*value="bridges"/,
     'bridge changes return to bridges');
$html = show_network_page($data, '', undef, 'root', 'networks', 'net-two');
my ($first) = $html =~ /data-network-name="([^"]+)"/;
is($first, 'private', 'selected network is first in the detail tab');
like($html,
     qr/data-network-name="private"[^>]*>\s*<section[^>]*cloudmin-network-selected/, 'selected network is highlighted');
unlike($html, qr/<form\b/,
       'read-only overview and detail tabs contain no forms');
is(scalar(() = show_virtual_network($network,
				    '') =~ /machine.cgi\?id=vm(?:-|%2D)one/g),
   1,
   'network card retains its deduplicated VM link');
like(show_host_network($bridge), qr/machine.cgi\?id=vm(?:-|%2D)two/,
     'bridge card retains attached VM links');

# Selected bridge navigation does not reorder or highlight virtual networks.
my $second_bridge = { %$bridge, name => 'br2' };
$html =
	show_network_page({ %$data, bridges => [ $bridge, $second_bridge ] },
			  '',
			  undef,
			  'root', 'bridges', 'br2');
my ($selected) =
	$html =~ /(<section[^>]*cloudmin-network-selected.*?<\/section>)/s;
like($selected, qr/>br2<\//, 'selected host bridge is highlighted');
is(scalar(() = $html =~ /\bcloudmin-network-selected\b/g), 1,
   'only the selected detail card is highlighted');
like($html, qr/>br2<\/.*?>br &lt;lan&gt;<\//s,
     'selected bridge is first in its tab');
# Recovery belongs to the bridges tab and shares the native card layout.
$html =
	show_network_page($data, 'token',
			  { state => 'confirm', name => 'br0', id => 'tx',
			    deadline => time() + 60, owner => 'root' }, 'root');
my $status_position = index($html, 'cloudmin-network-status');
ok($status_position > index($html, 'data-network-tab="bridges"') &&
   $status_position < index($html,
			    'data-network-tab="interfaces"'),
   'bridge progress and recovery stay inside the host bridges tab');
like($html, qr/cloudmin-network-pending/,
     'bridge progress retains its polling marker');
like($html, qr/ui_card_info/, 'bridge progress uses a native status card');
unlike($html, qr/ui_alert_box/, 'bridge progress has no separate alert boxes');
unlike($html, qr/value="create"/,
       'pending bridge change still blocks new network changes');
# Recovery remains available after the owner disappears, without allowing others
# to confirm unexpired changes.
for my $state ( 'rollback_failed', 'confirm' ) {
	$html = show_network_status({ state => $state, name => 'br0',
				      id => 'tx',
				      deadline => time() - 1,
				      owner => 'removed-user' },
				    'token', 'root');
	like($html, qr/value="rollback"/,
	     'another writer can recover '.$state);
	like($html, qr/ui_action_danger/, 'restore is a red action');
	unlike($html, qr/value="confirm"/,
	       'another writer cannot confirm '.$state);
	}

# A running recovery has no further actions or expired confirmation countdown.
$html =
	show_network_page($data, 'token', { state => 'rolling_back',
					    name => 'br0',
					    id => 'tx', deadline => time() - 60,
					    owner => 'root' }, 'root',
			  'bridges');
like($html, qr/Restoring the previous network settings/,
     'running recovery explains the current action');
like($html, qr/id="cloudmin-network-pending"/,
     'running recovery keeps polling');
unlike($html, qr/cloudmin-network-countdown/,
       'recovery does not show an expired confirmation countdown');
unlike($html, qr/value="(?:rollback|confirm|create|bridge_review)"/,
       'recovery hides repeat and conflicting actions');

# Empty inventories keep useful destinations without inventing activity.
$html =
	show_network_overview({ networks => [ ], bridges => [ ],
				interfaces => [ ] });
@counts = $html =~ /ui_stat_value[^>]*>.*?<\/svg>\s*(\d+)\s*<\/span>/sg;
is_deeply(\@counts, [ 0, 0, 0, 0 ], 'empty inventory reports zero counts');
like($html, qr/No networks or host bridges yet/,
     'empty overview explains the state');
like($html, qr/networks.cgi\?tab=networks/,
     'empty overview links to the network tab');
unlike($html, qr/data-sortable/, 'empty overview omits an empty table');
# Removal stays compact, signed and separate from the host connection badge.
my $removable = { %$bridge, name => 'br0', guests => [ ], networks => [ ] };
$html = show_host_network($removable, 0, 0, 'signed');
like($html, qr/value="bridge_remove_review"/,
     'unused bridge offers removal review');
like($html,
     qr/ui_action_danger[^>]*ui_action_small|ui_action_small[^>]*ui_action_danger/,
     'bridge removal uses a small red button');
unlike(show_host_network($removable, 0, 0, ''), qr/bridge_remove_review/,
       'read-only view has no removal action');
unlike(show_host_network({ %$removable, networks => [ 'default' ] }, 0, 0,
			 'signed'),
       qr/bridge_remove_review/, 'referenced bridge has no removal action');
unlike(show_host_network({ %$removable, guests => [ $guest ] }, 0, 0, 'signed'),
       qr/bridge_remove_review/, 'attached guest hides removal');
# Review and completion must describe removal, not reuse creation messages.
my $removal =
	{ operation => 'remove', name => 'br0', source => 'eth0', addresses =>
									  [ '192.0.2.2/24' ],
	  revision => 'reviewed', confirm_timeout => 180,
	  management => 1 };
$html = show_bridge_review($removal, 'signed');
like($html, qr/Review Bridge Removal/, 'review title describes removal');
like($html, qr/value="bridge_remove"/, 'review submits bridge removal');
like($html, qr/restores the bridge/, 'review explains removal recovery');
$html =
	show_network_status({ %$removal, state => 'complete',
			      owner => 'fixture' },
			    'signed', 'fixture');
like($html, qr/was removed/, 'completed status describes removal');
unlike($html, qr/was created|<form/,
       'completed removal has no creation message or repeat action');
done_testing();
