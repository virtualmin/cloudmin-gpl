# Functions for use by the command-line API

sub list_api_categories
{
return (
	[ "Backup and restore", "backup-systems.pl", "restore-systems.pl",
				"list-backup-logs.pl" ],
	[ "File management", "*-file.pl", "*-files.pl", "mount-system.pl",
			     "umount-system.pl", "list-directory.pl" ],
	[ "Virtual systems", "*-system.pl", "*-systems.pl",
			     "modify-limits.pl", "get-console.pl",
			     "modify-reverse-address.pl", ],
	[ "Virtual disks", "*-disk.pl", "*-disks.pl", "*-disk-storages.pl" ],
	[ "Amazon EC2", "*-ec2-*.pl" ],
	[ "Network interfaces", "*-interface.pl", "*-interfaces.pl",
				"set-default-gateway.pl" ],
	[ "System owners", "*-owner.pl", "*-owners.pl",
			   "list-owner-bandwidth.pl",
			   "*-plan.pl", "*-plans.pl" ],
	[ "Virtualmin domains", "*-domain.pl", "*-domains.pl" ],
	[ "License management", "*-licence.pl", "*-licences.pl" ],
	[ "Image management", "*-image.pl", "*-images.pl",
			      "set-image-rawsize.pl" ],
	[ "Provisioning", "*provision*.pl", "*-dns-zone.pl",
			  "*-mysql-database.pl", "*-mysql-login.pl",
			  "*-dns-records.pl" ],
	[ "Other scripts", "*.pl" ],
	);
}

sub list_api_category_descs
{
return (
"Virtual systems",
"These commands can be used to find, update, reboot and shutdown virtual
systems. Most of them take the following parameters to control which system or
systems to operate on :

<ul>
<li><tt>--host</tt> <i>hostname</i><br>Can be given multiple times to specify systems by name.
<li><tt>--group</tt> <i>groupname</i><br>Specifies systems that are members of the named group.
<li><tt>--type</tt> <i>code</i><br>Matches systems of some virtualization type, which can be one of <tt>xen</tt> , <tt>vservers</tt> , <tt>zones</tt> or <tt>real</tt>
<li><tt>--os</tt> <i>code</i><br>Matches systems known to be running some OS, specified by a code like <tt>centos</tt> , <tt>solaris</tt> , <tt>redhat</tt> or <tt>ubuntu</tt>.
<li><tt>--all-hosts</tt><br>Always matches all registered systems.
</ul>
<p></p>
",

"Virtual disks",
"Xen instances managed by Cloudmin can have one or more virtual disks, which are
typically stored in files on the host system. These commands allow you to
create, resize and delete disk images, or associate real devices with disks
on virtual systems.",

"Amazon EC2",
"The commands in this section are specific to EC2 virtual system creation,
and management of associated resources such as IP addresses.",

"Network Interfaces",
"Virtual systems running under Zones or Linux Vservers cannot manage their
own network interfaces - instead, they must be assigned by the host system,
which can be done using the commands in this section.",

"System owners",
"Cloudmin system owners are additional logins who have access to a limit set of
functions and managed systems. These commands allow you to list, create and
manage owner accounts.",

"Virtualmin domains",
"Cloudmin can manage Virtualmin domains across all managed systems via both the web
interface and from the command line. This can be particularly useful if you
have multiple hosting systems, and need a single location from which domains
can be setup, perhaps for use by a billing system.",

"License management",
"Cloudmin has the ability to add and manage Virtualmin licenses, which are needed
when creating new systems with Virtualmin installed. This category covers the
license management commands.",

"File management",
"Cloudmin can fetch files from and send files to any of the systems it manages,
either using SCP or direct access to the filesystem where possible. This
category covers commands for fetching and uploading files.",

"Backup and restore",
"Cloudmin can create backups of virtual systems and restore them using the
commands defined in this category.",

"Image management",
"An image is a template from which a virtual system can be created. Commands in
this category can be used to create, list and remove images.",

"Provisioning",
"These commands are part of the Cloudmin provisioning server plugin, and can be used to create DNS zones, MySQL databases and other services on host systems.",

"Other scripts",
"Programs in this section don't fall into any of the other categories.",
	);
}

sub list_api_skip_scripts
{
return ( "upload-api-docs.pl",
	 "postinstall.pl",
	 "import-api-docs.pl",
	 "set-image-rawsize.pl",
       );
}

sub list_api_directories
{
my ($pwd) = @_;
local $par = $pwd;
$par =~ s/\/([^\/]+)$//;
return ( $pwd, glob("$par/cloudmin-*") );
}

# create_api_helper_command([&extra-dirs])
# Creates the API helper command. Returns either 1 and the path, or 0 and
# an error message.
sub create_api_helper_command
{
local ($extradirs) = @_;
local @dirs = ( $module_root_directory );
push(@dirs, @$extradirs) if ($extradirs);
local $dirstr = join(" ", @dirs);
local $bash = &has_command("bash") || &has_command("sh");
if ($bash) {
	&open_tempfile(HELPER, ">$api_helper_command", 1, 0) ||
		return (0, "Failed to write to $api_helper_command : $!");
	&print_tempfile(HELPER, <<EOF);
#!$bash
WEBMIN_CONFIG=$config_directory
WEBMIN_VAR=$var_directory
PERLLIB=$root_directory
export WEBMIN_CONFIG WEBMIN_VAR PERLLIB
cd $module_root_directory
id -a | grep uid=0 >/dev/null
if [ "\$?" != 0 ]; then
	echo "$api_helper_command must be run as root"
	exit 2
fi
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
for dir in $dirstr; do
	if [ -x "\$dir/\$COMMAND" ]; then
		if [ "\$help" = "1" ]; then
			exec perldoc \$dir/\$COMMAND
		else
			exec \$dir/\$COMMAND "\$@"
		fi
	fi
done
echo Command \$COMMAND was not found
exit 1
EOF
	&close_tempfile(HELPER);
	&set_ownership_permissions(undef, undef, 0755, $api_helper_command);
	return (1, $api_helper_command);
	}
else {
	return (0, "bash was not found");
	}
}

1;

