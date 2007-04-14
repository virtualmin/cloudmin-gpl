#!/usr/local/bin/perl
# Create, update or delete an SSH key

require './server-manager-lib.pl';
&ReadParseMime();
if (!$in{'new'}) {
	($key) = grep { $_->{'id'} eq $in{'id'} } &list_ssh_keys();
	}
&error_setup($text{'key_err'});

if ($in{'delete'}) {
	# Remove this SSH key
	@servers = &list_managed_servers();
	@users = grep { $_->{'key'} eq $key->{'id'} } @servers;
	if (@users && !$in{'confirm'}) {
		# Ask first!
		&ui_print_header(undef, $text{'dkey_title'}, undef);

		print "<center>\n";
		print &ui_form_start("save_key.cgi", "form-data");
		print &ui_hidden("id", $in{'id'});
		print &ui_hidden("delete", 1);
		print &text('dkey_rusure', "<i>$key->{'desc'}</i>",
			join(", ", map { "<tt>$_->{'host'}</tt>" } @users)),
			"<p>\n";
		print $text{'dkey_rusure2'},"<p>\n";
		print &ui_form_end([ [ "confirm", $text{'dkey_ok'} ] ]);
		print "</center>\n";

		&ui_print_footer("list_keys.cgi", $text{'keys_return'});
		exit;
		}
	else {
		# Do it..
		&delete_ssh_key($key);
		}
	&webmin_log("delete", "key", $key->{'id'},
		    { 'desc' => $key->{'desc'} });
	}
elsif ($in{'new'}) {
	# Validate and/or generate
	$in{'desc'} =~ /\S/ || &error($text{'key_edesc'});
	$key = { 'desc' => $in{'desc'} };
	}
else {
	# Update
	}
&redirect("list_keys.cgi");

