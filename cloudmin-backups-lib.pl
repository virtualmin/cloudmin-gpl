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

1;
