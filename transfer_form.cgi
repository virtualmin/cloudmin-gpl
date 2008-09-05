#!/usr/local/bin/perl
# Show a form for uploading or downloading a file

require './server-manager-lib.pl';
&ReadParse();
@servers = &list_managed_servers();
($server) = grep { $_->{'id'} == $in{'id'} } @servers;
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

&ui_print_header(&server_in($server), $text{'transfer_title'}, "", "transfer");

# Show tabs
$prog = "transfer_form.cgi?id=$in{'id'}&mode=";
@tabs = ( [ "upload", $text{'transfer_tabupload'}, $prog."upload" ],
	  [ "download", $text{'transfer_tabdownload'}, $prog."download" ],
	  [ "transfer", $text{'transfer_tabtransfer'}, $prog."transfer" ],
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

# Start of transfer form
print &ui_tabs_start_tab("mode", "transfer");
print $text{'transfer_transferdesc'},"<p>\n";
print &ui_form_start("transfer.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'transfer_theader'}, undef, 2);

# File on system
print &ui_table_row($text{'transfer_transsource'},
        &ui_textbox("source", undef, 60));

# Target server
print &ui_table_row($text{'transfer_transdestid'},
	&ui_select("destid", undef,
		[ map { [ $_->{'id'}, $_->{'host'} ] }
		      grep { $_->{'id'} != $in{'id'} &&
			     &can_action($_, "transfer") &&
			     ($_->{'status'} eq 'virt' ||
			      $_->{'status'} eq 'novirt' ||
			      $_->{'status'} eq 'nowebmin' ||
			      $_->{'status'} eq 'nowebminlogin') } @servers ]));

# Destination file on other server
print &ui_table_row($text{'transfer_transdest'},
        &ui_textbox("dest", undef, 60, $text{'transfer_same'}));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'transfer_transferok'} ] ]);
print &ui_tabs_end_tab();

print &ui_tabs_end(1);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
