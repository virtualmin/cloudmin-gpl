#!/usr/local/bin/perl
# Show a list of disk file directories

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'directories_title'}, "", "directories");

@links = ( "<a href='edit_directory.cgi?new=1'>$text{'directories_add'}</a>" );
@directories = &list_directories();
if (@directories) {
	unshift(@links, &select_all_link("d"), &select_invert_link("d"));
	print &ui_form_start("delete_directories.cgi", "post");
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	%locmap = map { $_->{'id'}, $_->{'desc'} } &list_locations();
	print &ui_columns_start([ "",
				  $text{'directories_dir'},
				  $text{'directories_desc'},
				  $text{'directories_managers'},
				  $text{'directories_plans'}, ], 100, 0, \@tds);
	foreach $s (sort { lc($a->{'dir'}) cmp lc($b->{'dir'}) } @directories) {
		if ($s->{'managers'}) {
			$mdesc = join(" ", map { $text{$_.'_typedesc'} }
					    split(/\s+/, $s->{'managers'}));
			}
		else {
			$mdesc = "<i>$text{'directories_mall'}</i>";
			}
		if ($s->{'plans'} eq 'none') {
			$pdesc = "<i>$text{'directories_pnone'}</i>";
			}
		elsif ($s->{'plans'}) {
			$pdesc = join(", ", map { $p = &get_plan($_);
						  $p ? ( $p->{'desc'} ) : ( ) }
					    split(/\s+/, $s->{'plans'}));
			}
		else {
			$pdesc = "<i>$text{'directories_pall'}</i>";
			}
		if ($s->{'dir'}) {
			$ddesc = &html_escape($s->{'dir'});
			}
		else {
			$ddesc = "<i>$text{'directories_ddef'}</i>";
			}
		print &ui_checked_columns_row([
			"<a href='edit_directory.cgi?id=$s->{'id'}'>".
			  $ddesc."</a>",
			&html_escape($s->{'desc'}),
			$mdesc,
			$pdesc,
			], \@tds, "d", $s->{'id'}, 0, $s->{'default'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ undef, $text{'directories_delete'} ] ]);
	}
else {
	print "<b>$text{'directories_none'}</b><p>\n";
	print &ui_links_row(\@links);
	}

&ui_print_footer("", $text{'index_return'});

