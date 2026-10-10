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

1;
