use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore qw(convert_to_json convert_from_json);
use Encode qw(encode);
use Cloudmin::Status;
# All viewers share inventory, but each tracks its own delivered snapshot.
my $cache = Cloudmin::Status->new();
my @ids = map { sprintf('00000000-0000-0000-0000-%012d', $_) } 1..100;
for my $id (@ids) {
	$cache->record({ uuid => $id, name => "guest-$id", state => 'running',
		active => 1,
		xml => 'secret', cloudmin => { password => 'secret' } });
	}
my @clients = map { { id => 'overview' } } 1..10;
for my $client (@clients) {
	my $message = $cache->message($client);
	is(scalar(keys %{$message->{changed}}), 100,
		'one snapshot includes all 100 VMs');
	unlike(convert_to_json($message), qr/secret/,
		'private metadata never reaches subscribers');
	ok(!defined($cache->message($client)),
		'unchanged inventory sends nothing');
	}
ok(!defined($cache->next_probe(\@clients, 100)),
	'ten overviews do not trigger 1,000 SSH checks');
# Changing one guest must not resend the other 99 to any viewer.
my $id = $ids[3];
$cache->record({ uuid => $id, name => 'changed', state => 'shutoff' });
for my $client (@clients) {
	is_deeply([keys %{$cache->message($client)->{changed}}], [$id],
		'only changed VM is sent to each viewer');
	}
# Detail viewers share one health result and its retry interval.
my $detail = { id => $id };
push(@clients, $detail, { id => $id });
is($cache->next_probe(\@clients, 100), $id,
	'detail subscribers share the same probe');
$cache->checked($id, { ssh => 'responding' }, 100);
ok(!defined($cache->next_probe(\@clients, 129)),
	'healthy SSH backs off for every subscriber');
is($cache->next_probe(\@clients, 130), $id,
	'healthy SSH eventually checks reachability again');
# Hidden pages stop probes and catch up from the cache when shown again.
$cache->message($detail);
$detail->{paused} = 1;
$cache->invalidate($id);
ok(!defined($cache->message($detail)), 'paused subscriber receives no updates');
$clients[-1]->{paused} = 1;
ok(!defined($cache->next_probe(\@clients, 200)),
	'hidden detail pages stop guest probes');
$detail->{paused} = 0;
ok($cache->message($detail)->{changed}->{$id},
	'returning viewer receives accumulated changes');
# A result collected before deletion must not resurrect the guest.
$cache->remove($id);
is_deeply($cache->message($detail)->{removed}, [$id],
	'guest deletion is delivered');
$cache->checked($id, { ssh => 'responding' }, 300);
ok(!exists($cache->{health}->{$id}), 'late probe cannot restore a deleted VM');

# Libvirt names arrive as bytes, while decoded JSON can already be Unicode.
for my $name ("Caf\xc3\xa9", "Caf\x{e9}") {
    my $unicode = Cloudmin::Status->new();
    $unicode->record({ uuid => 'unicode', name => $name, state => 'shutoff' });
    is($unicode->message({ id => 'overview' })->{changed}{unicode}{vm}{name},
        "Caf\x{e9}", 'inventory name is decoded exactly once');
}

# Match send_utf8's encoding step for both Latin-1 and wider Unicode names.
my $wide = Cloudmin::Status->new();
my $wide_name = "Caf\x{e9} \x{65e5}\x{672c} \x{1f642}";
$wide->record({ uuid => 'unicode', name => $wide_name, state => 'shutoff' });
my $wire = encode('UTF-8', convert_to_json($wide->message({id => 'overview'})));
is(convert_from_json($wire)->{'changed'}->{'unicode'}->{'vm'}->{'name'},
    $wide_name, 'WebSocket text encoding preserves the complete guest name');

# A late DHCP lease must reach an overview without opening the guest's details.
my $leases = Cloudmin::Status->new();
$leases->record({ uuid => 'dhcp', active => 1, addresses => [] });
my $overview = { id => 'overview' };
$leases->message($overview);
my $address = [{ address => '192.0.2.30', source => 'lease' }];
$leases->refresh_addresses(['dhcp'], sub { $address });
is_deeply($leases->message($overview)->{changed}{dhcp}{vm}{addresses},
	$address, 'late DHCP address is broadcast to an overview');
$leases->refresh_addresses(['dhcp'], sub { die "Temporary lease lookup failure\n" });
ok(!defined($leases->message($overview)), 'lookup failure retains the last address');
$leases->refresh_addresses(['dhcp'], sub { [] });
is_deeply($leases->message($overview)->{changed}{dhcp}{vm}{addresses}, [],
	'expired host-observed address is removed');
$leases->checked('dhcp', { addresses => [{ address => '192.0.2.40', source => 'agent' }] }, 100);
$leases->message($overview);
$leases->refresh_addresses(['dhcp'], sub { die 'Agent-only address must be retained' });
ok(!defined($leases->message($overview)), 'host refresh retains agent-only static addresses');

# Pending differences travel through the cache and clear when inventory matches.
my $changes = {cpu_limit => {running => 2, saved => 3}};
$leases->record({uuid => 'dhcp', active => 1, pending => $changes});
is_deeply($leases->message($overview)->{changed}{dhcp}{vm}{pending}, $changes,
	'pending resources reach status subscribers');
$leases->record({uuid => 'dhcp', active => 1, pending => {}});
is_deeply($leases->message($overview)->{changed}{dhcp}{vm}{pending}, {},
	'matching settings clear pending badges through a delta');

done_testing();
