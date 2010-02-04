#!/usr/local/bin/perl
# Removes a bunch of licences from the pool

require './server-manager-lib.pl';
&error_setup($text{'ldelete_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "global");
&ReadParse();
@d = split(/\0/, $in{'d'});
@d || &error($text{'ldelete_enone'});
&obtain_lock_anything();

# Remove from list
@lics = &list_virtualmin_licences();
foreach $d (@d) {
	($lic) = grep { $_->{'serial'} eq $d } @lics;
	if ($lic) {
		$lic->{'vm2'} && &error($text{'ldelete_evm2'});
		@lics = grep { $_ ne $lic } @lics;
		}
	}
&save_virtualmin_licences(\@lics);
&webmin_log("delete", "licences", scalar(@d));
&redirect("list_licences.cgi?mode=list");
