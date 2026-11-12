use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
our $module_root_directory = abs_path("$Bin/..");
our $module_var_directory = tempdir(CLEANUP => 1);
our $remote_user = 'fixture';
require "$module_root_directory/cloudmin-lib.pl";

{
	package RetryImages;

	# check_token(self, owner, token) Accepts only this
	# fixture's submitted token.
	sub check_token
	{
	die 'Bad token' if ($_[2] ne 'fixture-token');
	}
	package RetryJobs;

	# get(self, id, owner) Models an already completed
	# creation owned by this user.
	sub get
	{
	return { id => $_[1], owner => $_[2], state => 'complete',
		 events => [ ],
		 request => { name => 'Existing VM', image => 'a' x 32 } };
	}
	}

# Repeated submission never needs a real libvirt or systemd connection.
{
	no warnings qw(redefine once);
	local *main::is_readonly_mode = sub { return 0; };
	local *main::get_vm_service = sub { return {
		jobs => bless({ }, 'RetryJobs'),
		images => bless({ }, 'RetryImages') }; };
	my $input = { token => 'fixture-token', name => 'Existing VM',
		      image => 'a' x 32 };
	my $result = call_vm_api(1, 'create', { %$input });
	is($result->{'state'}, 'complete',
	   'an identical retry returns the existing job');
	my $normalized = call_vm_api(1, 'create', { %$input,
						    name => ' Existing VM ',
						    image =>
							    ' '.('a' x 32).' ' });
	is($normalized->{'id'}, $result->{'id'},
	   'retry normalization matches initial validation');
	# A reused token cannot change the guest, image or installation mode.
	for my $change ( { name => 'Other VM' }, { image => 'b' x 32 },
			 { image => [ ] }, { install_source => 'iso' } ) {
		ok(!eval { call_vm_api(1, 'create',
				       { %$input, %$change }); 1 },
		   'a different VM cannot silently reuse a completed form');
		like($@, qr/Reload the page/,
		     'the rejected retry explains how to submit a new VM');
		}
	}
# Preset selection is part of the retry identity, not a new settings lookup.
{
	no warnings qw(redefine once);
	# is_readonly_mode() permits the fixture's retry submission.
	local *main::is_readonly_mode = sub { 0 };
	# get_vm_service() supplies stores without connecting to libvirt.
	local *main::get_vm_service = sub { return {
		jobs => bless({ }, 'RetryJobs'), images =>
							 bless({ },
							       'RetryImages') }; };
	# get(self, id, owner) supplies a completed job with
	# resolved preset values.
	local *RetryJobs::get = sub { return { id => $_[1], owner => $_[2],
					       state => 'complete',
					       events => [ ],
					       request =>
						       { name => 'Preset VM',
							 image => 'a' x 32,
							 install_source => 'iso',
							 template => 'b' x 32,
							 plan => 'c' x 32 } }; };
	# get_presets() fails if reconnection reads current preset values.
	local *main::get_presets =
		sub { die "Preset files must not be read on retry\n" };
	# Completed jobs keep resolved settings even after their presets change.
	my $fields =
		{ token => 'fixture-token', name => 'Preset VM', template =>
									 'b' x 32, plan => 'c' x 32 };
	is(call_vm_api(1, 'create', { %$fields })->{'state'}, 'complete',
	   'preset retry uses the resolved job after preset deletion or modification');
	foreach my $kind (qw(template plan)) {
		# Reject a different preset on an existing attempt.
		ok(!eval { call_vm_api(1, 'create',
				       { %$fields, $kind => 'd' x 32 }); 1 },
		   "retry cannot change $kind selection");
		like($@, qr/Reload the page/,
		     'changed selection requires a fresh token');
		}
	}

# New submissions take host-key policy from module configuration only.
{
	package KeySettingJobs;

	# get(self, id, owner) models a fresh request with no previous job.
	sub get
	{
	return undef;
	}

	# submit(self, id, owner, resource, request) retains
	# normalized settings.
	sub submit
	{
	return { id => $_[1], state => 'queued',
		 request => $_[4] };
	}

	# delete_credential(self, id, owner) needs no disk
	# state in this fixture.
	sub delete_credential
	{
	}

	# spawn(self, id, callback) prevents creation of a
	# real background process.
	sub spawn
	{
	}
	package KeySettingVMs;

	# prepare(self, input, [options], [hash]) Supplies validated fixture
	# settings while preserving the installation mode.
	sub prepare
	{
	return { name => 'fixture', image => 'a' x 32, install_source =>
							       $_[1]->{'install_source'} };
	}
	package main;
	no warnings qw(redefine once);
	local *KeySettingJobs::lock = sub { $_[2]->(); };
	our %config;
	local *main::is_readonly_mode = sub { 0 };
	local *main::get_vm_password_hash = sub { undef };
	my $saved;
	local *KeySettingJobs::submit = sub { $saved = $_[4];
		return { id => $_[1], state => 'queued', request => $saved }; };
	local *main::get_vm_service = sub { bless({ jobs => bless({ },
								  'KeySettingJobs'),
						    images => bless({ },
								    'RetryImages') }, 'KeySettingVMs') };
	for my $enabled ( 0, 1 ) {
		local $config{'machine_host_ssh_key'} = $enabled;
		call_vm_api(1, 'create',
			    { token => 'fixture-token',
			      host_ssh_key => !$enabled });
		is($saved->{'host_ssh_key'}, $enabled,
		   'creation input cannot override module key policy');
		}
	# Even an enabled module policy cannot add managed SSH
	# keys to an ISO install.
	local $config{'machine_host_ssh_key'} = 1;
	call_vm_api(1, 'create',
		    { token => 'fixture-token', install_source => 'iso' });
	is($saved->{'host_ssh_key'}, 0,
	   'installer never enables managed host access');
	# Non-root creators must not inherit stored host logins from shared
	# templates. prepare(self, input, [options], [password_hash]) enables
	# template registration.
	local *KeySettingVMs::prepare =
		sub { return { name => 'fixture', image => 'a' x 32,
			       software => 'virtualmin-gpl',
			       auth_type => 'password',
			       webmin_register => 1 }; };
	my $registrations = 0;
	# require_webmin_registration() records permission checks
	# without native writes.
	local *main::require_webmin_registration = sub { $registrations++; };
	call_vm_api(1, 'create',
		    { token => 'fixture-token', password => 'fixture-secret' });
	is($saved->{'webmin_register'}, 0,
	   'non-root creation disables template registration');
	ok(!exists($saved->{'webmin_password'}),
	   'non-root creation retains no proxy password');
	is($registrations, 0,
	   'non-root creation does not need Servers Index grants');
	# Root may use the same template only after checking native
	# registration grants.
	local $remote_user = 'root';
	call_vm_api(1, 'create',
		    { token => 'fixture-token', password => 'fixture-secret' });
	is($saved->{'webmin_register'}, 1,
	   'root keeps the template registration setting');
	is($saved->{'webmin_password'}, 'fixture-secret',
	   'root retains the submitted login for registration');
	is($registrations, 1,
	   'root still needs native registration permissions');
	}
# The real hashing helper must ignore cloud credentials for an ISO install.
is(get_vm_password_hash(undef,
			{ install_source => 'iso', auth_type => 'password' },
			'ignored'),
   undef,
   'installer ignores submitted cloud credentials without saving a hash');

# Existing management jobs retain fingerprints made with the previous encoder.
{
	package FingerprintJobs;

	# get(self, id, owner) returns the job captured
	# before the encoder change.
	sub get
	{
	return $_[0]->{'saved'};
	}

	# lock(self, resource, callback) needs no disk lock
	# for this saved fixture.
	sub lock
	{
	return $_[2]->();
	}
	}
{
	my $fields = { id => '11111111-2222-3333-4444-555555555555',
		       description => "Caf\x{e9} \x{65e5}\x{672c} \x{1f642}",
		       memory_mib => 950 };
	my $fingerprint =
		sha256_hex(WebminCore::convert_to_json($fields, 0, 1, 1));
	my $jobs =
		bless({ saved =>
				{ id => 'saved-job', state => 'complete',
				  events => [ ],
				  request => { fingerprint => $fingerprint } } },
		      'FingerprintJobs');
	no warnings qw(redefine once);
	local *main::is_readonly_mode = sub { 0 };
	local *main::get_vm_service = sub { return { jobs => $jobs,
						     images => bless({ },
								     'RetryImages') }; };
	my $result =
		call_vm_api(1, 'update', { %$fields,
					   token => 'fixture-token' });
	is($result->{'id'}, 'saved-job',
	   'UTF-8 retry matches the saved canonical fingerprint');
	ok(!eval { call_vm_api(1, 'update',
			       { %$fields, token => 'fixture-token',
				 memory_mib => 951 }); 1 },
	   'changed settings still reject reuse of the same token');
	like($@, qr/different settings/,
	     'changed fingerprint is reported explicitly');
	}
done_testing();
