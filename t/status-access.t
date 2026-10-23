use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore qw(convert_to_json);
require "$Bin/../lib/Cloudmin/Access.pm";

# Exercise the collector's actual access and reporting functions without
# starting Webmin, opening libvirt or changing a guest.
open(my $fh, '<', "$Bin/../status-server.pl") or die $!;
my $source = do { local $/; <$fh> };
my ($functions) = $source =~ /(sub authorize_client\n\{.*?)\n# connect_libvirt/s;
die 'Collector access functions not found' if (!$functions);
our (%clients, %dirty, $cache, $adapter, $access);
# authorized(session) supplies the policy selected by each scenario.
sub authorized { return $access; }
eval $functions.'; 1;' or die $@;

{
	package AccessCache;
	# record(self, record) retains the collected VM for subsequent viewers.
	sub record { $_[0]->{'vms'}->{$_[1]->{'uuid'}} = $_[1]; }
	package AccessAdapter;
	# get_domain_record(self, domain, brief) supplies an existing active guest.
	sub get_domain_record { return {uuid => 'fixture', active => 1}; }
	# get_domain_addresses(self, domain, record, brief) avoids network probes.
	sub get_domain_addresses { return []; }
	package AccessDomain;
	# set_memory_stats_period(self, period, flags) records attempted changes.
	sub set_memory_stats_period { push(@{$_[0]->{'changes'}}, [@_[1, 2]]); }
}
$cache = bless({vms => {}}, 'AccessCache');
$adapter = bless({}, 'AccessAdapter');
my $domain = bless({changes => []}, 'AccessDomain');
{ package AccessClient;
  # send_utf8(self, message) captures permission-change notices without a socket.
  sub send_utf8 { $_[0]->{'notice'} = $_[1]; }
  # disconnect(self) records an attempted close of this fixture's connection.
  sub disconnect { $_[0]->{'disconnected'} = 1; }
}
# A read-only administrator gets inventory without enabling guest reporting.
my $client = bless({session => 'fixture'}, 'AccessClient');
$access = {user => 'viewer', readonly => 1, policy => Cloudmin::Access->new({}, 1)};
ok(authorize_client($client), 'read-only module user is authorized');
ok(!$client->{'writable'}, 'read-only subscription has no guest write grant');
$clients{$client} = {client => $client};
collect_domain($domain);
is_deeply($domain->{'changes'}, [], 'read-only inventory does not enable balloon reports');
ok($cache->{'vms'}->{'fixture'}, 'read-only viewer still receives inventory');

# Granting host write access refreshes controls and enables live balloon reports.
$access = {user => 'writer', readonly => 0, policy => Cloudmin::Access->new({})};
ok(authorize_client($client), 'changed permissions refresh the live subscription');
like($client->{'notice'}, qr/access_changed/, 'client is told to refresh its controls');
# A new connection starts without a remembered policy signature.
delete $client->{'acl_signature'};
ok(authorize_client($client), 'writer reconnects with fresh permissions');
ok($dirty{'fixture'}, 'writer arrival refreshes existing cached guests');
collect_domain($domain);
is_deeply($domain->{'changes'}, [[10, 1]], 'writer retains live-only reporting setup');

# Enabling read-only stops guest writes; revoking the login refuses the session.
$access = {user => 'writer', readonly => 1, policy => Cloudmin::Access->new({}, 1)};
authorize_client($client);
collect_domain($domain);
is(scalar(@{$domain->{'changes'}}), 1, 'ACL downgrade removes the guest write grant');
# Password grants participate in live ACL changes, even without power access.
my $uuid = '11111111-2222-3333-4444-555555555555';
$access = {user => 'operator', policy => Cloudmin::Access->new({admin => 0, vms => $uuid, password => 1})};
authorize_client($client);
delete $client->{'notice'};
$access = {user => 'operator', policy => Cloudmin::Access->new({admin => 0, vms => $uuid})};
authorize_client($client);
like($client->{'notice'}, qr/access_changed/, 'revoking password reset sends an access-change notice');
# Revoking the session itself must still disconnect the viewer.
$access = undef;
ok(!authorize_client($client), 'revoked session is refused');
done_testing();
