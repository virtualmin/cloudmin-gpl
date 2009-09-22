#!/usr/local/bin/perl
# Configures the automatic download of new Virtualmin licenses

require './server-manager-lib.pl';
&error_setup($text{'lsched_err'});
&can_action_error(undef, "global");
&can_all_licenses() || &error($text{'lsched_eall'});
&ReadParse();

if ($in{'now'}) {
	# Just check now
	&ui_print_header(undef, $text{'lsched_title'}, "");

	print $text{'lsched_checking'},"<br>\n";
	$got = &fetch_virtualmin_licences();
	if (ref($got)) {
		# Was able to check
		if (@$got) {
			print &text('lsched_done', scalar(@$got)),"<p>\n";
			print &ui_columns_start([ $text{'licences_serial'},
						  $text{'licences_key'},
						  $text{'licences_domains'},
						  $text{'licences_servers'} ]);
			foreach $l (@$got) {
				print &ui_columns_row([
					$l->{'serial'},
					$l->{'key'},
				        $l->{'domains'} ||
						$text{'licences_unlimited'},
				        $l->{'servers'} ||
						$text{'licences_unlimited'},
					]);
				}
			print &ui_columns_end();
			}
		else {
			print $text{'lsched_none'},"<p>\n";
			}
		}
	else {
		print &text('lsched_failed', $got),"<p>\n";
		}

	if (ref($got)) {
		&webmin_log("fetch", "licences", scalar(@$got));
		}
	&ui_print_footer("list_licences.cgi", $text{'licences_return'});
	}
else {
	# Validate and save inputs
	$config{'licences_sched'} = $in{'sched'};
	if ($in{'email_def'}) {
		delete($config{'licences_email'});
		}
	else {
		$in{'email'} =~ /^\S+\@\S+$/ || &error($text{'lsched_eemail'});
		$config{'licences_email'} = $in{'email'};
		}
	&lock_file($module_config_file);
	&save_module_config();
	&unlock_file($module_config_file);
	&webmin_log($in{'sched'} ? "sched" : "unsched", "licences");

	&redirect("list_licences.cgi?mode=list");
	}

