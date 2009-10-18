
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

# Setup Cron job to check managed server statuses
&foreign_require("cron", "cron-lib.pl");
my ($job) = grep { $_->{'user'} eq 'root' &&
		      $_->{'command'} eq $check_status_cmd }
		    &cron::list_cron_jobs();
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
my ($job) = grep { $_->{'user'} eq 'root' &&
		      $_->{'command'} eq $check_licence_cmd }
		    &cron::list_cron_jobs();
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
	my $server = &get_managed_server(0);
	if ($server) {
		&check_server_status($server);
		&save_managed_server($server);
		}
	}

# Create API helper script /usr/bin/cloudmin
my $bash = &has_command("bash");
if ($bash) {
        &open_tempfile(HELPER, ">$api_helper_command", 1, 0);
        &print_tempfile(HELPER, <<EOF);
#!$bash
WEBMIN_CONFIG=$config_directory
WEBMIN_VAR=$var_directory
PERLLIB=$root_directory
export WEBMIN_CONFIG WEBMIN_VAR PERLLIB
cd $module_root_directory
if [ "\$1" = "" -o "\$1" = "help" -a "\$2" = "" -o "\$1" = "--help" -a "\$2" = "" -o "\$1" = "-help" -a "\$2" = "" ]; then
        echo "usage: $api_helper_command <command> [args..]"
        echo "   or: $api_helper_command help <command>"
	echo ""
	echo "Available commands :"
	echo ""
	COMMAND=list-commands
else
	COMMAND=\$1
fi
shift
if [ "\$COMMAND" = "help" ]; then
        help=1
        COMMAND=\$1
        shift
fi
echo \$COMMAND | fgrep .pl >/dev/null
if [ "\$?" != "0" ]; then
        COMMAND="\$COMMAND.pl"
fi
if [ "\$help" = "1" ]; then
        perldoc $module_root_directory/\$COMMAND
else
        exec $module_root_directory/\$COMMAND "\$@"
fi
EOF
        &close_tempfile(HELPER);
        &set_ownership_permissions(undef, undef, 0755, $api_helper_command);
        }

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
	my ($job) = grep { $_->{'user'} eq 'root' &&
			      $_->{'command'} eq $backup_space_cmd }
			    &cron::list_cron_jobs();
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

