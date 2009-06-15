#!/usr/local/bin/perl
# Show a form for creating or editing an account plan

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
@plans = &list_plans();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'plan_title1'}, "");
	$plan = { 'types' => join(' ', @virtual_server_management_types),
		  'actions' => join(' ', &list_owner_actions()) };
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

# Maximum systems
print &ui_table_row($text{'plan_max_servers'},
	&ui_opt_textbox("max_servers", $plan->{'max_servers'}, 6,
			$text{'domains_unlimited'}));

# Maximum RAM that can be allocated
print &ui_table_row($text{'plan_max_ram'},
	&ui_radio("max_ram_def", $plan->{'max_ram'} ? 0 : 1,
		  [ [ 1, $text{'domains_unlimited'} ],
		    [ 0, &ui_bytesbox("max_ram", $plan->{'max_ram'}, 6) ] ]));

# Maximum disk
print &ui_table_row($text{'plan_max_disk'},
	&ui_radio("max_disk_def", $plan->{'max_disk'} ? 0 : 1,
		  [ [ 1, $text{'domains_unlimited'} ],
		    [ 0, &ui_bytesbox("max_disk", $plan->{'max_disk'}, 6) ] ]));

print &ui_hidden_table_end();

print &ui_hidden_table_start($text{'plan_header2'}, "width=100%", 2, "acts", 1,
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
foreach $t (@virtual_server_management_types) {
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
			&ui_grid_table([
			   map { "<a href='edit_owner.cgi?name='.
				 &urlize($_->{'name'})."'>".
				 &html_escape($_->{'name'})."</a>" } @users ],
			   4, 100));
		}
	}

print &ui_hidden_table_end();

print &ui_form_end(
    $in{'new'} ? [ [ undef, $text{'create'} ] ]
	       : [ [ undef, $text{'plan_save'} ],
		   [ 'delete', $text{'delete'} ] ]); 

&ui_print_footer("list_plans.cgi", $text{'plans_return'});

