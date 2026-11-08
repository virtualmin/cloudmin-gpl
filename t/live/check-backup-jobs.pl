#!/usr/bin/perl
# check-backup-jobs.pl tests durable jobs, scheduling and rollback on a
# fixture VM.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use Test::More;

BEGIN
{
die "Run on a Linux test host as root\n" if ($^O ne 'linux' || $<);
$ENV{WEBMIN_CONFIG} = '/etc/webmin'; $ENV{WEBMIN_VAR} =
	'/var/webmin'; $ENV{REMOTE_USER} = 'root';
$0 = abs_path("$Bin/../../api.pl"); chdir("$Bin/../..") or die $!;
}
require './server-manager-lib.pl';
my $service = get_backup_service(); my $jobs = get_vm_jobs(); my $adapter =
	get_libvirt(1);
my $name =
	'cloudmin-backup-jobs-'.substr(substr(Cloudmin::Images::generate_id(),
					      0,
					      32), 0, 8);
my $dir =
	tempdir($name.'-XXXXXX', DIR => '/var/lib/libvirt/images',
		CLEANUP => 0);
my $dest =
	tempdir($name.'-XXXXXX',
		DIR => $ENV{'CLOUDMIN_BACKUP_DESTINATION_ROOT'} ||
		       '/var/tmp', CLEANUP => 0);
my ($pool, $guest, $schedule, $secret_schedule); my @ids;

# run_backup([overrides], [change]) submits and runs a real fixture backup.
# change(job_id) can inject journal state before the controller starts.
sub run_backup
{
my ($overrides, $change) = @_; my $id =
	substr(Cloudmin::Images::generate_id(), 0, 32); push(@ids, $id);
my $r =
	$service->prepare({ id => $guest->get_uuid_string(), target =>
								     { mode => 'local', path => $dest }, %{$overrides || { }} }, $id);
$jobs->submit($id, 'root', 'guest:'.$r->{uuid}, $r);
$change->($id) if $change;
$service->run($id); return $jobs->get($id);
}
# Use a stopped, disposable guest and private pool for disk and journal checks.
my $ok = eval {
	chmod(0755, $dir);
	$pool =
		$adapter->connect()->define_storage_pool(
			"<pool type='dir'><name>$name</name><target><path>$dir</path></target></pool>"); $pool->create();
	system('qemu-img', 'create', '-q', '-f', 'qcow2', "$dir/disk",
	       '32M') == 0 or die 'fixture disk'; $pool->refresh();
	my $caps = $adapter->get_host_capabilities();
	$guest =
		$adapter->connect()->define_domain(
			"<domain type='kvm'><name>$name</name><memory unit='MiB'>128</memory><vcpu>1</vcpu><os><type arch='$caps->{architecture}' machine='$caps->{machine}'>hvm</type></os><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='$dir/disk'/><target dev='vda' bus='virtio'/></disk></devices></domain>");
	my $first =
		run_backup(); is($first->{state}, 'complete',
				 'cold full backup completed');
	die($first->{error}) if $first->{state} ne 'complete';
	# Manual submissions start processes, but cannot copy
	# while disk work is held.
	my $queued_id =
		substr(Cloudmin::Images::generate_id(), 0, 32); push(@ids,
								     $queued_id);
	my $queued =
		$service->prepare({ id => $guest->get_uuid_string(), target =>
									     { mode => 'local', path => $dest } }, $queued_id);
	$jobs->submit($queued_id, 'root', 'guest:'.$queued->{uuid}, $queued);
	$jobs->lock('vm-work', sub {
		my $pid = $jobs->spawn($queued_id,
				       sub { $service->run($_[0]); });
		sleep(2);
		is($jobs->get($queued_id)->{state}, 'queued',
		   'backup waits for the shared disk-work queue');
		ok(!keys(%{$jobs->get($queued_id)->{resources}}),
		   'queued backup allocates no disks or overlays');
		$jobs->update($queued_id, sub { $_[0]->{cancel} = 1 });
		my $end = time() + 15; sleep(1) while time() < $end &&
			$jobs->get($queued_id)->{state} ne 'cancelled';
		is($jobs->get($queued_id)->{state}, 'cancelled',
		   'queued backup cancellation does not wait for disk work');
		waitpid($pid, 0);
		});
	# Inject cancellation and interruption before execution to
	# test rollback entry.
	my $cancel =
		run_backup({ },
			   sub { $jobs->update($_[0],
					       sub { $_[0]->{cancel} = 1 }); });
	is($cancel->{state}, 'cancelled',
	   'cancellation releases reservation'); ok(
		   !$cancel->{cleanup_pending},
		   'cancelled job has no pending cleanup');
	my $recovery =
		run_backup({ },
			   sub { $jobs->update($_[0],
					       sub { $_[0]->{state} =
					'running'; $_[0]->{resources}->{started} =
						1; }); });
	is($recovery->{state}, 'failed',
	   'interrupted backup rolls back'); ok(
		   !$recovery->{cleanup_pending},
		   'recovery restores source and releases reservation');
	# Break only this job's destination; failure must not
	# publish a backup record.
	my $unwritable =
		run_backup({ },
			   sub { my $id =
				$_[0]; $jobs->update($id,
						     sub { $_[0]->{request}->{target}->{path} = "$dest/missing" }); });
	is($unwritable->{state}, 'failed',
	   'failed transfer does not publish a backup'); ok(
		   !$service->record($unwritable->{id}),
		   'failed transfer has no completed record');
	ok(!$guest->is_active(), 'all failures preserve stopped source');
	if (!Cloudmin::BackupTransport::has_pro_providers()) {
		# Recheck queued requests so removing Pro cannot
		# start a disk copy first.
		my $unavailable = run_backup({ }, sub {
			$jobs->update($_[0],
				      sub { $_[0]->{request}->{target} =
					{ mode => 'gcs',
					  path => 'fixture' }; });
			});
		is($unavailable->{state}, 'failed',
		   'queued Pro backup fails on GPL');
		like($unavailable->{error}, qr/requires Cloudmin Pro/,
		     'queued job reports the edition requirement');
		ok(!$service->record($unavailable->{id}) &&
		   !$guest->is_active(),
		   'unavailable provider preserves source and publishes nothing');
		}
	# The same form attempt must reuse its verified
	# download and job identity.
	my $token = get_image_jobs()->form_token('root'); my $attempt =
		substr(Cloudmin::Images::generate_id(), 0, 32);
	my $inspect =
		submit_backup_operation('backup_inspect',
					{ backup => $first->{id},
					  token => $token,
					  attempt => $attempt });
	my $again =
		submit_backup_operation('backup_inspect',
					{ backup => $first->{id},
					  token => $token,
					  attempt => $attempt });
	is($again->{id}, $inspect->{id},
	   'identical inspection submission is idempotent'); push(@ids,
								  $inspect->{id});
	my $deadline = time() + 120; while (time() < $deadline &&
					    $jobs->get($inspect->{id})->{state} !~ /^(complete|failed)$/) {
		sleep(1)
		}
	is($jobs->get($inspect->{id})->{state}, 'complete',
	   'archive downloaded and verified');
	ok(!eval { $service->prepare_restore({ inspection => $inspect->{id},
					       pool => $pool->get_uuid_string(),
					       confirm => 1 }, 'a' x 32); 1 },
	   'restore refuses existing guest identity');
	# Check saved recurrence through native cron, including
	# Sunday as numeric zero.
	my $s =
		{ description => $name, target => { mode => 'local',
						    path => $dest },
		  guests => $guest->get_uuid_string(),
		  frequency => 'weekly',
		  hour =>
			  2, minute => 13, weekday => 0, enabled => 1,
		  purge => 1 };
	$schedule = save_backup_schedule($s);
	my ($saved) = grep { $_->{id} eq $schedule } @{backup_schedules()};
	is($saved->{weekday}, 0, 'Sunday remains Sunday');
	my ($cron) =
		grep { $_->{func} eq 'run_backup_schedule' &&
			$_->{args}->[0] eq
			$schedule } webmincron::list_webmin_crons();
	is($cron->{weekdays}, 0,
	   'Webmin cron retains Sunday'); is($cron->{file},
					     'server-manager-lib.pl',
					     'cron loads the module before execution');
	# Save each recurrence through the real cron service,
	# then return to weekly.
	foreach my $case (
		[ 'hourly', [ 13, '*', '*', '*', '*' ] ],
		[ 'daily', [ 13, 2, '*', '*', '*' ] ],
		[ 'weekly', [ 13, 2, '*', '*', 0 ] ],
		[ 'monthly', [ 13, 2, 31, '*', '*' ] ],
		[ 'yearly', [ 13, 2, 31, 12, '*' ] ] ) {
		save_backup_schedule({ %$s, sched => $schedule,
				       frequency =>
					       $case->[0], day => 31,
				       month => 12 });
		my ($actual) =
			grep { $_->{func} eq 'run_backup_schedule' &&
				$_->{args}->[0] eq
				$schedule } webmincron::list_webmin_crons();
		is_deeply([ @{
			$actual}{qw(mins hours days months weekdays)} ],
			  $case->[1],
			  "$case->[0] schedule saved in native cron");
		}
	save_backup_schedule({ %$s, sched => $schedule, enabled => 0 });
	ok(!grep({ $_->{func} eq 'run_backup_schedule' &&
		$_->{args}->[0] eq $schedule }
		 webmincron::list_webmin_crons()),
	   'disabled schedule has no cron entry');
	save_backup_schedule({ %$s, sched => $schedule });
	# A second invocation must skip a running schedule
	# without queuing backups.
	$jobs->lock('backup-schedule-'.$schedule, sub {
		local $SIG{ALRM} =
			sub { die "Schedule waited for its previous run\n"; };
		alarm(5);
		my $overlap =
			eval { run_backup_schedule($schedule); 1 }; my $error =
				$@;
		alarm(0);
		ok(!$overlap, 'overlapping schedule does not run');
		like($error, qr/Another operation is running/,
		     'schedule refuses contention immediately');
		});
	# Stored secrets are never rendered, and blank fields
	# keep their saved values.
	$secret_schedule =
		save_backup_schedule({ %$s, enabled => 0, target =>
								  { mode => 's3',
								    bucket => 'fixture', path => 'daily',
								    access =>
									    'fixture-id', secret => 'fixture-secret',
								    session_token =>
									    'fixture-token' } });
	require './cloudmin-backup-pages.pl';
	my $html = show_backup_form({ sched => $secret_schedule }, $token);
	unlike($html, qr/fixture-secret|fixture-token/,
	       'schedule editor does not echo stored credentials');
	save_backup_schedule({ %$s, sched => $secret_schedule, enabled => 0,
			       target =>
				       { mode => 's3', bucket => 'fixture',
					 path => 'daily',
					 access =>
						 'fixture-id', secret => '',
					 session_token => '' } });
	my ($secret) =
		grep { $_->{id} eq $secret_schedule } @{backup_schedules()};
	ok($secret->{target}->{secret} eq 'fixture-secret' &&
	   $secret->{target}->{session_token} eq 'fixture-token',
	   'blank saved credentials survive an actual schedule edit');
	# Optional browser checks reuse populated records while
	# this fixture exists.
	if (grep { $_ eq '--browser' } @ARGV) {
		system('python3', 't/live/check-backup-access.py',
		       '--browser') == 0 or
			die "Populated backup browser checks failed\n";
		}
	# Age one archive, then verify retention keeps the
	# newest and manual backups.
	run_backup_schedule($schedule);
	my ($old) =
		grep { ($_->{schedule} ||
			'') eq $schedule } @{$service->inventory()}; push(@ids,
									  $old->{id});
	my $record = $service->record($old->{id}); $record->{created} =
		time() - 3 * 86400; $service->record($old->{id}, $record);
	run_backup_schedule($schedule);
	ok($service->record($old->{id})->{deleted},
	   'retention deletes old successful schedule backup');
	ok(!$service->record($first->{id})->{deleted},
	   'retention preserves manual backups');
	my @latest =
		grep { ($_->{schedule} || '') eq $schedule &&
			!$_->{deleted} } @{$service->inventory()};
	is(scalar(@latest), 1,
	   'retention keeps the new successful backup'); push(@ids,
							      map { $_->{id} } @latest);
	# Recover a real imported volume left by an
	# interrupted restore controller.
	my $original =
		$guest->get_xml_description(3); $guest->undefine(); $guest =
			undef;
	my $restore_id =
		substr(Cloudmin::Images::generate_id(), 0, 32); push(@ids,
								     $restore_id);
	my $restore =
		$service->prepare_restore({ inspection => $inspect->{id},
					    pool =>
						    $pool->get_uuid_string(),
					    confirm => 1 }, $restore_id);
	$jobs->submit($restore_id, 'root', 'vm:'.$name, $restore);
	my $volume_name = "cloudmin-restore-$restore_id-disk0";
	my $volume =
		$adapter->upload_seed($pool->get_uuid_string(), $volume_name,
				      "$dir/disk", sub {
				$jobs->update($restore_id,
					      sub { $_[0]->{resources}->{volumes} =
						[ { pool => $pool->get_uuid_string(), name =>
											      $volume_name } ] });
				}, 'qcow2', 32 * 1024**2);
	$volume->{pool} = $pool->get_uuid_string();
	$jobs->update(
		$restore_id,
		sub { $_[0]->{state} = 'running'; $_[0]->{resources}->{volumes} =
			[ $volume ] });
	$service->run($restore_id);
	my $recovered = $jobs->get($restore_id);
	is($recovered->{state}, 'failed',
	   'interrupted restore rolls back instead of replaying imports');
	ok(!$recovered->{cleanup_pending} && !-e $volume->{path},
	   'interrupted restore removes its imported volume');
	ok(-f "$dir/disk" && -f "$dest/$first->{request}->{filename}",
	   'restore recovery preserves original disk and archive');
	$guest = $adapter->connect()->define_domain($original);
	# Expiry runs through the cron callback without
	# opening the inventory page.
	my $expired = $jobs->get($inspect->{id}); $expired->{updated} =
		time() - 90000;
	$jobs->write_data(
		sub { $_[0]->do('UPDATE jobs SET updated=?,record=? WHERE id=?',
				undef, $expired->{updated},
				convert_to_json($expired),
				$expired->{id}) });
	ensure_backup_cleanup(); ensure_backup_cleanup();
	my @maintenance =
		grep { $_->{module} eq 'server-manager' &&
			$_->{func} eq 'purge_backup_inspections' }
		webmincron::list_webmin_crons();
	is(scalar(@maintenance), 1,
	   'inspection cleanup has one hourly cron entry');
	purge_backup_inspections();
	ok(!-d $service->work($inspect->{id}),
	   'hourly cleanup removes expired inspection downloads');
	1;
	};
my $error = $@;
# Remove only this run's own guest, volumes, records and schedule.
eval { save_backup_schedule({ sched => $schedule, delete => 1 }) } if $schedule;
eval { save_backup_schedule({ sched => $secret_schedule, delete => 1 }) }
	if $secret_schedule;
my $busy = grep { $_->{request}->{name} eq $name && ($_->{cleanup_pending} ||
						     $_->{state} !~ /^(complete|failed|cancelled)$/) }
	   @{$jobs->list_pending()};
# Delete fixtures only after all operations have released their reservations.
if (!$busy) {
	# Guest removal must precede deletion of its pool and disk files.
	if ($guest) {
		$guest->destroy() if $guest->is_active();
		$guest->undefine();
		}
	# Remove only the pool created for this run.
	if ($pool) { $pool->destroy(); $pool->undefine(); }
	foreach my $id (@ids) {
		$service->clean_work($id);
		unlink($service->directory()."/$id.json");
		}
	remove_tree($dir, $dest);
	}
# Keep files available for recovery when rollback did not finish.
else { diag('Fixture retained for recovery: '.$dir); }
die $error if !$ok;
done_testing();
