#!/usr/local/bin/perl
# Actually create an AMI

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
&can_action_error($server, "image");
&error_setup($text{'newami_err'});

# Validate inputs
$in{'path'} =~ /^\S+$/ || &error($text{'newami_epath'});
$in{'size'} =~ /^\d+$/ || &error($text{'newami_esize'});
$in{'size'} *= $in{'size_units'};

# Get the EC2 account
($ec2) = grep { $_->{'id'} eq $in{'account'} } &list_ec2_accounts();

# Check for a clash
$images = &list_ec2_images($ec2);
if (ref($images) && !$in{'over'}) {
	($clash) = grep { $_->{'imageLocation'} =~ /^\Q$in{'path'}\E\// }
			@$images;
	$clash && &error(&text('newami_eclash', $clash->{'imageId'},
						$in{'path'}));
	}

&ui_print_unbuffered_header(&server_in($server), $text{'newami_title'}, "");

print &text('newami_doing', "<tt>$server->{'host'}</tt>",
			    "<tt>$ec2->{'account'}</tt>"),"<p>\n";

# Munge passwords and Virtualmin licence
($mok, $munged) = &munge_all_files($server, 1, !$in{'munge'});
if (!$mok) {
	goto FAILED;
	}

# Start the imaging process
print $text{'newami_creating'},"<br>\n";
$err = &type_ec2_create_ami($server, $in{'path'}, $ec2, $in{'size'});
if ($err) {
	print &text('newami_failed', $err),"<p>\n";
	goto FAILED;
	}
else {
	print $text{'newami_started'},"<p>\n";
	}

# Wait for completion
print $text{'newami_waiting'};
while(1) {
	sleep(1);
	print ".";
	$done = &type_ec2_create_ami_done($server);
	if ($done eq "OK") {
		print "<br>\n";
		print $text{'newami_done'},"<p>\n";
		last;
		}
	elsif ($done) {
		print "<br>\n";
		print &text('newami_failed', $done),"<p>\n";
		goto FAILED;
		}
	}

# Start the upload to S3
print &text('newami_uploading', "<tt>$in{'path'}</tt>"),"<br>\n";
$err = &type_ec2_upload_ami($server, $in{'path'}, $ec2);
if ($err) {
	print &text('newami_ufailed', $err),"<p>\n";
	goto FAILED;
	}
else {
	print $text{'newami_ustarted'},"<p>\n";
	}

# Wait for completion
print $text{'newami_uwaiting'};
while(1) {
	sleep(1);
	print ".";
	$done = &type_ec2_upload_ami_done($server);
	if ($done eq "OK") {
		print "<br>\n";
		print $text{'newami_udone'},"<p>\n";
		last;
		}
	elsif ($done) {
		print "<br>\n";
		print &text('newami_ufailed', $done),"<p>\n";
		goto FAILED;
		}
	}

# Register the new AMI, and optionally make public
print $text{'newami_register'},"<br>\n";
($ok, $ami) = &type_ec2_register_ami($server, $in{'path'}, $ec2, $in{'public'});
if ($ok) {
	print &text('newami_registered', "<tt>$ami</tt>"),"<p>\n";
	}
else {
	print &text('newami_eregister', $ami),"<p>\n";
	}
$complete = 1;

# Un-munge
FAILED:
&unmunge_all_files($server, $munged);

if ($complete) {
	print $text{'newami_alldone'},"<p>\n";
	}
else {
	print "<b>",$text{'newami_allfailed'},"</b><p>\n";
	}

&ui_print_footer("", $text{'index_return'});
