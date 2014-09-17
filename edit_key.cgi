#!/usr/local/bin/perl
# Shows a form for adding an SSH key (generated, from an existing file, or
# from an upload), or editing one

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&ui_print_header(undef, $in{'new'} ? $text{'key_create'}
				   : $text{'key_edit'}, "",
		 $in{'new'} ? "createkey" : "editkey");
if (!$in{'new'}) {
	($key) = grep { $_->{'id'} eq $in{'id'} } &list_ssh_keys();
	$key || &error($text{'key_egone'});
	}

print &ui_form_start("save_key.cgi", "form-data");
print &ui_hidden("new", $in{'new'});
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'key_header'}, undef, 2);

# Human-readable description
print &ui_table_row($text{'key_desc'},
		    &ui_textbox("desc", $key->{'desc'}, 40));

if ($in{'new'}) {
	# Source for new key
	@typeopts = ( );
	foreach $t (@server_management_types) {
		$kfunc = "type_${t}_ssh_key_opts";
		if (defined(&$kfunc)) {
			push(@typeopts, &$kfunc());
			}
		}
	print &ui_table_row($text{'pubkey_gen'},
		&ui_radio("gen", 0, 
		  [ [ 0, $text{'key_gen0'}."<br>" ],
		    [ 1, &text('key_gen1',
			       &ui_textbox("file", undef, 40))." ".
			 &file_chooser_button("file", 0)."<br>" ],
		    [ 2, &text('key_gen2',
			       &ui_upload("upload", 40))."<br>" ],
		    [ 3, &text('key_gen3',
			       &ui_textarea("data", undef, 5, 80))."<br>" ],
		    @typeopts,
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
		print &ui_table_row($text{'key_data'},
			&ui_textarea("data", $key->{'keydata'}, 10, 80));
		}
	else {
		# Show link to download binary key
		print &ui_table_row($text{'key_data'},
			"<a href='download_key.cgi/identity?id=$key->{'id'}'>".
			"$text{'key_download'}</a>");
		}

	# Show public key
	print &ui_table_row($text{'key_public'},
		&ui_textarea("public", &wrap_long_line(
					&generate_public_key($key), 80),
			     10, 80, "off", 0, "readonly disabled"));

	# Show type-specific key info
	foreach $t (@server_management_types) {
		$kfunc = "type_${t}_ssh_key_form";
		if (defined(&$kfunc)) {
			print &$kfunc($key);
			}
		}
	}

# Put on new systems?
print &ui_table_row($text{'key_addnew'},
	&ui_yesno_radio("addnew", $key->{'addnew'}));

print &ui_table_end();
print &ui_form_end($in{'new'} ? [ [ undef, $text{'create'} ] ]
			      : [ [ undef, $text{'save'} ],
				  [ "delete", $text{'delete'} ] ]);

&ui_print_footer("list_keys.cgi", $text{'keys_return'});

