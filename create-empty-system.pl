#!/usr/local/bin/perl

=head1 create-empty-system.pl

Creates a new empty virtual system of some type

This command creates a new system that is initially empty, but can be
setup by installing an operating system from a CD. The required parameters are :

C<--host> I<hostname> A short hostname for the system to create, which will also be used as the Xen or VServers instance name.
C<--desc> I<description> A human-readable name for the system, which you will typically have to quote.
C<--type> I<code> The virtualization type code, like ''xen'' , ''zones''  or ''vservers''

The CD image to install from can either be specified with the C<--imagefile>
flag followed by a filename on the host system, or the C<--image> flag followed
by the ID of a system image in ISO format. If neither are given, a VM with
an empty disk is created - however, it will be un-usable until either a CD
image is attached, or an operating system image is copied to the disk.

The flag C<--start-at-boot> can be given to have the new system restarted
when its host system reboots. Alternately, you can use C<--no-start-at-boot>
to disable this. If neither flag is given, the Cloudmin default setting
(chosen on the Cloudmin Configuration page in the UI) is used.

Once creation completes, you will need to use the Graphical Console page
in the Cloudmin UI to complete the installation process.

=head1 Example usage

  cloudmin create-empty-system.pl --type xen --host functest --desc 'Empty host' --xen-disksize 1024 --image xen-lenny-cd
  Copying CD image file to host system sentosa.home ..
  .. already in host cache
  Starting creation of empty Xen system ..
  .. creation started
  Waiting for creation to complete ..
  .. creation complete
  Adding DNS entry functest.home. for IP address 193.9.101.60 ..
  .. done
  Configuring Xen instance for VNC console access ..
  .. added on dynamic port
  Starting up new Xen instance ..
.. failed to start : Xen instance was started, but could not be accessed via SSH after 60 seconds
  Refreshing status ..
  .. done (noping)
  Enabling at hosting system boot ..
  .. done
  Creation of empty Xen system functest.home is complete

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*)\/[^\/]+$/) {
	chdir($pwd = $1);
	}
else {
	chop($pwd = `pwd`);
	}
$0 = "$pwd/create-empty-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

&set_all_text_print();

# Work out possible creation types
foreach $t (@server_management_types) {
	$lfunc = "type_".$t."_can_create_empty";
	if (defined(&$lfunc) && &$lfunc()) {
		push(@crtypes, $t);
		}
	}
@crtypes || &usage("No system types are available for creation!");

# Parse command line
$start_boot = $config{'default_start'};
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--type") {
		$type = shift(@ARGV);
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--desc") {
		$desc = shift(@ARGV);
		}
	elsif ($a eq "--image") {
		$image = shift(@ARGV);
		}
	elsif ($a eq "--imagefile") {
		$imagefile = shift(@ARGV);
		}
	elsif ($a eq "--id") {
		$newid = shift(@ARGV);
		}
	elsif ($a eq "--owner") {
		$ownername = shift(@ARGV);
		$owner = &get_system_owner($ownername);
		$owner || &usage("No system owner named $ownername exists");
		}
	elsif ($a eq "--manual-status") {
		$manual_status = 1;
		}
	elsif ($a eq "--disk-directory" || $a eq "--force-disk-directory") {
		$directory = shift(@ARGV);
		$directory =~ /^\/\S+$/ ||
		    &usage("--disk-directory must be followed by a full path");
		$force_directory = $a eq "--force-disk-directory" ? 1 : 0;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	elsif ($a eq "--start-at-boot") {
		$start_boot = 1;
		}
	elsif ($a eq "--no-start-at-boot") {
		$start_boot = 0;
		}
	elsif ($a =~ /^\-\-([^\-]+)\-(\S+)$/) {
		# Type-specific option
		$typeargs{$1}->{$2} = shift(@ARGV);
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Check for mandatory args
@servers = &list_managed_servers();
$type || &usage("Missing required --type parameter");
&can_create_server_usage($type);
$host || &usage("Missing required --host parameter");
$host =~ /^[a-z0-9\.\-]+$/ || &usage("Invalid hostname");
($clash) = grep { $_->{'host'} eq $host } @servers;
$clash && &usage("A system with the same hostname already exists");

# Check if can create
($can, $canerr) = &can_create_server($type);
$can || &usage("Creation is not allowed : $canerr");
&can_action_usage(undef, "empty");

# Create initial server object
$server = { 'id' => $newid || &server_id(),
	    'manager' => $type,
	    'type' => 'unknown',
	    'novirt' => $novirt,
	    'status' => 'create',
	    'image' => $image,
	    'bw_limit' => $config{'bw_def'},
	    'created' => time(),
	    'manual_status' => $manual_status,
	    'directory' => $directory,
	    'force_directory' => $force_directory,
	  };
$server->{'desc'} = $desc;
if ($image && $img->{'type'}) {
	$server->{'type'} = $img->{'type'};
	}
$server->{'host'} = $host;

# Check if any image is needed
$efunc = "type_".$type."_can_create_empty";
$empty = defined(&$efunc) && &$efunc();
$empty || &usage("Virtual system type $type does not support empty ".
		 "system creation");

if ($empty != 2) {
	# Validate CD image
	if ($image) {
		# Cloudmin CD image
		@images = &list_server_images($type);
		($img) = grep { $_->{'id'} eq $image } @images;
		$img || &usage("Image ID does not exist or in not valid for ".
			       "the specified system type");
		&can_image($img) ||
			&usage("You are not allowed to use this image");
		$img->{'format'} eq 'cd' ||
			&usage("Selected image is not a CD");
		$server->{'image'} = $image;
		$server->{'type'} = $img->{'type'};
		}
	elsif ($imagefile) {
		# Regular file
		&can_action_usage(undef, "global");
		$imagefile =~ /^\/\S+$/ ||
			&usage("--imagefile must be followed by a full path");
		$server->{'imagefile'} = $imagefile;
		}
	}
else {
	# No image needed
	($image || $imagefile) &&
		&usage("No CD image can be specified for a $type system");
	}

# Disable logins
$server->{'ssh_user'} = 'root';
$server->{'ssh_nologin'} = 1;
$server->{'ssh_protocol'} = 2;
$server->{'no_webmin_login'} = 1;
$server->{'port'} = 10000;
$server->{'type'} = 'unknown';

# Call type-specific create parse function
$pfunc = "type_".$type."_create_args_parse";
if (defined(&$pfunc)) {
	$err = &$pfunc($typeargs{$type}, $server, 1);
	&usage($err) if ($err);
	}

# Check for hostname clash again, as the parse may have changed it
if ($server->{'host'}) {
	($clash) = grep { $_->{'host'} eq $server->{'host'} } @servers;
	$clash && &usage("A system with the same hostname already exists");
	}

# Validate owner resource limits
$limits = &get_owner_limits();
if ($limits) {
	# Validate disk limit
	$dsfunc = "type_".$type."_get_disk_size";
	$incr = defined(&$dsfunc) ? &$dsfunc($server) : undef;
	if ($incr && $limits->{'max_disk'}) {
		# May be over disk limit
		if ($limits->{'disk'} + $incr > $limits->{'max_disk'}) {
			&usage("Creating this system would exceed your disk ",
			       "limit of ",&nice_size($limits->{'max_disk'}));
			}
		}
	elsif (!$incr && $limits->{'max_disk'}) {
		# System has no disk limits, but owner does
		&usage("You cannot create a system with unlimited disk as ",
		       "your limit is ",&nice_size($limits->{'max_disk'}));
		}

	# Validate RAM limit
	$mfunc = "type_".$type."_get_memory_size";
	$incr = defined(&$mfunc) ? &$mfunc($server) : undef;
	if ($incr && $limits->{'max_ram'}) {
		# May be over RAM limit
		if ($limits->{'ram'} + $incr > $limits->{'max_ram'}) {
			&usage("Creating this system would exceed your memory ",
			       "limit of ",&nice_size($limits->{'max_ram'}));
			}
		}
	elsif (!$incr && $limits->{'max_ram'}) {
		# System has no RAM limits, but owner does
		&usage("You cannot create a system with unlimited memory as ",
		       "your limit is ",&nice_size($limits->{'max_ram'}));
		}

	# Validate CPU limit
	$cfunc = "type_".$type."_get_cpu_size";
	$incr = defined(&$cfunc) ? &$cfunc($server) : undef;
	if ($incr && $limits->{'max_cpu'}) {
		# May be over CPU limit
		if ($limits->{'cpu'} + $incr > $limits->{'max_cpu'}) {
			&usage("Creating this system would exceed your CPU ",
			       "limit of ",$limits->{'max_cpu'});
			}
		}
	elsif (!$incr && $limits->{'max_cpu'}) {
		# System has no CPU limit, but owner does
		&usage("You cannot create a system with unlimited CPU as ",
		       "your limit is ",$limits->{'max_cpu'});
		}

	# Validate IPs limit, assuming new system will have exactly 1
	$incr = scalar(split(/\s+/, $server->{'ip_addresses'})) || 1;
	if ($limits->{'max_ips'}) {
		if ($limits->{'ips'} + $incr > $limits->{'max_ips'}) {
			&usage("Creating this system would exceed your IP ",
			       "address limit of ",$limits->{'max_ips'});
			}
		}
	}

# Validate directory
$err = &validate_directory($server);
$err && &usage("--disk-directory is invalid : $err");

# Run pre-creation script
&run_system_script($server, 'before', 'create') || exit(2);
&obtain_lock_server($server);

# If there is an image file, copy to the server (if needed)
if ($img) {
	$vhost = &get_parent_server($server);
	print "Copying CD image file to host system $vhost->{'host'} ..\n";
	($imageok, $imagetemp, $imagehost) = &transfer_image_files($server);
	if ($imageok == 0) {
		print ".. failed : $imagetemp\n";
		exit(1);
		}
	else {
		$server->{'imagetemp'} = $imagetemp;
		$server->{'imagelocal'} = ($imageok != 1);
		$ih = $imagehost->{'host'};
		print $imageok == 1 ? " .. transferred from $ih\n\n" :
		      $imageok == 2 ? " .. already on host system\n\n" :
		      $imageok == 3 ? " .. already in host cache\n\n" :
				      " .. transferred from $ih, ".
				      "and added to host cache\n\n";
		}
	}

# Start the creation
$tfunc = "type_".$type."_desc";
$tdesc = &$tfunc();
print "Starting creation of empty $tdesc system ..\n";

# Call the server type's creation function, then wait for it to be come ready
$cfunc = "type_".$type."_create";
$err = &$cfunc($server, undef, undef, 0, 1);
if ($err) {
	$err = &strip_html_tags($err);
	print ".. creation failed : $err\n";
	exit(2);
	}

$dfunc = "type_".$type."_create_done";
if (defined(&$dfunc)) {
	print ".. creation started\n\n";
	print "Waiting for creation to complete ..\n";
	while(1) {
		$err = &$dfunc($server, 1);
		if ($err eq "OK") {
			last;
			}
		elsif ($err) {
			$err = &strip_html_tags($err);
			if ($imageok == 1) {
				&cleanup_image_files($server, $imagetemp);
				}
			print ".. creation failed : $err\n\n";
			exit(1);
			}
		sleep(1);
		}
	}
if ($imageok == 1) {
	&cleanup_image_files($server, $imagetemp);
	}
print ".. creation complete\n\n";
&complete_managed_server($server);
&save_managed_server($server);

# Add to system owner, either from command line or current user
if ($access{'owner'}) {
	# This user
	$owner = &get_system_owner($base_remote_user);
	}
if ($owner) {
	&grant_to_system_owner($owner, $server);
	}

# Remove old SSH keys for this system
&clear_ssh_host_key($server);
if ($vhost) {
	&clear_remote_ssh_host_key($server, $vhost);
	}

# Call any post-creation function
$dfunc = "type_".$type."_create_post";
if (defined(&$dfunc)) {
	&$dfunc($server, undef, undef, 0, 1);
	}

# Call any really final post-creation function
$dfunc = "type_".$type."_create_ready";
if (defined(&$dfunc)) {
	&$dfunc($server, undef, undef, 0, 1);
	}

# Re-check and save the status
print "Refreshing status ..\n";
&save_managed_server($server);
&check_server_status($server, 1);
&save_managed_server($server);
print ".. done ($server->{'status'})\n\n";

# Enable at boot time, if possible
$bfunc = "type_".$type."_set_atboot";
if (defined(&$bfunc) && $start_boot) {
	print "Enabling at hosting system boot ..\n";
	&$bfunc($server, 1);
	print ".. done\n\n";
	}

# Create console user
$cfunc = "type_".$type."_supports_console_login";
if (defined(&$cfunc)) {
	print "Creating console access user ..\n";
	$err = &create_console_user($server);
	&save_managed_server($server);
	print $err ? ".. creation failed : $err\n\n" : ".. done\n\n";
	}

# Run post-creation script
&run_system_script($server, 'after', 'create');
&release_lock_server($server);

print "Creation of empty $tdesc system $server->{'host'} is complete\n";
&cloudmin_api_log(\@OLDARGV);
exit(0);

sub usage
{
print @_,"\n\n" if ($_[0]);
print "Creates a new empty virtual system of some type.\n";
print "\n";
my $crtypes = join("|", @crtypes);
print "cloudmin create-empty-system --host name\n";
print "                             --type $crtypes\n" if ($crtypes);
print "                            [--desc \"system description\"]\n";
print "                            [--image id | --imagefile path]\n";
print "                            [--id number]\n";
print "                            [--disk-directory dir]\n";
print "                            [--start-at-boot | --no-start-at-boot]\n";
if (defined(&list_system_owners)) {
	print "                            [--owner name]\n";
	}
if ($type) {
	# Show type-specific command line args
	$afunc = "type_".$type."_create_args";
	if (defined(&$afunc)) {
		foreach $a (&$afunc(1)) {
			my ($o1, $o2) = $a->{'opt'} ? ("[", "]") : ( );
			print "                            ";
			if ($a->{'value'}) {
				print $o1,"--".$type."-".$a->{'name'}," ",$a->{'value'}.$o2;
				}
			else {
				print $o1,"--".$type."-".$a->{'name'},$o2;
				}
			print "\n";
			}
		}
	}
exit(1);
}

