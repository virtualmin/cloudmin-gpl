#!/usr/local/bin/perl
# Show a list of auto-scaling groups

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ui_print_header(undef, $text{'scalegroups_title'}, "", "scalegroups");
&can_action_error(undef, "global");

# Find existing alerts and list them
@scalegroups = &list_scalegroups();
if (@scalegroups) {
	print &ui_form_start("delete_scalegroups.cgi", "get");
	unshift(@links, &select_all_link("d"),
			&select_invert_link("d"));
	print &ui_links_row(\@links);
	@tds = ( "width=5" );
	print &ui_columns_start([ "", $text{'scalegroups_host'},
				  $text{'scalegroups_enabled'},
				  $text{'scalegroups_manager'},
				  $text{'scalegroups_clone'},
				  $text{'scalegroups_cond'},
				  $text{'scalegroups_status'} ], 100, 0, \@tds);
	foreach $s (@scalegroups) {
		my $clone = &get_managed_server($s->{'clone'});
		print &ui_checked_columns_row([
			"<a href='edit_scalegroup.cgi?id=$s->{'id'}'>".
			  $s->{'host'}."</a>",
			$s->{'enabled'} ? $text{'yes'} :
				"<font color=red>$text{'no'}</font>",
			$text{$s->{'manager'}.'_typedesc'},
			$clone->{'host'},
			&describe_alert_rules($s),
			&describe_scalegroup_status($s),
			], \@tds, "d", $s->{'id'});
		}
	print &ui_columns_end();
	print &ui_links_row(\@links);
	print &ui_form_end([ [ 'delete', $text{'scalegroups_delete'} ],
			     undef,
			     [ 'refresh', $text{'scalegroups_refresh'} ],
			     undef,
			     [ 'up', $text{'scalegroups_up'} ],
			     [ 'down', $text{'scalegroups_down'} ],
			   ]);
	}
else {
	print "<b>$text{'scalegroups_none'}</b><p>\n";
	}

# Show form to add
print &ui_form_start("edit_scalegroup.cgi");
print &ui_hidden("new", 1);
print &ui_submit($text{'scalegroups_add'});
print &ui_select("manager", undef,
		 [ map { [ $_, $text{$_.'_typedesc'} ] }
		       @virtual_server_management_types ]);
print &ui_form_end();

&ui_print_footer("", $text{'index_return'});
