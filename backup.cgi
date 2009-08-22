#!/usr/local/bin/perl
# Execute one backup and show output

require './server-manager-lib.pl';
&error_setup($text{'brun_err'});
&can_action_error(undef, "backup");
&ReadParse();
($backup) = grep { $_->{'id'} eq $in{'id'} } &list_available_backups();
$backup || &error($text{'backup_egone'});
&obtain_lock_anything();

# Make sure this backup can be run
if ($access{'owner'}) {
	$backup->{'owner'} eq $base_remote_user ||
		&error($text{'brun_ecannot'});
	}
@servers = &get_backup_servers($backup);
foreach $s (@servers) {
	&can_action_error($s, "backup");
	}

&ui_print_unbuffered_header(undef, $text{'brun_title'}, "");

# Show systems and destination
if ($backup->{'dest'}) {
	print "<b>",&text('brun_destdesc', scalar(@servers),
		    &nice_backup_destination($backup->{'dest'})),"</b><p>\n";
	}
else {
	print "<b>",&text('brun_destdesc2', scalar(@servers)),"</b><p>\n";
	}

# Execute it, and show output
&$indent_print();
$rv = &execute_backup($backup);
&$outdent_print();

# Print a summary line
@ok = grep { $rv->{$_->{'id'}} &&
	     $rv->{$_->{'id'}}->{'ok'} } @servers;
if (scalar(@ok) == scalar(@servers)) {
	print "<b>",&text('brun_allok', scalar(@ok)),"</b><p>\n";
	}
else {
	print "<b><font color=red>",
	      &text('brun_somefailed', scalar(@ok),
		    scalar(@servers)-scalar(@ok)),"</font></b><p>\n";
	}

&ui_print_footer("list_backups.cgi", $text{'backups_return'});
