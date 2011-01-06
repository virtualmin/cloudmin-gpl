#!/usr/local/bin/perl
# Show a form for creating or editing an account plan

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
@plans = &list_plans();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'plan_title1'}, "");
	$plan = { 'types' => join(' ', @virtual_server_management_types),
		  'actions' => join(' ', &list_safe_owner_actions()) };
	}
else {
	&ui_print_header(undef, $text{'plan_title2'}, "");
	($plan) = grep { $_->{'id'} eq $in{'id'} } @plans;
	}

print &ui_form_start("save_plan.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
print &ui_hidden_table_start($text{'plan_header'}, "width=100%", 2, "main", 1,
			     [ "width=30%" ]);

# Plan name
print &ui_table_row($text{'plan_desc'},
	&ui_textbox("desc", $plan->{'desc'}, 60));

foreach $l (@plan_limit_types) {
	$field = &indexof($l, @nice_plan_limit_types) >= 0 ?
		&ui_bytesbox("max_".$l, $plan->{'max_'.$l}, 6) :
		&ui_textbox("max_".$l, $plan->{'max_'.$l} || undef, 6);
	print &ui_table_row($text{'plan_max_'.$l},
		&ui_radio("max_".$l."_def", $plan->{'max_'.$l} ? 0 : 1,
			  [ [ 1, $text{'domains_unlimited'} ],
			    [ 0, $field ] ]).
		($l eq "cpu" ? "%" : ""));
	}

print &ui_hidden_table_end();

print &ui_hidden_table_start($text{'plan_header2'}, "width=100%", 2, "acts", 0,
			     [ "width=30%" ]);

# Allowed actions
%actions = map { $_, 1 } split(/\s+/, $plan->{'actions'});
print &ui_table_row($text{'plan_actions'},
	&ui_grid_table(
	     [ map { &ui_checkbox("actions", $_, $text{'owner_action_'.$_},
				  $actions{$_}) } &list_owner_actions() ],
	     2, 100, [ "width=50%", "width=50%" ]));

# Allowed VPS types
@cantypes = split(/\s+/, $plan->{'types'});
foreach $t (grep { $_ ne 'this' } @server_management_types) {
	$dfunc = "type_".$t."_desc";
	push(@typesboxes, &ui_checkbox("types", $t, &$dfunc(),
				       &indexof($t, @cantypes) >= 0));
	}
print &ui_table_row($text{'plan_types'}, join("<br>\n", @typesboxes));

# Users on this plan
if (!$in{'new'}) {
	@users = grep { $_->{'acl'}->{'plan'} eq $plan->{'id'} }
		      &list_system_owners();
	if (@users) {
		print &ui_table_row($text{'plan_owners'},
			&ui_links_row([
			   map { "<a href='edit_owner.cgi?name=".
				 &urlize($_->{'name'})."'>".
				 &html_escape($_->{'name'})."</a>" } @users ]));
		}
	}

print &ui_hidden_table_end();

print &ui_hidden_table_start($text{'plan_header3'}, "width=100%", 2, "hosts", 0,
			     [ "width=30%" ]);

# Allowed host systems
@parents = grep { &is_parent_server($_) } &list_managed_servers();
if (@parents) {
	@parents = sort { $a->{'host'} cmp $b->{'host'} } @parents;
	@groups = &unique(map { split(/\t/, $_->{'group'}) } @parents);
	print &ui_table_row($text{'plan_hosts'},
		&ui_radio("hosts_def", $plan->{'hosts'} ? 0 : 1,
			  [ [ 1, $text{'plan_hosts1'} ],
			    [ 0, $text{'plan_hosts0'} ] ])."<br>\n".
		&ui_select("hosts", [ split(/\s+/, $plan->{'hosts'}) ],
			   [ (map { [ $_->{'id'}, $_->{'host'} ] } @parents),
			     (map { [ "group_".$_, &text('plan_mems', $_) ] }
				  @groups) ],
			   5, 1));
	}
else {
	print &ui_hidden("hosts_def", 1);
	}

# Host system allocation mode
print &ui_table_row($text{'plan_hostmode'},
	&ui_radio_table("hostmode", $plan->{'hostmode'},
			[ [ '', $text{'plan_hostmodefree'} ],
			  map { [ $_, $text{'plan_hostmode'.$_} ] }
			      @plan_hostmodes ], 1));

print &ui_hidden_table_end();

@images = defined(&list_server_images) ? &list_server_images() : ( );
if (@images) {
	print &ui_hidden_table_start($text{'plan_header4'}, "width=100%", 2,
				     "images", 0, [ "width=30%" ]);

	# Allowed system images
	print &ui_table_row($text{'plan_images'},
		&ui_radio("images_def", $plan->{'images'} ? 0 : 1,
			  [ [ 1, $text{'plan_images1'} ],
			    [ 0, $text{'plan_images0'} ] ])."<br>\n".
		&ui_select("images", [ split(/\s+/, $plan->{'images'}) ],
			   [ [ "none", $text{'plan_noimage'} ],
			     map { [ $_->{'id'}, $_->{'longdesc'} ] }
				 sort { $a->{'desc'} cmp $b->{'desc'} }
				      &list_server_images() ], 10, 1));

	print &ui_hidden_table_end();
	}
else {
	print &ui_hidden("images_def", 1);
	}

# Section for plugin-defined limits
@iplugins = grep { &plugin_defined($_, "show_plan_inputs") } @plugins;
if (@iplugins) {
	print &ui_hidden_table_start($text{'plan_header5'}, "width=100%", 2,
				     "plugins", 0, [ 'width=30%' ]);
	foreach $p (@iplugins) {
		print &plugin_call($p, "show_plan_inputs", $plan, $in{'new'});
		}
	print &ui_hidden_table_end();
	}

print &ui_form_end(
    $in{'new'} ? [ [ undef, $text{'create'} ] ]
	       : [ [ undef, $text{'plan_save'} ],
		   [ 'delete', $text{'delete'} ] ]); 

&ui_print_footer("list_plans.cgi", $text{'plans_return'});

