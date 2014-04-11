#!/usr/local/bin/perl
# Find files under some directory on a remote system

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

print "Content-type: text/plain\n\n";
if (!&can_ssh_status($server)) {
	print $text{'filemanager_esearch'},"\n";
	return;
	}
$err = &temp_mount_filesystem_if_needed($server);
if ($err) {
	print $err,"\n";
	return;
	}

# Build up a find command
$in{'dir'} =~ s/^\/+/\//g;
if ($in{'dir'} ne '/') {
	$in{'dir'} =~ s/\/$//;
	}
$cmd = "find ".quotemeta($in{'dir'})." -name ".quotemeta($in{'match'});
if ($in{'type'}) {
	$cmd .= " -type ".quotemeta($in{'type'});
	}
if ($in{'user'}) {
	$cmd .= " -user ".quotemeta($in{'user'});
	}
if ($in{'group'}) {
	$cmd .= " -group ".quotemeta($in{'group'});
	}
if ($in{'size'}) {
	$cmd .= " -size ".quotemeta($in{'size'});
	}
if ($in{'xdev'}) {
	$cmd .= " -mount";
	}

# Add grep for some text pattern
if ($in{'cont'}) {
	$cmd .= " | xargs fgrep -l ".quotemeta($in{'cont'});
	}

# Run it on the remote system
($out, $ex, $err) = &execute_command_on_server($server, $cmd);
if ($err) {
	print $err,"\n";
	}
elsif ($ex) {
	print $out,"\n";
	}
else {
	print "\n";
	foreach my $f (split(/\r?\n/, $out)) {
		$fil = &file_info_line($server, $f);
		print $fil,"\n" if ($fil);
		}
	}
