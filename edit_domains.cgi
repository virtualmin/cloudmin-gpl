#!/usr/local/bin/perl
# Show domains on some system

require './server-manager-lib.pl';
&ReadParse();

# Get and check system
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});

&ui_print_header(&server_in($server), $text{'domains_title'}, "", "domains2");

# Hosted domains 
if (defined($server->{'virtualmin_domains'}) &&
    $server->{'virtualmin_domains'} > $config{'display_max'} &&
    !$in{'many'}) {
	# Too many domains to show
	$toomanydoms = 1;
	}
else {
	@doms = &get_server_domains($server);
	}

$candoms = &can_action($server, "domains");
$clink = "<a href='list_domains.cgi?create=1&".
	 "id=$server->{'id'}'>$text{'edit_domsadd'}</a>";
if ($toomanydoms) {
	# Show too many message
	print "<b>",&text('edit_toomany',
			  $server->{'virtualmin_domains'}),"</b><p>\n";
	print &ui_links_row([
		"<a href='edit_domains.cgi?id=$in{'id'}&many=1'>".
		 $text{'edit_showmany'}."</a>",
		$candoms ? ( $clink ) : ( ) ]);
	}
elsif (@doms) {
	$bs = &get_server_blocksize($server);
	@tds = $candoms ? ( "width=5" ) : ( );
	@links = ( &select_all_link("d"),
		   &select_invert_link("d"),
		   $clink );
	if ($candoms) {
		print &ui_form_start("mass_domains.cgi", "post");
		print &ui_hidden("id", $in{'id'});
		print &ui_links_row(\@links);
		}
	print &ui_columns_start([
		  $candoms ? ( "" ) : ( ),
		  $text{'domains_dom'},
		  $text{'domains_type'},
		  $text{'domains_desc'},
		  $info->{'quota'} ? ( $text{'domains_quota'},
				       $text{'domains_uquota'} ) : ( ),
		  ], 100, 0, \@tds);
	foreach $d (sort { $a->{'dom'} cmp $b->{'dom'} } @doms) {
		if ($info->{'quota'}) {
			($dquota) = grep
				{ $_->[0]->{'id'} == $d->{'id'} }
				@{$info->{'quota'}};
			}
		$di1 = $d->{'disabled'} ? "<i>" : "";
		$di2 = $d->{'disabled'} ? "</i>" : "";
		@cols = (
			$di1.&domain_link($server, $d).$di2,
			$d->{'alias'} ? $text{'domains_alias'} :
			 $d->{'subdom'} ? $text{'domains_subdom'} :
			 $d->{'parent'} ? $text{'domains_sub'} :
					  $text{'domains_top'},
			$d->{'owner'},
			$info->{'quota'} ? (
			   $d->{'parent'} ?$text{'domains_fromparent'} :
			   $d->{'quota'} ? &nice_size($d->{'quota'}*$bs)
					 : $text{'domains_unlimited'},
			   $dquota ? &nice_size($dquota->[1]) : "" )
				   : ( ),
			);
		if ($candoms) {
			print &ui_checked_columns_row(\@cols, \@tds,
				"d", $server->{'id'}."/".$d->{'id'});
			}
		else {
			print &ui_columns_row(\@cols, \@tds);
			}
		}
	print &ui_columns_end();
	if ($candoms) {
		print &ui_links_row(\@links);
		print &ui_form_end([
			[ "delete", $text{'domains_delete'} ],
			undef,
			[ "disable", $text{'domains_disable'} ],
			[ "enable", $text{'domains_enable'} ],
			undef,
			[ "move", $text{'domains_move'} ],
			]);
		}
	}
else {
	print "<b>$text{'edit_nodoms'}</b><p>\n";
	}

&ui_print_footer("", $text{'index_return'});

if (defined(&theme_select_server)) {
	&theme_select_server($server);
	}


