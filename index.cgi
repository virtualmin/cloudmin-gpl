#!/usr/local/bin/perl
# Show a table of managed servers, links to create new ones, and global options

require './server-manager-lib.pl';
&ui_print_header(undef, $module_info{'desc'}, "", "intro", 1, 1);
&ReadParse();

# Check server manager licence, show an error if invalid
$lerr = &licence_error_message();
print $lerr if ($lerr);

@allservers = sort { $a->{'host'} cmp $b->{'host'} } &list_managed_servers();

# Build select links
@links = ( &select_all_link("d"), &select_invert_link("d") );
@upservers = grep { $_->{'status'} eq 'virt' ||
		    $_->{'status'} eq 'novirt' ||
		    $_->{'status'} eq 'nowebminlogin' ||
		    $_->{'status'} eq 'downwebmin' ||
		    $_->{'status'} eq 'nowebmin' } @allservers;
@weservers = grep { $_->{'status'} eq 'virt' ||
                    $_->{'status'} eq 'novirt' } @allservers;
if (@upservers && defined(&select_rows_link)) {
	push(@links, &select_rows_link("d", 0, $text{'index_selup'},
				       [ map { $_->{'id'} } @upservers ]));
	}
if (@weservers && defined(&select_rows_link)) {
	push(@links, &select_rows_link("d", 0, $text{'index_selwe'},
				       [ map { $_->{'id'} } @weservers ]));
	}

# Build add links
if (!$main::vm2_no_create_links) {
	foreach $t (@server_management_types) {
		$lfunc = "type_".$t."_create_links";
		if (defined(&$lfunc)) {
			foreach $l (&$lfunc()) {
				$prog = $l->{'create'} ? "create_form.cgi"
						       : "add_form.cgi";
				push(@crlinks,
				  "<a href='$prog?type=$t'>$l->{'desc'}</a>");
				}
			}
		}
	}

# Find all servers
$searching = $in{'search'} || $in{'gok'} || $in{'pok'} || $in{'eok'};
if (@allservers > $config{'display_max'} || $searching) {
	# Too many! Show a search form
	if (!$searching) {
		print &text('index_toomany', scalar(@allservers),
					     $config{'display_max'}),"<p>\n";
		}

	print &ui_form_start("index.cgi");
	print "<table cellpadding=1 cellspacing=1>\n";

	# Search by hostname or desc
	print "<tr> <td><b>$text{'index_search'}</b></td>\n";
	print "<td>",&ui_textbox("search", $in{'search'}, 30),"</td>\n";
	print "<td>",&ui_submit($text{'index_searchok'}),"</td> </tr>\n";

	# Search by group
	@groups = &unique(map { split(/\t/, $_->{'group'}) } @allservers);
	if (@groups) {
		print "<tr> <td><b>$text{'index_gsearch'}</b></td>\n";
		print "<td>",&ui_select("gsearch", $in{'gsearch'},
					\@groups),"</td>\n";
		print "<td>",&ui_submit($text{'index_searchgok'},
					"gok"),"</td> </tr>\n";
		}

	# Search by host system
	@parents = grep { &is_parent_server($_) } @allservers;
	if (@parents) {
		print "<tr> <td><b>$text{'index_psearch'}</b></td>\n";
		print "<td>",&ui_select("psearch", $in{'psearch'},
		    [ map { [ $_->{'id'}, $_->{'host'} ] } @parents ]),"</td>\n";
		print "<td>",&ui_submit($text{'index_searchpok'},
					"pok"),"</td> </tr>\n";
		}

	# Search by EC2 account (normally hidden)
	if ($in{'eok'}) {
		print "<tr> <td><b>$text{'index_esearch'}</b></td>\n";
		print "<td>",&ui_select("esearch", $in{'esearch'},
		    [ map { [ $_->{'id'}, $_->{'account'} ] }
			  &list_ec2_accounts() ]),"</td>\n";
		print "<td>",&ui_submit($text{'index_searcheok'},
					"eok"),"</td> </tr>\n";
		}

	print "</table>\n";

	print &ui_form_end();
	if ($in{'gok'}) {
		# Search by group
		@servers = grep { my @g = split(/\t/, $_->{'group'});
				&indexof($in{'gsearch'}, @g) >= 0 } @allservers;
		}
	elsif ($in{'pok'}) {
		# Search by parent
		($parent) = grep { $_->{'id'} eq $in{'psearch'} } @allservers;
		@servers = grep { my $p = &get_parent_server($_);
			  $p && $p->{'id'} eq $parent->{'id'} } @allservers;
		}
	elsif ($in{'eok'}) {
		# Search by EC2 account
		($ec2) = grep { $_->{'id'} == $in{'esearch'} }
			      &list_ec2_accounts();
		@servers = grep { $_->{'ec2'} == $in{'esearch'} } @allservers;
		}
	else {
		# By hostname
		$s = $in{'search'};
		@servers = grep { $_->{'host'} =~ /\Q$s\E/i ||
				  $_->{'desc'} =~ /\Q$s\E/i } @allservers;
		}
	}
else {
	@servers = @allservers;
	}

# Show a table of managed servers
$posscount = $virtcount = $procount = 0;
if (@servers) {
	# Some servers to show .. display search type message
	if ($in{'gok'}) {
		print &text('index_resgroup', &html_escape($in{'gsearch'}),
			    scalar(@allservers), scalar(@servers)),"<p>\n";
		}
	elsif ($in{'pok'}) {
		print &text('index_resparent', &html_escape($parent->{'host'}),
			    scalar(@allservers), scalar(@servers)),"<p>\n";
		}
	elsif ($in{'eok'}) {
		print &text('index_resec2', &html_escape($ec2->{'account'}),
			    scalar(@allservers), scalar(@servers)),"<p>\n";
		}
	elsif ($in{'search'}) {
		print &text('index_ressearch', &html_escape($in{'search'}),
			    scalar(@allservers), scalar(@servers)),"<p>\n";
		}

	# Make categories to show
	if ($config{'cat_mode'} == 0) {
		# All in one
		@cats = ( [ \@servers ] );
		}
	elsif ($config{'cat_mode'} == 1) {
		# By manager
		foreach my $s (@servers) {
			$s->{'cat_manager'} = $s->{'manager'} eq 'this' ?
						'real' : $s->{'manager'};
			}
		foreach my $t (&unique(map { $_->{'cat_manager'} } @servers)) {
			my @intype = grep { $_->{'cat_manager'} eq $t }@servers;
			$dfunc = "type_".$t."_desc";
			push(@cats, [ \@intype, &text('index_cattype',
						      &$dfunc()) ]);
			}
		}
	elsif ($config{'cat_mode'} == 2) {
		# By group
		foreach my $g ("", &unique(map { split(/\t+/, $_->{'group'}) }
					       @servers)) {
			my @ingroup;
			if ($g eq '') {
				@ingroup = grep { $_->{'group'} eq '' }@servers;
				}
			else {
				@ingroup = grep { &indexof($g,
				  split(/\t+/, $_->{'group'})) >= 0 } @servers;
				}
			if (@ingroup) {
				push(@cats, [ \@ingroup,
				   $g ? &text('index_catgroup', "<tt>$g</tt>")
				      : $text{'index_catnogroup'} ]);
				}
			}
		}

	print &ui_form_start("mass.cgi", "post");
	@tds = ( "width=5" );
	print &ui_links_row([ @links, @crlinks ]);
	foreach $cat (@cats) {
		print &ui_subheading($cat->[1]) if ($cat->[1]);
		print &ui_columns_start([
			"",
			$text{'index_host'},
			$text{'index_type'},
			$text{'index_os'},
			$text{'index_status'},
			$text{'index_desc'},
			], 100, 0, \@tds);
		foreach my $s (@{$cat->[0]}) {
			$t = $s->{'manager'};
			$tfunc = "type_".$t."_desc";
			$pos = $s->{'virtualmin_poss'};
			$posdesc = undef;
			if ($pos) {
				# Has some updates
				$posscount += $pos;
				$posdesc = " - ".&text($pos > 1 ?
					'index_poss' : 'index_pos', $pos);
				}
			$shost = $s->{'short_host'};
			print &ui_checked_columns_row([
			    $s->{'status'} eq 'create' ? $shost :
			     "<a href='edit_serv.cgi?id=$s->{'id'}'>$shost</a>",
			    &$tfunc(),
			    &describe_os($s->{'type'}),
			    &describe_status($s, 1, 2).$posdesc,
			    $s->{'desc'},
			    ], \@tds, "d", $s->{'id'});
			$virtcount++ if ($s->{'status'} eq 'virt');
			$procount++ if ($s->{'virtualmin_serial'});
			}
		print &ui_columns_end();
		}
	print &ui_links_row([ @links, @crlinks ]);
	print &ui_form_end([
			     [ "refresh", $text{'index_refresh'} ],
			     $posscount ? ( [ "update",$text{'index_update'} ] )
					: ( ),
			     $procount ? ( [ "script", $text{'index_script'} ] )
				       : ( ),
			     undef,
			     [ "dereg", $text{'index_dereg'} ],
			     [ "delete", $text{'index_delete'} ],
			     undef,
			     [ "shutdown", $text{'index_shutdown'} ],
			     [ "startup", $text{'index_startup'} ],
			     undef,
			     [ "upload", $text{'index_upload'} ],
			     [ "run", $text{'index_run'} ],
			   ]);
	}
elsif (@allservers) {
	# No servers matched the search
	print "<b>$text{'index_nonematched'}</b><p>\n" if ($in{'search'});
	print &ui_links_row(\@crlinks);
	}
else {
	# No servers exist
	print "<b>$text{'index_none'}</b><p>\n";
	@links = @links[2..$#links];
	print &ui_links_row(\@crlinks);
	}

# Show icons for global settings
($glinks, $gtitles, $gicons) = &get_global_links($virtcount);
if (@$glinks) {
	print "<hr>\n";
	print &ui_subheading($text{'index_header'});
	&icons_table($glinks, $gtitles, $gicons);
	}

&ui_print_footer("/", $text{'index'});

