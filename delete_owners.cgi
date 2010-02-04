#!/usr/local/bin/perl
# Delete, disable or enable a bunch of system owners

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'downers_err'});
&error_if_cloudmin_replica();
@d = split(/\0/, $in{'d'});
@d || &error($text{'downers_enone'});

foreach $d (@d) {
	$owner = &get_system_owner($d);
	if ($owner) {
		if ($in{'disable'}) {
			# Just lock password
			$owner->{'pass'} = "!".$owner->{'pass'}
				if ($owner->{'pass'} !~ /^!/);
			&save_system_owner($owner, $owner);
			}
		elsif ($in{'enable'}) {
			# Un-lock password
			$owner->{'pass'} =~ s/^!//;
			&save_system_owner($owner, $owner);
			}
		else {
			# Delete him
			&delete_system_owner($owner);
			}
		}
	}
&webmin_log($in{'disable'} ? 'disable' : $in{'enable'} ? 'enable' : 'delete',
	    'owners', scalar(@d));
&redirect("list_owners.cgi");

