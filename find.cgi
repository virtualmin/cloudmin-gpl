#!/usr/local/bin/perl
# Scan a host system for virtual systems of some type, such as Xen

require './server-manager-lib.pl';
use Socket;
&ReadParse();
&can_add_server_error($in{'type'});
&error_setup($text{'find_err'});
@servers = &list_managed_servers();
($vhost) = grep { $_->{'id'} eq $in{'id'} } @servers;
$tmplserver = { 'manager' => $in{'type'} };

# Validate inputs and update template object
$err = &parse_ssh_login_form(\%in, $tmplserver);
&error($err) if ($err);
$err = &parse_webmin_login_form(\%in, $tmplserver);
&error($err) if ($err);

# Show progress
&ui_print_unbuffered_header(&server_in($vhost), $text{'find_title'}, "");

@found = &type_xen_find_servers($vhost, $tmplserver);
if (@found && defined(&theme_post_save_server)) {
	&theme_post_save_server($found[0]);
	}

&ui_print_footer("", $text{'index_return'});
