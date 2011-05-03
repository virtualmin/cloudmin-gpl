#!/usr/local/bin/perl
# Show a form for creating or editing a single auto-scaling group

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

if ($in{'new'}) {
	# Creating a new one
	&ui_print_header(undef, $text{'scalegroup_ctitle'}, "");
	$scalegroup = { };
	}
else {
	# Editing an existing one
	&ui_print_header(undef, $text{'scalegroup_etitle'}, "");
	$scalegroup = &get_scalegroup($in{'id'});
	$scalegroup || &error($text{'scalegroup_egone'});
	}

print &ui_form_start("save_scalegroup.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("new", $in{'new'});
@tds = ( "width=20% nowrap" );

# Section for host system details
print &ui_hidden_table_start($text{'scalegroup_header1'}, "width=100%", 2,
			     "hosts", 1, \@tds);

print &ui_hidden_table_end("hosts");

# Section for scaling conditions
print &ui_hidden_table_start($text{'scalegroup_header2'}, "width=100%", 2,
			     "cond", 1, \@tds);

print &ui_hidden_table_end("cond");

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});

