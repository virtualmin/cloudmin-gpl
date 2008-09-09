#!/usr/local/bin/perl
# Create a new EC2 snapshot

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&error_setup($text{'csnapshot_err'});
&ReadParse();

# Get the account and volume
@accounts = &list_ec2_accounts();
($ec2id, $vid) = split(/\//, $in{'volume'});
($ec2) = grep { $_->{'id'} eq $ec2id } @accounts;
$ec2 || &error(&text('dvolume_egone1', $ec2id));
$vols = &list_ec2_volumes($ec2);
&error($vols) if (!ref($vols));
($v) = grep { $_->{'volumeId'} eq $vid } @$vols;
$v || &error(&text('dvolume_egone2', $vid));

# Do it, and tell the user
&ui_print_unbuffered_header(undef, $text{'csnapshot_title'}, "");

print &text('csnapshot_doing', $vid,
	    &nice_size($v->{'size'}*1024*1024*1024)),"<br>\n";
($ok, $msg) = &create_ec2_snapshot($ec2, $vid);
if ($ok) {
	print &text('csnapshot_done', "<tt>$msg</tt>"),"<p>\n";
	}
else {
	print &text('csnapshot_failed', $msg),"<p>\n";
	}

&ui_print_footer("list_volumes.cgi?mode=snaps", $text{'volumes_return2'});

