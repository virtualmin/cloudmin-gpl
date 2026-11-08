use strict;
use warnings;
our ($module_root_directory, $module_var_directory, $module_name, $remote_user,
     %text);
require "$module_root_directory/lib/Cloudmin/Backups.pm";
require "$module_root_directory/lib/Cloudmin/BackupTransport.pm";
$Cloudmin::BackupSSH::directory = "$module_var_directory/backups/ssh";

# get_backup_service() shares VM reservations, isolated
# workers and audit history.

sub get_backup_service
{
return Cloudmin::Backups->new(%{get_vm_service()}, directory =>
							   "$module_var_directory/backups",
			      validate_target => \&Cloudmin::BackupTransport::validate,
			      target_label => \&Cloudmin::BackupTransport::label,
			      transfer => \&Cloudmin::BackupTransport::transfer);
}

# submit_backup_operation(action, input) journals a validated backup or restore.
# The API checks host permissions, read-only mode and CSRF before calling here.

sub submit_backup_operation
{
my ($action, $in) = @_;
my $service = get_backup_service();
my $jobs = get_vm_jobs();
# Inspection downloads need expiry even when nobody returns to the list page.
ensure_backup_cleanup() if ($action eq 'backup_inspect');
# Bind retries to the form attempt and settings, excluding API envelope fields.
my $id =
	substr(
		Digest::SHA::sha256_hex('backup:'.$action.':'.
					Cloudmin::Attempts::key(@$in{qw(token attempt)})), 0,
		32);
my %fields = %$in; delete(@fields{qw(token attempt action version)});
my $fingerprint = Digest::SHA::sha256_hex(convert_to_json(\%fields, 0, 1, 1));
my $job = $jobs->lock('create-host', sub {
	my $existing = $jobs->get($id, $remote_user);
	# Repeated submissions reuse the job only when their
	# settings are identical.
	if ($existing) {
		die "This form already submitted different settings; reload the page\n"
			if ($existing->{'request'}->{'fingerprint'}
			    ne $fingerprint);
		return $existing;
		}
	my $r;
	# Reserve the source only after checking for
	# conflicting guest operations.
	if ($action eq 'backup') {
		$jobs->assert_guest_available($in->{'id'});
		$r = $service->prepare($in, $id);
		}
	# Restore validates the cached inspection and
	# destination identity first.
	elsif ($action eq 'restore') { $r = $service->prepare_restore($in,
								      $id); }
	# Inspection downloads bytes without allocating a replacement guest.
	else {
		my ($target, $file, $checksum);
		# A listed archive reuses private settings and
		# its original checksum.
		if ($in->{'backup'}) {
			my $record = $service->record($in->{'backup'}) ||
				     die "Backup not found\n";
			die "This backup was deleted\n"
				if ($record->{'deleted'});
			($target, $file) = @$record{qw(target filename)};
			$checksum = $record->{'sha256'};
			}
		# External archives use the submitted destination
		# and acquire a checksum.
		else { ($target, $file) = ( $in->{'target'},
					    $in->{'filename'} ); }
		$target = Cloudmin::BackupTransport::validate($target, 1);
		Cloudmin::BackupTransport::preflight($target, 1);
		die "Enter a backup archive filename ending in .tar or .tar.gz\n"
			if (($file ||
			     '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,199}\.tar(?:\.gz)?\z/);
		$r =
			{ operation => 'backup_inspect', name => $file,
			  target =>
				  $target, filename => $file,
			  expected_sha256 => $checksum };
		}
	$r->{'fingerprint'} = $fingerprint;
	return $jobs->submit($id, $remote_user, $action eq 'backup'
		? 'guest:'.$r->{'uuid'}
		: $action eq 'restore'
			? 'vm:'.lc($r->{'name'})
			: 'backup-inspect:'.$id, $r);
	});
# Do not restart a terminal job when a browser resubmits its form.
$jobs->spawn($id, sub { run_vm_job($_[0]); })
	if ($job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
return get_public_vm_job($job);
}

# backup_schedules() reads private schedules; credentials never enter list rows.

sub backup_schedules
{
my $dir = get_backup_service()->directory().'/schedules';
# A host with no saved schedules has no schedule directory yet.
return [ ] if (!-d $dir);
opendir(my $dh, $dir) or die "Cannot list backup schedules\n";
my @ids = map { /^([a-f0-9]{32})\.json$/ ? $1 : () } readdir($dh);
closedir($dh);
return [ map { convert_from_json(read_file_contents("$dir/$_.json")) } sort @ids ];
}

# backup_schedule_time(input) validates and normalizes the selected recurrence.

sub backup_schedule_time
{
my ($in) = @_;
my $frequency = $in->{'frequency'} || '';
die "Select an hourly, daily, weekly, monthly or yearly schedule\n"
	if ($frequency !~ /\A(?:hourly|daily|weekly|monthly|yearly)\z/);
my %when =
	( frequency => $frequency, minute => 0, hour => 0, weekday => 0,
	  day => 1,
	  month => 1 );
my %limits =
	( minute => [ 0, 59 ], hour => [ 0, 23 ], weekday => [ 0, 6 ],
	  day => [ 1, 31 ],
	  month => [ 1, 12 ] );
# Hidden fields from other recurrence choices must not affect the saved time.
my @fields = ( 'minute', $frequency ne 'hourly' ? ('hour') : (),
	       $frequency eq 'weekly' ? ('weekday') : (),
	       $frequency =~ /\A(?:monthly|yearly)\z/ ? ('day') : (),
	       $frequency eq 'yearly' ? ('month') : () );
foreach my $field (@fields) {
	# Accept numeric choices only; cron expressions must not
	# pass through the form.
	my $value = $in->{$field};
	my ($min, $max) = @{$limits{$field}};
	die "Enter a schedule $field from $min to $max\n"
		if (!defined($value) || ref($value) || $value !~ /\A\d+\z/ ||
		    $value < $min || $value > $max);
	$when{$field} = 0 + $value;
	}
if ($frequency eq 'yearly') {
	# February 29 is valid in leap years; dates that
	# never occur are mistakes.
	my @days = ( 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );
	die "Select a day that exists in the chosen month\n"
		if ($when{'day'} > $days[$when{'month'} - 1]);
	}
return \%when;
}

# backup_schedule_cron(schedule) maps one recurrence to Webmin cron fields.

sub backup_schedule_cron
{
my ($s) = @_;
my $f = $s->{'frequency'};
# Keep weekdays unrestricted for calendar dates: cron otherwise matches either.
return { mins => $s->{'minute'}, hours => $f eq 'hourly' ? '*' : $s->{'hour'},
	 days => $f eq 'monthly' || $f eq 'yearly' ? $s->{'day'} : '*',
	 months => $f eq 'yearly' ? $s->{'month'} : '*',
	 weekdays => $f eq 'weekly' ? $s->{'weekday'} : '*' };
}

# save_backup_schedule(input) saves a schedule and Webmin's native cron entry.

sub save_backup_schedule
{
my ($in) = @_;
my $id = $in->{'sched'} || substr(Cloudmin::Images::generate_id(), 0, 32);
Cloudmin::Jobs::validate_id($id);
return get_vm_jobs()->lock('backup-schedules', sub {
	my ($old) = grep { $_->{'id'} eq $id } @{backup_schedules()};
	die "Backup schedule not found\n" if ($in->{'sched'} && !$old);
	foreign_require('webmincron');
	my ($cron) =
		grep { $_->{'module'} eq $module_name &&
			$_->{'func'} eq 'run_backup_schedule' &&
			$_->{'args'}->[0] eq $id }
		webmincron::list_webmin_crons();
	my $dir = get_backup_service()->directory().'/schedules';
	make_dir($dir, 0700, 1) or die "Cannot create schedule directory\n"
		if (!-d $dir);
	# Remove the cron trigger before deleting its saved settings.
	if ($in->{'delete'}) {
		webmincron::delete_webmin_cron($cron) if ($cron);
		unlink("$dir/$id.json") or
			die "Cannot delete backup schedule\n";
		return $id;
		}
	# Blank secrets retain saved values; unattended SSH still
	# needs approved trust.
	my $target =
		Cloudmin::BackupTransport::saved_target($in->{'target'}, $old
			? $old->{'target'}
			: undef);
	Cloudmin::BackupSSH::require_trusted($target)
		if ($target->{'mode'} eq 'ssh');
	# Persist UUIDs and a bounded age, not names or
	# caller-supplied cron syntax.
	my @guests = grep { length } split(/[\s\0,]+/, $in->{'guests'} || '');
	die "Select one or more virtual machines\n"
		if (!$in->{'all'} && !@guests);
	die "Invalid virtual machine selection\n"
		if (grep {
			!/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/ } @guests);
	die "Enter a retention period from 0 to 3650 days\n"
		if (($in->{'purge'} // 0) !~ /\A\d+\z/ ||
		    ($in->{'purge'} || 0) > 3650);
	my $when = backup_schedule_time($in);
	my $s =
		{ id => $id, description =>
				     substr($in->{'description'} || '', 0, 200),
		  owner => $remote_user,
		  target => $target, guests => \@guests,
		  all => $in->{'all'} ? 1 : 0, enabled => $in->{'enabled'}
			  ? 1
			  : 0,
		  shutdown => $in->{'shutdown'} ? 1 : 0, compression =>
								 $in->{'compression'} ? 1 : 0,
		  purge => 0 + ($in->{'purge'} || 0), %$when };
	# A leftover file from an interrupted save must not
	# block the next update.
	my ($fh, $temp) =
		File::Temp::tempfile('.schedule-XXXXXXXX', DIR => $dir,
				     UNLINK =>
					     1);
	print($fh convert_to_json($s)) && close($fh) or
		die "Cannot write backup schedule\n";
	rename($temp, "$dir/$id.json") or die "Cannot save backup schedule\n";
	# Enabled schedules use native Webmin cron with a fully loaded module.
	if ($s->{'enabled'}) {
		$cron ||= { module => $module_name, file =>
							    'server-manager-lib.pl',
			    func => 'run_backup_schedule',
			    args => [ $id ] };
		my $time = backup_schedule_cron($s);
		@$cron{keys %$time} = values %$time;
		webmincron::save_webmin_cron($cron);
		}
	# Disabled schedules retain their settings but must
	# have no active trigger.
	elsif ($cron) { webmincron::delete_webmin_cron($cron); }
	webmin_log('save', 'backup_schedule', $id,
		   { description => $s->{'description'} });
	return $id;
	});
}

# run_backup_schedule(id) backs up selected machines serially,
# then applies retention.

sub run_backup_schedule
{
my ($id) = @_;
require './server-manager-lib.pl' if (!defined(&get_vm_jobs));
Cloudmin::Jobs::validate_id($id);
die "Backup changes are disabled in read-only mode\n" if (is_readonly_mode());
# A nonblocking schedule lock prevents overlapping runs of this same schedule.
return get_vm_jobs()->lock('backup-schedule-'.$id, sub {
	my ($s) = grep { $_->{'id'} eq $id } @{backup_schedules()};
	die "Backup schedule not found or disabled\n"
		if (!$s || !$s->{'enabled'});
	# Scheduled work must not outlive the owner's permission
	# to manage this host.
	my %modules; read_acl(\%modules, undef, [ $s->{'owner'} ]);
	my %acl = get_module_acl($s->{'owner'}, $module_name);
	my %global = get_module_acl($s->{'owner'}, '');
	die "The schedule owner no longer has permission to back up this host\n"
		if ((!$modules{$s->{'owner'}, $module_name} &&
		     !$modules{$s->{'owner'}, '*'}) ||
		    !Cloudmin::Access->new(\%acl,
					   $global{'readonly'})->allows('manage'));
	my $service = get_backup_service();
	my $jobs = get_vm_jobs();
	# Existing schedules retain their backup and retention work after
	# expiry. Only this jobs instance skips admission; the owner's
	# ACLs were checked above.
	delete($jobs->{'admit'});
	my @guests = $s->{'all'}
		? map { $_->{'uuid'} } @{get_libvirt()->list_domains(1)}
		: @{$s->{'guests'}};
	my @errors;
	# Finish each guest before the next, while collecting
	# failures for the report.
	foreach my $uuid (@guests) {
		my $ok = eval {
			my $job_id =
				substr(Cloudmin::Images::generate_id(), 0, 32);
			# Selection and reservation share the same lock as
			# interactive submissions.
			$jobs->lock('create-host', sub {
				$jobs->assert_guest_available($uuid);
				my $r = $service->prepare({ %$s, id => $uuid,
							    schedule => $id },
							  $job_id);
				$jobs->submit($job_id, $s->{'owner'}, 'guest:'.
					      $uuid, $r);
				});
			$service->run($job_id);
			my $job = $jobs->get($job_id);
			die(($job->{'error'} || 'Backup failed')."\n")
				if ($job->{'state'} ne 'complete');
			1;
			};
		push(@errors, "$uuid: ".error_message($@)) if (!$ok);
		}
	# Purge only this schedule's successful backups,
	# retaining the newest per VM.
	if (!@errors && $s->{'purge'}) {
		my %newest;
		foreach my $row (@{$service->inventory()}) {
			# Inventory is newest first; skip the first live
			# archive for each guest.
			next
				if ($row->{'deleted'} ||
				    ($row->{'schedule'} || '') ne $id ||
				    !$newest{$row->{'uuid'}}++);
			next if ($row->{'created'} >=
				 time() - 86400 * $s->{'purge'});
			my $ok = eval { delete_cloudmin_backup($row->{'id'}); 1 };
			push(@errors, error_message($@)) if (!$ok);
			}
		}
	# Report every failed guest or deletion after
	# finishing the remaining work.
	die join("\n", @errors)."\n" if (@errors);
	return 1;
	}, 1);
}

# ensure_backup_cleanup() registers hourly expiry independently of UI activity.

sub ensure_backup_cleanup
{
get_vm_jobs()->lock('backup-maintenance', sub {
	foreign_require('webmincron');
	# Repeated inspections must not create duplicate hourly cleanup entries.
	return
		if (grep { $_->{'module'} eq $module_name &&
			  $_->{'func'} eq 'purge_backup_inspections' }
		    webmincron::list_webmin_crons());
	webmincron::save_webmin_cron({ module => $module_name, file =>
								       'server-manager-lib.pl', func => 'purge_backup_inspections',
				       args => [ ], mins => 17, hours => '*',
				       days => '*',
				       months => '*', weekdays => '*' });
	});
}

# purge_backup_inspections() removes expired downloads
# without touching archives.

sub purge_backup_inspections
{
get_backup_service()->purge_inspections();
}

# delete_cloudmin_backup(id) deletes only the archive named by a saved record.

sub delete_cloudmin_backup
{
my ($id) = @_;
my $service = get_backup_service();
return get_vm_jobs()->lock('backup-file-'.$id, sub {
	my $r = $service->record($id) || die "Backup not found\n";
	# Repeated deletion is harmless; mark success only after
	# removing the archive.
	return if ($r->{'deleted'});
	Cloudmin::BackupTransport::transfer('delete', $r->{'target'},
					    $r->{'filename'},
					    $service->directory().'/unused');
	$r->{'deleted'} = time(); $service->record($id, $r);
	webmin_log('delete', 'backup', $id, { name => $r->{'name'} });
	});
}

1;
