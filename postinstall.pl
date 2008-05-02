
do 'server-manager-lib.pl';

sub module_install
{
# Make sure the remote.cgi page is accessible in non-session mode
local %miniserv;
&get_miniserv_config(\%miniserv);
if ($virtualmin_pro) {
	local @sa = split(/\s+/, $miniserv{'sessiononly'});
	if (&indexof("/$module_name/remote.cgi", @sa) < 0) {
		# Need to add
		push(@sa, "/$module_name/remote.cgi");
		$miniserv{'sessiononly'} = join(" ", @sa);
		&put_miniserv_config(\%miniserv);
		&reload_miniserv();
		}
	}

# Setup Cron job to check managed server statuses
&foreign_require("cron", "cron-lib.pl");
local ($job) = grep { $_->{'user'} eq 'root' &&
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
local ($job) = grep { $_->{'user'} eq 'root' &&
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

# Refresh local status
local ($server) = grep { $_->{'id'} == 0 } &list_managed_servers();
if ($server) {
	&check_server_status($server);
	&save_managed_server($server);
	}

# Record the install time for this version
local %itimes;
&read_file($install_times_file, \%itimes);
local $basever = &get_base_module_version();
if (!$itimes{$basever}) {
	$itimes{$basever} = time();
	&write_file($install_times_file, \%itimes);
	}
}

