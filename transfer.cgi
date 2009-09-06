#!/usr/local/bin/perl
# Transfer a file from one Cloudmin system to another

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'transfer_err'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

# Validate inputs
$in{'source'} =~ /^\/\S/ || &error($text{'transfer_esource'});
$dest = &get_managed_server($in{'destid'});
$dest || &error($text{'transfer_edest'});
&can_action_error($dest, "transfer");
$in{'dest_def'} || $in{'dest'} =~ /^\/\S/ || &error($text{'transfer_edest2'});

&ui_print_unbuffered_header(&server_in($server),
			    $text{'transfer_title2'}, "");

# Do it
$in{'dest'} = $in{'source'} if ($in{'dest_def'});
print &text('transfer_done', "<tt>$in{'source'}</tt>",
			     "<tt>$server->{'host'}</tt>",
			     "<tt>$in{'dest'}</tt>",
			     "<tt>$dest->{'host'}</tt>"),"<br>\n";
$err = &transfer_file_between_servers($server, $dest,
				      $in{'source'}, $in{'dest'});
if ($err) {
	print &text('transfer_failed', $err),"<p>\n";
	}
else {
	print $text{'create_done'},"<p>\n";
	}

&ui_print_footer("transfer_form.cgi?id=$in{'id'}&mode=download",
		 $text{'transfer_return'},
		 "", $text{'index_return'});

