#!/usr/local/bin/perl
# Shows a form for adding an SSH key public key, or editing one

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&ui_print_header(undef, $in{'new'} ? $text{'pubkey_create'}
				   : $text{'pubkey_edit'}, "",
		 $in{'new'} ? "createpubkey" : "editpubkey");
if (!$in{'new'}) {
	($key) = grep { $_->{'id'} eq $in{'id'} } &list_ssh_keys();
	$key || &error($text{'key_egone'});
	}

print &ui_form_start("save_pubkey.cgi", "form-data");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'pubkey_header'}, undef, 2);

# Human-readable description
print &ui_table_row($text{'key_desc'},
		    &ui_textbox("desc", $key->{'desc'}, 40));

if ($in{'new'}) {
	# Source for new key
	print &ui_table_row($text{'key_gen'},
		&ui_radio("gen", 1, 
		  [ [ 1, &text('key_gen1',
			       &ui_textbox("file", undef, 40))." ".
			 &file_chooser_button("file", 0)."<br>" ],
		    [ 2, &text('key_gen2',
			       &ui_upload("upload", 40))."<br>" ],
		    [ 3, &text('key_gen3',
			       &ui_textarea("data", undef, 5, 80))."<br>" ],
		  ]));
	}
else {
	# Details of existing key
	if ($key->{'external'}) {
		# Show source file
		print &ui_table_row($text{'key_file'},
			&ui_textbox("file", $key->{'file'}, 60)." ".
			&file_chooser_button("file", 0));
		}
	elsif ($key->{'keydata'} =~ /^[\040-\176\r\n]+$/) {
		# Show key text
		print &ui_table_row($text{'key_public'},
			&ui_textarea("data", $key->{'keydata'}, 10, 80));
		}
	else {
		# Show link to download binary key
		print &ui_table_row($text{'key_public'},
			"<a href='download_key.cgi/identity?id=$key->{'id'}'>".
			"$text{'key_download'}</a>");
		}
	}

# Put on new systems?
print &ui_table_row($text{'key_addnew'},
	&ui_yesno_radio("addnew", $in{'new'} ? 1 : $key->{'addnew'}));

print &ui_table_end();
print &ui_form_end($in{'new'} ? [ [ undef, $text{'create'} ] ]
			      : [ [ undef, $text{'save'} ],
				  [ "delete", $text{'delete'} ] ]);

&ui_print_footer("list_keys.cgi", $text{'keys_return'});

