#!/usr/local/bin/perl
# Show a form for creating a system image

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();

&ui_print_header(&server_in($server), $text{'mkimage_title'}, "", "mkimage");

print $text{'mkimage_desc2'},"<p>\n";
if ($server->{'status'} ne 'down') {
	print $text{'mkimage_desc3'},"<p>\n";
	}

print &ui_form_start("create_image.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'mkimage_header'}, undef, 2, [ "width=30%" ]);

$tfunc = "type_".$server->{'manager'}."_desc";
print &ui_table_row($text{'mkimage_type'},
		    &$tfunc());

print &ui_table_row($text{'mkimage_id'},
		    &ui_textbox("imageid", undef, 30));

print &ui_table_row($text{'mkimage_desc'},
		    &ui_textbox("desc", undef, 60));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'mkimage_ok'} ] ]);


