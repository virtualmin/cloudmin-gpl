
do 'server-manager-lib.pl';

# backup_config_files()
# Returns files and directories that can be backed up
sub backup_config_files
{
my @rv;

# Add SSH keys, domains, collected info and this system
push(@rv, $ssh_keys_dir, $server_domains_dir, $server_collected_dir,
	  $this_server_status);

# Add virtualmin licenses
push(@rv, $virtualmin_licences_file);

# Add Bandwidth data and previous commands
push(@rv, $bandwidth_dir, $shell_previous_dir);

# Add EC2 accounts
if ($ec2_accounts_dir) {
	push(@rv, $ec2_accounts_dir);
	}

# Add plans
push(@rv, $owner_plans_dir);

# Scheduled backups
push(@rv, $scheduled_backups_dir);

# Locations file
push(@rv, $locations_file);

# IP pools file
push(@rv, $pools_file);
push(@rv, $pools6_file);

# Syncs dir
push(@rv, $vsyncs_dir);

# Image storages dir
push(@rv, $image_storages_dir);

# Alerts dir
push(@rv, $alerts_dir);

# DNS roundrobins dir
push(@rv, $roundrobins_dir);

# Auto-scaling dir
push(@rv, $scalegroups_dir);

return &unique(@rv);
}

# pre_backup(&files)
# Called before the files are actually read
sub pre_backup
{
return undef;
}

# post_backup(&files)
# Called after the files are actually read
sub post_backup
{
return undef;
}

# pre_restore(&files)
# Called before the files are restored from a backup
sub pre_restore
{
return undef;
}

# post_restore(&files)
# Called after the files are restored from a backup
sub post_restore
{
return undef;
}

1;

