#!/usr/local/bin/perl
# Show the first wizard form asking for the virtualization type and source

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'import_title'}, "");
&ReadParse();

print &ui_form_start("manual_image_form.cgi", "post");
print &ui_table_start($text{'import_header'}, undef, 2);

# VM type
my @opts;
foreach my $t (@virtual_server_management_types) {
	my $mfunc = "type_".$t."_can_manual_image";
	if (defined(&$mfunc) && &$mfunc()) {
		push(@opts, [ $t, $text{$t.'_typedesc'} ]);
		}
	}
print &ui_table_row($text{'import_type'},
	&ui_select("manager", undef, \@opts));

# Import source
my $sgrid = &ui_grid_table([
	$text{'import_stackuser'},
	&ui_textbox("stackuser", $config{'stackuser'}, 30),
	$text{'import_stackpass'},
	&ui_password("stackpass", $config{'stackpass'}, 30),
	], 2);
print &ui_table_row($text{'import_source'},
	&ui_radio("source", 0, [ [ 0, $text{'import_source0'}."<br>" ],
				 [ 1, $text{'import_source1'}."<br>" ],
				 [ 2, $text{'import_source2'}."<br>".
				      $sgrid ] ]));


print &ui_table_end();
print &ui_form_end([ [ undef, $text{'import_continue'} ] ]);

&ui_print_footer("", $text{'index_return'});
