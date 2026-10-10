use strict;
use warnings;
our ($module_root_directory, $module_var_directory, $module_name, $remote_user, %text);
require "$module_root_directory/lib/Cloudmin/Backups.pm";
require "$module_root_directory/lib/Cloudmin/BackupTransport.pm";
$Cloudmin::BackupSSH::directory = "$module_var_directory/backups/ssh";

# get_backup_service() shares VM reservations, isolated workers and audit history.
sub get_backup_service
{
return Cloudmin::Backups->new(%{get_vm_service()}, directory => "$module_var_directory/backups",
	validate_target => \&Cloudmin::BackupTransport::validate,
	target_label => \&Cloudmin::BackupTransport::label,
	transfer => \&Cloudmin::BackupTransport::transfer);
}

# backup_schedules() reads private schedules; credentials never enter list rows.
sub backup_schedules
{
my $dir = get_backup_service()->directory().'/schedules';
# A host with no saved schedules has no schedule directory yet.
return [] if (!-d $dir);
opendir(my $dh, $dir) or die "Cannot list backup schedules\n";
my @ids = map { /^([a-f0-9]{32})\.json$/ ? $1 : () } readdir($dh);
closedir($dh);
return [map { convert_from_json(read_file_contents("$dir/$_.json")) } sort @ids];
}

# backup_schedule_time(input) validates and normalizes the selected recurrence.
sub backup_schedule_time
{
my ($in) = @_;
my $frequency = $in->{'frequency'} || '';
die "Select an hourly, daily, weekly, monthly or yearly schedule\n"
	if ($frequency !~ /\A(?:hourly|daily|weekly|monthly|yearly)\z/);
my %when = (frequency => $frequency, minute => 0, hour => 0, weekday => 0, day => 1, month => 1);
my %limits = (minute => [0,59], hour => [0,23], weekday => [0,6], day => [1,31], month => [1,12]);
# Hidden fields from other recurrence choices must not affect the saved time.
my @fields = ('minute', $frequency ne 'hourly' ? ('hour') : (),
	$frequency eq 'weekly' ? ('weekday') : (),
	$frequency =~ /\A(?:monthly|yearly)\z/ ? ('day') : (),
	$frequency eq 'yearly' ? ('month') : ());
foreach my $field (@fields) {
	# Accept numeric choices only; cron expressions must not pass through
	# the form.
	my $value = $in->{$field};
	my ($min, $max) = @{$limits{$field}};
	die "Enter a schedule $field from $min to $max\n"
		if (!defined($value) || ref($value) || $value !~ /\A\d+\z/ || $value < $min || $value > $max);
	$when{$field} = 0+$value;
}
if ($frequency eq 'yearly') {
	# February 29 is valid in leap years; dates that never occur are mistakes.
	my @days = (31,29,31,30,31,30,31,31,30,31,30,31);
	die "Select a day that exists in the chosen month\n" if ($when{'day'} > $days[$when{'month'}-1]);
}
return \%when;
}

# backup_schedule_cron(schedule) maps one recurrence to Webmin cron fields.
sub backup_schedule_cron
{
my ($s) = @_;
my $f = $s->{'frequency'};
# Keep weekdays unrestricted for calendar dates: cron otherwise matches either.
return {mins => $s->{'minute'}, hours => $f eq 'hourly' ? '*' : $s->{'hour'},
	days => $f eq 'monthly' || $f eq 'yearly' ? $s->{'day'} : '*',
	months => $f eq 'yearly' ? $s->{'month'} : '*',
	weekdays => $f eq 'weekly' ? $s->{'weekday'} : '*'};
}

# save_backup_schedule(input) saves a schedule and Webmin's native cron entry.
sub save_backup_schedule
{
my ($in) = @_;
my $id = $in->{'sched'} || substr(Cloudmin::Images::generate_id(),0,32);
Cloudmin::Jobs::validate_id($id);
return get_vm_jobs()->lock('backup-schedules', sub {
	my ($old) = grep { $_->{'id'} eq $id } @{backup_schedules()};
	die "Backup schedule not found\n" if ($in->{'sched'} && !$old);
	foreign_require('webmincron');
	my ($cron) = grep { $_->{'module'} eq $module_name && $_->{'func'} eq 'run_backup_schedule' &&
		$_->{'args'}->[0] eq $id } webmincron::list_webmin_crons();
	my $dir = get_backup_service()->directory().'/schedules';
	make_dir($dir, 0700, 1) or die "Cannot create schedule directory\n" if (!-d $dir);
	# Remove the cron trigger before deleting its saved settings.
	if ($in->{'delete'}) {
		webmincron::delete_webmin_cron($cron) if ($cron);
		unlink("$dir/$id.json") or die "Cannot delete backup schedule\n";
		return $id;
	}
	# Blank secrets retain saved values; unattended SSH still needs approved
	# trust.
	my $target = Cloudmin::BackupTransport::saved_target($in->{'target'}, $old ? $old->{'target'} : undef);
	Cloudmin::BackupSSH::require_trusted($target) if ($target->{'mode'} eq 'ssh');
	# Persist UUIDs and a bounded age, not names or caller-supplied cron
	# syntax.
	my @guests = grep { length } split(/[\s\0,]+/, $in->{'guests'} || '');
	die "Select one or more virtual machines\n" if (!$in->{'all'} && !@guests);
	die "Invalid virtual machine selection\n" if (grep { !/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/ } @guests);
	die "Enter a retention period from 0 to 3650 days\n" if (($in->{'purge'} // 0) !~ /\A\d+\z/ || ($in->{'purge'} || 0) > 3650);
	my $when = backup_schedule_time($in);
	my $s = {id => $id, description => substr($in->{'description'} || '',0,200), owner => $remote_user,
		target => $target, guests => \@guests, all => $in->{'all'} ? 1 : 0, enabled => $in->{'enabled'} ? 1 : 0,
		shutdown => $in->{'shutdown'} ? 1 : 0, compression => $in->{'compression'} ? 1 : 0,
		purge => 0+($in->{'purge'} || 0), %$when};
	# A leftover file from an interrupted save must not block the next update.
	my ($fh, $temp) = File::Temp::tempfile('.schedule-XXXXXXXX', DIR => $dir, UNLINK => 1);
	print($fh convert_to_json($s)) && close($fh) or die "Cannot write backup schedule\n";
	rename($temp, "$dir/$id.json") or die "Cannot save backup schedule\n";
	# Enabled schedules use native Webmin cron with a fully loaded module.
	if ($s->{'enabled'}) {
		$cron ||= {module => $module_name, file => 'server-manager-lib.pl', func => 'run_backup_schedule', args => [$id]};
		my $time = backup_schedule_cron($s);
		@$cron{keys %$time} = values %$time;
		webmincron::save_webmin_cron($cron);
	}
	# Disabled schedules retain their settings but must have no active
	# trigger.
	elsif ($cron) { webmincron::delete_webmin_cron($cron); }
	webmin_log('save', 'backup_schedule', $id, {description => $s->{'description'}});
	return $id;
});
}

1;
