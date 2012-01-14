#!/usr/local/bin/perl
# Update the default image directory for disks

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "disks");
$vhost = &get_parent_server($server);
&obtain_lock_server($server);

# Save disk directory
if ($server->{'new_directory'} ne $in{'directory'}) {
	$server->{'new_directory'} = $in{'directory'};
	if ($server->{'directory'} ne '') {
		$err = &validate_directory($server, undef, 'new_directory');
		&error($err) if ($err);
		}
	}

&save_managed_server($server);
&release_lock_server($server);
&webmin_log("diskdir", "server", $server->{'host'});
&redirect("list_disks.cgi?id=$in{'id'}");

