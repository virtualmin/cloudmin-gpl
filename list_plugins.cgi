#!/usr/local/bin/perl
# Shows a list of available plugins, with checkboxes

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'plugins_title'}, "", "plugins");

# Find modules that are plugins
foreach $minfo (&get_all_module_infos()) {
	$root = &module_root_directory($minfo->{'dir'});
	if (&check_os_support($minfo) &&
	    -r "$root/cloudmin_feature.pl") {
		&foreign_require($minfo->{'dir'}, "cloudmin_feature.pl");

		# What does this plugin provide?
		@prov = ( );
		foreach my $f ("server_actions", "settings_links",
			       "theme_sections") {
			if (&plugin_defined($minfo->{'dir'}, $f)) {
				push(@prov, $text{'plugins_'.$f});
				}
			}

		# Links to actions
		@acts = ( );
		if (-r "$root/config.info") {
			push(@acts, "<a href='../config.cgi?$minfo->{'dir'}'>".
				    "$text{'plugins_config'}</a>");
			}
		if (!$minfo->{'hidden'}) {
			push(@acts, "<a href='../$minfo->{'dir'}/'>".
				    "$text{'plugins_open'}</a>");
			}
		push(@acts, $text{'plugins_noacts'}) if (!@acts);

		# Add the row
		push(@table, [
			{ 'type' => 'checkbox', 'name' => 'd',
			  'value' => $minfo->{'dir'},
			  'checked' => &indexof($minfo->{'dir'}, @plugins) >= 0
			},
			&plugin_call($minfo->{'dir'}, "plugin_desc"),
			join(", ", @prov),
			&ui_links_row(\@acts),
			]);
		}
	}

# Show a form table to enable
print &ui_form_columns_table(
	"save_plugins.cgi",
	[ [ undef, $text{'save'} ] ],
	0,
	undef,
	undef,
	[ $text{'plugins_active'}, $text{'plugins_desc'},
	  $text{'plugins_prov'}, $text{'plugins_actions'} ],
	100,
	\@table,
	1,
	undef,
	undef,
	$text{'plugins_none'},
	);

&ui_print_footer("", $text{'index_return'});
