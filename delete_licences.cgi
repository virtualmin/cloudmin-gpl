#!/usr/local/bin/perl
# Removes a bunch of licences from the pool

require './server-manager-lib.pl';
&error_setup($text{'ldelete_err'});
&can_action_error(undef, "global");
&ReadParse();
@d = split(/\0/, $in{'d'});
@d || &error($text{'ldelete_enone'});

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
&redirect("list_licences.cgi?mode=list");
