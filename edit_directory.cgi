#!/usr/local/bin/perl
# Show a form for creating or editing a disk image directory

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
@directories = &list_directories();
if ($in{'new'}) {
	&ui_print_header(undef, $text{'directory_title1'}, "");
	$directory = { };
	}
else {
	&ui_print_header(undef, $text{'directory_title2'}, "");
	($directory) = grep { $_->{'id'} eq $in{'id'} } @directories;
	$directory || &error($text{'directory_egone'});
	}

print &ui_form_start("save_directory.cgi", "post");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'directory_header'}, "width=100%", 2);

# Directory path
print &ui_table_row($text{'directory_dir'},
	&ui_textbox("dir", $directory->{'dir'}, 60));

# Disk directory description
print &ui_table_row($text{'directory_desc'},
	&ui_textbox("desc", $directory->{'desc'}, 60));

# Can use on host systems
# XXX location groups
@allhosts = grep { &is_parent_server($_) } &list_managed_servers();
@hosts = map { $s = &get_managed_server($_); $s ? ( $s ) : ( ) }
	     split(/\s+/, $directory->{'hosts'});
print &ui_table_row($text{'directory_hosts'},
	&ui_radio("hosts_def", $directory->{'hosts'} ? 0 : 1,
		  [ [ 1, $text{'directory_hosts1'} ],
		    [ 0, $text{'directory_hosts0'} ] ])."<br>\n".
	      &ui_multi_select("hosts",
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @hosts ],
		       [ map { [ $_->{'id'}, $_->{'host'} ] } @allhosts ],
		       10, 1, 0, $text{'alert_serveropts'},
				 $text{'alert_servervals'}));

# Virtualization types
%mans = map { $_, 1 } split(/\s+/, $directory->{'managers'});
print &ui_table_row($text{'directory_managers'},
	&ui_radio("managers_def", $directory->{'managers'} ? 0 : 1,
		  [ [ 1, $text{'directory_managers1'} ],
		    [ 0, $text{'directory_managers0'} ] ])."<br>\n".
	join(" ", map { &ui_checkbox("managers", $_,
                                     $text{$_.'_typedesc'} || $_, $mans{$_}) }
                        @hosted_server_management_types));

# Owner plans
@plans = defined(&list_plans) ? &list_plans() : ( );
%plans = map { $_, 1 } split(/\s+/, $directory->{'plans'});
print &ui_table_row($text{'directory_plans'},
	&ui_radio("plans_def", $directory->{'plans'} eq 'none' ? 2 :
			       $directory->{'plans'} ? 0 : 1,
		  [ [ 2, $text{'directory_plans2'} ],
		    [ 1, $text{'directory_plans1'} ],
		    [ 0, $text{'directory_plans0'} ] ])."<br>\n".
	&ui_select("plans", [ keys %plans ],
		   [ map { [ $_->{'id'}, $_->{'desc'} ] }
			 &list_plans() ],
		   5, 1));

print &ui_table_end();

print &ui_form_end(
    $in{'new'} ? [ [ undef, $text{'create'} ] ]
	       : [ [ undef, $text{'save'} ],
		   [ 'delete', $text{'delete'} ] ]); 

&ui_print_footer("list_directories.cgi", $text{'directories_return'});

