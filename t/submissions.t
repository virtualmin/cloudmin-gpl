use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use Digest::SHA qw(sha256_hex);
use WebminCore qw(convert_to_json convert_from_json);
require "$Bin/../lib/Cloudmin/Images.pm";
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../cloudmin-submission-lib.pl";
our $module_var_directory = tempdir(CLEANUP => 1);
our $remote_user = 'fixture';
my (%locks, %busy);
# lock_file(path), unlock_file(path) and test_lock(path) use real advisory locks
# for competing retries; busy flags model workers independently.
my %locking = ( lock_file => sub {
	open(my $fh, '>>', $_[0].'.lock') or die $!;
	flock($fh, LOCK_EX) or die $!; $locks{$_[0]} = $fh; return 1;
	}, unlock_file => sub { close(delete $locks{$_[0]}); },
		test_lock => sub { $busy{$_[0]} || 0 } );
my $images = Cloudmin::Images->new(directory => "$module_var_directory/images",
				   %locking, log => sub { },
				   disk_free => sub { 10**12 });
my $jobs =
	Cloudmin::Jobs->new(directory => "$module_var_directory/jobs", %locking,
			    log => sub { });

# get_image_jobs() returns the isolated image store used by the handshake.
sub get_image_jobs
{
$images
}

# get_vm_jobs() returns the isolated durable job store.
sub get_vm_jobs
{
$jobs
}

# require_access(scope) permits preparation while licensing blocks new changes.
sub require_access
{
die "License required\n" if ($_[0] ne 'host'); 1
}

# is_readonly_mode() allows submissions in the fixture.
sub is_readonly_mode
{
0
}

# unique(values...) removes duplicate selections while retaining their order.
sub unique
{
my %seen; grep { !$seen{$_}++ } @_
}
# No job exists until validation succeeds, so repeated checks keep one attempt.
my $token = $images->form_token($remote_user);
my %input =
	( token => $token, kind => 'vm', operation => 'create', proposed =>
									'a' x 32 );
my $first = prepare_submission({ %input })->{'attempt'};
is($first, 'a' x 32, 'first submit accepts a browser attempt ID');
is(prepare_submission({ %input, proposed => 'b' x 32 })->{'attempt'}, $first,
   'a lost first reply or concurrent tab returns the first attempt');
is(prepare_submission({ %input, attempt => $first, proposed =>
							   'b' x 32 })->{'attempt'}, $first,
   'validation failure before job creation keeps its attempt');
# Accepted and successful jobs must remain idempotent on resubmission.
my $id =
	substr(sha256_hex('vm-create:'.Cloudmin::Attempts::key($token, $first)),
	       0, 32);
$jobs->submit($id, $remote_user, 'vm:fixture',
	      { uuid => 'fixture', name => 'fixture' });
for my $state (qw(queued running complete)) {
	$jobs->update($id, sub { $_[0]->{'state'} = $state });
	is(prepare_submission({ %input, attempt => $first, proposed =>
								   'b' x 32 })->{'attempt'}, $first,
	   "$state job cannot become another attempt");
	}
# Failures cannot advance while cleanup or an existing guest needs attention.
$jobs->update(
	$id,
	sub { $_[0]->{'state'} = 'failed'; $_[0]->{'cleanup_pending'} = 1 });
ok(!eval { prepare_submission({ %input, attempt => $first, proposed =>
								   'b' x 32 }); 1 },
   'partial creation blocks retry');
like($@, qr/needs recovery/, 'recovery message explains the next step');
$jobs->update($id,
	      sub { $_[0]->{'cleanup_pending'} =
		0; $_[0]->{'resources'}->{'software'} =
			1 });
my $blocked =
	prepare_submission({ %input, attempt => $first, proposed => 'b' x 32 });
is($blocked->{'retryable'}, 0,
   'software failure explicitly prevents another submission');
like($blocked->{'error'}, qr/was created/,
     'software failure explains that creation succeeded');
like($blocked->{'error'}, qr/Refresh the page to start a new creation/,
     'blocked creation explains how to get a fresh form');
ok(!exists($blocked->{'attempt'}),
   'software failure grants no creation attempt');
# A terminal record alone does not prove that its worker has stopped.
$jobs->update($id, sub { $_[0]->{'resources'} = { } });
$busy{"$module_var_directory/jobs/worker-$id"} = 1;
ok(!eval { prepare_submission({ %input, attempt => $first, proposed =>
								   'b' x 32 }); 1 },
   'finishing worker blocks retry');
%busy = ();
# Concurrent retry decisions converge even before a replacement job exists.
my @children;
for my $n (1 .. 2) {
	my $pid = fork(); die $! if (!defined $pid);
	if (!$pid) {
		# Each child requests a different successor
		# under the same file lock.
		my $next =
			prepare_submission({ %input, attempt => $first,
					     proposed =>
						     "$n" x 32 })->{'attempt'};
		open(my $out, '>', "$module_var_directory/result-$n") or die $!;
		print $out $next; close $out; exit 0;
		}
	push @children, $pid;
	}
waitpid($_, 0) for @children;
my @results =
	map { open(my $fh, '<', "$module_var_directory/result-$_") or
		die $!; local $/; <$fh> } ( 1, 2 );
is($results[0], $results[1], 'racing retries have one successor');
isnt($results[0], $first, 'confirmed clean failure obtains a fresh attempt');
is($jobs->get($id)->{'state'}, 'failed',
   'the old failed job remains unchanged');
# A delayed duplicate must not advance past the successor it already received.
my $next_id =
	substr(sha256_hex('vm-create:'.Cloudmin::Attempts::key($token,
							       $results[0])), 0,
	       32);
$jobs->submit($next_id, $remote_user, 'vm:fixture', { name => 'fixture' });
$jobs->update($next_id, sub { $_[0]->{'state'} = 'failed' });
is(prepare_submission({ %input, attempt => $first, proposed =>
							   'c' x 32 })->{'attempt'}, $results[0],
   'late duplicate retry cannot advance an already failed successor');
is(prepare_submission({ %input, attempt => $results[0], proposed =>
								'c' x 32 })->{'attempt'}, 'c' x 32,
   'a deliberate retry of the replacement can advance');
# Every durable management action uses an independent attempt chain.
for my $operation (
	qw(clone update delete delete_disk power_cycle snapshot_create snapshot_restore snapshot_delete)) {
	my %request = ( %input, operation => $operation );
	my $attempt = prepare_submission({ %request })->{'attempt'};
	my $prefix = $operation eq 'clone'
		? 'vm-clone:'
		: "vm-manage:$operation:";
	my $ident =
		substr(sha256_hex($prefix.Cloudmin::Attempts::key($token,
								  $attempt)), 0,
		       32);
	$jobs->submit($ident, $remote_user, "guest:$operation",
		      { operation => $operation });
	$jobs->update($ident, sub { $_[0]->{'state'} = 'failed' });
	is(prepare_submission({ %request, attempt => $attempt,
				proposed =>
					'd' x 32 })->{'attempt'}, 'd' x 32,
	   "$operation retries a clean failure");
	}
# Image batches retry failures individually and retain successful imports.
my %image_input =
	( token => $token, kind => 'image', selection => "rocky\ndebian",
	  proposed =>
		  'e' x 32 );
# Preparation allocates attempts even when the eventual upload will be refused.
{
	no warnings qw(redefine once);
	local *main::cloudmin_license_status = sub { { allowed => 0 } };
	my $result = prepare_submission({ %image_input });
	ok($result->{'native_submit'},
	   'blocked image upload uses the normal form');
	ok($result->{'image_attempts'},
	   'blocked upload still receives its attempt IDs');
	}
my $attempts = prepare_submission({ %image_input })->{'image_attempts'};
my $map = convert_from_json($attempts);
my %imports;
for my $selection (qw(rocky debian)) {
	$imports{$selection} = $images->create($remote_user, $token,
					       { source => 'url',
						 format => 'qcow2',
						 pool => 'fixture' },
					       $selection, $map->{$selection});
	$imports{$selection}->{'state'} = $selection eq 'rocky'
		? 'ready'
		: 'failed';
	$imports{$selection}->{'cleanup_pending'} = 0;
	$images->save($imports{$selection}->{'id'}, $imports{$selection});
	}
my $retry =
	convert_from_json(prepare_submission({ %image_input, image_attempts =>
								     $attempts,
					       proposed => 'f' x 32 })->{'image_attempts'});
is($retry->{'rocky'}, $map->{'rocky'}, 'successful batch image is retained');
is($retry->{'debian'}, 'f' x 32, 'only the failed image gets another attempt');
# Explicit cleanup releases a failed import without disturbing its batch peer.
my $partial =
	$images->create($remote_user, $token, { source => 'url',
						format => 'qcow2' },
			'debian', $retry->{'debian'});
$partial->{'state'} = 'failed'; $partial->{'cleanup_pending'} =
	1; $images->save($partial->{'id'}, $partial);
ok(!eval { prepare_submission({ %image_input, image_attempts =>
						      convert_to_json($retry),
				proposed => '0' x 32 }); 1 },
   'partial import blocks retry');
like($@, qr/needs cleanup/, 'image cleanup has actionable guidance');
$partial->{'state'} = 'deleted'; $partial->{'cleanup_pending'} =
	0; $images->save($partial->{'id'}, $partial);
my $cleaned =
	convert_from_json(prepare_submission({ %image_input, image_attempts =>
								     convert_to_json($retry),
					       proposed => '0' x 32 })->{'image_attempts'});
is($cleaned->{'debian'}, '0' x 32,
   'explicit image cleanup allows another attempt');
# Reject malformed per-image IDs before they can select a retry record.
for my $invalid ( '{"debian":null}', '{"debian":""}', '{"debian":"../bad"}' ) {
	ok(!eval { Cloudmin::Attempts::image_attempts({ image_attempts =>
								$invalid }); 1 },
	   'malformed image attempt rejected');
	}
# Security checks apply to the handshake as well as the actual submission.
for my $bad ( { token => 'bad' }, { proposed => '../bad' },
	      { attempt => '9' x 32 } ) {
	ok(!eval { prepare_submission({ %input, %$bad }); 1 },
	   'invalid token or attempt rejected');
	}
{
	local $remote_user = 'other';
	ok(!eval { prepare_submission({ %input }); 1 },
	   'foreign user cannot select an attempt');
	}
done_testing();
