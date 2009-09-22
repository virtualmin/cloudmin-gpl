#!/usr/local/bin/perl
# Clear the SSH host key on the Cloudmin master for some system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});

&clear_ssh_host_key($server);
&check_server_status($server);
&save_managed_server($server);
&webmin_log("hostkey", "server", $server->{'host'});
&redirect("edit_serv.cgi?id=$server->{'id'}");

