#!/usr/local/bin/perl
# Show a form for creating an Amazon EC2 image

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();

&ui_print_header(&server_in($server), $text{'newami_title'}, "", "newami");

print $text{'newami_desc'},"<p>\n";

print &ui_form_start("newami.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'newami_header'}, undef, 2, [ "width=30%" ]);

$tfunc = "type_".$server->{'manager'}."_desc";
print &ui_table_row($text{'mkimage_type'},
		    &$tfunc());

print &ui_table_row($text{'newami_path'},
		    &ui_textbox("path", undef, 60));

@accounts = &list_ec2_accounts();
print &ui_table_row($text{'newami_account'},
     &ui_select("account", $accounts[0]->{'id'},
		[ map { [ $_->{'id'}, "$_->{'desc'} ($_->{'account'})" ] }
		      @accounts ]));

print &ui_table_row($text{'newami_size'},
		    &ui_bytesbox("size", 5*1024*1024*1024, 10));

print &ui_table_row($text{'newami_public'},
		    &ui_yesno_radio("public", 0));

print &ui_table_row($text{'newami_over'},
		    &ui_yesno_radio("over", 0));

print &ui_table_row($text{'newami_munge'},
		    &ui_yesno_radio("munge", 1));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'newami_ok'} ] ]);

&ui_print_footer("", $text{'index_return'});

