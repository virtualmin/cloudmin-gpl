#!/usr/local/bin/perl
# Show the status of some server, with a limited set of editable fields and
# sections showing domains and status

require './server-manager-lib.pl';
&ReadParse();
&ui_print_header(undef, $text{'edit_title'}, "", "edit");
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$status = $server->{'status'};

# Basic details section
print &ui_form_start("save_serv.cgi", "post");
print &ui_hidden("id", $in{'id'});
print &ui_hidden_table_start($text{'edit_bheader'}, "width=100%", 2, "basic", 1);

# Hostname
print &ui_table_row($text{'edit_host'}, "<tt>$server->{'host'}</tt>");

# System type
$t = $server->{'manager'};
$tfunc = "type_".$t."_desc";
print &ui_table_row($text{'edit_type'}, &$tfunc());

if ($server->{'id'} != 0) {
	# Description (editable)
	print &ui_table_row($text{'edit_desc'},
			    &ui_textbox("desc", $server->{'desc'}, 50), 3);
	}

# Last status
print &ui_table_row($text{'edit_status'},
		    &text('edit_statustime', &describe_status($server, 1, 0),
					     &make_date($server->{'statustime'})));

if ($status eq 'virt' || $status eq 'novirt') {
	# Has Webmin .. show more info
	$info = &get_server_collected($server);
	print &ui_table_row($text{'edit_os'},
			    &describe_os($server->{'type'}));

	print &ui_table_row($text{'edit_webmin'},
			    $info->{'general'}->{'version'});
	}

if ($status eq 'virt') {
	# Enabled for Virtualmin domain creation
	print &ui_table_row($text{'add_canvirt'},
			    &ui_yesno_radio("canvirt", $server->{'novirt'} ? 0 : 1));
	}

print &ui_hidden_table_end("basic");
print &ui_form_end([ [ "save", $text{'save'} ],
		     undef,
		     $status eq 'novirt' ?
		     	( [ "installvirt", $text{'edit_installvirt'} ] ) :
		     $status eq 'nowebmin' ?
		     	( [ "installwebmin", $text{'edit_installwebmin'} ] ) : ( ),
		     [ "reboot", $text{'edit_reboot'} ] ]);

# Virtualmin status
if ($status eq 'virt' && $info) {
	print &ui_hidden_table_start($text{'edit_cheader'}, "width=100%", 2, "coll");

	print &ui_hidden_table_end("coll"),"<p>\n";
	}

# Hosted domains 
if ($status eq 'virt') {
	@doms = &get_server_domains($server);
	print &ui_hidden_table_start($text{'edit_dheader'}, "width=100%", 2, "doms");

	print &ui_hidden_table_end("doms"),"<p>\n";
	}

&ui_print_footer("", $text{'index_return'});

