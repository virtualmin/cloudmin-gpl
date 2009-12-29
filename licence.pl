#!/usr/local/bin/perl
# Check licence validity, and save the status

package server_manager;
$main::no_acl_check++;
require './server-manager-lib.pl';

&read_file($licence_status, \%licence);
&update_server_manager_licence(\%licence);
&write_file($licence_status, \%licence);

# Check for new Virtualmin licences
if ($config{'licences_sched'}) {
	$got = &fetch_virtualmin_licences();
	if (ref($got) && @$got) {
		# Found some .. email to the user
		&foreign_require("mailboxes", "mailboxes-lib.pl");
		$msg = "The following Virtualmin licenses have been automaticallly added for\nuse by systems managed by Cloudmin :\n\n";
		$fmt = "%-20.20s %-20.20s %-10.10s %-10.10s\n";
		$msg .= sprintf $fmt, "Serial", "Key", "Domains", "Servers";
		$msg .= sprintf $fmt, ("-" x 20), ("-" x 20), ("-" x 10), ("-" x 10);
		foreach $l (@$got) {
			$msg .= sprintf $fmt, $l->{'serial'},
					      $l->{'key'},
					      $l->{'domains'} || "Unlimited",
					      $l->{'servers'} || "Unlimited";
			}
		$msg .= "\n";
		&mailboxes::send_text_mail(&mailboxes::get_from_address(),
					   $config{'licences_email'},
					   undef,
					   "New Virtualmin licenses",
					   $msg);
		}
	}
