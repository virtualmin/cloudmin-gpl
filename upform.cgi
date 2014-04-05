#!/usr/local/bin/perl
# Display the upload form for a remote system

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse(undef, undef, 1);
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

&popup_header($file::text{'upload_title'});
$upid = time().$$;
$args = ($in{'extra'} ? $in{'extra'}."&" : "?")."upid=$upid&id=$in{'id'}";

print &ui_form_start("upload_file.cgi$args", "form-data", undef,
		     &read_parse_mime_javascript($upid, [ "file" ]));
print &ui_table_start($file::text{'upload_title'}, "width=100%", 2);

print &ui_table_row($file::text{'upload_file'},
		    &ui_upload("file", 20));

print &ui_table_row($file::text{'upload_dir'},
		    &ui_textbox("dir", $in{'dir'}, 20)."\n".
		    &ui_submit($file::text{'upload_ok'}));

# Upload as user
$user = "root";
print &ui_table_row($file::text{'upload_user'},
		    &ui_user_textbox("user", $user));

print &ui_table_end();
print &ui_form_end();
&popup_footer();

