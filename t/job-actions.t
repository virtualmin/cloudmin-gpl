use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;
our ($remote_user);
$remote_user = 'admin';
require "$Bin/../cloudmin-job-actions.pl";
# Load page dependencies before installing the access stubs they would replace.
require "$Bin/../cloudmin-pages.pl";
my $readonly = 0;
my $allowed = 1;
my $job =
	{ id => 'a' x 32, state => 'running', operation => 'create',
	  can_cancel => 1,
	  resources => { software => 1 } };
my @actions;
{
	no warnings qw(redefine once);
	# require_access(grant) models host access before
	# reading private job stores.
	*require_access = sub { die "Access denied\n" unless $allowed };
	# is_readonly_mode() supplies the current fixture ACL.
	*is_readonly_mode = sub { $readonly };
	}

# get_vm_jobs() supplies VM records without opening the host's job store.

sub get_vm_jobs
{
bless({ }, 'ActionStore')
}

# get_image_jobs() supplies import records and signed-token checks.

sub get_image_jobs
{
bless({ }, 'ActionStore')
}

# get_public_vm_job(job) returns the fixture's already public fields.

sub get_public_vm_job
{
+{ %{$_[0]} }
}

# call_vm_api(version, action, input) records authorized changes only.

sub call_vm_api
{
push(@actions, $_[1]); 1
}
{
	package ActionStore;

	# get(self, id) refuses unknown IDs without touching real job storage.

	sub get
	{
	die "Job not found\n" if $_[1] ne $job->{'id'}; $job
	}

	# check_token(self, owner, token) checks the acting
	# administrator's token.

	sub check_token
	{
	die "Bad token\n" unless ($_[2] || '') eq 'valid'
	}

	# remove(self, id) records image cancellation.

	sub remove
	{
	push(@actions, 'image-remove'); 1
	}
	}
# Reject invalid requests before a controller callback changes the fixture.
my $input =
	{ type => 'vm', action => 'cancel_cleanup', job => 'a' x 32, token =>
									     'valid', confirm => 1 };
is(get_job_action($input)->{'software'}, 1,
   'action validation identifies guest setup');
is_deeply(\@actions, [ ], 'reviewing an action performs no mutation');
for my $case (
	qw(get token confirm readonly delegated completed operation started)) {
	local $ENV{'REQUEST_METHOD'} = $case eq 'get' ? 'GET' : 'POST';
	$readonly = $case eq 'readonly'; $allowed =
		$case ne 'delegated';
	local $job->{'state'} = $case eq 'completed' ? 'complete' : 'running';
	local $job->{'operation'} = $case eq 'operation' ? 'backup' : 'create';
	local $job->{'can_cancel'} = $case ne 'started';
	my %request = %$input;
	# Test token failure separately from other request requirements.
	$request{'token'} = 'bad' if $case eq 'token';
	# A valid token still needs the button's explicit action marker.
	delete $request{'confirm'} if $case eq 'confirm';
	ok(!eval { change_job_action(\%request); 1 },
	   "$case cannot request destructive cleanup");
	is_deeply(\@actions, [ ],
		  "$case rejection leaves resources alone");
	}
# A direct signed POST can cancel work and later retry retained cleanup.
$readonly = 0; $allowed = 1;
local $ENV{'REQUEST_METHOD'} = 'POST';
ok(change_job_action($input), 'cleanup button dispatches to the signed API');
is_deeply(\@actions, [ 'cancel_cleanup' ], 'only the submitted action runs');
$job->{'state'} = 'failed'; $job->{'cleanup_pending'} = 1;
ok(change_job_action({ %$input, action => 'recover' }),
   'failed cleanup is retryable');

# Discard applies only to retained edits and still requires a signed POST.
$job->{'operation'} = 'update'; $job->{'can_cancel'} = 0;
ok(change_job_action({ %$input, action => 'discard' }),
   'started failed edits can discard remaining changes');
is($actions[-1], 'discard',
   'discard dispatches through the VM API safety checks');
for my $case (qw(token get readonly operation cleanup)) {
	local $ENV{'REQUEST_METHOD'} = $case eq 'get' ? 'GET' : 'POST';
	local $job->{'operation'} = $case eq 'operation' ? 'create' : 'update';
	local $job->{'cleanup_pending'} = $case ne 'cleanup';
	$readonly = $case eq 'readonly';
	my $before = scalar(@actions);
	ok(!eval { change_job_action({ %$input, action => 'discard',
				       token => $case eq 'token'
					       ? 'bad'
					       : 'valid' }); 1 },
	   "$case rejects discard");
	is(scalar(@actions), $before, "$case leaves the job unchanged");
	}
$readonly = 0;

# Render the same rows used by initial loads and live polling.
our %text;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) {
	chomp;
	# Read the real key=value labels used by the renderer.
	$text{$1} = $2 if /\A([^=]+)=(.*)\z/;
	}
close($lang);
my $row = { type => 'vm', id => 'a' x 32, name => 'Fixture', state => 'running',
	    created => 1, can_cancel => 1, operation => 'create',
	    software => 1 };
my $data = { can_control => 1, token => 'fixture-token' };
# Polling must not offer another action while cancellation is pending.
like(show_jobs_status({ %$data, jobs => [ $row ] }), qr/<form\b/,
     'active creation offers job controls');
for my $state (qw(queued running recovering)) {
	my $html =
		show_jobs_status({ %$data, jobs =>
						   [ { %$row, state => $state,
							  cancel => 1 } ] });
	like($html, qr/\Q$text{'jobs_cancelling'}\E/,
	     "$state cancellation shows its status");
	unlike($html, qr/<form\b/, "$state cancellation has no action buttons");
	}
unlike(show_jobs_status({ %$data, jobs => [ { %$row, type => 'image',
	operation => 'import', state => 'downloading', cancel => 1 } ] }),
       qr/<form\b/,
       'cancelling image imports also hide actions');
like(show_jobs_status({ %$data, jobs => [ { %$row, state => 'failed',
	cancel => 1, cleanup_pending => 1 } ] }),
     qr/name="action"[^>]*value="recover"/,
     'failed cancellation still offers recovery');
# Once cancellation fails, retain recovery controls and escaped diagnostics.
my $recovery =
	{ %$row, state => 'failed', operation => 'update', can_cancel => 0,
	  cleanup_pending => 1, error => '<failed>', cleanup_warning =>
							     '<cleanup>',
	  audit_warning => '<audit>' };
my $html = show_jobs_status({ %$data, jobs => [ $recovery ] });
like($html, qr/name="action"[^>]*value="recover"/,
     'Active Jobs offers recovery directly');
like($html, qr/name="action"[^>]*value="discard"/,
     'Active Jobs retains failed-edit discard');
like($html, qr/&lt;failed&gt;.*&lt;cleanup&gt;.*&lt;audit&gt;/s,
     'all recovery diagnostics are escaped');
unlike($html, qr/machine_jobs\.cgi/,
       'recovery no longer links to a second job list');
unlike(show_jobs_status({ %$data, can_control => 0, jobs => [ $recovery ] }),
       qr/<form\b/,
       'read-only recovery has no controls');

# Old links redirect without attempting recovery or requiring a token.
{
	no warnings qw(redefine once);
	local $INC{'./server-manager-lib.pl'} = 1;
	local *main::can_access = sub { 1 };
	local *main::ReadParse = sub { };
	local *main::error_setup = sub { };
	local *main::recover_vm_jobs =
		sub { die "Navigation must not resume work\n" };
	my $redirect;
	local *main::redirect = sub { $redirect = $_[0] };
	for my $method (qw(GET POST)) {
		local $ENV{'REQUEST_METHOD'} = $method;
		local %main::in = ( navigation => 1 );
		my $before = scalar(@actions);
		do "$Bin/../machine_jobs.cgi";
		is($@, '', "$method legacy navigation succeeds");
		is($redirect, 'jobs.cgi', "$method opens Active Jobs");
		is(scalar(@actions), $before,
		   "$method navigation leaves work alone");
		}
	}
done_testing();
