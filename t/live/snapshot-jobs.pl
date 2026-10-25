#!/usr/bin/perl
# snapshot-jobs.pl(uuid, [cleanup, name, directory])
# Reports active fixture jobs or removes their records after resource cleanup.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP qw(decode_json);

# snapshot_jobs(database, uuid) includes terminal jobs outside recent history.
sub snapshot_jobs
{
my ($db, $uuid) = @_;
# A host with no job database has no fixture records to inspect.
return [] if (!$db);
return [grep { ($_->{'request'}->{'uuid'} || '') eq $uuid }
	map { decode_json($_->[0]) } @{$db->selectall_arrayref('SELECT record FROM jobs')}];
}

# cleanup_snapshot_jobs(jobs, adapter, uuid, name, directory) removes only a
# finished fixture's records, after its guest and storage directory are gone.
sub cleanup_snapshot_jobs
{
my ($jobs, $adapter, $uuid, $name, $directory) = @_;
# Refuse identifiers that could select unrelated guests or storage directories.
die "Invalid fixture name\n" if ($name !~ /\Acloudmin-snapshot-(?:agent|ui)-[a-f0-9]{8}\z/);
die "Invalid fixture directory\n" if ($directory !~ m{\A(?:/var/lib/libvirt/images|/private/tmp|/tmp)/cloudmin-snapshot-(?:agent|ui)-[a-zA-Z0-9_-]+\z});
return $jobs->lock('vm-work', sub { $jobs->lock('create-host', sub {
	# Never hide a recovery record while its guest or disks still need attention.
	die "Fixture virtual machine still exists\n" if ($adapter->find_domain($uuid));
	die "Fixture storage still exists\n" if (-e $directory || -l $directory);
	return $jobs->write_data(sub {
		# callback(db) validates and removes the batch in one transaction.
		my ($db) = @_;
		my $records = snapshot_jobs($db, $uuid);
		foreach my $job (@$records) {
			my $r = $job->{'request'};
			# A shared UUID alone does not prove this is a finished snapshot job.
			die "Job does not belong to this snapshot fixture\n" if ($r->{'name'} ne $name ||
				($r->{'operation'} || '') !~ /\Asnapshot_(?:create|restore|delete)\z/);
			die "Fixture job is still active\n" if ($job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/ ||
				$jobs->busy($job->{'id'}));
			# The supplied directory must contain every disk recorded by the job.
			die "Fixture job has no disk inventory\n" if (!@{$r->{'disks'} || []});
			foreach my $disk (@{$r->{'disks'}}) {
				# Shared read-only media belongs to the host, not the fixture.
				next if ($disk->{'readonly'});
				foreach my $path ($disk->{'volume'}->{'path'}, $disk->{'overlay'} || ()) {
					die "Fixture disk is outside its directory\n" if (!defined($path) ||
						index($path, "$directory/") != 0 || $path =~ m{(?:\A|/)\.\.(?:/|\z)});
				}
				}
			# Retire private inputs with the job; Webmin's audit history remains.
			$db->do('DELETE FROM credentials WHERE id = ?', undef, $job->{'id'});
			$db->do('DELETE FROM jobs WHERE id = ?', undef, $job->{'id'});
			}
		return scalar(@$records);
		});
	}) }, 1);
}

# main() initializes Webmin only when invoked on the disposable Linux host.
sub main
{
die "Linux test host as root only\n" unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$Bin/../..") || die $!;
$0 = abs_path("$Bin/../../api.pl");
require './server-manager-lib.pl';
my ($uuid, $action, $name, $directory) = @ARGV;
die "Invalid fixture UUID\n" if (!$uuid || $uuid !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/);
my $jobs = get_vm_jobs();
if (defined($action)) {
	# Record removal requires explicit cleanup arguments and resource checks.
	die "Invalid fixture cleanup arguments\n" if ($action ne 'cleanup' || !defined($name) || !defined($directory));
	print cleanup_snapshot_jobs($jobs, get_libvirt(1), $uuid, $name, $directory), "\n";
	return;
}
# The caller polls this count while workers finish; this command does not wait.
my $db = $jobs->connect(0);
my @active = grep {
	($_->{'state'} !~ /\A(?:complete|failed|cancelled)\z/ || $jobs->busy($_->{'id'}))
	} @{snapshot_jobs($db, $uuid)};
$db->disconnect() if ($db);
print scalar(@active), "\n";
}

main() if (!caller);
1;
