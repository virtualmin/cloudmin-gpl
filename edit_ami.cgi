#!/usr/local/bin/perl
# Shows details of one AMI that you own, with a field to control grants

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

# Get the EC2 account and AMI
($ec2) = grep { $_->{'id'} eq $in{'ec2'} } &list_ec2_accounts();
$images = &list_ec2_images($ec2);
ref($images) || &error($images);
($ami) = grep { $_->{'imageId'} eq $in{'id'} } @$images;
$ami || &error($text{'eami_egone'});

&ui_print_header(undef, $text{'eami_title'}, "", "eami");

print &ui_form_start("save_ami.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("ec2", $in{'ec2'});
print &ui_table_start($text{'eami_header'}, undef, 2, [ "width=30%" ]);

# AMI ID
print &ui_table_row($text{'eami_ami'}, "<tt>$ami->{'imageId'}</tt>");

# S3 path
print &ui_table_row($text{'eami_path'}, "<tt>$ami->{'imageLocation'}</tt>");

# EC2 account
print &ui_table_row($text{'eami_account'},
		    "$ec2->{'account'} ($ec2->{'desc'})");

# Used by systems
@users = grep { $_->{'ec2_image'} eq $ami->{'imageId'} }
	      &list_managed_servers();
if (@users) {
	print &ui_table_row($text{'eami_users'},
		join("<br>", map { "<a href='edit_serv.cgi?id=$_->{'id'}'>".
				   "$_->{'host'}</a>" } @users));
	}

# Grants
$grants = &list_ec2_ami_grants($ec2, $ami->{'imageId'});
if (ref($grants)) {
	$gstr = "";
	foreach $g (@$grants) {
		if ($g->[0] eq 'user') {
			$gstr .= $g->[1]."\n";
			}
		elsif ($g->[1] eq 'all') {
			$public = 1;
			}
		else {
			$gstr .= "\@".$g->[1]."\n";
			}
		}
	print &ui_table_row($text{'eami_grants'},
		&ui_textarea("grants", $gstr, 3, 30)."<br>\n".
		&ui_checkbox("public", 1, $text{'eami_public'}, $public));
	}

# Product codes
foreach $pc (@{$ami->{'productCodes'}->{'item'}}) {
	push(@pcodes, $pc->{'productCode'});
	}
print &ui_table_row($text{'eami_codes'},
	@pcodes ? "<tt>$pcodes[0]</tt>"
		: &ui_opt_textbox("code", undef, 30, $text{'eami_nocode'}).
		  "<br>".$text{'eami_codewarn'});

print &ui_table_end();
print &ui_form_end([ ref($grants) ? ( [ undef, $text{'save'} ] ) : ( ),
		     [ "delete", $text{'delete'} ] ]);

&ui_print_footer("list_amis.cgi", $text{'amis_return'});
