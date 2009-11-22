#!/usr/local/bin/perl
# Opens a window for selecting a running linux KVM instance

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
&can_add_server_error("kvm");
&popup_header($text{'kchooser_title'});

# Get the server, and it's instances
$vhost = &get_managed_server_by("id", $in{'host'});
$instances = &list_kvm_instances($vhost);

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
	print "<b>",&text('kchooser_elist', $instances),"</b><p>\n";
	}
elsif (!@$instances) {
	print "<b>",$text{'kchooser_enone'},"</b><p>\n";
	}
else {
	print &ui_columns_start([ $text{'kchooser_pid'},
				  $text{'kchooser_fs'},
				  $text{'kchooser_mem'},
				  $text{'ichooser_state'} ], 100);
	@servers = &list_managed_servers();
	foreach my $i (@$instances) {
		($s) = grep { $_->{'kvm_filesystem'} eq $i->{'filesystem'} }
			    @servers;
		$mem = $i->{'args'}->{'m'} * 1024 * 1024;
		print &ui_columns_row([
		    $s ? $i->{'pid'} :
			"<a href='' onClick='select(\"$i->{'pid'}\")'>".
			"$i->{'pid'}</a>",
		    $i->{'filesystem'},
		    $mem ? &nice_size($mem) : $text{'kchooser_uk'},
		    $s ? &text('ichooser_unuse', $s->{'host'})
		       : $text{'ichooser_free'}
		    ]);
		}
	print &ui_columns_end();
	}

&popup_footer();

