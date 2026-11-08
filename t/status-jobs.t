use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes ();
require "$Bin/../lib/Cloudmin/Images.pm";

# Use the real atomic image store; only VM-store reads are fixtures here.
my $dir = tempdir(CLEANUP => 1);
my $images = Cloudmin::Images->new(directory => "$dir/images");
my $vms = bless { directory => "$dir/vms", rows => [ ], reads => 0 },
	  'FixtureVMJobs';
mkdir($vms->{'directory'}) || die $!;

# get_image_jobs() supplies the isolated JSON store to the collector function.
sub get_image_jobs
{
return $images;
}

# get_vm_jobs() supplies the isolated VM store to the collector function.
sub get_vm_jobs
{
return $vms;
}

{
	package FixtureVMJobs;

	# list(self, owner, active) counts reads and can
	# simulate a store outage.
	sub list
	{
	my ($self) = @_;
	$self->{'reads'}++;
	die "Fixture store unavailable\n" if ($self->{'fail'});
	return $self->{'rows'};
	}

	# list_pending(self) includes recovery records in the collector fixture.
	sub list_pending
	{
	return $_[0]->list();
	}
	}

# Load the actual collector function without binding a socket or forking.
open(my $fh, '<', "$Bin/../status-server.pl") || die $!;
my $source = do { local $/; <$fh> };
close($fh);
my ($function) = $source =~ /(sub refresh_jobs\n\{.*?\n\})\n\nmy \$server/s;
die 'Collector function not found' if (!$function);
eval 'my ($jobs_signature, $jobs_checked, $image_count, $job_error,
	%job_counts); $jobs_signature = "initial"; '.$function.'
# counts(now) exposes only the public totals calculated by the collector.
sub counts {
	refresh_jobs($_[0]);
	return [$image_count, { %job_counts }, $job_error];
}
1;' or die $@;

is_deeply(counts(100), [ 0, { }, 0 ], 'fresh host has no active jobs');
is($vms->{'reads'}, 1, 'first snapshot reads both stores');
counts(101);
is($vms->{'reads'}, 1, 'unchanged stores are not scanned every tick');

# A new JSON record must update a live count without any SQLite write.
my $id = 'a' x 32;
my $job = { id => $id, state => 'queued', owner => 'first',
	    created => time() };
$images->save($id, $job);
is_deeply(counts(105), [ 1, { }, 0 ],
	  'image-only submission updates the count');
$job->{'state'} = 'ready';
$images->save($id, $job);
is_deeply(counts(110), [ 0, { }, 0 ],
	  'quick JSON replacements are counted even with coarse timestamps');

# VM totals stay separate by owner while the image total remains shared.
open($fh, '>', "$vms->{directory}/jobs.sqlite") || die $!;
print($fh 'fixture'); close($fh);
$vms->{'rows'} = [ { owner => 'first' }, { owner => 'second' },
		   { owner => 'second' } ];
is_deeply(counts(115), [ 0, { first => 1, second => 2 }, 0 ],
	  'VM database changes preserve per-user totals');

# A worker can die without saving. Quiet stores must eventually be recounted.
$job->{'state'} = 'queued';
$job->{'pid'} = $$;
$images->save($id, $job);
is(counts(120)->[0], 1, 'a live image worker is included');
{
	no warnings qw(redefine once);
	local *Cloudmin::Images::list = sub { return [ ]; };
	is(counts(125)->[0], 0,
	   'quiet stores refresh after the worker disappears or the job expires');
	}

# An unchanged signature cannot preserve a transient read failure forever.
$vms->{'fail'} = 1;
is(counts(130)->[2], 1, 'unreadable job store makes the count unavailable');
delete($vms->{'fail'});
is(counts(135)->[2], 0, 'a quiet store recovers on the periodic retry');
done_testing();
