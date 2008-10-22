#!/usr/local/bin/perl
# Shows a list of available plugins, with checkboxes

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'plugins_title'}, "", "plugins");

# Find modules that are plugins
foreach $minfo (&get_all_module_infos()) {
	$root = &module_root_directory($minfo->{'dir'});
	if (&check_os_support($minfo) &&
	    -r "$root/vm2_feature.pl") {
		&foreign_require($minfo->{'dir'}, "vm2_feature.pl");
		@acts = ( );
		if (-r "$root/config.info") {
			push(@acts, "<a href='../config.cgi?$minfo->{'dir'}'>".
				    "$text{'plugins_config'}</a>");
			}
		if (!$minfo{'hidden'}) {
			push(@acts, "<a href='../$minfo->{'dir'}/'>".
				    "$text{'plugins_open'}</a>");
			}
		push(@table, [
			{ 'type' => 'checkbox', 'name' => 'd',
			  'value' => $minfo->{'dir'},
			  'checked' => &indexof($minfo->{'dir'}, @plugins) >= 0
			},
			&foreign_call($minfo->{'dir'}, "plugin_desc"),
			&ui_links_row(\@acts),
			]);
		}
	}

# Show a form table to enable
# XXX

&ui_print_footer("", $text{'index_return'});
