#!/usr/local/bin/perl
# Updates the permission grants on an owned AMI

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'eami_err'});

# Get the EC2 account and AMI
($ec2) = grep { $_->{'id'} eq $in{'ec2'} } &list_ec2_accounts();
$images = &list_ec2_images($ec2);
ref($images) || &error($images);
($ami) = grep { $_->{'imageId'} eq $in{'id'} } @$images;
$ami || &error($text{'eami_egone'});

if ($in{'delete'}) {
	# De-register, after asking for confirmation
	if ($in{'confirm'}) {
		# Just do it
		$err = &type_ec2_deregister_ami($ec2, $ami->{'imageId'});
		&error($err) if ($err);

		if ($in{'s3'}) {
			# Also delete from S3
			$err = &type_ec2_delete_s3_ami($ec2, $ami->{'imageLocation'});
			&error($err) if ($err);
			}

		&redirect("list_amis.cgi");
		}
	else {
		# Ask first
		&ui_print_header(undef, $text{'dami_title'}, "");

		print &ui_form_start("save_ami.cgi");
		print &ui_hidden("delete", 1);
		print &ui_hidden("id", $in{'id'});
		print &ui_hidden("ec2", $in{'ec2'});
		print "<center>",
		      &text('dami_rusure', "<tt>$ami->{'imageId'}</tt>",
				"<tt>$ami->{'imageLocation'}</tt>"),"<p>\n",
		      &ui_submit($text{'dami_ok'}, "confirm"),"<p>\n",
		      &ui_checkbox("s3", 1, $text{'dami_s3'}),
		      "</center>";
		print &ui_form_end();

		&ui_print_footer("list_amis.cgi", $text{'amis_return'});
		}
	}
else {
	# Updating grants .. need to work out what has changed
	$oldgrants = &list_ec2_ami_grants($ec2, $ami->{'imageId'});
	ref($oldgrants) || &error($oldgrants);
	@newgrants = ( );
	foreach $g (split(/\s+/, $in{'grants'})) {
		if ($g =~ /^\@(\S+)$/) {
			push(@newgrants, [ "group", $1 ]);
			}
		else {
			push(@newgrants, [ "user", $g ]);
			}
		}
	if ($in{'public'}) {
		push(@newgrants, [ "group", "all" ]);
		}
	$err = &save_ec2_ami_grants($ec2, $ami->{'imageId'}, \@newgrants);
	&error($err) if ($err);

	# Update product code
	if (defined($in{'code'}) && !$in{'code_def'}) {
		$err = &save_ec2_ami_product($ec2, $ami->{'imageId'},
					     $in{'code'});
		&error($err) if ($err);
		}

	&redirect("list_amis.cgi");
	}

