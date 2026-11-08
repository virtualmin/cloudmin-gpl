use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use POSIX ();
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/VMs.pm";
# These journal tests need SQLite, but never require a real libvirt daemon.
plan skip_all => 'SQLite modules required'
	if (!eval { Cloudmin::Jobs::dependencies(); 1 });

# fixture() supplies a real journal and isolated deletion callbacks.

sub fixture
{
my $dir = tempdir(CLEANUP => 1);
my %locks;
my $jobs = Cloudmin::Jobs->new(directory => "$dir/jobs",
			       lock_file =>
				       sub { die 'Nested lock' if $locks{$_[0]}; $locks{$_[0]} = 1 },
			       unlock_file => sub { delete $locks{$_[0]} },
			       test_lock =>
				       sub { $locks{$_[0]} }, log => sub { });
my $adapter = bless({ }, 'CleanupAdapter');
# Model setup after guest creation has committed, with only
# journalled resources.
my $service = Cloudmin::VMs->new(jobs => $jobs, adapter => sub { $adapter },
				 ssh_keys => bless({ }, 'CleanupKeys'));
my $id = 'b' x 32;
$jobs->submit($id, 'owner', 'guest:fixture',
	      { name => 'fixture', uuid => 'fixture', pool => 'pool' });
$jobs->update($id, sub {
	$_[0]->{'state'} = 'running'; $_[0]->{'cancel'} =
		1; $_[0]->{'cleanup_created'} = 1;
	$_[0]->{'events'} = [ { step => 'software_boot', state => 'running' } ];
	$_[0]->{'resources'} = { software => 1, domain => 1, ssh_key => 1,
				 disk => { name => 'owned-system',
					   key => 'owned-key' }, seed =>
									 { name => 'owned-seed' } };
	});
return ( $jobs, $service, $adapter, $id );
}
{
	package CleanupAdapter;

	# check_creation_cleanup(self, job) emulates inventory ownership checks.

	sub check_creation_cleanup
	{
	die "Changed storage\n"
		if $_[0]->{'changed'}; 1
	}

	# remove_created_guest(self, uuid, id) records domain
	# removal before storage.

	sub remove_created_guest
	{
	die "Undefine failed\n"
		if $_[0]->{'fail'}; $_[0]->{'removed'} = $_[2];
	}

	# remove_created_volume(self, pool, name, key) records
	# only journalled volumes.

	sub remove_created_volume
	{
	push(@{$_[0]->{'volumes'}}, $_[2]);
	}
	package CleanupKeys;

	# remove(self, uuid, id) records key removal without
	# using real credentials.

	sub remove
	{
	$_[0]->{'removed'} = $_[2];
	}
	}

# Successful cleanup removes owned state; failed checks retain it for recovery.
for my $case (qw(success changed fail)) {
	my ($jobs, $service, $adapter, $id) = fixture();
	$adapter->{$case} = 1;
	Cloudmin::Software::run($service, $id);
	my $job = $jobs->get($id);
	if ($case eq 'success') {
		# Every owned resource is removed before the
		# reservation is released.
		is($job->{'state'}, 'cancelled',
		   'explicit cleanup cancels committed setup');
		is($adapter->{'removed'}, $id,
		   'only the creation-owned domain is removed');
		is_deeply($adapter->{'volumes'}, [ 'owned-seed',
						   'owned-system' ],
			  'only journalled disks are removed');
		is($service->{'ssh_keys'}->{'removed'}, $id,
		   'managed key ownership reaches cleanup');
		ok(!$job->{'cleanup_pending'},
		   'completed cleanup releases its reservation');
		ok(!$job->{'resources'}->{'domain'},
		   'completed cleanup no longer reports a created guest');
		}
	else {
		# Preserve disks after a failed ownership or
		# undefine check, then retry.
		is($job->{'state'}, 'failed',
		   "$case cleanup failure is recorded");
		ok($job->{'cleanup_pending'},
		   "$case retains recovery and reservation");
		ok(!$adapter->{'volumes'},
		   "$case cannot delete disks after a failed ownership or domain check");
		delete $adapter->{$case};
		$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
		Cloudmin::Software::run($service, $id);
		is($jobs->get($id)->{'state'}, 'cancelled',
		   "$case cleanup can be retried");
		}
	}

# A dead but unreaped worker must not block recovery or the disk queue.
SKIP: {
	skip 'Linux process-state check', 5 if $^O ne 'linux';
	my $dir = tempdir(CLEANUP => 1);
	my $pid = fork();
	# Stop immediately if no child exists; only the child
	# exits without reaping.
	die $! if !defined $pid;
	POSIX::_exit(0) if !$pid;
	for (1 .. 100) {
		last if Cloudmin::Jobs::zombie($pid);
		select(undef, undef, undef, 0.01);
		}
	ok(Cloudmin::Jobs::zombie($pid),
	   'fixture worker exited without being reaped');
	my $file = "$dir/worker-".('a' x 32);
	open(my $fh, '>', "$file.lock") or die $!;
	print $fh "$pid\n"; close $fh;
	my $store =
		Cloudmin::Jobs->new(directory => $dir,
				    test_lock => sub { $pid });
	ok(!$store->busy('a' x 32),
	   'zombie does not count as an active worker');
	$store->clear_dead_lock($file);
	ok(!-e "$file.lock", 'zombie-owned lock is released');
	waitpid($pid, 0);
	# The same cleanup must leave a currently running owner's lock intact.
	open($fh, '>', "$file.lock") or die $!;
	print $fh "$$\n"; close $fh;
	$store->{'test_lock'} = sub { $$ };
	$store->clear_dead_lock($file);
	ok(-e "$file.lock", 'live worker lock is retained');
	ok($store->busy('a' x 32), 'live worker still blocks duplicate work');
	}
done_testing();
