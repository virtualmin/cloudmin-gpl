use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/lib";
use CloudminTest;
no warnings 'once';
use JSON::PP;
require "$Bin/../lib/Cloudmin/Status.pm";
use Cwd ();
require(Cwd::abs_path("$Bin/../cloudmin-access-lib.pl"));

# Compare default administrator access with assigned viewer and operator roles.
my $one = '11111111-2222-3333-4444-555555555555';
my $other = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
my @grants = qw(power force console terminal password);
my $admin = Cloudmin::Access->new({ });
my $readonly = Cloudmin::Access->new({ }, 1);
my $viewer = Cloudmin::Access->new({ admin => 0, vms => uc($one) });
my $operator = Cloudmin::Access->new({ admin => 0, vms => $one,
				       map { $_ => 1 } @grants });
# Check each role's grants, VM assignments and read-only restrictions together.
for my $grant ( 'host', 'manage', 'view', @grants ) {
	ok($admin->allows($grant, $one),
	   "existing administrator retains $grant");
	is($readonly->allows($grant, $one), $grant =~ /^(host|view)$/ ? 1 : 0,
	   "read-only administrator: $grant");
	is($viewer->allows($grant, $one), $grant eq 'view' ? 1 : 0,
	   "assigned viewer: $grant");
	is($operator->allows($grant, $one), $grant =~ /^(host|manage)$/ ? 0 : 1,
	   "assigned operator: $grant");
	ok(!$operator->allows($grant, $other), "foreign VM refuses $grant");
	# Read-only mode preserves viewing but blocks changes and connections.
	ok(!Cloudmin::Access->new({ admin => 0, vms => $one,
				    map { $_ => 1 } @grants },
				  1)->allows($grant,
					     $one),
	   "read-only overrides delegated $grant") if ($grant ne 'view');
	}
# Granting one capability must not imply any other capability.
for my $grant (@grants) {
	my $policy =
		Cloudmin::Access->new({ admin => 0, vms => $one, $grant => 1 });
	ok($policy->allows($grant, $one),
	   "$grant can be granted independently");
	ok(!$policy->allows($_, $one),
	   "$grant does not imply $_") for grep { $_ ne $grant } @grants;
	}
# Restricted users need valid assignments to view a VM.
for my $acl ( { admin => 'bad' }, { admin => 0 }, { admin => 0, vms => '*' },
	      { admin => 0, vms => 'name' }, { admin => 0, vms => $other } ) {
	ok(!Cloudmin::Access->new($acl)->allows('view', $one),
	   'missing or invalid assignments deny');
	}
# Unknown actions fail for administrators too; delegated IDs must be scalars.
ok(!$admin->allows('typo', $one),
   'unknown permissions fail closed for everyone');
ok(!$operator->allows('power', [ ]), 'structured VM input is refused');
ok(!$operator->allows('power', undef), 'missing VM is refused');

# A shared cache must filter snapshots, deltas, probes and
# capabilities per user.
my $cache = Cloudmin::Status->new();
$cache->record({ uuid => $_, name => $_, active => 1, state =>
							      'running' }) for ($one, $other);
$cache->checked($one,
		{ console_available => 1, serial_available => 1,
		  terminal_available => 1 },
		1);
my $sub = { id => 'overview', policy => $viewer };
my $message = $cache->message($sub);
is_deeply([ keys %{$message->{'changed'}} ], [ $one ],
	  'snapshot contains only assigned VM');
# Neither console mode may bypass the viewer's lack of interactive permissions.
is($message->{'changed'}->{$one}->{'health'}->{'console_available'}, 0,
   'viewer has no console capability');
is($message->{'changed'}->{$one}->{'health'}->{'serial_available'}, 0,
   'viewer has no serial capability');
is($message->{'changed'}->{$one}->{'health'}->{'terminal_available'}, 0,
   'viewer has no terminal capability');
# Filtering for one viewer must not change shared data or probe unassigned VMs.
is($cache->{'health'}->{$one}->{'console_available'}, 1,
   'shared health is not changed by redaction');
is_deeply($cache->resource_ids([ $sub ]), [ $one ],
	  'metrics cover only visible assigned VMs');
ok(!$cache->next_probe([ { id => $other, policy => $viewer } ], 100),
   'foreign detail cannot schedule probes');
# Ignore changes to unassigned VMs; report when an assigned VM is removed.
$cache->record({ uuid => $other, name => 'changed', state => 'running' });
ok(!$cache->message($sub), 'foreign change produces no delta');
$cache->remove($one);
is_deeply($cache->message($sub)->{'removed'}, [ $one ],
	  'assigned VM removal reaches viewer');

# Test controller permission checks without Webmin or job stores.
our ($module_root_directory, $remote_user, %access, %text);
$module_root_directory = "$Bin/..";
$remote_user = 'operator';
require "$Bin/../cloudmin-lib.pl";
my $calls = 0;
no warnings 'redefine';
# is_readonly_mode() leaves writes enabled so the tests check VM permissions.
local *main::is_readonly_mode = sub { 0 };
# get_vm_service() fails if a rejected request tries to open a store.
local *main::get_vm_service = sub { $calls++; die "Store reached\n" };
%access = ( admin => 0, vms => $one, power => 1 );
# A power grant cannot authorize host actions or password resets,
# even with a valid token.
for my $action (qw(settings snapshots status list create review update delete
	delete_disk add_disk attach_disk detach_disk grow_disk change_media add_interface
	update_interface remove_interface snapshot_create snapshot_restore snapshot_delete
	power_cycle discard cancel recover reset_password)) {
	ok(!eval { call_vm_api(1, $action,
			       { id => $one, token => 'admin-token' }); 1 },
	   "restricted controller denies $action");
	like($@, qr/Cloudmin permissions/,
	     "$action denied before store or token");
	}
# An unassigned VM cannot be controlled, even with a borrowed token.
for my $action (
	qw(start shutdown reboot suspend resume autostart force_off reset reset_password)) {
	ok(!eval { call_vm_api(1, $action,
			       { id => $other, token => 'admin-token' }); 1 },
	   "foreign $action denied");
	like($@, qr/Cloudmin permissions/,
	     'foreign VM cannot be controlled');
	}
# Delegated options return grants without opening a service or job store.
is($calls, 0, 'all denials happened before store creation');
is_deeply(call_vm_api(1, 'options', { }), { permissions => {
	power => 1, force => 0, console => 0, terminal => 0,
	password => 0 } },
	  'operator options contain no host resources');

done_testing();
