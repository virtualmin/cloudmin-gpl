#!/usr/local/bin/perl
# Show a table of managed servers, links to create new ones, and global options

require './server-manager-lib.pl';
&ui_print_header(undef, $module_info{'desc'}, "", "intro", 1, 1);
&ReadParse();

# Check server manager licence, show an error if invalid
$lerr = &licence_error_message();
print $lerr if ($lerr);

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

# Find all servers
@allservers = sort { $a->{'host'} cmp $b->{'host'} } &list_managed_servers();
if (@allservers > $config{'display_max'}) {
	# Too many! Show a search form
	print &text('index_toomany', scalar(@allservers),
				     $config{'display_max'}),"<p>\n";
	print &ui_form_start("index.cgi");
	print "<b>$text{'index_search'}</b>\n";
	print &ui_textbox("search", $in{'search'}, 30),"\n";
	print &ui_submit($text{'index_searchok'});
	print &ui_form_end();
	$s = $in{'search'};
	@servers = grep { $_->{'host'} =~ /\Q$s\E/i ||
			  $_->{'desc'} =~ /\Q$s\E/i } @allservers;
	}
else {
	@servers = @allservers;
	}

# Show a table of managed servers
if (@servers) {
	# Some servers to show
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
	$posscount = 0;
	foreach my $s (@servers) {
		$t = $s->{'manager'};
		$tfunc = "type_".$t."_desc";
		$pos = $s->{'virtualmin_poss'};
		$posdesc = undef;
		if ($pos) {
			# Has some updates
			$posscount += $pos;
			$posdesc = " - ".&text($pos > 1 ? 'index_poss'
							: 'index_pos', $pos);
			}
		print &ui_checked_columns_row([
		    $s->{'status'} eq 'create' ? $s->{'host'} :
		      "<a href='edit_serv.cgi?id=$s->{'id'}'>$s->{'host'}</a>",
		    &$tfunc(),
		    &describe_os($s->{'type'}),
		    &describe_status($s, 1, 1).$posdesc,
		    $s->{'desc'},
		    ], \@tds, "d", $s->{'id'});
		$virtcount++ if ($s->{'status'} eq 'virt');
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([
			     [ "refresh", $text{'index_refresh'} ],
			     $posscount ? ( [ "update",$text{'index_update'} ] )
					: ( ),
			     undef,
			     [ "dereg", $text{'index_dereg'} ],
			     [ "delete", $text{'index_delete'} ],
			   ]);
	}
elsif (@allservers) {
	# No servers matched the search
	print "<b>$text{'index_nonematched'}</b><p>\n" if ($in{'search'});
	@links = @links[2..$#links];
	print &ui_links_row(\@links);
	}
else {
	# No servers exist
	print "<b>$text{'index_none'}</b><p>\n";
	@links = @links[2..$#links];
	print &ui_links_row(\@links);
	}

# Show icons for global settings
($glinks, $gtitles, $gicons) = &get_global_links($virtcount);
if (@$glinks) {
	print "<hr>\n";
	print &ui_subheading($text{'index_header'});
	&icons_table($glinks, $gtitles, $gicons);
	}

&ui_print_footer("/", $text{'index'});

