# Functions for use by the command-line API

sub list_api_categories
{
return (
	[ "Virtual systems", "*-system.pl", "*-systems.pl",
			     "modify-limits.pl", "get-console.pl" ],
	[ "Virtual disks", "*-disk.pl", "*-disks.pl" ],
	[ "Amazon EC2", "*-ec2-*.pl" ],
	[ "Network interfaces", "*-interface.pl", "*-interfaces.pl" ],
	[ "System owners", "*-owner.pl", "*-owners.pl" ],
	[ "Virtualmin domains", "*-domain.pl", "*-domains.pl" ],
	[ "License management", "*-licence.pl", "*-licences.pl" ],
	[ "File management", "*-file.pl" ],
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

  * ''--host'' //hostname//\\\\ Can be given multiple times to specify systems by name.
  * ''--group'' //groupname//\\\\ Specifies systems that are members of the named group.
  * ''--type'' //code//\\\\ Matches systems of some virtualization type, which can be one of ''xen'' , ''vservers'' , ''zones'' or ''real''
  * ''--os'' //code//\\\\ Matches systems known to be running some OS, specified by a code like ''centos'' , ''solaris'' , ''redhat'' or ''ubuntu''.
  * ''--all-hosts''\\\\ Always matches all registered systems.
",

"Virtual disks",
"Xen instances managed by VM2 can have one or more virtual disks, which are
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
"VM2 system owners are additional logins who have access to a limit set of
functions and managed systems. These commands allow you to list, create and
manage owner accounts.",

"Virtualmin domains",
"VM2 can manage Virtualmin domains across all managed systems via both the web
interface and from the command line. This can be particularly useful if you
have multiple hosting systems, and need a single location from which domains
can be setup, perhaps for use by a billing system.",

"License management",
"VM2 has the ability to add and manage Virtualmin licenses, which are needed
when creating new systems with Virtualmin installed. This category covers the
license management commands.",

"File management",
"VM2 can fetch files from and send files to any of the systems it manages,
either using SCP or direct access to the filesystem where possible. This
category covers commands for fetching and uploading files.",

"Other scripts",
"Programs in this section don't fall into any of the other categories.",
	);
}

sub list_api_skip_scripts
{
return ( "upload-api-docs.pl",
	 "postinstall.pl",
       );
}

1;

