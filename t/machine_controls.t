use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;
our $module_root_directory = "$Bin/..";
our $module_var_directory = tempdir(CLEANUP => 1);
our $remote_user = 'fixture';
require "$module_root_directory/cloudmin-lib.pl";

{
	package ControlJobs;

	# lock(self, resource, callback) models serialized lifecycle requests.

	sub lock
	{
	return $_[2]->();
	}

	# assert_guest_available(self, uuid) models an idle management queue.

	sub assert_guest_available
	{
	return 1;
	}
	package ControlImages;

	# check_token(self, user, token) rejects missing and
	# foreign form tokens.

	sub check_token
	{
	die "Bad token\n" unless ($_[2] ||
				  '') eq 'fixture-token';
	}
	package ControlAdapter;

	# get_domain(self, id) resolves the fixture or simulates a removed VM.

	sub get_domain
	{
	return $_[0]->{'vm'}
		if ($_[1] eq $_[0]->{'vm'}->{'uuid'});
	return undef;
	}

	# start_domain(self, id) records the requested operation.

	sub start_domain
	{
	push(@{$_[0]->{'calls'}}, [ 'start', $_[1] ]);
	}

	# shutdown_domain(self, id) records clean shutdown or a libvirt refusal.

	sub shutdown_domain
	{
	die "Guest refused shutdown\n" if ($_[0]->{'fail'});
	push(@{$_[0]->{'calls'}}, [ 'shutdown', $_[1] ]);
	}

	# reboot_domain(self, id) records the requested operation.

	sub reboot_domain
	{
	push(@{$_[0]->{'calls'}}, [ 'reboot', $_[1] ]);
	}

	# suspend_domain(self, id) records a pause without powering down.

	sub suspend_domain
	{
	push(@{$_[0]->{'calls'}}, [ 'suspend', $_[1] ]);
	}

	# resume_domain(self, id) records continuation of a paused guest.

	sub resume_domain
	{
	push(@{$_[0]->{'calls'}}, [ 'resume', $_[1] ]);
	}

	# reset_domain(self, id) records the confirmed hard reset.

	sub reset_domain
	{
	push(@{$_[0]->{'calls'}}, [ 'reset', $_[1] ]);
	}

	# destroy_domain(self, id) records emergency power-off
	# or a libvirt refusal.

	sub destroy_domain
	{
	die "Power off failed\n" if ($_[0]->{'fail'});
	push(@{$_[0]->{'calls'}}, [ 'destroy', $_[1] ]);
	}

	# set_domain_autostart(self, id, enabled) records the
	# explicit boot policy.

	sub set_domain_autostart
	{
	push(@{$_[0]->{'calls'}},
	     [ 'autostart', $_[1], $_[2] ]);
	}
	}

my $uuid = '11111111-2222-3333-4444-555555555555';
my $adapter = bless({ vm => { uuid => $uuid, name => 'fixture', active => 0,
			      state => 'shutoff', persistent => 1 },
		      calls => [ ] },
		    'ControlAdapter');
my $readonly = 0;
my @audit;
no warnings qw(redefine once);
local *main::is_readonly_mode = sub { $readonly };
local *main::get_vm_service = sub { return {
	images => bless({ }, 'ControlImages'), jobs =>
						       bless({ },
							     'ControlJobs') }; };
local *main::get_libvirt = sub { die "Not writable" unless $_[0];
	return $adapter; };
local *main::webmin_log = sub { push(@audit, [ @_ ]); };
my $input = { id => $uuid, token => 'fixture-token' };

# Security and malformed requests must fail before a libvirt mutation or audit.
for my $case (
	[ 'start', { token => '' }, qr/Bad token/ ],
	[ 'start', { id => 'fixture' }, qr/Invalid virtual machine ID/ ],
	[ 'start', { id => [ ] }, qr/Invalid virtual machine ID/ ],
	[ 'start', { id => '0' x 8 . '-0000-0000-0000-'.('0' x 12) },
	  qr/not found/ ],
	[ 'autostart', { enabled => 2 }, qr/Select whether/ ],
	[ 'destroy', { }, qr/Unknown virtual machine API action/ ],
	[ 'shutdown', { }, qr/must be running/ ],
	[ 'reboot', { }, qr/must be running/ ],
	[ 'force_off', { }, qr/Confirm force power off/ ],
	[ 'force_off', { confirm => 0 }, qr/Confirm force power off/ ],
	[ 'force_off', { confirm => [ ] }, qr/Confirm force power off/ ],
	[ 'force_off', { confirm => 1, token => '' }, qr/Bad token/ ],
	[ 'force_off', { confirm => 1 }, qr/already stopped/ ],
) {
	ok(!eval { call_vm_api(1, $case->[0], { %$input, %{$case->[1]} }); 1 },
	   'invalid action rejected');
	like($@, $case->[2], 'failure explains the rejected input');
	}
{
	local $adapter->{'vm'}->{'persistent'} = 0;
	ok(!eval { call_vm_api(1, 'autostart', { %$input, enabled => 1 }); 1 },
	   'transient guest cannot autostart');
	like($@, qr/persistent/, 'transient error explains the requirement');
	}
# Read-only mode vetoes power, password and hardware changes before libvirt.
$readonly = 1;
for my $action (
	qw(start shutdown reboot suspend resume reset force_off reset_password autostart update delete delete_disk grow_disk change_media
	add_disk attach_disk detach_disk add_interface update_interface remove_interface)) {
	ok(!eval { call_vm_api(1, $action, { %$input, enabled => 1 }); 1 },
	   'read-only user cannot control guests');
	like($@, qr/read-only/, 'read-only failure precedes libvirt');
	}
is_deeply($adapter->{'calls'}, [ ], 'rejected requests caused no mutations');
is_deeply(\@audit, [ ], 'rejected requests have no success audit');
$readonly = 0;

# Every allowed action calls the existing adapter and logs only public identity.
is_deeply(call_vm_api(1, 'start', { %$input }),
	  { id => $uuid, name => 'fixture', action => 'start' },
	  'start returns acceptance');
$adapter->{'vm'}->{'active'} = 1;
$adapter->{'vm'}->{'state'} = 'running';
ok(!eval { call_vm_api(1, 'start', { %$input }); 1 },
   'stale start request is rejected');
for my $action (qw(shutdown reboot)) {
	is(call_vm_api(1, $action, { %$input })->{'action'}, $action,
	   'running guest accepts power request');
	}
for my $enabled ( 1, 1, 0 ) {
	call_vm_api(1, 'autostart', { %$input, enabled => $enabled });
	is($adapter->{'calls'}->[-1]->[2], $enabled,
	   'boot policy uses explicit value, including retries');
	}
is_deeply([ map { $_->[0] } @{$adapter->{'calls'}} ],
	  [ qw(start shutdown reboot autostart autostart autostart) ],
	  'adapter received only allowed methods');
is(scalar(@audit), 6, 'each accepted change has one audit entry');
is_deeply($audit[0], [ 'start', 'vm', $uuid, { name => 'fixture' } ],
	  'audit contains no token');
$adapter->{'fail'} = 1;
ok(!eval { call_vm_api(1, 'shutdown', { %$input }); 1 },
   'libvirt refusal propagates');
like($@, qr/Guest refused shutdown/, 'libvirt failure retained');
is(scalar(@audit), 6, 'refused operation has no success audit');

# Emergency control remains available when the guest cannot process ACPI events.
$adapter->{'fail'} = 0;
foreach my $state (qw(running blocked paused shutdown crashed pmsuspended)) {
	$adapter->{'vm'}->{'state'} = $state;
	is(call_vm_api(1, 'force_off', { %$input, confirm => 1 })->{'action'},
	   'force_off',
	   "confirmed power-off accepts an active $state guest");
	is_deeply($adapter->{'calls'}->[-1], [ 'destroy', $uuid ],
		  'only the target guest is powered off through libvirt');
	}
is_deeply($audit[-1], [ 'force_off', 'vm', $uuid, { name => 'fixture' } ],
	  'emergency power-off has a distinct audit record');
my $calls = scalar(@{$adapter->{'calls'}});
my $logs = scalar(@audit);
$adapter->{'vm'}->{'active'} = 0;
ok(!eval { call_vm_api(1, 'force_off', { %$input, confirm => 1 }); 1 },
   'a guest stopped since confirmation cannot be powered off again');
like($@, qr/already stopped/, 'stale confirmation explains the current state');
$adapter->{'vm'}->{'active'} = 1;
$adapter->{'fail'} = 1;
ok(!eval { call_vm_api(1, 'force_off', { %$input, confirm => 1 }); 1 },
   'failed emergency power-off propagates');
like($@, qr/Power off failed/, 'libvirt power-off error is retained');
is(scalar(@{$adapter->{'calls'}}), $calls, 'failed power-off adds no mutation');
is(scalar(@audit), $logs, 'failed power-off adds no success audit');
# Pause/resume validate execution state; hard reset also needs confirmation.
$adapter->{'fail'} = 0;
$adapter->{'vm'}->{'state'} = 'running';
is(call_vm_api(1, 'suspend', $input)->{'action'}, 'suspend',
   'running guest accepts Pause');
ok(!eval { call_vm_api(1, 'resume', $input); 1 },
   'running guest cannot be resumed');
$adapter->{'vm'}->{'state'} = 'paused';
is(call_vm_api(1, 'resume', $input)->{'action'}, 'resume',
   'paused guest accepts Resume');
ok(!eval { call_vm_api(1, 'suspend', $input); 1 },
   'paused guest cannot be paused again');
ok(!eval { call_vm_api(1, 'reset', $input); 1 },
   'hard reset requires confirmation');
is(call_vm_api(1, 'reset', { %$input, confirm => 1 })->{'action'}, 'reset',
   'confirmed reset uses existing action API');
is_deeply($adapter->{'calls'}->[-1], [ 'reset', $uuid ],
	  'only selected guest is reset');
is_deeply($audit[-1], [ 'reset', 'vm', $uuid, { name => 'fixture' } ],
	  'hard reset is audited separately');
# Confirmation cannot turn a stopped guest into a valid reset target.
$adapter->{'vm'}->{'active'} = 0;
ok(!eval { call_vm_api(1, 'reset', { %$input, confirm => 1 }); 1 },
   'stopped guest is not reset');
done_testing();
