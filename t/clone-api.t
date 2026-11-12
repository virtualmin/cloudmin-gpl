use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
our $module_root_directory = abs_path("$Bin/..");
our $module_var_directory = tempdir(CLEANUP => 1);
our ($remote_user, %access);
$remote_user = 'fixture';
require "$module_root_directory/cloudmin-lib.pl";
{
	package CloneAPIJobs;

	# lock(self, name, callback) isolates controller
	# validation from host locks.
	sub lock
	{
	$_[2]->()
	}

	# assert_guest_available(self, uuid) supplies an idle fixture source.
	sub assert_guest_available
	{
	}

	# get(self, id, [owner]) returns a previously submitted fixture job.
	sub get
	{
	$_[0]->{$_[1]}
	}

	# submit(self, id, owner, resource, request) captures
	# the durable request.
	sub submit
	{
	$_[0]->{$_[1]} =
		{ id => $_[1], state => 'queued', request => $_[4],
		  resources => { } }
	}

	# spawn(self, id, callback) records scheduling without
	# starting libvirt work.
	sub spawn
	{
	$_[0]->{'spawned'}++
	}

	# delete_credential(self, id, owner) records expiry
	# of the form's secret.
	sub delete_credential
	{
	$_[0]->{'erased'}++
	}
	package CloneAPIImages;

	# check_token(self, owner, token) models the signed form token contract.
	sub check_token
	{
	die "Bad token\n" if (($_[2] || '') ne 'token')
	}
	package CloneAPIService;

	# prepare(self, input, id, [hash]) captures inputs
	# after permission checks.
	sub prepare
	{
	$_[0]->{'prepared'}++; return { %{$_[1]}, operation =>
							  'clone',
					source_uuid => $_[1]->{'id'},
					uuid => 'new' }
	}

	# run(self, id) records dispatch of the immutable stored operation.
	sub run
	{
	$_[0]->{'ran'} = $_[1]
	}
	package CloneAPIPresets;

	# resolve(self, input, mode) proves clone-specific
	# resolution is selected.
	sub resolve
	{
	die "Wrong resolver mode\n"
		unless $_[2] eq 'clone'; return { %{$_[1]} }
	}
	}
my $jobs = bless({ }, 'CloneAPIJobs');
my $service = bless({ }, 'CloneAPIService');
my $readonly = 0;
# Stub host services while keeping the real controller's validation and retries.
{
	no warnings qw(redefine once);
	local *main::get_vm_service =
		sub { { jobs => $jobs, images => bless({ },
						       'CloneAPIImages') } };
	local *main::get_vm_jobs = sub { $jobs };
	local *main::get_clone_service = sub { $service };
	local *main::get_presets = sub { bless({ }, 'CloneAPIPresets') };
	local *main::is_readonly_mode = sub { $readonly };
	my $input =
		{ id => 'source', name => 'copy', token => 'token', auth_type =>
									    'keys', ssh_keys => 'fixture' };
	$readonly = 1;
	# Permission failures must precede source inspection and job allocation.
	ok(!eval { call_vm_api(1, 'clone', { %$input }); 1 },
	   'read-only administrators cannot clone');
	like($@, qr/read-only/, 'read-only rejection precedes preparation');
	$readonly = 0;
	%access = ( admin => 0, power => 1, vms => 'source' );
	for my $action (qw(clone clone_options)) {
		ok(!eval { call_vm_api(1, $action, { %$input }); 1 },
		   'delegated source access does not grant cloning');
		like($@, qr/Access denied/, 'host permission required');
		}
	%access = ( admin => 1 );
	ok(!eval { call_vm_api(1, 'clone', { %$input, token => 'bad' }); 1 },
	   'invalid form token rejected');
	ok(!$service->{'prepared'},
	   'rejected calls never reach source preparation');
	my $first = call_vm_api(1, 'clone', { %$input });
	# Repeated input reuses a job; changing settings requires a new attempt.
	my $again = call_vm_api(1, 'clone', { %$input });
	is($again->{'id'}, $first->{'id'},
	   'repeated submission returns the original clone');
	is($service->{'prepared'}, 1, 'retry cannot allocate another clone');
	ok(!eval { call_vm_api(1, 'clone', { %$input,
					     name => 'different' }); 1 },
	   'changed input cannot reuse a submitted form');
	like($@, qr/different clone settings/, 'retry conflict is explained');
	ok(!exists($first->{'request'}),
	   'public status omits source XML and credentials');
	# Public results omit credentials and dispatch still
	# uses the stored request.
	ok($jobs->{'erased'}, 'submission expires any retained password hash');
	run_vm_job($first->{'id'});
	is($service->{'ran'}, $first->{'id'},
	   'worker dispatch uses the recorded clone operation');
	}
done_testing();
