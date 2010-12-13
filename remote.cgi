#!/usr/local/bin/perl
# This program is designed to be called via HTTP requests from programs, and
# simply passes on parameters to a specified command-line program

package server_manager;
$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();

if (!$in{'program'}) {
	# Tell the user what needs to be done
	print "Content-type: text/plain\n\n";
	print "This CGI is designed to be invoked by other programs wanting\n";
	print "to perform some Cloudmin action programatically, such as\n";
	print "creating or modifying systems and domains.\n\n";

	print "You must supply at least the CGI parameter 'program', which\n";
	print "specifies which of the Cloudmin command-line scripts to\n";
	print "run. You must also supply appropriate parameters to the\n";
	print "program, similar to those that it accepts on the Unix command\n";
	print "line. For example, to reboot a system you would use a URL\n";
	print "like :\n";

	print "http://yourserver:10000/server-manager/remote.cgi?program=shutdown-system&host=xenbox1\n\n";
	
	print "All output from the command will be returned to the caller.\n";
	exit;
	}
elsif (!&can_action(undef, "api")) {
	print "Content-type: text/plain\n\n";
	print "You are not allowed to call the remote API.\n";
	exit(0);
	}

# Get output format
$format = defined($in{'json'}) ? 'json' :
	  defined($in{'xml'}) ? 'xml' :
	  defined($in{'perl'}) ? 'perl' :
		undef;

# Prevent executed programs from doing referer checks
delete($ENV{'MINISERV_CONFIG'});

# Run the program
$main::virtualmin_remote_api = 1;
$ENV{'VIRTUALMIN_REMOTE_API'} = 1;
$in{'program'} =~ /^[a-z0-9\.-]+$/i || &error($text{'remote_eprogram'});
$cmd = $dir = undef;
foreach $m ($module_name, @plugins) {
	$mdir = &module_root_directory($m);
	$mcmd = "$mdir/$in{'program'}.pl";
	if (-x $mcmd) {
		$cmd = $mcmd;
		$dir = $mdir;
		}
	}
if (!$cmd) {
	print "Content-type: text/plain\n\n";
	print "Remote program $in{'program'} does not exist\n";
	exit(0);
	}
foreach $i (keys %in) {
	next if ($i eq "program" || $i eq $format);
	if ($in{$i} eq "") {
		$cmd .= " --".quotemeta($i);
		}
	else {
		foreach $v (split(/\0/, $in{$i})) {
			$cmd .= " --".quotemeta($i)." ".quotemeta($v);
			}
		}
	}
print "Content-type: text/plain\n\n";
$remote_addr = $ENV{'REMOTE_ADDR'} || &to_ipaddress($ENV{'REMOTE_HOST'});
$remote_host = $ENV{'REMOTE_HOST'};
if ($format) {
	# Convert to selected format
	$err = &check_remote_format($format);
	if ($err) {
		print "Invalid format $format : $err\n";
		exit(0);
		}
	&clean_environment();
	$ENV{'REMOTE_USER'} = $remote_user;
	$ENV{'REMOTE_ADDR'} = $remote_addr;
	$ENV{'REMOTE_HOST'} = $remote_host;
	$out = &backquote_command("$cmd 2>&1");
	&reset_environment();
	print &convert_remote_format($out, $?, $in{'program'}, \%in, $format);
	}
else {
	# Stream output directly
	&clean_environment();
	$ENV{'REMOTE_USER'} = $remote_user;
	$ENV{'REMOTE_ADDR'} = $remote_addr;
	$ENV{'REMOTE_HOST'} = $remote_host;
	&open_execute_command(OUT, "$cmd 2>&1", 1);
	while(<OUT>) {
		print $_;
		}
	close(OUT);
	print "\n";
	print "Exit status: $?\n";
	&reset_environment();
	}

