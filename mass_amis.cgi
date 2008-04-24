#!/usr/local/bin/perl
# Delete, grant or revoke a bunch of AMIs

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

# Get all the AMIs selected
@ec2s = &list_ec2_accounts();
foreach $d (split(/\0/, $in{'d'})) {
	($amiid, $ec2id) = split(/\//, $d);
	($ec2) = grep { $_->{'id'} eq $ec2id } @ec2s;
	if (!$amicache{$ec2id}) {
		local $images = &list_ec2_images($ec2);
		ref($images) || &error($images);
		$amicache{$ec2id} = $images;
		}
	($ami) = grep { $_->{'imageId'} eq $amiid } @{$amicache{$ec2id}};
	$ami || &error(&text('mami_egone', $amiid));
	$ami->{'ec2'} = $ec2;
	push(@amis, $ami);
	}
@amis || &error($text{'mami_enone'});

if ($in{'delete'}) {
	# Delete selected, after asking first
	&error_setup($text{'mami_err1'});
	if ($in{'confirm'}) {
		# Just do it
		foreach $ami (@amis) {
			$ec2 = $ami->{'ec2'};
			$err = &type_ec2_deregister_ami(
				$ec2, $ami->{'imageId'});
			&error(&text('mami_edelete', $ami->{'imageId'}, $err))
				if ($err);

			if ($in{'s3'}) {
				# Also delete from S3
				$err = &type_ec2_delete_s3_ami(
					$ec2, $ami->{'imageLocation'});
				&error(&text('mami_es3',
					     $ami->{'imageId'},$err)) if ($err);
				}
			}

		&redirect("list_amis.cgi");
		}
	else {
		# Ask first
		&ui_print_header(undef, $text{'mami_dtitle'}, "");

		print &ui_form_start("mass_amis.cgi");
		print &ui_hidden("delete", 1);
		foreach $d (split(/\0/, $in{'d'})) {
			print &ui_hidden("d", $d);
			}
		print "<center>",
		      &text('mami_rusure', scalar(@amis)),"<p>\n",
		      &ui_submit($text{'mami_ok'}, "confirm"),"<p>\n",
		      &ui_checkbox("s3", 1, $text{'dami_s3'}),"<p>\n",
		      &text('mami_selected',
			join(" ", map { "<tt>$_->{'imageId'}</tt>" } @amis)),
		      "</center>\n";
		print &ui_form_end();

		&ui_print_footer("list_amis.cgi", $text{'amis_return'});
		}

	}
elsif ($in{'public'}) {
	# Add public grant to selected
	&error_setup($text{'mami_err2'});
	foreach my $ami (@amis) {
		$ec2 = $ami->{'ec2'};
		$grants = &list_ec2_ami_grants($ec2, $ami->{'imageId'});
		ref($grants) || &error($grants);
		($got) = grep { $_->[0] eq 'group' && $_->[1] eq 'all' }
			      @$grants;
		if (!$got) {
			push(@$grants, [ 'group', 'all' ]);
			$err = &save_ec2_ami_grants(
				$ec2, $ami->{'imageId'}, $grants);
			$err && &error(&text('mami_egrant', $ami->{'imageId'},
							    $err));
			}
		}
	&redirect("list_amis.cgi");
	}
elsif ($in{'private'}) {
	# Remove public grant from selected
	&error_setup($text{'mami_err2'});
	foreach my $ami (@amis) {
		$ec2 = $ami->{'ec2'};
		$grants = &list_ec2_ami_grants($ec2, $ami->{'imageId'});
		ref($grants) || &error($grants);
		($got) = grep { $_->[0] eq 'group' && $_->[1] eq 'all' }
			      @$grants;
		if ($got) {
			@$grants = grep { $_ ne $got } @$grants;
			$err = &save_ec2_ami_grants(
				$ec2, $ami->{'imageId'}, $grants);
			$err && &error(&text('mami_egrant', $ami->{'imageId'},
							    $err));
			}
		}
	&redirect("list_amis.cgi");
	}
else {
	&error("No button clicked");
	}

