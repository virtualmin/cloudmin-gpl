use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;

# Load the controller with isolated paths and mock its host dependencies below.
our $module_root_directory = "$Bin/..";
our $module_var_directory = tempdir(CLEANUP => 1);
our $remote_user = 'fixture';
our %access;
require "$module_root_directory/cloudmin-lib.pl";

{
	package PasswordDomain;

	# get_info(self) supplies current state without parsing guest XML.
	sub get_info
	{
	return { state => $_[0]->{'state'} };
	}

	# get_guest_info(self, types, flags) models readiness
	# changing after page load.
	sub get_guest_info
	{
	# Exercise a failed probe as well as empty and malformed replies.
	die "Agent unavailable\n" if ($_[0]->{'agent_error'});
	return $_[0]->{'agent'};
	}

	# set_user_password(self, username, password, flags)
	# models the native call.
	sub set_user_password
	{
	my ($self, @args) = @_;
	# Include the secret to catch unsafe backend error forwarding.
	die "Backend included password: $args[1]\n" if ($self->{'fail'});
	push(@{$self->{'calls'}}, \@args);
	}
	package PasswordAdapter;
	our @ISA = ('Cloudmin::Libvirt');

	# find_domain(self, uuid) records that validation reached libvirt.
	sub find_domain
	{
	$_[0]->{'lookups'}++; return $_[0]->{'domain'};
	}

	# get_domain(self, uuid, [skip_addresses]) returns public identity only.
	sub get_domain
	{
	return { uuid => $_[1], name => 'fixture' };
	}
	package PasswordJobs;

	# lock(self, resource, callback) requires the VM management lock name.
	sub lock
	{
	die "Wrong lock"
		if ($_[1] ne 'create-host'); return $_[2]->();
	}

	# assert_guest_available(self, uuid) simulates a VM
	# reserved by a pending job.
	sub assert_guest_available
	{
	die "Guest is busy\n" if ($_[0]->{'busy'});
	}

	# submit(self, ...) must never retain password changes as jobs.
	sub submit
	{
	die "Password reached job persistence";
	}
	package PasswordImages;

	# check_token(self, user, token) accepts only the fixture's valid token.
	sub check_token
	{
	die "Invalid token\n" if (($_[2] || '') ne 'valid');
	}
	}

# Start with a running guest and usable agent for validation and refusal tests.
my $id = '11111111-2222-3333-4444-555555555555';
my $domain =
	bless({ state => 1, agent => { name => 'Linux' }, calls => [ ] },
	      'PasswordDomain');
my $adapter = PasswordAdapter->new(readonly => 0);
$adapter->{'domain'} = $domain;
my $jobs = bless({ }, 'PasswordJobs');
my $readonly = 0;
my (@audit, @native_log);
no warnings qw(redefine once);
# is_readonly_mode() supplies the Webmin mode selected by each test.
local *main::is_readonly_mode = sub { $readonly };
# get_vm_service() supplies token and job checks without opening SQLite.
local *main::get_vm_service = sub { return {
	jobs => $jobs, images => bless({ }, 'PasswordImages') }; };
# get_libvirt(write) checks that the controller requests a writable adapter.
local *main::get_libvirt =
	sub { die 'Expected writable adapter' if (!$_[0]); return $adapter; };
# webmin_log(action, type, id, details) captures the controller's audit fields.
local *main::webmin_log = sub { push(@audit, [ @_ ]); };
# additional_log(type, object, message) captures the native call's audit text.
local *Cloudmin::Libvirt::additional_log = sub { push(@native_log, [ @_ ]); };
# Password delegation is independent of power control; exercise non-ASCII input.
%access = ( admin => 0, vms => $id, password => 1 );
my $secret = 'Secret with spaces and ünicode';

# reset_account([fields]) submits a fresh request with optional field overrides.
# fields defaults to {}; fresh input is needed because the API removes secrets.
sub reset_account
{
my ($fields) = @_;
return call_vm_api(1, 'reset_password', {
	id => $id, token => 'valid', username => 'root', password =>
								 $secret,
	%{$fields || { }} });
}

# A valid token cannot replace the grant, and a grant cannot replace the token.
for my $case ( [ 0, 'valid' ], [ 1, '' ], [ 1, 'borrowed' ] ) {
	local $access{'password'} = $case->[0];
	ok(!eval { reset_account({ token => $case->[1] }); 1 },
	   'permission or token refusal');
	like($@, qr/permissions|Invalid token/,
	     'denial explains access requirement');
	}
# Delegation still needs a guest assignment and cannot bypass read-only mode.
{
	local $access{'vms'} = '';
	ok(!eval { reset_account(); 1 },
	   'password grant still requires the VM assignment');
	}
$readonly = 1;
ok(!eval { reset_account(); 1 }, 'read-only vetoes password grant');
like($@, qr/read-only/, 'read-only refusal is explicit');
$readonly = 0;
is($adapter->{'lookups'} || 0, 0, 'access refusals never reach libvirt');

# Invalid values cannot reach the native password call or appear in errors.
for my $fields ( { username => "root\ninjected" }, { username => 'root:other' },
		 { username => [ ] }, { username => '' }, { password => [ ] },
		 { password => '' },
		 { password => "bad\0password" },
		 { password => "bad\npassword" },
		 { password => 'x' x 1025 } ) {
	ok(!eval { reset_account($fields); 1 },
	   'malformed account input refused');
	like($@, qr/Enter a/, 'validation uses a fixed message');
	}
# The adapter independently rejects writes, even if a caller bypasses the API.
{
	local $adapter->{'readonly'} = 1;
	ok(!eval { $adapter->set_user_password($id, 'root', $secret); 1 },
	   'adapter refuses read-only connections');
	}
# Paused, stopped and other non-running states must never reach the native call.
for my $state ( 0, 3, 4, 5, 6, 7 ) {
	local $domain->{'state'} = $state;
	ok(!eval { reset_account(); 1 },
	   'non-running guest refuses password reset');
	like($@, qr/must be running/, 'current power state is checked');
	}
# Only a nonempty agent information hash proves the readiness probe succeeded.
for my $reply ( undef, { }, 'bad reply' ) {
	local $domain->{'agent'} = $reply;
	ok(!eval { reset_account(); 1 },
	   'missing agent response refuses reset');
	like($@, qr/agent is not responding/, 'agent error is clear');
	}
# Probe exceptions and pending VM jobs must also stop the reset.
{
	local $domain->{'agent_error'} = 1;
	ok(!eval { reset_account(); 1 }, 'failed agent probe refuses reset');
	local $jobs->{'busy'} = 1;
	ok(!eval { reset_account(); 1 }, 'pending management job blocks reset');
	like($@, qr/busy/, 'management conflict is retained');
	}
is_deeply($domain->{'calls'}, [ ],
	  'all refusals left the guest account untouched');

# Successful account changes are immediate and preserve the password verbatim.
my $input = { id => $id, token => 'valid', username => 'root',
	      password => $secret, password_again => $secret };
is_deeply(call_vm_api(1, 'reset_password', $input),
	  { id => $id, name => 'fixture', action => 'reset_password' },
	  'success exposes only public identity');
ok(!exists($input->{'password'}) && !exists($input->{'password_again'}),
   'form secrets consumed before logging');
is_deeply($domain->{'calls'}, [ [ 'root', $secret, 0 ] ],
	  'native binding receives plaintext and flags=0');
# Both audit layers keep account identity while omitting plaintext credentials.
is_deeply(\@audit,
	  [ [ 'reset_password', 'vm', $id,
	      { name => 'fixture', username => 'root' } ] ],
	  'audit contains the target account, without credentials');
like($native_log[0]->[2], qr/libvirt API: set_user_password/,
     'native call remains auditable');
unlike($native_log[0]->[2], qr/\Q$secret\E/, 'native log omits the password');
# Libvirt's blocked state still counts as running for agent operations.
{
	local $domain->{'state'} = 2;
	ok(reset_account(), 'blocked CPU state is still a running guest');
	}

# Even a backend exception containing the password must never reach the caller.
{
	local $domain->{'fail'} = 1;
	ok(!eval { reset_account(); 1 }, 'native failure is reported');
	like($@, qr/Could not reset the password/,
	     'native failure gives account and agent guidance');
	unlike($@, qr/\Q$secret\E|Backend/,
	       'raw backend details are discarded');
	}
is(scalar(@audit), 2, 'failed native operation adds no success audit');
is(scalar(@native_log), 2, 'failed native call adds no audit record');
done_testing();
