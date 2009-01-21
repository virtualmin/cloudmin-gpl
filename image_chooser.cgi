#!/usr/local/bin/perl
# Opens a window for selecting an EC2 AMI

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
&can_create_server_error("ec2");
&popup_header($text{'achooser_title'});

# Get the account, and it's available images
($ec2) = grep { $_->{'id'} eq $in{'account'} } &list_ec2_accounts();
$images = &list_ec2_images($ec2);

# Selector javascript
print <<EOF;
<script>
function select(image)
{
top.opener.ifield.value = image;
top.close();
}
</script>
EOF

# Show search form
print &ui_form_start("image_chooser.cgi");
print &ui_hidden("account", $in{'account'});
print "<b>$text{'ichooser_search'}</b>\n";
print &ui_textbox("search", $in{'search'}, 30);
print &ui_submit($text{'ichooser_ok'});
print &ui_form_end();

# Apply search
$s = $in{'search'};
if (ref($images) && $s) {
	$images = [ grep { $_->{'imageId'} =~ /\Q$s\E/i ||
			   $_->{'imageLocation'} =~ /\Q$s\E/i ||
			   $_->{'imageOwnerId'} =~ /\Q$s\E/i } @$images ];
	}

if (!ref($images)) {
	print "<b>",&text('ichooser_elogin', $images),"</b><p>\n";
	}
elsif (!@$images && $s) {
	print "<b>",&text('achooser_enone2',
			  "<i>".&html_escape($s)."</i>"),"</b><p>\n";
	}
elsif (!@$images) {
	print "<b>",$text{'achooser_enone'},"</b><p>\n";
	}
else {
	print &ui_columns_start([ $text{'achooser_id'},
				  $text{'achooser_path'},
				  $text{'achooser_owner'} ], 100);
	foreach my $i (@$images) {
		next if ($i->{'imageType'} ne 'ami');
		local $path = $i->{'imageLocation'};
		$path =~ s/\.manifest\.xml$//;
		$path =~ s/\.img$//;
		print &ui_columns_row([
		    "<a href='' onClick='select(\"$i->{'imageId'}\")'>".
		    "$i->{'imageId'}</a>",
		    $path,
		    $i->{'imageOwnerId'},
		    ]);
		}
	print &ui_columns_end();
	}

&popup_footer();

