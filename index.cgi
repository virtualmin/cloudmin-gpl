#!/usr/local/bin/perl
# Show a table of managed servers, links to create new ones, and global options

require './server-manager-lib.pl';
&ui_print_header(undef, $module_info{'desc'}, "", "intro", 1, 1);
&ReadParse();

if (!%in) {
	# Try to use default search
	if (&read_file($default_search_file, \%in)) {
		$using_default_search = 1;
		}
	}
else {
	# See what default search is
	&read_file($default_search_file, \%defsearch);
	if (&same_hash(\%in, \%defsearch)) {
		$using_default_search = 1;
		}
	}

# Check server manager licence, show an error if invalid
$lerr = &licence_error_message();
print $lerr if ($lerr);

@allservers = &list_managed_servers_sorted();

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
$searching = $in{'search'} || $in{'gok'} || $in{'pok'} || $in{'eok'} ||
	     $in{'sok'};
$formno = 0;
if (@allservers > $config{'display_max'} || $searching) {
	# Too many! Show a search form
	if (!$searching) {
		print &text('index_toomany', scalar(@allservers),
					     $config{'display_max'}),"<p>\n";
		}
	else {
		print &text('index_searchform'),"<p>\n";
		}

	print &ui_form_start("index.cgi");
	@grid = ( );

	# Search by hostname or desc
	push(@grid, "<b>$text{'index_search'}</b>");
	push(@grid, &ui_textbox("search", $in{'search'}, 30).
	            " ".&ui_submit($text{'index_searchok'}));

	# Search by group
	@groups = &unique(map { split(/\t/, $_->{'group'}) } @allservers);
	if (@groups) {
		push(@grid, "<b>$text{'index_gsearch'}</b>");
		push(@grid, &ui_select("gsearch", $in{'gsearch'}, \@groups).
			    " ".&ui_submit($text{'index_searchgok'}, "gok"));
		}

	# Search by host system
	@parents = grep { &is_parent_server($_) } @allservers;
	if (@parents) {
		push(@grid, "<b>$text{'index_psearch'}</b>");
		push(@grid, &ui_select("psearch", $in{'psearch'},
		    [ map { [ $_->{'id'}, $_->{'host'} ] } @parents ]).
			    " ".&ui_submit($text{'index_searchpok'}, "pok"));
		}

	# Search by status (including some useful pseudo-statuses)
	push(@grid, "<b>$text{'index_ssearch'}</b>");
	push(@grid, &ui_select("ssearch", $in{'ssearch'} || 'up',
			[ [ 'up', "&lt;$text{'status_up'}&gt;" ],
			  [ 'wm', "&lt;$text{'status_wm'}&gt;" ],
			  [ 'bad', "&lt;$text{'status_bad'}&gt;" ],
			  [ 'updates', "&lt;$text{'status_updates'}&gt;" ],
			  map { [ $_->[0], $text{'status_'.$_->[0]} ] }
			      @server_statuses ]).
		    " ".&ui_submit($text{'index_searchsok'}, "sok"));

	# Search by EC2 account (normally hidden)
	if ($in{'eok'}) {
		push(@grid, "<b>$text{'index_esearch'}</b>");
		push(@grid, &ui_select("esearch", $in{'esearch'},
		    [ map { [ $_->{'id'}, $_->{'account'} ] }
			  &list_ec2_accounts() ]).
			    " ".&ui_submit($text{'index_searcheok'}, "eok"));
		}
	print &ui_grid_table(\@grid, 4, 100,
		[ "width=10%", "width=40%", "width=10%", "width=40%" ]),"<p>\n";

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
	elsif ($in{'sok'}) {
		# Search by status
		if ($in{'ssearch'} eq 'up') {
			@sts = ( 'nowebmin', 'novirt', 'virt' );
			}
		elsif ($in{'ssearch'} eq 'wm') {
			@sts = ( 'novirt', 'virt' );
			}
		elsif ($in{'ssearch'} eq 'bad') {
			@sts = ( 'down', 'nohost', 'nossh', 'nosshlogin',
				 'downwebmin', 'nowebminlogin' );
			}
		else {
			@sts = ( $in{'ssearch'} );
			}
		if ($in{'ssearch'} eq 'updates') {
			# Search by updates
			@servers = grep { $_->{'virtualmin_poss'} } @allservers;
			}
		else {
			# By regular status
			@servers = grep { &indexof($_->{'status'}, @sts) >= 0 }
					@allservers;
			}
		}
	else {
		# By hostname
		$s = $in{'search'};
		@servers = grep { $_->{'host'} =~ /\Q$s\E/i ||
				  $_->{'desc'} =~ /\Q$s\E/i } @allservers;
		}
	$formno++;
	}
else {
	@servers = @allservers;
	}

# Build select links
@links = ( &select_all_link("d", $formno), &select_invert_link("d", $formno) );
@upservers = grep { $_->{'status'} eq 'virt' ||
		    $_->{'status'} eq 'novirt' ||
		    $_->{'status'} eq 'nowebminlogin' ||
		    $_->{'status'} eq 'downwebmin' ||
		    $_->{'status'} eq 'nowebmin' } @servers;
@weservers = grep { $_->{'status'} eq 'virt' ||
                    $_->{'status'} eq 'novirt' } @servers;
if (@upservers && defined(&select_rows_link)) {
	push(@links, &select_rows_link("d", $formno, $text{'index_selup'},
				       [ map { $_->{'id'} } @upservers ]));
	}
if (@weservers && defined(&select_rows_link)) {
	push(@links, &select_rows_link("d", $formno, $text{'index_selwe'},
				       [ map { $_->{'id'} } @weservers ]));
	}

# Show a table of managed servers
$posscount = $virtcount = $procount = 0;
if (@servers) {
	# Some servers to show .. display search type message if any
	@g = ( );
	if ($in{'gok'}) {
		push(@g, &text('index_resgroup', &html_escape($in{'gsearch'}),
			    scalar(@allservers), scalar(@servers)));
		}
	elsif ($in{'pok'}) {
		push(@g, &text('index_resparent',
			    &html_escape($parent->{'host'}),
			    scalar(@allservers), scalar(@servers)));
		}
	elsif ($in{'eok'}) {
		push(@g, &text('index_resec2', &html_escape($ec2->{'account'}),
			    scalar(@allservers), scalar(@servers)));
		}
	elsif ($in{'sok'}) {
		($st) = grep { $_->[0] eq $in{'ssearch'} } @server_statuses;
		$msg = $text{'status_'.$in{'ssearch'}};
		if ($st) {
			$msg = "<font color=$st->[1]>$msg</font>";
			}
		push(@g, &text('index_resstatus', $msg,
			    scalar(@allservers), scalar(@servers)));
		}
	elsif ($in{'search'}) {
		push(@g, &text('index_ressearch', &html_escape($in{'search'}),
			    scalar(@allservers), scalar(@servers)));
		}
	if (@g) {
		if ($using_default_search) {
			push(@g, "<a href='save_search.cgi'>".
				 "$text{'index_nosearch'}</a>");
			}
		else {
			push(@g, "<a href='save_search.cgi?in=".&urlize($in).
				 "'>$text{'index_savesearch'}</a>");
			}
		print &ui_grid_table(\@g, 2, 100,
			[ "", "width=20% align=right" ]);
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
			    ("&nbsp;&nbsp;" x $s->{'indent'}).
			    ($s->{'status'} eq 'create' ? $shost :
				     "<a href='edit_serv.cgi?".
				     "id=$s->{'id'}'>$shost</a>"),
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
if (!$main::vm2_no_global_links) {
	($glinks, $gtitles, $gicons) = &get_global_links($virtcount);
	if (@$glinks) {
		print "<hr>\n";
		print &ui_subheading($text{'index_header'});
		&icons_table($glinks, $gtitles, $gicons);
		}
	}

&ui_print_footer("/", $text{'index'});

sub same_hash
{
local ($a, $b) = @_;
local $aa = join("&", map { $_."=".$a->{$_} } sort { $a cmp $b } (keys %$a));
local $bb = join("&", map { $_."=".$b->{$_} } sort { $a cmp $b } (keys %$b));
return $aa eq $bb;
}

