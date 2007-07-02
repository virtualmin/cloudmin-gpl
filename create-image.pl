#!/usr/local/bin/perl
# Packages an existing system up as an image

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/create-image.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--desc") {
		$desc = shift(@ARGV);
		}
	elsif ($a eq "--id") {
		$id = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args
$host || &usage("Missing --host parameter");
$desc || &usage("Missing --desc parameter");
$id || &usage("Missing --id parameter");

# Get the server to image
($server) = grep { $_->{'host'} eq $host } &list_managed_servers();
$server || &usage("No server with hostname $host was found");
$nfunc = "type_".$server->{'manager'}."_no_image";
if (defined(&$nfunc) && &$nfunc($server)) {
	&usage("The selected server type cannot be converted to an image");
	}
if ($server->{'status'} eq 'nohost') {
	&usage("A server whose host system is down cannot be imaged");
	}
($clash) = grep { $_->{'id'} eq $id } &list_server_images();
$clash && &usage("An image with the ID $id already exists");

# Create initial image hash
$image = { 'id' => $id,
	   'desc' => $desc,
	   'manager' => $server->{'manager'} };

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
if (!&$ifunc($server, $image, $temp)) {
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

	# Save the new image file
	&save_server_image($image);
	}

# Cleanup the image on the host
$ifunc = "type_".$server->{'manager'}."_cleanup_image";
if (!&$ifunc($server, $image, $temp)) {
	exit(3);
	}

if ($shutdown) {
	&$first_print("Starting up system ..");
	$err = &startup_server($server);
	if ($err) {
		&$second_print(".. startup failed : $err");
		exit(4);
		}
	else {
		&$second_print(".. done");
		}

	# Re-check status
	&$first_print("Refreshing system status ..");
	&check_server_status($server);
	&save_managed_server($server);
	&$second_print(".. done");
	}

# Exit if image transfer failed, but only after cleanup is done
if ($err) {
	exit(5);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Converts an existing virtual system into an image.\n";
print "\n";
print "usage: create-image.pl --host name\n";
print "                       --desc \"image description\"\n";
print "                       --id image-id\n";
exit(1);
}

