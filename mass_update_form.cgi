#!/usr/local/bin/perl
# Show a form for finding updates on multiple systems, with searching

require './server-manager-lib.pl';
&ReadParse();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
@servers || &error($text{'mass_enone'});
&can_action_error(\@servers, "update");
if (@servers == 1) {
	&ui_print_header(&server_in($servers[0]), $text{'update_title'}, "");
	}
else {
	&ui_print_header(undef, $text{'update_title'}, "");
	}

# Find all the updates
@upservers = ( );
%oldvers = ( );
%newvers = ( );
$olds = 0;
foreach $s (@servers) {
	$info = &get_server_collected($s);
	my @poss;
	if (!$in{'virt'}) {
		@poss = @{$info->{'allposs'}};
		}
	@poss = @{$info->{'poss'}} if (!@poss);
	$anyvirt++ if (@{$info->{'poss'}});
	if (@poss) {
		push(@upservers, $s);
		}

	# Find new and old versions for each package
	foreach $pkg (@poss) {
		$k = $pkg->{'system'}."/".$pkg->{'name'};
		if (&indexof($pkg->{'version'}, @{$newvers{$k}}) < 0) {
			push(@{$newvers{$k}}, $pkg->{'version'});
			}
		if ($pkg->{'oldversion'} &&
		    &indexof($pkg->{'oldversion'}, @{$oldvers{$k}}) < 0) {
			push(@{$oldvers{$k}}, $pkg->{'oldversion'});
			$olds++;
			}
		$pkgs{$k} ||= $pkg;
		$pkgs{$k}->{'count'}++;
		}
	}

# Show search form
print &ui_form_start("mass_update_form.cgi");
foreach $d (keys %d) {
	print &ui_hidden("d", $d);
	}
print &ui_table_start(undef, undef, 2);
print &ui_table_row($text{'update_search'},
		    &ui_textbox("search", $in{'search'}, 30)." ".
		    &ui_submit($text{'update_sok'}));
if ($anyvirt) {
	print &ui_table_row($text{'update_virt'},
			&ui_yesno_radio("virt", $in{'virt'}));
	}
print &ui_table_end();
print &ui_form_end();

# Apply any search
@pkgs = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } values %pkgs;
if ($in{'search'}) {
	@pkgs = grep { $_->{'name'} =~ /\Q$in{'search'}\E/i ||
		       $_->{'desc'} =~ /\Q$in{'search'}\E/i } @pkgs;
	}

# Show matching packages
if (@pkgs) {
	print "<p>",&text('update_count', scalar(@pkgs)),"<br>\n";
	print &ui_form_start("mass_update.cgi");
	foreach $d (keys %d) {
		print &ui_hidden("d", $d);
		}
	@tds = ( "width=5" );
	@links = ( &select_all_link("p", 1),
		   &select_invert_link("p", 1) );
	print &ui_links_row(\@links);
	print &ui_columns_start([
		'',
		$text{'update_name'},
		$olds ? ( $text{'update_oldversions'} ) : ( ),
		$text{'update_versions'},
		@servers > 1 ? ( $text{'update_servers'} ) : ( ),
		$text{'update_desc'} ], 100, 0, \@tds);
	foreach $pkg (@pkgs) {
		$k = $pkg->{'system'}."/".$pkg->{'name'};
		print &ui_checked_columns_row([
			$pkg->{'name'},
			$olds ? ( join(" ", @{$oldvers{$k}}) ) : ( ),
			join(" ", @{$newvers{$k}}),
			@servers == 1 ? ( ) : ( $pkg->{'count'} ),
			$pkg->{'desc'},
			], \@tds, "p", $k, 1);
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ undef, $text{'update_ok'} ] ]);
	}
else {
	print "<p>$text{'update_none'}<p>\n";
	}

if (@servers == 1 && defined(&theme_select_server)) {
	&theme_select_server($servers[0]);
	}

&ui_print_footer("", $text{'index_return'});

