#!/usr/local/bin/perl
# Opens a window for choosing a free IP address

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &popup_error($text{'edit_egone'});
&popup_header($text{'ipchooser_title'});

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

$ifunc = "type_".$server->{'manager'}."_available_ip_addresses";
if (!defined(&$ifunc)) {
	print "<b>",$text{'ipchooser_ealloc'},"</b><p>\n";
	}
else {
	@ips = &$ifunc($server);
	if (!@ips) {
		print "<b>",$text{'ipchooser_enone'},"</b><p>\n";
		}
	else {
		print &ui_columns_start([ $text{'ipchooser_ip'},
					  $text{'ipchooser_netmask'} ], 100);
		foreach $i (@ips) {
			print &ui_columns_row([
			  "<a href='' onClick='select(\"$i->{'ip'}\")'>".
			    $i->{'ip'}."</a>",
			  &net::prefix_to_mask($i->{'cidr'}) ]);
			}
		print &ui_columns_end();
		}
	}

&popup_footer();

