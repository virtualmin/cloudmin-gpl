#!/usr/local/bin/perl
# Actually create an AMI

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
&error_setup($text{'newami_err'});

# Validate inputs
$in{'path'} =~ /^\S+$/ || &error($text{'newami_epath'});
$in{'size'} =~ /^\d+$/ || &error($text{'newami_esize'});
$in{'size'} *= $in{'size_units'};

&ui_print_unbuffered_header(&server_in($server), $text{'newami_title'}, "");

# Munge passwords and Virtualmin licence
# XXX re-factor
local @munged;
foreach my $m ([ \&munge_virtualmin_licence_files, 'mkimage_mungelicence' ],
	       [ \&munge_shadow_root_password, 'mkimage_mungeshadow' ],
	       [ \&munge_authorized_key, 'mkimage_mungessh' ]) {
	&$first_print($text{$m->[1]});
	local $mfunc = $m->[0];
	local $munged = &$mfunc($server);
	if (!ref($munged)) {
		&$second_print(&text('mkimage_emunge', $err));
		goto FAILED;
		}
	else {
		push(@munged, @$munged);
		&$second_print($text{'create_done'});
		}
	}

# Start the imaging process
print $text{'newami_creating'},"<br>\n";
$err = &type_ec2_create_ami($server);
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
print $text{'newami_uploading'},"<br>\n";
$err = &type_ec2_upload_ami($server);
if ($err) {
	print &text('newami_ufailed', $err),"<p>\n";
	goto FAILED;
	}
else {
	print $text{'newami_ustarted'},"<p>\n";
	}

# Wait for completion

# Register the new AMI, and optionally make public

# Un-munge
FAILED:
&$first_print($text{'mkimage_unmunge'});
foreach my $m (@munged) {
	local ($file, $data) = @$m;
	local $err = &put_file_data_to_server($server, $data, $file);
	if ($err) {
		&$second_print(&text('create_eunmunge', $file, $err));
		return 0;
		}
	}
&$second_print($text{'create_done'});


&ui_print_footer("", $text{'index_return'});
