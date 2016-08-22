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

if ($in{'bg'}) {
	# Launch it in the background
	&system_logged("$backup_cron_cmd --id $backup->{'id'} >/dev/null 2>&1 </dev/null &");
	print "<b>$text{'brun_background'}</b><p>\n";
	}
else {
	# Execute it, and show output
	&$indent_print();
	$rv = &execute_backup($backup);
	&$outdent_print();

	# Print a summary line
	@ok = grep { $rv->{$_->{'id'}} &&
		     ($rv->{$_->{'id'}}->{'ok'} ||
		      $rv->{$_->{'id'}}->{'empty'}) } @servers;
	@bad = grep { !$rv->{$_->{'id'}} ||
		      !($rv->{$_->{'id'}}->{'ok'} ||
			$rv->{$_->{'id'}}->{'empty'}) } @servers;
	if (scalar(@ok) == scalar(@servers)) {
		print "<b>",&text('brun_allok', scalar(@ok)),"</b><p>\n";
		}
	else {
		print "<b><font color=red>",
		      &text('brun_somefailed', scalar(@ok), scalar(@bad)),
		      "</font></b><p>\n";
		}

	# Show failure reasons
	print "<table>\n";
	foreach $s (@bad) {
		print "<tr> <td>$s->{'host'}</td> <td>:</td> <td>$rv->{$s->{'id'}}->{'msg'}</td> </tr>\n";
		}
	print "</table>\n";
	}

&webmin_log("backup", "backup", $backup->{'id'},
	    { 'dest' => $backup->{'dest'},
	      'host' => join(' ', map { $_->{'host'} } @servers) });

&ui_print_footer("list_backups.cgi", $text{'backups_return'});
