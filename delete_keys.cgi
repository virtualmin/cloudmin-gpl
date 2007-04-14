#!/usr/local/bin/perl
# Delete a bunch of SSH keys

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'dkeys_err'});
@d = split(/\0/, $in{'d'});
@d || &error($text{'dkeys_enone'});

# Get all the keys, and their users
@allkeys = &list_ssh_keys();
@servers = &list_managed_servers();
foreach $d (@d) {
	($key) = grep { $_->{'id'} eq $d } @allkeys;
	$key || &error($text{'dkeys_egone'});
	push(@keys, $key);
	@keyusers = grep { $_->{'key'} eq $key->{'id'} } @servers;
	push(@users, @keyusers);
	}

if (@users && !$in{'confirm'}) {
	# Have to ask first
	&ui_print_header(undef, $text{'dkeys_title'}, undef);

	print "<center>\n";
	print &ui_form_start("delete_keys.cgi", "post");
	foreach $d (@d) {
		print &ui_hidden("d", $d);
		}
	print &text('dkeys_rusure', scalar(@keys),
		join(", ", map { "<tt>$_->{'host'}</tt>" } @users)),
		"<p>\n";
	print $text{'dkeys_rusure2'},"<p>\n";
	print &ui_form_end([ [ "confirm", $text{'dkeys_ok'} ] ]);
	print "</center>\n";

	&ui_print_footer("list_keys.cgi", $text{'keys_return'});
	}
else {
	# Do them
	foreach $key (@keys) {
		&delete_ssh_key($key);
		}
	&webmin_log("delete", "keys", scalar(@keys));
	&redirect("list_keys.cgi");
	}

