#!/usr/local/bin/perl
# Either update the details of some server, or perform some action

require './server-manager-lib.pl';
&error_if_cloudmin_replica();
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
$t = $server->{'manager'};
$oldserver = { %$server };

# Validate inputs, and save details
&error_setup($text{'save_err'});
&can_action($server, "view");
&obtain_lock_server($server);

if ($server->{'id'} != 0) {
	$server->{'desc'} = $in{'desc'};
	}

&save_managed_server($server);
&release_lock_server($server);
&webmin_log("modify", "server", $server->{'host'});
&redirect("index.cgi?refresh=$server->{'id'}");
