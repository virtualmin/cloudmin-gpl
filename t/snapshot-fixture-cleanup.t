use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/live/snapshot-jobs.pl";
plan skip_all => 'DBI and DBD::SQLite are required'
	if (!eval { Cloudmin::Jobs::dependencies(); 1 });

{
	package FixtureAdapter;
	# find_domain(self, uuid) models absence, presence or a failed lookup.
	sub find_domain { die "Libvirt unavailable\n" if ($_[0]->{'error'}); return $_[0]->{'present'}; }
}

my $store = tempdir(CLEANUP => 1);
my $directory = tempdir('cloudmin-snapshot-ui-XXXXXX', DIR => '/tmp', CLEANUP => 1);
my $uuid = '11111111-2222-4333-8444-555555555555';
my $name = 'cloudmin-snapshot-ui-1234abcd';
my $busy = 0;
my $jobs = Cloudmin::Jobs->new(directory => $store,
	lock_file => sub { 1 }, unlock_file => sub { },
	test_lock => sub { $busy && $_[0] =~ /\/worker-/ }, log => sub { });
my $adapter = bless({}, 'FixtureAdapter');

# Keep more than one history page so cleanup cannot rely on the newest 50 jobs.
for my $n (1..55) {
	my $id = sprintf('%032x', $n);
	$jobs->submit($id, 'fixture-owner', 'vm:'.$uuid, { uuid => $uuid, name => $name,
		operation => 'snapshot_create', disks => [{ volume => { path => "$directory/disk.qcow2" } },
			{ readonly => 1 }] });
	$jobs->update($id, sub { $_[0]->{'state'} = 'complete'; });
}
my $last = sprintf('%032x', 55);
$jobs->update($last, sub { $_[0]->{'state'} = 'failed'; $_[0]->{'cleanup_pending'} = 1; });
my $other = 'f'x32;
$jobs->submit($other, 'other-owner', 'vm:another', { uuid => 'other-uuid', name => 'Unrelated guest' });

# Retain every job if resources remain, inventory fails or a worker is active.
ok(!eval { cleanup_snapshot_jobs($jobs, $adapter, $uuid, $name, $directory); 1 }, 'existing fixture storage prevents cleanup');
like($@, qr/storage still exists/, 'storage refusal explains what remains');
rmdir($directory) || die $!;
for my $condition ('present', 'error') {
	$adapter->{$condition} = 1;
	ok(!eval { cleanup_snapshot_jobs($jobs, $adapter, $uuid, $name, $directory); 1 }, "guest $condition prevents cleanup");
	delete($adapter->{$condition});
}
$busy = 1;
ok(!eval { cleanup_snapshot_jobs($jobs, $adapter, $uuid, $name, $directory); 1 }, 'live worker prevents cleanup');
$busy = 0;
$jobs->update($last, sub { $_[0]->{'state'} = 'recovering'; });
ok(!eval { cleanup_snapshot_jobs($jobs, $adapter, $uuid, $name, $directory); 1 }, 'queued recovery prevents cleanup');
ok($jobs->get(sprintf('%032x', 1)), 'failed cleanup rolls back earlier record deletions');
$jobs->update($last, sub { $_[0]->{'state'} = 'failed'; });

# Never accept a different guest name or disks outside the removed directory.
ok(!eval { cleanup_snapshot_jobs($jobs, $adapter, $uuid, 'ordinary-guest', $directory); 1 }, 'ordinary guest name is refused');
ok(!eval { cleanup_snapshot_jobs($jobs, $adapter, $uuid, 'cloudmin-snapshot-ui-aaaaaaaa', $directory); 1 }, 'different fixture name is refused');
$jobs->update($last, sub { $_[0]->{'request'}->{'disks'}->[0]->{'volume'}->{'path'} = "$store/disk.qcow2"; });
ok(!eval { cleanup_snapshot_jobs($jobs, $adapter, $uuid, $name, $directory); 1 }, 'foreign disk keeps recovery records');
$jobs->update($last, sub { $_[0]->{'request'}->{'disks'}->[0]->{'volume'}->{'path'} = "$directory/disk.qcow2"; });

is(cleanup_snapshot_jobs($jobs, $adapter, $uuid, $name, $directory), 55, 'all completed fixture records, including retained failures, are removed');
is(scalar(@{$jobs->list_recovery()}), 0, 'removed fixture no longer appears in recovery');
is($jobs->get($other)->{'request'}->{'name'}, 'Unrelated guest', 'unrelated job remains untouched');
is(cleanup_snapshot_jobs($jobs, $adapter, $uuid, $name, $directory), 0, 'cleanup can be repeated safely');
done_testing();
