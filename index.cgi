#!/usr/local/bin/perl
# Show a table of managed servers, links to create new ones, and global options

require './server-manager-lib.pl';
&ui_print_header(undef, $text{'index_title'}, "", "intro", 1, 1);
&ReadParse();

if (!%in || scalar(keys %in) == 1 && $in{'refresh'}) {
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

@allservers = &list_available_managed_servers_sorted();

# Build add links
if (!$main::cloudmin_no_create_links) {
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
	print &show_search_form(\%in, \@allservers);
	print &ui_form_end();
	$formno++;

	# Apply the current search
	@servers = &apply_search_form(\%in, \@allservers);
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
		my $parent = &get_managed_server_by("id", $in{'psearch'});
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

	# Work out columns to show
	@colnames = ( split(/,/, $config{'index_cols'}) );
	if (defined(&list_locations)) {
		%lmap = map { $_->{'id'}, $_->{'desc'} } &list_locations();
		}

	print &ui_form_start("mass.cgi", "post");
	@tds = ( "width=5" );
	print &ui_links_row([ @links, @crlinks ]);
	foreach $cat (@cats) {
		print &ui_subheading($cat->[1]) if ($cat->[1]);
		print &ui_columns_start([
			"",
			$text{'index_host'},
			(map { $text{'index_'.$_} } @colnames),
			], 100, 0, \@tds);
		foreach my $s (@{$cat->[0]}) {
			$t = $s->{'manager'};
			$tfunc = "type_".$t."_desc";
			$pos = $s->{'all_poss'} || $s->{'virtualmin_poss'};
			$posdesc = undef;
			if ($pos) {
				# Has some updates
				$posscount += $pos;
				$posdesc = " - ".&text($pos > 1 ?
					'index_poss' : 'index_pos', $pos,
					"mass_update_form.cgi?d=$s->{'id'}");
				}

			# Create hostname link
			$shost = $s->{'short_host'};
			if ($s->{'status'} eq 'create') {
				# Creating, cannot edit
				$link = $shost;
				}
			elsif (&can_action($s, "edit") ||
			       &can_action($s, "view")) {
				$link = "<a href='edit_serv.cgi?".
                                     "id=$s->{'id'}'>$shost</a>";
				}
			else {
				$link = $shost;
				}

			# Create other columns
			@cols = ( );
			foreach $c (@colnames) {
				if ($c eq "manager") {
					push(@cols, &$tfunc());
					}
				elsif ($c eq "type") {
					push(@cols, &describe_os($s->{'type'}));
					}
				elsif ($c eq "status") {
					push(@cols, &describe_status($s, 1, 2).
						    $posdesc);
					}
				elsif ($c eq "location") {
					if ($s->{'location'}) {
						$l = $s->{'location'};
						}
					else {
						my $vs = &get_parent_server($s);
						if ($vs && $vs->{'location'}) {
							$l = $vs->{'location'};
							}
						else {
							$l = undef;
							}
						}
					if ($l && $lmap{$l}) {
						push(@cols, $lmap{$l});
						}
					else {
						push(@cols, '');
						}
					}
				elsif ($c eq "ip") {
					$ip = &get_server_ip($s);
					push(@cols, $ip);
					}
				else {
					push(@cols, $s->{$c});
					}
				}

			print &ui_checked_columns_row([
			    ("&nbsp;&nbsp;" x $s->{'indent'}).$link,
			    @cols,
			    ], \@tds, "d", $s->{'id'});
			$virtcount++ if ($s->{'status'} eq 'virt');
			$procount++ if ($s->{'virtualmin_serial'});
			}
		print &ui_columns_end();
		}
	print &ui_links_row([ @links, @crlinks ]);
	@buts = (    [ "refresh", $text{'index_refresh'} ],
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
		     [ "reboot", $text{'index_reboot'} ],
		     undef,
		     [ "upload", $text{'index_upload'} ],
		     [ "run", $text{'index_run'} ],
		 );
	@buts = grep { !$_ || &can_action(undef, $_->[0]) } @buts;
	while(@buts && !$buts[0]) { shift(@buts); }	# Strip leading spacers
	print &ui_form_end(\@buts);
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
if (!$main::cloudmin_no_global_links) {
	($glinks, $gtitles, $gicons) = &get_global_links($virtcount);
	if (@$glinks) {
		print "<hr>\n";
		print &ui_subheading($text{'index_header'});
		&icons_table($glinks, $gtitles, $gicons);
		}
	}

# Refresh left frame if requested by redirector
if ($in{'refresh'} && defined(&theme_post_save_server)) {
	if ($in{'refresh'} eq 'all') {
		# Whole left frame
		&theme_post_save_server($allservers[0]);
		}
	else {
		# Just one server
		$server = &get_managed_server_by("id", $in{'refresh'});
		if ($server) {
			&theme_post_save_server($server);
			}
		}
	}

&ui_print_footer("/", $text{'index'});

sub same_hash
{
my ($ahash, $bhash) = @_;
my $aa = join("&", map { $_."=".$a->{$_} } sort { $a cmp $b } (keys %$ahash));
my $bb = join("&", map { $_."=".$b->{$_} } sort { $a cmp $b } (keys %$bhash));
return $aa eq $bb;
}

