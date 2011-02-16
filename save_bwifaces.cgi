#!/usr/local/bin/perl
# Change the interfaces for which bandwidth collection is done

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'ifaces_bwerr'});
&error_if_cloudmin_replica();

# Get the server and check support
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "ifaces");
&can_action_error($server, "bw");
&obtain_lock_server($server);

# Validate and store config
if ($in{'bw_all'}) {
	delete($server->{'bw_ifaces'});
	}
else {
	@ifaces = split(/\0/, $in{'bw_ifaces'});
	@ifaces || &error($text{'ifaces_bwnone'});
	$server->{'bw_ifaces'} = join(" ", @ifaces);
	}

&save_managed_server($server);
&release_lock_server($server);
&webmin_log("bwifaces", "server", $server->{'host'},
            { 'ifaces' => $server->{'bw_ifaces'} });

&redirect("list_ifaces.cgi?id=$in{'id'}&refresh=1");

