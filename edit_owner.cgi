#!/usr/local/bin/perl
# Show a form for creating or editing an owner

require './server-manager-lib.pl';
&ReadParse();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'owner_title1'}, "");
	}
else {
	&ui_print_header(undef, $text{'owner_title2'}, "");
	$owner = &get_system_owner($in{'name'});
	}
@allservers = &list_managed_servers_sorted();

print &ui_form_start("save_owner.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("old", $in{'name'});
print &ui_table_start($text{'owner_header'}, undef, 2);

# Username
print &ui_table_row($text{'owner_name'},
	&ui_textbox("name", $owner->{'name'}, 40));

# Password
print &ui_table_row($text{'owner_pass'},
	($in{'new'} ? "" : &ui_radio("pass_def", 1, 
			    [ [ 1, $text{'owner_leave'} ],
			      [ 0, $text{'owner_set'} ] ])).
	&ui_password("pass", undef, 20));

# Description
print &ui_table_row($text{'owner_real'},
	&ui_textbox("real", $owner->{'real'}, 40));

# Contact email
print &ui_table_row($text{'owner_email'},
	&ui_textbox("email", $owner->{'acl'}->{'email'}, 40));

# Managed servers
print &ui_table_row($text{'owner_servers'},
	&ui_select("servers", [ split(/\s+/, $owner->{'acl'}->{'servers'}) ],
		   [ map { $_->{'id'}, ("&nbsp;&nbsp;" x $_->{'indent'}).
					$_->{'short_host'} } @allservers ],
		   10, 1));

print &ui_table_end();
print &ui_form_end(
    $in{'new'} ? [ [ undef, $text{'create'} ] ]
	       : [ [ undef, $text{'save'} ], [ 'delete', $text{'delete'} ] ]); 

&ui_print_footer("list_owners.cgi", $text{'owners_return'});

