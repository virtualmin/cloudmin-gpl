#!/usr/local/bin/perl
# Display details of one custom link

require './server-manager-lib.pl';
&ReadParse();
&can_action_error(undef, "global");

# Page header
if ($in{'new'}) {
	&ui_print_header(undef, $text{'elink_title1'}, "", "edit_link");
	$link = { 'who' => { 'master' => 1, 'owner' => 1 } };
	}
else {
	&ui_print_header(undef, $text{'elink_title2'}, "", "edit_link");
	@links = &list_custom_links();
	$link = $links[$in{'idx'}];
	}
@cats = &list_custom_link_categories();

print &ui_hidden_start($text{'newlinks_docs'}, "docs", 0);
print "$text{'newlinks_descr'}<p>\n";
&print_subs_table("HOST", "IP", "SSH_USER");
print &ui_hidden_end(),"<p>\n";

# Start of link details section
print &ui_form_start("save_link.cgi", "post");
print &ui_hidden("idx", $in{'idx'});
print &ui_hidden("new", $in{'new'});
print &ui_hidden_table_start($text{'elink_header1'}, "width=100%", 2,
			     "main", 1, [ "width=30%" ]);

# Description
print &ui_table_row($text{'elink_desc'},
	&ui_textbox("desc", $link->{'desc'}, 40));

# URL template
print &ui_table_row($text{'elink_url'},
	&ui_textbox("url", $link->{'url'}, 60));

# Open mode
print &ui_table_row($text{'elink_open'},
	&ui_radio("open", int($link->{'open'}),
		  [ [ 0, $text{'newlinks_same'} ],
		    [ 1, $text{'newlinks_new'} ] ]));

# Category on menu
print &ui_table_row($text{'elink_cat'},
	&ui_select("cat", $link->{'cat'},
		   [ [ undef, $text{'newlinks_nocat'} ],
		     map { [ $_->{'id'}, $_->{'desc'} ] } @cats ]));

print &ui_hidden_table_end();

# Start of visibility section
print &ui_hidden_table_start($text{'elink_header2'}, "width=100%", 2,
			     "vis", 1, [ "width=30%" ]);

# User types
print &ui_table_row($text{'elink_who'},
	join("<br>\n", map { &ui_checkbox("who", $_,
                                $text{'newlinks_'.$_}, $link->{'who'}->{$_}) }
                           ('master', 'owner')));

# Virtualization type
print &ui_table_row($text{'elink_manager'},
	&ui_select("manager", $link->{'manager'},
                     [ [ "", "&lt;$text{'newlinks_any'}&gt;" ],
                       map { [ $_, $text{$_.'_typedesc'} ] }
			   @server_management_types ]));

# Systems with status
%selst = map { $_, 1 } split(/\s+/, $link->{'status'});
@grid = ( );
foreach my $st (grep { $_ ne 'down' } map { $_->[0] } @server_statuses) {
	$sdesc = &describe_status({ 'status' => $st }, 1, 0);
	push(@grid, &ui_checkbox("status", $st, $sdesc, $selst{$st}));
	}
print &ui_table_row($text{'elink_status'},
	&ui_radio("status_def", $link->{'status'} ? 0 : 1,
		  [ [ 1, $text{'elink_status1'} ],
		    [ 0, $text{'elink_status0'} ] ])."<br>\n".
	&ui_grid_table(\@grid, 5));

# Visible to
$pmode = $link->{'plans'} eq '' ? 2 :
	 $link->{'plans'} eq '*' ? 1 : 0;
@plans = defined(&list_plans) ? &list_plans() : ( );
@opts = ( [ 2, $text{'elink_plans2'} ],
	  [ 1, $text{'elink_plans1'} ] );
if (@plans) {
	push(@opts, [ 0, $text{'elink_plans0'} ]);
	%plans = map { $_, 1 } split(/\s+/, $link->{'plans'});
	$psel = "<br>\n".
		&ui_select("plans", [ keys %plans ],
                   [ map { [ $_->{'id'}, $_->{'desc'} ] }
                         &list_plans() ],
                   5, 1);
	}
print &ui_table_row($text{'elink_plans'},
	&ui_radio("plans_def", $pmode, \@opts).$psel);

print &ui_hidden_table_end();
print &ui_form_end(
	$in{'new'} ? [ [ undef, $text{'create'} ] ]
		   : [ [ undef, $text{'save'} ], [ 'delete', $text{'delete'} ] ]
	);

&ui_print_footer("edit_newlinks.cgi", $text{'newlinks_return'});

