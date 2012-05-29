
do 'server-manager-lib.pl';

sub module_install
{
# Make sure the remote.cgi page is accessible in non-session mode
my %miniserv;
&get_miniserv_config(\%miniserv);
my @sa = split(/\s+/, $miniserv{'sessiononly'});
if (&indexof("/$module_name/remote.cgi", @sa) < 0) {
	# Need to add
	push(@sa, "/$module_name/remote.cgi");
	$miniserv{'sessiononly'} = join(" ", @sa);
	&put_miniserv_config(\%miniserv);
	&reload_miniserv();
	}

# Remember the first version we installed, to avoid showing new features
# from before it
$config{'first_version'} ||= &get_base_module_version();
&save_module_config();

# Setup Cron job to check managed server statuses
&foreign_require("cron", "cron-lib.pl");
my $job = &find_server_manager_cron_job($check_status_cmd);
if (!$job) {
	$job = { 'command' => $check_status_cmd,
		 'user' => 'root',
		 'mins' => '0,5,10,15,20,25,30,35,40,45,50,55',
		 'hours' => '*',
		 'days' => '*',
		 'weekdays' => '*',
		 'months' => '*',
		 'active' => 1, };
	&cron::create_cron_job($job);
	&cron::create_wrapper($check_status_cmd, $module_name, "status.pl");
	}

# And cron job to check licence
my $job = &find_server_manager_cron_job($check_licence_cmd);
if (!$job) {
	$job = { 'command' => $check_licence_cmd,
		 'user' => 'root',
		 'mins' => int(rand()*60),
		 'hours' => '*',
		 'days' => '*',
		 'weekdays' => '*',
		 'months' => '*',
		 'active' => 1, };
	&cron::create_cron_job($job);
	&cron::create_wrapper($check_licence_cmd, $module_name, "licence.pl");
	}

# Refresh my status
if ($config{'show_this'}) {
	my $server = &get_this_managed_server();
	if ($server) {
		&check_server_status($server);
		&save_managed_server($server);
		}
	}

# Create API helper script /usr/bin/cloudmin
local @plugindirs = map { &module_root_directory($_) } @plugins;
&create_api_helper_command(\@plugindirs);

# Link vm2 command as well
&unlink_file($old_api_helper_command);
&symlink_file($api_helper_command, $old_api_helper_command);

# Update system owners to set plan if missing
if (&supports_plans()) {
	my ($plan) = &list_plans();
	my $fixed_count = 0;
	foreach my $o (&list_system_owners()) {
		if (!$o->{'acl'}->{'plan'}) {
			$o->{'acl'}->{'plan'} = $plan->{'id'};
			&save_system_owner($o, $o);
			$fixed_count++;
			}
		}
	&apply_plan($plan) if ($fixed_count);
	&save_plan($plan);
	}

# Create cron job to count owner's backup space used
if (defined(&list_backups)) {
	my $job = &find_server_manager_cron_job($backup_space_cmd);
	if (!$job) {
		$job = { 'command' => $backup_space_cmd,
			 'user' => 'root',
			 'mins' => int(rand()*60),
			 'hours' => int(rand()*24),
			 'days' => '*',
			 'weekdays' => '*',
			 'months' => '*',
			 'active' => 1, };
		&cron::create_cron_job($job);
		&cron::create_wrapper($backup_space_cmd,
				      $module_name, "space.pl");
		}
	}

# Enable preloading of server-manager-lib-funcs.pl
my $msc = $ENV{'MINISERV_CONFIG'} || "$config_directory/miniserv.conf";
my %miniserv;
&get_miniserv_config(\%miniserv);
my @preload = split(/\s+/, $miniserv{'preload'});
my $changed_preload = 0;
my $lib = "server-manager=server-manager/server-manager-lib-funcs.pl";
if (&indexof($lib, @preload) < 0) {
	push(@preload, $lib);
	$miniserv{'preload'} = join(" ", &unique(@preload));
	$changed_preload = 1;
	}
if (!$miniserv{'premodules'}) {
	$miniserv{'premodules'} = "WebminCore";
	$changed_preload = 1;
	}
if ($changed_preload) {
	# Only apply miniserv change if needed
	&put_miniserv_config(\%miniserv);
	}
if (&check_pid_file($miniserv{'pidfile'})) {
	# Always restart, in case code has changed
	&restart_miniserv();
	}

# Save all storage locations to store sizes
foreach my $s (&list_storages()) {
	&save_storage($s);
	}

# Pre-create the images dir
&make_dir($server_images_dir, 0700);

# Record the install time for this version
my %itimes;
&read_file($install_times_file, \%itimes);
my $basever = &get_base_module_version();
if (!$itimes{$basever}) {
	$itimes{$basever} = time();
	&write_file($install_times_file, \%itimes);
	}
}

1;

