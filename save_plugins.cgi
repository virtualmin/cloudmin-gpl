#!/usr/local/bin/perl
# Updates the list of enabled plugins

require './server-manager-lib.pl';
&error_setup($text{'plugins_err'});
&error_if_cloudmin_replica();
&ReadParse();
&can_action_error(undef, "global");

# Check each to see if usable
@newplugins = split(/\0/, $in{'d'});
foreach my $p (@newplugins) {
	&foreign_require($p, "cloudmin_feature.pl");
	$desc = &plugin_call($p, "plugin_desc");
	$err = &plugin_call($p, "plugin_check");
	if ($err) {
		&error(&text('plugins_echeck', $desc, $err));
		}
	}

# Save them
&obtain_lock_anything();
$config{'plugins'} = join(" ", @newplugins);
&lock_file($module_config_file);
&save_module_config();
&unlock_file($module_config_file);

# Re-write helper command with new plugins list
local @plugindirs = map { &module_root_directory($_) } @newplugins;
&create_api_helper_command(\@plugindirs);

&webmin_log("plugins");
&redirect("index.cgi?refresh=all");

