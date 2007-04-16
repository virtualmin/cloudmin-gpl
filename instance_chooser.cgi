#!/usr/local/bin/perl
# Opens a window for selecting a running EC2 instance

require './server-manager-lib.pl';
&ReadParse();
&popup_header($text{'ichooser_title'});

# Get the account, and it's instances
($ec2) = grep { $_->{'id'} eq $in{'account'} } &list_ec2_accounts();
$instances = &list_ec2_instances($ec2, 'running');

# Selector javascript
print <<EOF;
<script>
function select(instance)
{
top.opener.ifield.value = instance;
top.close();
}
</script>
EOF

if (!ref($instances)) {
	print "<b>",&text('ichooser_elogin', $instances),"</b><p>\n";
	}
elsif (!@$instances) {
	print "<b>",$text{'ichooser_enone'},"</b><p>\n";
	}
else {
	print &ui_columns_start([ $text{'ichooser_id'},
				  $text{'ichooser_ami'},
				  $text{'ichooser_state'} ], 100);
	@servers = &list_managed_servers();
	foreach my $i (@$instances) {
		($s) = grep { $_->{'instance'} eq $i->{'instanceId'} }
			    @servers;
		print &ui_columns_row([
		    $s ? $i->{'instanceId'} :
			"<a href='' onClick='select(\"$i->{'instanceId'}\")>".
			"$i->{'instanceId'}</a>",
		    $i->{'imageId'},
		    $s ? &text('ichooser_unuse', $s->{'host'})
		       : $text{'ichooser_free'}
		    ]);
		}
	print &ui_columns_end();
	}

&popup_footer();

