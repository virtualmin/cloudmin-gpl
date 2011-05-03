#!/usr/local/bin/perl
# Show a form for creating or editing a single auto-scaling group

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();

if ($in{'new'}) {
	# Creating a new one
	&ui_print_header(undef, $text{'scalegroup_ctitle'}, "");
	$scalegroup = { 'host' => 'system${NUM}',
			'min' => 1,
			'max' => 5 };
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
			     "host", 1, \@tds);

print &ui_table_row($text{'scalegroup_desc'},
	&ui_textbox("desc", $scalegroup->{'desc'}, 60));

print &ui_table_row($text{'scalegroup_host'},
	&ui_textbox("host", $scalegroup->{'host'}, 40));

print &ui_table_row($text{'scalegroup_min'},
	&ui_textbox("min", $scalegroup->{'min'}, 5));

print &ui_table_row($text{'scalegroup_max'},
	&ui_textbox("max", $scalegroup->{'max'}, 5));

print &ui_hidden_table_end("host");

# Section for new system details
print &ui_hidden_table_start($text{'scalegroup_header2'}, "width=100%", 2,
			     "system", 1, \@tds);

print &ui_hidden_table_end("system");

# Section for scaling conditions
print &ui_hidden_table_start($text{'scalegroup_header3'}, "width=100%", 2,
			     "cond", 0, \@tds);

print &ui_hidden_table_end("cond");

# Section for email notification
print &ui_hidden_table_start($text{'scalegroup_header4'}, "width=100%", 2,
			     "email", 0, \@tds);

print &ui_hidden_table_end("email");

if ($in{'new'}) {
	print &ui_form_end([ [ undef, $text{'create'} ] ]);
	}
else {
	print &ui_form_end([ [ undef, $text{'save'} ],
			     [ 'delete', $text{'delete'} ] ]);
	}

&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});

