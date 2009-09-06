#!/usr/local/bin/perl
# Scan a host system for virtual systems of some type, such as Xen

require './server-manager-lib.pl';
use Socket;
&ReadParse();
&can_add_server_error($in{'type'});
&error_setup($text{'find_err'});
$vhost = &get_managed_server($in{'id'});
$tmplserver = { 'manager' => $in{'type'} };

if (!$in{'copyauth'}) {
	# Validate inputs and update template object
	$err = &parse_ssh_login_form(\%in, $tmplserver);
	&error($err) if ($err);
	$err = &parse_webmin_login_form(\%in, $tmplserver);
	&error($err) if ($err);
	}
else {
	# Default authentication settings come from Xen host
	&copy_ssh_login_details($vhost, $tmplserver);
	&copy_webmin_login_details($vhost, $tmplserver);
	}

# Show progress
&ui_print_unbuffered_header(&server_in($vhost),
			    $text{'find_title_'.$in{'type'}}, "");

$ffunc = "type_".$in{'type'}."_find_servers";
@found = &$ffunc($vhost, $tmplserver, $in{'running'},
		 $in{'dir_def'} ? undef : $in{'dir'});
if (@found && defined(&theme_post_save_server)) {
	&theme_post_save_server($found[0]);
	}

&ui_print_footer("", $text{'index_return'});
