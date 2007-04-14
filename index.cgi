#!/usr/local/bin/perl
# Show a table of managed servers, links to create new ones, and global options

require './server-manager-lib.pl';
&ui_print_header(undef, $module_info{'desc'}, "", "intro", 1, 1);

# Build add links
@links = ( &select_all_link("d"), &select_invert_link("d") );
foreach $t (@server_management_types) {
	$lfunc = "type_".$t."_create_links";
	if (defined(&$lfunc)) {
		foreach $l (&$lfunc()) {
			$prog = $l->{'create'} ? "create_form.cgi"
					       : "add_form.cgi";
			push(@links,"<a href='$prog?type=$t'>$l->{'desc'}</a>");
			}
		}
	}

# Show a table of managed servers
@servers = &list_managed_servers();
if (@servers) {
	print &ui_form_start("mass.cgi", "post");
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	print &ui_columns_start([
		"",
		$text{'index_host'},
		$text{'index_type'},
		$text{'index_os'},
		$text{'index_status'},
		$text{'index_desc'},
		], 100, 0, \@tds);
	foreach my $s (@servers) {
		$t = $s->{'manager'};
		$tfunc = "type_".$t."_desc";
		print &ui_checked_columns_row([
		    "<a href='edit_serv.cgi?id=$s->{'id'}'>$s->{'host'}</a>",
		    &$tfunc(),
		    &describe_os($s->{'type'}),
		    &describe_status($s, 1),
		    $s->{'desc'}
		    ], \@tds);
		}
	print &ui_columns_end();
	print &ui_form_end([ [ "dereg", $text{'index_dereg'} ],
			     [ "delete", $text{'index_delete'} ] ]);
	}
else {
	print "<b>$text{'index_none'}</b><p>\n";
	@links = @links[2..$#links];
	}
print &ui_links_row(\@links);

# Show icons for global settings
push(@glinks, "list_keys.cgi");
push(@gtitles, $text{'keys_title'});
push(@gicons, "images/keys.gif");
foreach $t (@server_management_types) {
	$gfunc = "type_".$t."_global_links";
	if (defined(&$gfunc)) {
		foreach $g (&$gfunc()) {
			push(@glinks, $g->{'link'});
			push(@gtitles, $g->{'title'});
			push(@gicons, $g->{'icon'});
			}
		}
	}
if (@glinks) {
	print "<hr>\n";
	print &ui_subheading($text{'index_header'});
	&icons_table(\@glinks, \@gtitles, \@gicons);
	}

&ui_print_footer("/", $text{'index'});

