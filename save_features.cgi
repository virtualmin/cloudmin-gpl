#!/usr/local/bin/perl
# Save list of default features

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'features_err'});

if ($in{'def'}) {
	# Use automatic defaults
	delete($config{'defs'});
	}
else {
	# Use selected
	@features = split(/\0/, $in{'features'});
	@features || &error($text{'features_enone'});
	$config{'defs'} = join(" ", @features);
	}
&save_module_config();
&redirect("");

