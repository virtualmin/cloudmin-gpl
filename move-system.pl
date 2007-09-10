#!/usr/local/bin/perl
# Moves a virtual system to another host, by imaging it and copying across
# the image file
# XXX need to update DNS
# XXX don't allow transfer to self
# XXX new system must support same virtual type!

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/move-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--dest") {
		$dest = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args
$host || &usage("Missing --host parameter");
$dest || &usage("Missing --dest parameter");

# Get the server to image
($server) = grep { $_->{'host'} eq $host } &list_managed_servers();
$server || &usage("No system with hostname $host was found");
$nfunc = "type_".$server->{'manager'}."_no_image";
if (defined(&$nfunc) && &$nfunc($server)) {
	&usage("The selected system type cannot be converted to an image ".
	       "for moving");
	}
if ($server->{'status'} eq 'nohost') {
	&usage("A system whose host system is down cannot be moved");
	}
($destserver) = grep { $_->{'host'} eq $dest } &list_managed_servers();
$destserver || &usage("No system with hostname $host was found");

# Create a fake image hash, for use by functions
$image = { 'id' => time().".move",
	   'manager' => $server->{'manager'},
	 };

# Select temp dir for image on parent host
&$first_print("Creating temporary directory for image files ..");
$pfunc = "type_".$server->{'manager'}."_parent";
$vhost = &$pfunc($server);
($tempok, $temp) = &create_image_files_tempdir($vhost, $image->{'id'});
if (!$tempok) {
	&$second_print(".. failed : $temp");
	exit(3);
	}
else {
	&$second_print(".. done");
	}

$sfunc = "type_".$server->{'manager'}."_no_shutdown";
$noshut = defined(&$sfunc) && &$sfunc($server);
if ($server->{'status'} ne 'down' && !$noshut) {
	# Shut it down
	&$first_print("Shutting down system ..");
	$err = &shutdown_server($server);
	if ($err) {
		&$second_print(".. shutdown failed : $err");
		exit(2);
		}
	else {
		&$second_print(".. done");
		}
	$server->{'status'} = 'down';
	&save_managed_server($server);
	$shutdown = 1;
	}

# Convert the remote system into an image file - this will output progress
$ifunc = "type_".$server->{'manager'}."_create_image";
if (!&$ifunc($server, $image, $temp, 1)) {
	exit(3);
	}

# Transfer the image file to the master
&$first_print("Fetching image files from host ..");
$err = &fetch_image_files($vhost, $image, $temp, 0);
if ($err) {
	&$second_print(".. failed : $err");
	}
else {
	&$second_print(".. fetched all files");
	}

# Cleanup the image on the old host
$ifunc = "type_".$server->{'manager'}."_cleanup_image";
if (!&$ifunc($server, $image, $temp)) {
	exit(3);
	}

# Exit if image transfer failed, but only after cleanup is done
if ($err) {
	exit(5);
	}

# Transfer the image to the new host system
# XXX

# Delete the old system
# XXX

# Create the new system
# XXX populate $newserver

&$first_print("Starting up system ..");
$err = &startup_server($newserver);
if ($err) {
	&$second_print(".. startup failed : $err");
	exit(4);
	}
else {
	&$second_print(".. done");
	}

# Re-check status
&$first_print("Refreshing system status ..");
&check_server_status($newserver);
&save_managed_server($newserver);
&$second_print(".. done");

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Moves a virtual system from one host to another.\n";
print "\n";
print "usage: move-system.pl --host name\n";
print "                      --dest new-host-system-name\n";
print "                      [--direct]\n";
exit(1);
}

