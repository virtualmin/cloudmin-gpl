#!/usr/local/bin/perl
# Updates the list of enabled plugins

require './server-manager-lib.pl';
&error_setup($text{'plugins_err'});
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
$config{'plugins'} = join(" ", @newplugins);
&lock_file($module_config_file);
&save_module_config();
&unlock_file($module_config_file);
&redirect("index.cgi?refresh=all");

