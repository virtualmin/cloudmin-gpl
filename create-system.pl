#!/usr/local/bin/perl

=head1 create-system.pl

Creates a new virtual system of some type

This command takes different parameters depending on the type of virtual
system being created, but the following are always required :

C<--host> I<hostname> A short hostname for the system to create, which will also be used as the Xen or VServers instance name.
C<--desc> I<description> A human-readable name for the system, which you will typically have to quote.
C<--type> I<code> The virtualization type code, like ''xen'' , ''zones''  or ''vservers''
C<--ssh-pass> I<password> The initial root password for the new system.

For a virtual system, you will need to specify the host system to create it
on, using the C<--xen-host>, C<--vservers-host> or C<--zones-host> parameter.
If the system is to be created from an image, you will need to select it with
the C<--image> parameter, followed by an image ID. To see the full list of
available and required options for a particular system type, run
C<create-system.pl> with the C<--type> and C<--help> flags.

If you are creating a system from an image that includes Virtualmin Pro, you
will need to specify a license using either the C<--allocate-serial> parameter,
or C<--serial> and C<--key>. The former will select an available license from
the pool of those registered with Cloudmin, while the latter let you specify a
serial number and key explicity. 

=head1 Example usage

  cloudmin create-system --host xennoupdate --type xen --desc "Test without updates" --ssh-pass smeg  --no-update --xen-host sentosa.home --xen-memory 512 --image xen-centos5.0-virtualmin --allocate-serial
  Copying system image files ..
   .. done
  Starting creation of Xen system ..
  .. creation started
  Waiting for creation to complete ..
  .. creation complete
  Mounting new instance's filesystem ..
  .. mounted on /mnt/xen-xennoupdate
  Copying modules for kernel 2.6.18-8.1.4.el5xen to Xen filesystem ..
  .. done
  Setting root password ..
  .. done
  Updating configuration files with hostname and IP address ..
  .. done
  Updating network configuration files ..
  .. done
  Updating Virtualmin licence files ..
  .. done
  Allowing SSH logins by root ..
  .. already allowed
  Un-mounting instance's filesystem ..
  .. done
  Adding DNS entry xennoupdate.home. for IP address 193.9.101.245 ..
  .. done
  Starting up new Xen instance ..
  .. done
  Setting Webmin password ..
  .. done
  Waiting for Webmin to start ..
  .. started OK
  Refreshing status ..
  .. done
  Checking Virtualmin configuration ..
  .. done
  Enabling at hosting system boot ..
  .. done
  Creation of Xen system xennoupdate.home is complete

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
$0 = "$pwd/create-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

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
	elsif ($a eq "--ssh-key") {
		$ssh_key = shift(@ARGV);
		($key) = grep { $_->{'id'} eq $ssh_key } @keys;
		$key || &usage("No SSH key with ID $ssh_key found");
		$key->{'public'} && &usage("The SSH key with ID $ssh_key is a public key only");
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
	elsif ($a eq "--no-update") {
		$noupdate = 1;
		}
	elsif ($a eq "--id") {
		$newid = shift(@ARGV);
		}
	elsif ($a eq "--owner") {
		$ownername = shift(@ARGV);
		$owner = &get_system_owner($ownername);
		$owner || &usage("No system owner named $ownername exists");
		}
	elsif ($a eq "--serial") { $serial = shift(@ARGV); }
	elsif ($a eq "--key") { $key = shift(@ARGV); }
	elsif ($a eq "--same-serial") { $same_serial = 1; }
	elsif ($a eq "--allocate-serial") { $allocate_serial = 1; }
	elsif ($a eq "--no-check-serial") { $nocheck_serial = 1; }
	elsif ($a =~ /^\-\-([^\-]+)\-(\S+)$/) {
		# Type-specific option
		$typeargs{$1}->{$2} = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args
@servers = &list_managed_servers();
$type || &usage("Missing required --type parameter");
$hfunc = "type_".$type."_no_create_hostname";
if (!defined(&$hfunc) || !&$hfunc()) {
	$host || &usage("Missing required --host parameter");
	$host =~ /^[a-z0-9\.\-]+$/ || &usage("Invalid hostname");
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
$ifunc = "type_".$type."_must_image";
if (defined(&$ifunc) && &$ifunc($server) && !$image) {
	&usage("The --image parameter must be given for this system type");
	}
if ($image) {
	# Validate image ID
	@images = &list_server_images($type);
	($img) = grep { $_->{'id'} eq $image } @images;
	$img || &usage("Image ID does not exist or in not valid for the ".
		       "specified system type");
	}

# Check if can create
($can, $canerr) = &can_create_server($type);
$can || &usage("Creation is not allowed : $canerr");

# Work out serial and key
if ($same_serial) {
	($serial, $key) = &get_server_manager_serial();
	}
elsif ($allocate_serial) {
	($serial, $key) = &allocate_virtualmin_serial(0);
	$serial || &usage($key);
	}
elsif ($serial && !$nocheck_serial) {
	$tok = &check_virtualmin_serial($serial, $key);
	$tok || &usage("Serial $serial or key $key is not valid");
	$tok > 0 || &usage("Could not validate serial number and key");
	}

# Create initial server object
$server = { 'id' => $newid || &server_id(),
	    'manager' => $type,
	    'type' => 'unknown',
	    'novirt' => $novirt,
	    'status' => 'create',
	    'image' => $image,
	    'bw_limit' => $config{'bw_def'},
	    'created' => time(),
	  };
$server->{'desc'} = $desc;
if ($image && $img->{'type'}) {
	$server->{'type'} = $img->{'type'};
	}
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

# Check for hostname clash again, as the parse may have changed it
if ($server->{'host'}) {
	($clash) = grep { $_->{'host'} eq $server->{'host'} } @servers;
	$clash && &usage("A system with the same hostname already exists");
	}

# Make sure a serial is given if needed
if (!$serial && !$key) {
	if ($image) {
		$img->{'virtualmin'} eq 'pro' &&
			&usage("A Virtualmin license must be specified when ".
			       "creating from an image that includes it");
		}
	$vfunc = "type_".$type."_will_virtualmin";
	if (defined(&$vfunc) && &$vfunc($server)) {
		&usage("A Virtualmin license must be specified when ".
		       "creating from an image that includes it");
		}
	}

# Run pre-creation script
&run_system_script($server, 'before', 'create') || exit(2);
&obtain_lock_server($server);

if ($serial) {
	# Mark this key as in-use
	&start_installing_virtualmin_licence($serial, $key);
	}

# If there is an image file, copy to the server (if needed)
if ($image) {
	$img = &get_server_image($image);
	$vhost = &get_parent_server($server);
	print "Copying system image files to host system $vhost->{'host'} ..\n";
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
print "Starting creation of $tdesc system ..\n";

# Call the server type's creation function, then wait for it to be come ready
$cfunc = "type_".$type."_create";
$err = &$cfunc($server, $serial, $key);
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

# Add to system owner
if ($owner) {
	$owner->{'acl'}->{'servers'} =
		join(' ', split(/\s+/, $owner->{'acl'}->{'servers'}),
			  $server->{'id'});
	&save_system_owner($owner, $owner);
	}

# Remove old SSH keys for this system
&clear_ssh_host_key($server);

# Call any post-creation function
$dfunc = "type_".$type."_create_post";
if (defined(&$dfunc)) {
	&$dfunc($server, $serial, $key);
	}

if (!$no_ssh) {
	# Wait at most 120 seconds for SSH to come up (indicating that booting
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
			elsif ($sshcount > 120) {
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
	$server->{'pass'} ||= $server->{'ssh_pass'};
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

	# Start Webmin in case it hasn't been
	&execute_command_on_server($server,
		"/etc/webmin/start >/dev/null 2>&1 </dev/null &");
	}
elsif ($webmin_mode) {
	# Need to install Webmin
	my ($src, $type, $err) = &get_install_webmin_source($server);
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

# Call any really final post-creation function
$dfunc = "type_".$type."_create_ready";
if (defined(&$dfunc)) {
	&$dfunc($server, $serial, $key);
	}

# Re-check and save the status
print "Refreshing status ..\n";
&save_managed_server($server);
&check_server_status($server, 1);
&save_managed_server($server);
print ".. done ($server->{'status'})\n\n";

# Enable Webmin status collection
if ($server->{'status'} eq 'novirt') {
	print "Enabling background status collection ..\n";
	$err = &enable_webmin_status_collection($server);
	if ($err) {
		print ".. failed : $err\n\n";
		}
	else {
		print ".. done\n\n";
		}
	}

if ($serial) {
	# Key is no longer in progress
	&stop_installing_virtualmin_licence($serial, $key);
	}

# If the server has Virtualmin, update all Virtualmin packages
if ($server->{'status'} eq 'virt' && !$noupdate) {
	&update_virtualmin_packages($server);
	}

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

# If the system has Virtualmin, update any domains on the old default IP
if ($server->{'status'} eq 'virt') {
	@doms = &get_server_domains($server);
	if (@doms) {
		print "Updating IPs in Virtualmin domains ..\n";
		$err = &update_virtualmin_ips($server);
		if ($err) {
			print ".. failed : $err\n\n";
			}
		else {
			print ".. done\n\n";
			}
		}
	}

# Enable at boot time, if possible
$bfunc = "type_".$type."_set_atboot";
if (defined(&$bfunc)) {
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

# Enable package management
if ($config{'packages_def'} && ($server->{'status'} eq 'virt' ||
			        $server->{'status'} eq 'novirt')) {
	print "Enabling software package management ..\n";
	$err = &save_server_cluster_software($server, 1);
	print $err ? ".. failed : $err\n\n" : ".. done\n\n";
	}

# Run post-creation script
&run_system_script($server, 'after', 'create');
&release_lock_server($server);

print "Creation of $tdesc system $server->{'host'} is complete\n";
&cloudmin_api_log(\@OLDARGV);
exit(0);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new virtual system of some type.\n";
print "\n";
my $crtypes = join("|", @crtypes);
print "cloudmin create-system --host name\n";
print "                       --type $crtypes\n" if ($crtypes);
print "                      [--desc \"system description\"]\n";
print "                       --ssh-key keyid | --ssh-pass password\n";
print "                      [--webmin | --webmin-pass password]\n";
print "                      [--novirt]\n";
print "                      [--image id]\n";
print "                      [--no-update]\n";
print "                      [--serial number --key number] |\n";
print "                      [--same-serial] | [--allocate-serial]\n";
print "                      [--no-check-serial]\n";
print "                      [--id number]\n";
if (defined(&list_system_owners)) {
	print "                      [--owner name]\n";
	}
if ($type) {
	# Show type-specific command line args
	$afunc = "type_".$type."_create_args";
	if (defined(&$afunc)) {
		foreach $a (&$afunc()) {
			my ($o1, $o2) = $a->{'opt'} ? ("[", "]") : ( );
			print "                      ";
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

