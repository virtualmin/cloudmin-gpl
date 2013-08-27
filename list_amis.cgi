#!/usr/local/bin/perl
# Shows a list of AMIs, with checkboxes to delete

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'amis_title'}, "", "amis");

# Get all the AMIs that are visible
foreach $ec2 (&list_ec2_accounts()) {
	my $images = &list_ec2_images($ec2);
	if (ref($images)) {
		foreach $ami (@$images) {
			next if ($ami->{'imageType'} ne 'ami');
			my $alr = $done{$ami->{'imageId'}};
			if ($alr) {
				# Already seen .. but is this EC2 account the
				# owner, and so better?
				if ($alr->{'imageOwnerId'} eq $ec2->{'account'}) {
					$alr->{'ec2'} = $ec2;
					}
				next;
				}
			$done{$ami->{'imageId'}} = $ami;
			$ami->{'ec2'} = $ec2;
			push(@amis, $ami);
			}
		}
	else {
		push(@errs, [ $ec2, $images ]);
		}
	$myaccounts{$ec2->{'account'}} = $ec2;
	}
@amis = sort { $a->{'imageId'} cmp $b->{'imageId'} } @amis;

if (@amis) {
	@links = ( &select_all_link("d"), &select_invert_link("d") );
	@tds = ( "width=5" );
	@servers = &list_managed_servers();
	print &ui_form_start("mass_amis.cgi", "post");
	print &ui_links_row(\@links);
	print &ui_columns_start([ "",
				  $text{'amis_id'},
				  $text{'amis_path'},
				  $text{'amis_owner'},
				  $text{'amis_public'},
				  $text{'amis_pcode'},
				  $text{'amis_users'} ], 100, 0, \@tds);
	foreach $ami (@amis) {
		$ec2 = $ami->{'ec2'};
		@users = grep { $_->{'ec2_image'} eq $ami->{'imageId'} }
			      @servers;
		$users = @users == 0 ? $text{'keys_nousers'} :
			 @users > 4 ? &text('keys_manyusers', scalar(@users)) :
			   join("<br>", map { "<tt>$_->{'host'}</tt>" } @users);
		$public = $ami->{'isPublic'} eq 'true' ?
			"<font color=#00aa00>$text{'yes'}</font>" :
			"<font color=#ff0000>$text{'no'}</font>";
		$ami->{'imageLocation'} =~ s/(image)?\.manifest\.xml$//;
		$ami->{'imageLocation'} =~ s/\.img$//;
		$ami->{'imageLocation'} =~ s/\///;
		$pcode = join(" ", map { $_->{'productCode'} }
				       @{$ami->{'productCodes'}->{'item'}});
		if ($myaccounts{$ami->{'imageOwnerId'}}) {
			# Our image
			print &ui_checked_columns_row([
				"<a href='edit_ami.cgi?".
				 "id=$ami->{'imageId'}&ec2=$ec2->{'id'}'>".
				 "$ami->{'imageId'}</a>",
				$ami->{'imageLocation'},
				$ami->{'imageOwnerId'}." (".
				  $text{'amis_ours'}.")",
				$public,
				$pcode,
				$users,
				], \@tds, "d",
				$ami->{'imageId'}."/".$ec2->{'id'});
			}
		else {
			# Someone else's
			print &ui_columns_row([
				&ui_checkbox("d", undef, "", 0, 0, 1),
				$ami->{'imageId'},
				$ami->{'imageLocation'},
				$ami->{'imageOwnerId'},
				$public,
				$pcode,
				$users
				], \@tds);
			}
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ "delete", $text{'amis_delete'} ],
			     undef,
			     [ "public", $text{'amis_makepublic'} ],
			     [ "private", $text{'amis_makeprivate'} ],
			   ]);
	}
elsif (@errs) {
	print "<b>$text{'amis_nonefailed'}</b><p>\n";
	foreach my $err (@errs) {
		print $err->[0]->{'account'}." : ".$err->[1]."<br>\n";
		}
	}
else {
	print "<b>$text{'amis_nonefound'}</b><p>\n";
	}

&ui_print_footer("", $text{'index_return'});

