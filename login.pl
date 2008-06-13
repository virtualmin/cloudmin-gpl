#!/usr/local/bin/perl
# This script is the shell for each system's special console user, and will
# connect to the console on the host system

$main::no_acl_check++;
require './server-manager-lib.pl';

# Work out server, based on username
($server) = grep { $_->{'console_user'} eq $ENV{'USER'} }
		 &list_managed_servers();
if (!$server) {
	print "Failed to find a VM2 managed system for $ENV{'USER'}\n";
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

# Turn off echo on STDIN
eval "use IO::Stty";
if (!$@) {
	IO::Stty::stty(\*STDIN, 'raw', '-echo');
	}

# Pass all input back and forth
select($fh); $| = 1; select(STDOUT);
$| = 1;
while(1) {
	$rmask = undef;
	vec($rmask, fileno(STDIN), 1) = 1;
	vec($rmask, fileno($fh), 1) = 1;
	local $sel = select($rmask, undef, undef, 0);
	if (vec($rmask, fileno(STDIN), 1)) {
		# Got something from SSH client
		my $buf;
		$ok = sysread(STDIN, $buf, 1024);
		last if ($ok <= 0);	# End of the client
		syswrite($fh, $buf, length($buf));
		}
	if (vec($rmask, fileno($fh), 1)) {
		# Got something from console
		my $buf;
		$ok = sysread($fh, $buf, 1024);
		last if ($ok <= 0);	# End of the client
		syswrite(STDOUT, $buf, length($buf));
		}
	}
print "Console connection closed\n";

