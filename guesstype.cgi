#!/usr/local/bin/perl
# Guess the type of some virtual system

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "edit");

$guess = &guess_os_type($server);
if ($guess) {
	$server->{'type'} = $guess;
	&check_server_status($server);
	&save_managed_server($server);
	}
&webmin_log("guesstype", "server", $server->{'host'});

&redirect("edit_serv.cgi?id=$server->{'id'}&refresh=1");

