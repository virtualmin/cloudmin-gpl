
do 'server-manager-lib.pl';

sub module_install
{
# Convert all existing cron jobs to WebminCron, except existing backups
foreach my $script (@cron_cmds) {
	if ($script ne $backup_cron_cmd && $script ne $vsync_cron_cmd) {
		&convert_cron_script($script);
		}
	}

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
if (!&find_cron_script($check_status_cmd)) {
	my $job = { 'command' => $check_status_cmd,
		    'user' => 'root',
		    'mins' => '0,5,10,15,20,25,30,35,40,45,50,55',
		    'hours' => '*',
		    'days' => '*',
		    'weekdays' => '*',
		    'months' => '*',
		    'active' => 1, };
	&setup_cron_script($job);
	}

# And cron job to check licence
if (!&find_cron_script($check_licence_cmd)) {
	my $job = { 'command' => $check_licence_cmd,
		    'user' => 'root',
		    'mins' => int(rand()*60),
		    'hours' => '*',
		    'days' => '*',
		    'weekdays' => '*',
		    'months' => '*',
		    'active' => 1, };
	&setup_cron_script($job); 
	}

# Refresh my status
if ($config{'show_this'}) {
	my $server = &get_this_managed_server();
	if ($server) {
		&check_server_status($server, 0, 1);
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
	if (!&find_cron_script($backup_space_cmd)) {
		my $job = { 'command' => $backup_space_cmd,
			    'user' => 'root',
			    'mins' => int(rand()*60),
			    'hours' => int(rand()*24),
			    'days' => '*',
			    'weekdays' => '*',
			    'months' => '*',
			    'active' => 1, };
		&setup_cron_script($job);
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

