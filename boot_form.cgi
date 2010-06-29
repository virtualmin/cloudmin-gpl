#!/usr/local/bin/perl
# Show a form for changing a system's boot mode

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'boot_errget'});
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "boot");

# Get the current boot mode
$lfunc = "type_".$server->{'manager'}."_list_boot_modes";
$modes = &$lfunc($server);
ref($modes) || &error($modes);
$gfunc = "type_".$server->{'manager'}."_get_boot_mode";
($ok, $mode) = &$gfunc($server);
$ok || &error($mode);

&ui_print_header(&server_in($server), $text{'boot_title'}, "", "boot");

print $text{'boot_desc'},"<p>\n";

print &ui_form_start("boot.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'boot_header'}, undef, 2);

# System type
$tfunc = "type_".$server->{'manager'}."_desc";
print &ui_table_row($text{'mkimage_type'},
		    &$tfunc());

# Current kernel
$info = &get_server_collected($server);
if ($info && $info->{'kernel'}->{'version'}) {
	print &ui_table_row($text{'boot_kernel'},
		&text('boot_kernelmsg', $info->{'kernel'}->{'version'},
					$info->{'kernel'}->{'arch'},
					$info->{'kernel'}->{'os'}));
	}

# Host system's kernel
$vhost = &get_parent_server($server);
$vinfo = &get_server_collected($vhost);
if ($vinfo && $vinfo->{'kernel'}->{'version'}) {
	print &ui_table_row($text{'boot_vkernel'},
		&text('boot_kernelmsg', $vinfo->{'kernel'}->{'version'},
					$vinfo->{'kernel'}->{'arch'},
					$vinfo->{'kernel'}->{'os'}));
	}

# Boot mode
print &ui_table_row($text{'boot_mode'},
	&ui_select("mode", $mode,
		   [ map { [ $_->{'id'}, $_->{'desc'} ] } @$modes ]));

# Reboot after changing?
print &ui_table_row($text{'boot_reboot'},
	&ui_yesno_radio("reboot", 0));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'clone_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
