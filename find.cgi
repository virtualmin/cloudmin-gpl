#!/usr/local/bin/perl
# Scan a host system for virtual systems of some type, such as Xen

require './server-manager-lib.pl';
use Socket;
&ReadParse();
$type = $in{'type'};
&can_add_server_error($type);
&error_setup($text{'find_err'});
$vhost = &get_managed_server($in{'id'});
$tmplserver = { 'manager' => $type };

if (!$in{'copyauth'}) {
	# Validate inputs and update template object
	$nsfunc = "type_".$type."_no_ssh";
	if (!defined(&$nsfunc) || !&$nsfunc()) {
		$err = &parse_ssh_login_form(\%in, $tmplserver);
		&error($err) if ($err);
		}
	$nwfunc = "type_".$type."_no_webmin";
	if (!defined(&$nwfunc) || !&$nwfunc()) {
		$err = &parse_webmin_login_form(\%in, $tmplserver);
		&error($err) if ($err);
		}
	}
else {
	# Default authentication settings come from host
	&copy_ssh_login_details($vhost, $tmplserver);
	&copy_webmin_login_details($vhost, $tmplserver);
	}

# Show progress
&ui_print_unbuffered_header(&server_in($vhost),
			    $text{'find_title_'.$type}, "");

$ffunc = "type_".$type."_find_servers";
@found = &$ffunc($vhost, $tmplserver, $in{'running'},
		 $in{'dir_def'} ? undef : $in{'dir'});
if (@found && defined(&theme_post_save_server)) {
	&theme_post_save_server($found[0]);
	}

&ui_print_footer("", $text{'index_return'});
