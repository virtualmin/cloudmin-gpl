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

1;
