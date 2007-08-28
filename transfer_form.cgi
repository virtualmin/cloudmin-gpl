#!/usr/local/bin/perl
# Show a form for uploading or downloading a file

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();

&ui_print_header(&server_in($server), $text{'transfer_title'}, "", "transfer");

# Show tabs
$prog = "transfer_form.cgi?id=$in{'id'}&mode=";
@tabs = ( [ "upload", $text{'transfer_tabupload'}, $prog."upload" ],
	  [ "download", $text{'transfer_tabdownload'}, $prog."download" ],
	);
print &ui_tabs_start(\@tabs, "mode", $in{'mode'} || "upload", 1);

# Start of upload form
print &ui_tabs_start_tab("mode", "upload");
print $text{'transfer_uploaddesc'},"<p>\n";
print &ui_form_start("upload.cgi", "form-data");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'transfer_uheader'}, undef, 2);

# Source for file
print &ui_table_row($text{'transfer_upsource'},
	&ui_radio_table("source", 0, 
	  [ [ 0, $text{'transfer_local'}, &ui_upload("local", 40) ],
	    [ 1, $text{'transfer_file'}, &ui_textbox("file", undef, 40) ] ]));

# Destination on server
print &ui_table_row($text{'transfer_updest'},
	&ui_textbox("dest", undef, 60));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'transfer_uploadok'} ] ]);
print &ui_tabs_end_tab();

# Start of download form
print &ui_tabs_start_tab("mode", "download");
print $text{'transfer_downloaddesc'},"<p>\n";
print &ui_form_start("download.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'transfer_dheader'}, undef, 2);

# File on system
print &ui_table_row($text{'transfer_downsource'},
	&ui_textbox("source", undef, 60));

# Save mode
print &ui_table_row($text{'transfer_downdest'},
	&ui_radio_table("dest", 0, 
	  [ [ 0, $text{'transfer_show'},
		 &ui_checkbox("force", 1, $text{'transfer_force'}) ],
	    [ 1, $text{'transfer_file2'},
		 &ui_textbox("file", undef, 40) ] ]));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'transfer_downloadok'} ] ]);
print &ui_tabs_end_tab();

print &ui_tabs_end(1);

&ui_print_footer("", $text{'index_return'});
