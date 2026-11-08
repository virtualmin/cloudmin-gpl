use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
our $module_root_directory = "$Bin/..";
our $module_var_directory = tempdir(CLEANUP => 1);
our $remote_user = 'fixture';
require "$module_root_directory/cloudmin-lib.pl";
{
	package SnapshotAPIJobs;

	# Model job storage for the controller's token and retry checks.
	# lock(self, name, callback) bypasses locking in this controller test.

	sub lock
	{
	$_[2]->()
	}

	# assert_guest_available(self, uuid) models an idle guest.

	sub assert_guest_available
	{
	}

	# get(self, id, [owner]) finds a fixture job; ownership
	# is not modeled here.

	sub get
	{
	$_[0]->{$_[1]}
	}

	# submit(self, id, owner, resource, request) records the queued request.

	sub submit
	{
	$_[0]->{$_[1]} =
		{ id => $_[1], owner => $_[2], state => 'queued',
		  request => $_[4],
		  resources => { } }
	}

	# spawn(self, id, callback) counts launches without starting a worker.

	sub spawn
	{
	$_[0]->{'spawned'}++
	}
	package SnapshotAPIImages;

	# check_token(self, owner, token) accepts only the fixture form token.

	sub check_token
	{
	die "Bad token\n" if (($_[2] || '') ne 'token')
	}
	package SnapshotAPIManager;

	# The controller must call this service only after ACL and token
	# validation. prepare(self, action, input, id) records
	# controller validation calls.

	sub prepare
	{
	$_[0]->{'prepared'}++; return { operation => $_[1], uuid =>
								    $_[2]->{'id'}, label => $_[2]->{'label'} }
	}

	# inventory(self, [uuid]) returns an empty history for
	# the requested guest.

	sub inventory
	{
	{ snapshots => [ ], requested => $_[1] }
	}

	# run(self, id) records dispatch to the snapshot service.

	sub run
	{
	$_[0]->{'ran'} = $_[1]
	}
	}
my $jobs = bless({ }, 'SnapshotAPIJobs');
my $manager = bless({ }, 'SnapshotAPIManager');
my $readonly = 0;
{
	no warnings qw(redefine once);
	local *main::get_vm_service =
		sub { { jobs => $jobs, images => bless({ },
						       'SnapshotAPIImages') } };
	local *main::get_vm_jobs = sub { $jobs };
	local *main::get_snapshot_manager = sub { $manager };
	local *main::is_readonly_mode = sub { $readonly };
	$readonly = 1;
	is(call_vm_api(1, 'snapshots', { id => 'guest' })->{'requested'},
	   'guest',
	   'read-only users can inspect snapshot history');
	ok(!eval { call_vm_api(1, 'snapshot_create', { token => 'token' }); 1 },
	   'read-only users cannot submit snapshots');
	like($@, qr/read-only/, 'write ACL is enforced');
	$readonly = 0;
	ok(!eval { call_vm_api(1, 'snapshot_create', { }); 1 },
	   'snapshot mutation requires a signed token');
	ok(!$manager->{'prepared'},
	   'rejected requests never reach libvirt preparation');
	my $input =
		{ id => 'guest', token => 'token', label => 'Before update',
		  revision => 'revision' };
	my $first = call_vm_api(1, 'snapshot_create', { %$input });
	my $again = call_vm_api(1, 'snapshot_create', { %$input });
	is($again->{'id'}, $first->{'id'},
	   'identical submission returns the same job');
	is($manager->{'prepared'}, 1,
	   'retry does not prepare or allocate twice');
	ok(!eval { call_vm_api(1, 'snapshot_create',
			       { %$input, label => 'Other point' }); 1 },
	   'a reused form cannot silently change snapshot settings');
	like($@, qr/different settings/, 'retry mismatch is explained');
	run_vm_job($first->{'id'});
	is($manager->{'ran'}, $first->{'id'},
	   'stored snapshot jobs dispatch to the snapshot service');
	}
done_testing();
