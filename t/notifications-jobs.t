use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use WebminCore;
use DBI;
use File::Temp qw(tempdir);
no warnings qw(redefine once);
our ($module_root_directory, $module_var_directory);
# Load the job scan with a private data directory.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
require "$module_root_directory/cloudmin-notifications-lib.pl";
# More than one scan limit verifies durable pagination and deduplication.
my $job_path = "$module_var_directory/jobs.sqlite";
my $db = DBI->connect("dbi:SQLite:dbname=$job_path", '', '',
	{ RaiseError => 1, PrintError => 0 });
$db->do('CREATE TABLE jobs (id TEXT, updated INTEGER, state TEXT, record TEXT)');
my $vm = '11111111-1111-4111-8111-111111111111';
# Insert 505 failed backup jobs for one guest.
for my $i (1 .. 505) {
	my $job = { resource => 'guest:'.$vm,
		request => { id => 'backup-id', uuid => $vm, operation => 'backup' } };
	$db->do('INSERT INTO jobs VALUES (?, ?, ?, ?)', undef,
		sprintf('%032d', $i), 1000 + $i, 'failed',
		Cloudmin::Notifications::encode($job));
	}
$db->disconnect();

# JobScan::connect(self, write) exposes an isolated durable job fixture.
sub JobScan::connect
{
return DBI->connect("dbi:SQLite:dbname=$job_path", '', '',
	{ RaiseError => 1, PrintError => 0 });
}
# Route these fixture jobs to one guest through an enabled all-scope rule.
my $jobs = bless { }, 'JobScan';
my $store = get_notifications();
my $target = $store->save_target({ name => 'Fixture', type => 'email',
	address => 'fixture@example.invalid' })->{id};
$store->save_rule({ name => 'Failed jobs', metric => 'job_failed', scope => 'all',
	targets => [ $target ] }, 1000);
# The second scan resumes the first; later overlap must not duplicate events.
my $rules = $store->configuration()->{rules};
notification_job_failures($store, $jobs, $rules);
my $first = $store->history($vm, 0, 500);
is(scalar(@{$first->{events}}), 500, 'bounded scan covers first failure batch');
notification_job_failures($store, $jobs, $rules);
my $second = $store->history($vm, $first->{cursor}, 500);
is(scalar(@{$second->{events}}), 5, 'next scan resumes remaining failures');
notification_job_failures($store, $jobs, $rules);
is(scalar(@{$store->history($vm, $first->{cursor}, 500)->{events}}), 5,
	'repeated scan does not duplicate failures');
is($second->{events}->[0]->{owner}, $vm, 'resource determines exact guest owner');

# Schedule-level failure is recorded without swallowing the original exception.
require "$module_root_directory/cloudmin-backups-lib.pl";
{
	# run_backup_schedule_work(id) fails before a controller job can exist.
	local *main::run_backup_schedule_work = sub { die "Fixture preparation failed\n" };
	eval { run_backup_schedule('a' x 32) };
	is($@, "Fixture preparation failed\n", 'original scheduled failure is preserved');
	}
my $latest = $store->history(undef, undef, 1)->{events}->[0];
is($latest->{owner}, 'host', 'preparation failures are host events');
like($latest->{subject}, qr/^schedule:/, 'schedule failure has durable source');
unlike($latest->{label}, qr/Fixture preparation failed/,
	'raw job error text is not exposed to notification recipients');
done_testing();
