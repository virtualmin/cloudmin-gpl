#!/usr/local/bin/perl
# Show a form for uploading a file to multiple systems

require './server-manager-lib.pl';
&ReadParse();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();

&ui_print_header(&server_in($server), $text{'mupload_title'}, "", "mupload");

print &text('mupload_desc', scalar(@servers)),"<p>\n";
print &ui_form_start("massupload.cgi", "form-data");
foreach $d (keys %d) {
	print &ui_hidden("d", $d);
	}
print &ui_table_start($text{'mupload_header'}, undef, 2);

# Source for file
print &ui_table_row($text{'transfer_upsource'},
	&ui_radio_table("source", 0, 
	  [ [ 0, $text{'transfer_local'}, &ui_upload("local", 40) ],
	    [ 1, $text{'transfer_file'}, &ui_textbox("file", undef, 40) ] ]));

# Destination on servers
print &ui_table_row($text{'transfer_updest'},
	&ui_textbox("dest", undef, 60));

# Actual servers
print &ui_table_row($text{'mupload_servers'},
	join(" , ", map { "<tt>$_->{'host'}</tt>" } @servers));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'transfer_uploadok'} ] ]);

&ui_print_footer("", $text{'index_return'});
