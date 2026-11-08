use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
our ($module_root_directory, $module_var_directory, $remote_user, %access,
     %text);
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
$remote_user = 'second-admin';
require "$module_root_directory/cloudmin-lib.pl";
plan skip_all => 'DBI and DBD::SQLite are required'
	if (!eval { Cloudmin::Jobs::dependencies(); 1 });

# Deployment labels expose only display text from the saved request.
{
	local @text{qw(vm_summary_setup vm_summary_none)} =
		( 'Packages and setup scripts', 'No extra software' );
	my $request = { name => 'deployment', image_name => 'Rocky Linux 10',
			software => 'virtualmin-pro',
			virtualmin_bundle => 'LEMP',
			virtualmin_postgres => 1,
			virtualmin_key => 'private-key', before_script =>
								 'private-script' };
	my $job = { request => $request, state => 'queued', resources => { } };
	my $public = get_public_vm_job($job);
	is_deeply(
		[ @{$public}{qw(image_name software_name)} ],
		[ 'Rocky Linux 10',
		  'Virtualmin Pro with Nginx and PostgreSQL' ],
		'saved OS and stack are available without a live catalogue lookup');
	unlike(convert_to_json($public), qr/private-key|private-script/,
	       'display labels omit license and script content');
	is(get_public_vm_job({ %$job, request =>
					      { %$request,
						install_source => 'iso' } })->{'software_name'},
	   'No extra software',
	   'installer media does not claim to install Virtualmin');
	is(get_public_vm_job({ %$job, request =>
					      { %$request,
						software => 'none' } })->{'software_name'},
	   'Packages and setup scripts',
	   'custom setup matches the form summary');
	}

{
	package AccessImages;

	# check_token(self, owner, token) accepts only the acting user's token.
	sub check_token
	{
	die "Bad token\n" if ($_[2] ne $_[1].'-token');
	}
	package AccessManager;

	# discard_change(self, id) records access without changing hardware.
	sub discard_change
	{
	$_[0]->{'discarded'} = $_[1];
	}
	}

# Use the real store's owner checks; isolate host locks and worker execution.
my $jobs = Cloudmin::Jobs->new(directory => "$module_var_directory/jobs",
			       lock_file => sub { 1 }, unlock_file => sub { },
			       test_lock => sub { 0 },
			       log => sub { });
my $id = 'a' x 32;
$jobs->submit($id, 'first-admin', 'vm:job-access-test', {
	name => 'job-access-test', uuid =>
					   '11111111-2222-4333-8444-555555555555',
	password_hash => 'private-hash', virtualmin_key =>
						 'private-key' });
my $manager = bless({ }, 'AccessManager');
my $readonly = 0;
{
	no warnings qw(redefine once);
	# is_readonly_mode() exposes the current test's access setting.
	local *main::is_readonly_mode = sub { $readonly };
	# get_vm_service() shares the isolated store and
	# owner-aware token checker.
	local *main::get_vm_service = sub {
		return { jobs => $jobs, images => bless({ }, 'AccessImages') };
		};
	# get_vm_manager() records authorized discard requests
	# without host changes.
	local *main::get_vm_manager = sub { $manager };
	# spawn(self, id) accepts scheduling without starting a real worker.
	local *Cloudmin::Jobs::spawn = sub { return 1; };

	# Both writable and read-only host administrators can inspect all jobs.
	for my $mode ( 0, 1 ) {
		$readonly = $mode;
		my $status = call_vm_api(1, 'status', { job => $id });
		is($status->{'id'}, $id,
		   'another administrator can read job status');
		ok(!exists($status->{'request'}),
		   'private provisioning data is omitted');
		is_deeply([ map { $_->{'id'} } @{call_vm_api(1, 'list', { })} ],
			  [ $id ],
			  "history includes and deduplicates other owners' jobs");
		}

	# Read-only access cannot cancel, recover or discard even with a token.
	for my $action (qw(cancel cancel_cleanup recover discard)) {
		ok(!eval { call_vm_api(1, $action,
				       { job => $id,
					 token => "$remote_user-token" }); 1 },
		   "read-only administrator cannot $action");
		like($@, qr/read-only/, 'read-only rejection is explicit');
		}
	$readonly = 0;
	%access = ( admin => 0 );
	# Delegated users cannot inspect or control host jobs, including by ID.
	for my $action (qw(status list cancel cancel_cleanup recover discard)) {
		ok(!eval { call_vm_api(1, $action,
				       { job => $id,
					 token => "$remote_user-token" }); 1 },
		   "delegated user cannot $action jobs");
		like($@, qr/Access denied/,
		     'ACL rejection precedes job access');
		}
	%access = ( admin => 1 );
	# Cross-owner controls still validate the acting administrator's token.
	ok(!eval { call_vm_api(1, 'cancel',
			       { job => $id,
				 token => 'first-admin-token' }); 1 },
	   "another owner's token cannot authorize cancellation");
	like($@, qr/Bad token/, 'token failure is preserved');
	my $cancelled = call_vm_api(1, 'cancel',
				    { job => $id,
				      token => "$remote_user-token" });
	ok($cancelled->{'cancel'},
	   'administrator can request cross-owner cancellation');
	$jobs->update($id, sub {
		$_[0]->{'state'} = 'failed'; $_[0]->{'cleanup_pending'} = 1;
		});
	is(call_vm_api(1, 'recover',
		       { job => $id, token => "$remote_user-token" })
	   ->{'state'}, 'recovering',
	   "administrator can recover another owner's job");
	call_vm_api(1, 'discard', { job => $id,
				    token => "$remote_user-token" });
	is($manager->{'discarded'}, $id,
	   'administrator can request safe discard');
	is($jobs->get($id)->{'owner'}, 'first-admin',
	   'original job owner is retained');
	ok(!eval { $jobs->get($id, $remote_user); 1 },
	   'owner checks used for new submissions remain enforced');
	# Software cancellation stops the guest service
	# without creation rollback.
	$jobs->update($id, sub {
		$_[0]->{'state'} = 'running'; $_[0]->{'cleanup_pending'} = 0;
		$_[0]->{'resources'}->{'software'} =
			1; delete($_[0]->{'cancel'});
		});
	ok(get_public_vm_job($jobs->get($id))->{'can_cancel'},
	   'software setup exposes cancellation');
	ok(call_vm_api(1, 'cancel',
		       { job => $id,
			 token => "$remote_user-token" })->{'cancel'},
	   'administrator can cancel committed software setup');

	# Require the explicit cleanup marker before reserving
	# the committed guest.
	ok(!eval { call_vm_api(1, 'cancel_cleanup',
			       { job => $id,
				 token => "$remote_user-token" }); 1 },
	   'cleanup cannot bypass confirmation');
	like($@, qr/Confirm/, 'missing confirmation is explicit');
	$jobs->update($id,
		      sub { delete($_[0]->{'cancel'}); $_[0]->{'resource'} =
			'software:'.$id; });
	my $cleanup =
		call_vm_api(1, 'cancel_cleanup',
			    { job => $id, token => "$remote_user-token",
			      confirm => 1 });
	ok($cleanup->{'cleanup_created'} && $cleanup->{'cancel'},
	   'confirmed cleanup is durable');
	is($jobs->get($id)->{'resource'},
	   'guest:11111111-2222-4333-8444-555555555555',
	   'cleanup reserves the committed guest against later edits');
	ok(
		!eval { $jobs->assert_guest_available(
			'11111111-2222-4333-8444-555555555555'); 1 },
		'new hardware changes cannot race deletion');
	$jobs->update($id, sub { $_[0]->{'state'} = 'complete'; });
	ok(!eval { call_vm_api(1, 'cancel_cleanup',
			       { job => $id, token => "$remote_user-token",
				 confirm => 1 }); 1 },
	   'cached confirmation cannot delete a completed creation');
	}
done_testing();
