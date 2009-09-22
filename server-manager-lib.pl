# Functions for general setup and management of multiple Virtualmin servers

BEGIN { push(@INC, ".."); };
eval "use WebminCore;";

&init_config();
&foreign_require("servers", "servers-lib.pl");
&foreign_require("proc", "proc-lib.pl");
&foreign_require("net", "net-lib.pl");
&remote_error_setup(\&remote_error_handler);
%access = &get_module_acl();

if (!$done_server_manager_lib_funcs) {
	do 'server-manager-lib-funcs.pl';
	}

# Work out which virtual system types are supported and enabled
@server_management_types = ( );
%server_management_types = ( );
@virtual_server_management_types = ( );
foreach my $smt (@possible_server_management_types) {
	if ($config{'show_'.$smt} &&
	    -r $module_root_directory."/".$smt."-type-lib.pl") {
		push(@server_management_types, $smt);
		$server_management_types{$smt} = 1;
		my $vfunc = "type_".$smt."_is_virtual";
		if (defined(&$vfunc) && &$vfunc()) {
			push(@virtual_server_management_types, $smt);
			}
		my $ifunc = "type_".$smt."_init";
		if (defined(&$ifunc)) {
			&$ifunc();
			}
		}
	}

$ssh_keys_dir = "$module_config_directory/keys";
$server_domains_dir = "$module_config_directory/domains";
$server_collected_dir = "$module_config_directory/coll";
$this_server_status = "$module_config_directory/this";

$historic_info_dir = "$module_config_directory/history";

$check_status_cmd = "$module_config_directory/status.pl";
$check_licence_cmd = "$module_config_directory/licence.pl";
$bandwidth_cron_cmd = "$module_config_directory/bandwidth.pl";
@cron_cmds = ( $check_status_cmd, $check_licence_cmd,
	       $bandwidth_cron_cmd );

@standard_virtualmin_features = (
	{ 'feature' => 'dir', 'desc' => 'Home directory',
	  'enabled' => 1, 'default' => 1, 'auto' => 1 },
	{ 'feature' => 'unix', 'desc' => 'Administration user',
	  'enabled' => 1, 'default' => 1, 'auto' => 1 },
	{ 'feature' => 'mail', 'desc' => 'Mail for domain',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'dns', 'desc' => 'BIND DNS domain',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'web', 'desc' => 'Apache website',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'webalizer', 'desc' => 'Webalizer reporting',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'ssl', 'desc' => 'SSL website',
	  'enabled' => 1, 'default' => 0 },
	{ 'feature' => 'logrotate', 'desc' => 'Log file rotation',
	  'enabled' => 1, 'default' => 1, 'auto' => 1 },
	{ 'feature' => 'mysql', 'desc' => 'MySQL database',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'postgres', 'desc' => 'PostgreSQL database',
	  'enabled' => 1, 'default' => 1 },
	{ 'feature' => 'ftp', 'desc' => 'ProFTPd server',
	  'enabled' => 1, 'default' => 0 },
	{ 'feature' => 'webmin', 'desc' => 'Webmin login',
	  'enabled' => 1, 'default' => 1 },
	);

%webmin_download_source = (
	'rpm' => 'http://www.webmin.com/download/rpm/webmin-current.rpm',
	'dpkg' => 'http://www.webmin.com/download/deb/webmin-current.deb',
	'pkgadd' => 'http://www.webmin.com/download/webmin-current.pkg.gz',
	'tgz' => 'http://www.webmin.com/download/webmin-current.tar.gz',
	);

$pkgget_download_url = "http://www.blastwave.org/pkg_get.pkg";

@server_statuses = (
	[ 'down' => 'ff0000' ],
	[ 'noping' => 'ff1100' ],
	[ 'alive' => '00ff00' ],
	[ 'paused' => 'aa0000' ],
	[ 'nossh' => 'ff220000' ],
	[ 'nohost' => 'ff440000' ],
	[ 'nosshlogin' => 'ff6600' ],
	[ 'nowebmin' => 'ff00ff' ],
	[ 'downwebmin' => 'ff22ff' ],
	[ 'nowebminlogin' => 'ff44ff' ],
	[ 'novirt' => '008800' ],
	[ 'virt' => '00aa00' ]
	);

$licence_status = "$module_config_directory/licence-status";
$licence_file = "/etc/server-manager-license";
$licence_cache_file = "$module_config_directory/licence-cache";
$cloudmin_yum_repo = "/etc/yum.repos.d/vm2.repo";
if (!-r $cloudmin_yum_repo) {
	$cloudmin_yum_repo = "/etc/yum.repos.d/cloudmin.repo";
	}
$upgrade_cloudmin_host = "cloudmin.virtualmin.com";
$upgrade_vm2_host = "vm2.virtualmin.com";

$virtualmin_licence_host = "software.virtualmin.com";
$virtualmin_licence_port = 80;
$vm2_licence_prog = "/cgi-bin/slicence.cgi";
$virtualmin_licence_prog = "/cgi-bin/vlicence.cgi";
$virtualmin_licence_ssl = 0;
$virtualmin_installer_prog = "/cgi-bin/install.cgi";
$virtualmin_solaris_installer_prog = "/cgi-bin/install.cgi";
$virtualmin_alllicences_prog = "/cgi-bin/alllicences.cgi";
$virtualmin_gpl_installer_path = "/gpl/scripts/install.sh";

$virtualmin_licences_file = "$module_config_directory/virtualmin-licences";
$serial_cache_file = "$module_config_directory/serial-cache";
$virtualmin_progress_file = "$module_config_directory/progress-licences";

@virtualmin_operating_systems = ( "debian", "ubuntu", "redhat", "fedora",
				  "centos", "solaris" );

$virtualmin_apt_package_key = "http://software.virtualmin.com/lib/RPM-GPG-KEY-virtualmin";
$virtualmin_webmin_apt_package_key = "http://software.virtualmin.com/lib/RPM-GPG-KEY-webmin";

$default_search_file = "$module_config_directory/defaultsearch.$remote_user";

@newfeatures_dirs = ( "$module_root_directory/newfeatures-all" );
$newfeatures_seen_dir = "$module_config_directory/seenfeatures";
$install_times_file = "$module_config_directory/installtimes";

$bandwidth_dir = "$module_config_directory/bandwidth";

$shell_previous_dir = "$module_config_directory/previous";

$login_shell_cmd = "$module_config_directory/login.pl";
$login_home_base = $ENV{'WEBMIN_VAR'}."/login";

$api_helper_command = "/usr/sbin/cloudmin";
$old_api_helper_command = "/usr/sbin/vm2";

$ping_host_timeout = 2;

$xen_cpu_seconds_file = "$module_config_directory/xen-cpu-seconds";

$owner_plans_dir = "$module_config_directory/plans";

@plan_limit_types = ( 'servers', 'ram', 'disk', 'cpu', 'ips', 'bw',
		      'space' );
@nice_plan_limit_types = ( 'ram', 'disk', 'bw', 'space' );
@plan_hostmodes = ( 'mem', 'disk', 'rand', 'location' );

$usage_data_dir = "$module_config_directory/usage";
$usage_cron_cmd = "$module_config_directory/usage.pl";

$scheduled_backups_dir = "$module_config_directory/backups";
$backup_cron_cmd = "$module_config_directory/backup.pl";
$backup_log_dir = "$module_config_directory/backuplogs";
$backup_space_cmd = "$module_config_directory/space.pl";

$locations_file = "$module_config_directory/locations";

$server_images_dir = "$ENV{'WEBMIN_VAR'}/$module_name";
$server_images_url = "http://cloudmin.virtualmin.com/images/images.txt";
$server_images_base = "http://cloudmin.virtualmin.com/images/";
$server_images_cache = "$module_config_directory/server-images-cache";
$images_cache_dir = "/var/cloudmin-images";

# Init all plugins
@confplugins = split(/\s+/, $config{'plugins'});
if ($no_vm2_plugins) {
	@confplugins = ( );
	}
@plugins = ( );
foreach my $pname (@confplugins) {
	if (&foreign_check($pname)) {
		&foreign_require($pname, "cloudmin_feature.pl");
		push(@plugins, $pname);
		}
	}

&set_all_html_print();

1;

