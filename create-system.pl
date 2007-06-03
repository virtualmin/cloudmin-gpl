#!/usr/local/bin/perl
# Creates a new virtual system of some type

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/create-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Get SSH keys
@keys = &list_ssh_keys();
&set_all_text_print();

# Work out possible creation types
foreach $t (@server_management_types) {
	$lfunc = "type_".$t."_create_links";
	if (defined(&$lfunc)) {
		foreach $l (&$lfunc()) {
			if ($l->{'create'}) {
				push(@crtypes, $t);
				}
			}
		}
	}
@crtypes || &usage("No system types are available for creation!");

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--type") {
		$type = shift(@ARGV);
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--desc") {
		$desc = shift(@ARGV);
		}
	elsif ($a eq "--ssh-key") {
		$ssh_key = shift(@ARGV);
		($key) = grep { $_->{'id'} eq $ssh_key } @keys;
		$key || &usage("No SSH key with ID $ssh_key found");
		}
	elsif ($a eq "--ssh-pass") {
		$ssh_pass = shift(@ARGV);
		}
	elsif ($a eq "--webmin") {
		$webmin_mode = 1;
		}
	elsif ($a eq "--webmin-pass") {
		$webmin_pass = shift(@ARGV);
		$webmin_mode = 2;
		}
	elsif ($a eq "--novirt") {
		$novirt = 1;
		}
	elsif ($a eq "--image") {
		$image = shift(@ARGV);
		}
	elsif ($a =~ /^\-\-([^\-]+)\-(\S+)$/) {
		# Type-specific option
		$typeargs{$1}->{$2} = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args
$type || &usage("Missing required --type parameter");
$hfunc = "type_".$type."_no_create_hostname";
if (!defined(&$hfunc) || !&$hfunc()) {
	$host || &usage("Missing required --host parameter");
	$host =~ /^[a-z0-9\.\-\_]+$/ || &usage("Invalid hostname");
	($clash) = grep { $_->{'host'} eq $host } @servers;
	$clash && &usage("A system with the same hostname already exists");
	}
$sfunc = "type_".$type."_no_ssh";
$no_ssh = defined(&$sfunc) && &$sfunc();
if (!$no_ssh) {
	$ssh_pass || $ssh_key ||
		&usage("One of --ssh-pass or --ssh-key must be given");
	}
$pfunc = "type_".$type."_no_create_pass";
if (defined(&$pfunc) && &$pfunc()) {
	$ssh_key || &usage("The specified system type can only use ".
			   "the --ssh-key parameter, not --ssh-pass");
	}
if (($no_ssh || !$ssh_pass) && $webmin_mode == 1) {
	&usage("--webmin-pass must be given to specify the Webmin password ".
	       "when no SSH password is available");
	}
if ($image) {
	# Validate image ID
	@images = &list_server_images($type);
	($img) = grep { $_->{'id'} eq $image } @images;
	$img || &usage("Image ID does not exist or in not valid for the ".
		       "specified system type");
	}

# Create initial server object
$server = { 'id' => time().$$,
	    'manager' => $type,
	    'type' => 'unknown',
	    'novirt' => $novirt,
	    'status' => 'create',
	    'image' => $image,
	  };
$server->{'desc'} = $desc;
if (!defined(&$hfunc) || !&$hfunc()) {
	$server->{'host'} = $host;
	}
if (!$no_ssh) {
	$server->{'ssh_user'} = 'root';
	if ($ssh_pass) {
		$server->{'ssh_pass'} = $ssh_pass;
		}
	else {
		$server->{'key'} = $ssh_key;
		}
	$server->{'ssh_protocol'} = 2;
	}
if ($webmin_mode == 1) {
	# Same as SSH root
	$server->{'user'} = $server->{'ssh_user'};
	$server->{'pass'} = $server->{'ssh_pass'};
	$server->{'ssh_pass_same'} = 1;
	}
elsif ($webmin_mode == 2) {
	# Password specified for Webmin root
	$server->{'user'} = 'root';
	$server->{'pass'} = $webmin_pass;
	}
if ($webmin_mode) {
	$server->{'port'} = 10000;
	}

# Call type-specific create parse function
$pfunc = "type_".$type."_create_args_parse";
if (defined(&$pfunc)) {
	$err = &$pfunc($typeargs{$type}, $server);
	&usage($err) if ($err);
	}

# If there is an image file, copy to the server
if ($image) {
	$img = &get_server_image($image);
	print "Copying system image files ..\n";
	($imageok, $imagetemp) = &transfer_image_files($server);
	if (!$imageok) {
		print ".. failed : $imagetemp\n";
		exit(1);
		}
	else {
		$server->{'imagetemp'} = $imagetemp;
		print " .. done\n\n";
		}
	}

# Start the creation
$tfunc = "type_".$type."_desc";
$tdesc = &$tfunc();
print "Starting creation of $tdesc system ..\n";

# Call the server type's creation function, then wait for it to be come ready
$cfunc = "type_".$type."_create";
$err = &$cfunc($server);
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
		$err = &$dfunc($server);
		if ($err eq "OK") {
			last;
			}
		elsif ($err) {
			$err = &strip_html_tags($err);
			&cleanup_image_files($server, $imagetemp);
			print ".. creation failed : $err\n\n";
			exit(1);
			}
		sleep(1);
		}
	}
&cleanup_image_files($server, $imagetemp);
print ".. creation complete\n\n";
&save_managed_server($server);

# Call any post-creation function
$dfunc = "type_".$type."_create_post";
if (defined(&$dfunc)) {
	&$dfunc($server);
	}

if (!$no_ssh) {
	# Wait at most 60 seconds for SSH to come up (indicating that booting
	# is done), if need be
	$bfunc = "type_".$type."_needs_boot";
	if (defined(&$bfunc) && &$bfunc($server)) {
		# Check in a loop until SSH is available
		print "Waiting for SSH server ..\n";
		$sshcount = 0;
		while(1) {
			($sshstatus, $ssherr, $webmindir, $webminport,
			 $webminssl) = &check_server_ssh_login($server);
			if ($sshstatus == 0) {
				print ".. SSH server ready\n\n";
				last;
				}
			elsif ($sshcount > 60) {
				print ".. SSH server took too long\n\n";
				last;
				}
			$sshcount++;
			sleep(1);
			}
		}
	}
if (!$webmindir) {
	# Just check once to get Webmin root, if any
	($sshstatus, $ssherr, $webmindir, $webminport, $webminssl) =
		&check_server_ssh_login($server);
	}

# Check if the server has Webmin (it may have been part of the install image)
if ($webmindir) {
	# Yes, it was setup as part of the server creation .. go with its
	# port and SSL settings
	$server->{'port'} = $webminport;
	$server->{'ssl'} = $webminssl;

	# Forcibly set the password
	$server->{'user'} ||= 'root';
	$server->{'pass'} ||= &generate_random_password();
	print "Setting Webmin password ..\n";
	$perr = &set_server_webmin_password($server, $webmindir, "root",
					    $server->{'pass'});
	if ($perr) {
		print ".. failed : $perr\n\n";
		}
	else {
		print ".. done\n\n";
		}
	}
elsif ($webmin_mode) {
	# Need to install Webmin
	local ($src, $type, $err) = &get_install_webmin_source($server);
	if (!$err) {
		print "Installing Webmin ..\n";
		($out, $err, $webmindir) =
			&install_webmin_server($server, $src, $type, 1);
		if ($err) {
			$server->{'user'} = undef;	# No webmin
			$server->{'pass'} = undef;
			print ".. Webmin install failed : $err\n\n";
			}
		else {
			print ".. done\n\n";
			}
		}
	}

# If we do have Webmin, wait for it to start
if ($webmindir) {
	print "Waiting for Webmin to start ..\n";
	$err = &wait_webmin_server($server, 60);
	if (!$err) {
		print ".. started OK\n\n";
		}
	else {
		print ".. did not start in 60 seconds. Last error was : $err\n\n";
		}
	}

# Re-check and save the status
print "Refreshing status ..\n";
&save_managed_server($server);
&check_server_status($server);
&save_managed_server($server);
print ".. done\n\n";

# If the server has Virtualmin, do a config check
if ($server->{'status'} eq 'virt') {
	print "Checking Virtualmin configuration ..\n";
	&check_virtualmin_config($server);
	if ($server->{'virtualmin_checked'}) {
		print ".. done\n\n";
		}
	else {
		print ".. configuration problems found\n\n";
		}
	&save_managed_server($server);
	}

# Enable at boot time, if possible
$bfunc = "type_".$type."_set_atboot";
if (defined(&$bfunc)) {
	print "Enabling at hosting system boot ..\n";
	&$bfunc($server, 1);
	print ".. done\n\n";
	}

print "Creation of $tdesc system $server->{'host'} is complete\n";
exit(0);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new virtual system of some type.\n";
print "\n";
local $crtypes = join("|", @crtypes);
print "usage: create-systems.pl --host name\n";
print "                         --type $crtypes\n" if ($crtypes);
print "                         [--desc \"system description\"]\n";
print "                         --ssh-key keyid | --ssh-pass password\n";
print "                         [--webmin | --webmin-pass password]\n";
print "                         [--novirt]\n";
print "                         [--image id]\n";
if ($type) {
	# Show type-specific command line args
	$afunc = "type_".$type."_create_args";
	if (defined(&$afunc)) {
		foreach $a (&$afunc()) {
			local ($o1, $o2) = $a->{'opt'} ? ("[", "]") : ( );
			print "                         ";
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

