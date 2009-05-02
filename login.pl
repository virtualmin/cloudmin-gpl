#!/usr/local/bin/perl
# This script is the shell for each system's special console user, and will
# connect to the console on the host system

$main::no_acl_check++;
require './server-manager-lib.pl';

# Work out server, based on username
($server) = grep { $_->{'login_user'} eq $ENV{'USER'} }
		 &list_managed_servers();
if (!$server) {
	print "Failed to find a Cloudmin managed system for $ENV{'USER'}\n";
	exit(1);
	}

# SSH to the host system, and run the console command
$cfunc = "type_".$server->{'manager'}."_console_command";
$cmd = &$cfunc($server);
$vhost = &get_parent_server($server);
($out, $ex, $err, $status, $fh, $fpid) =
	&execute_command_on_server($vhost, $cmd, 0, 1);
if ($err) {
	print "Failed to connect to console : $err\n";
	exit(2);
	}
elsif ($ex) {
	print "Failed to connect to console : $out\n";
	exit(2);
	}
print "Connected to console of $server->{'host'} ..\n\n";
&forward_console_data($fh);
print "Console connection closed\n";

