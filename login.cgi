#!/usr/local/bin/perl
# Show an SSH applet for logging into a system's console, or root SSH

require './server-manager-lib.pl';
&ReadParse();
use Socket;
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
&can_action_error($server, "console");
&ui_print_header(&server_in($server),
	 $in{'shell'} ? $text{'login_title'} : $text{'login_title2'}, "");

# Check for python
$python = &has_command("python");
if (!$python) {
        &ui_print_endpage(&text('login_epython', "<tt>python</tt>"));
        }

# Setup user if needed
if (!$in{'shell'}) {
	$clfunc = "type_".$server->{'manager'}."_supports_console_login";
	$ok = &$clfunc($server);
	if ($ok < 0) {
	       $err = &create_console_user($server);
	       $err && &error(&text('login_euser', $err));
	       &save_managed_server($server);
	       }
	}

# Pick a free port
&get_miniserv_config(\%miniserv);
$port = $miniserv{'port'} + 1;
$proto = getprotobyname('tcp');
socket(TEST, PF_INET, SOCK_STREAM, $proto) ||
        &error("Socket failed : $!");
setsockopt(TEST, SOL_SOCKET, SO_REUSEADDR, pack("l", 1));
while(1) {
        last if (bind(TEST, sockaddr_in($port, INADDR_ANY)));
        $port++;
        }
close(TEST);

# Run the Ajaxterm webserver
$pid = fork();
if (!$pid) {
        chdir("$module_root_directory/ajaxterm");
        untie(*STDIN); open(STDIN, "</dev/null");
        untie(*STDOUT); open(STDOUT, ">/dev/null");
        untie(*STDERR); open(STDERR, ">/dev/null");
	$cmd = $in{'shell'} ? "shell-system.pl" : "login-system.pl";
        exec($python, "ajaxterm.py", "--port", $port, "--log",
		      "--command", "$module_root_directory/$cmd --host $server->{'host'}");
        exit(1);
        }

# Wait for it to come up
$try = 0;
while(1) {
        my $err;
        &open_socket("localhost", $port, TEST2, \$err);
        last if (!$err);
        $try++;
        if ($try > 30) {
                &error(&text('login_estart', 30, $port));
                }
        sleep(1);
        }
close(TEST2);

# Record owner of this login
$statusdir = $ENV{'WEBMIN_VAR'}."/".$module_name."-login";
if (!-d $statusdir) {
	&make_dir($statusdir, 0700);
	}
$statusfile = "$statusdir/$port";
&open_tempfile(STATUS, ">$statusfile");
&print_tempfile(STATUS, $remote_user,"\n");
&close_tempfile(STATUS);

# Show the iframe
print "<center>\n";
print "<iframe src=proxy.cgi/$port/ ",
      "width=700 height=500 frameborder=0></iframe><br>\n";
print "<input type=button onClick='window.open(\"proxy.cgi/$port/\", \"ajaxterm\", \"toolbar=no,menubar=no,scrollbars=no,resizable=yes,width=700,height=500\")' value='$text{'login_popup'}'><p>\n";

# Fork process that checks for inactivity
if (!fork()) {
	untie(*STDIN); close(STDIN);
	untie(*STDOUT); close(STDOUT);
	untie(*STDERR); close(STDERR);
	while(1) {
		my @st = stat($statusfile);
		if (@st && time() - $st[9] > $config{'login_timeout'}) {
			# No activity
			last;
			}
		if (!kill(0, $pid)) {
			# Dead
			last;
			}
		sleep(10);
		}
	unlink($statusfile);
	kill('KILL', $pid);
	exit(0);
	}

# Show message about how to do direct login
if ($server->{'login_user'} && !$in{'shell'}) {
	print &ui_hidden_start($text{'login_instr'}, 'instr', 0);
	($host, $sshport, $protos) = &get_ssh_host_port();
	print &text('login_desc', $ENV{'SERVER_NAME'}, $sshport,
		    $server->{'login_user'}, $server->{'login_pass'}),"<p>\n";
	print "<pre>",
	      "ssh $server->{'login_user'}\@$ENV{'SERVER_NAME'}",
	      "</pre>";
	print &ui_hidden_end('instr');
	}
print "</center>\n";

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
