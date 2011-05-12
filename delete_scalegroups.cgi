#!/usr/local/bin/perl
# Delete, evaluate or re-scale selected groups

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
&can_action_error(undef, "global");
@d = split(/\0/, $in{'d'});

if ($in{'delete'}) {
	# Remove selected groups
	&error_setup($text{'dscalegroups_err'});
	@d || &error($text{'dscalegroups_enone'});
	foreach $id (@d) {
		$scalegroup = &get_scalegroup($id);
		&delete_scalegroup($scalegroup) if ($scalegroup);
		}
	&webmin_log("delete", "scalegroups", scalar(@d));
	&redirect("list_scalegroups.cgi");
	}
elsif ($in{'refresh'}) {
	# Evaluate selected groups
	# XXX
	}
elsif ($in{'up'}) {
	# Scale up selected groups
	&error_setup($text{'scaleup_err'});
	@d || &error($text{'dscalegroups_enone'});
	&ui_print_header(undef, $text{'scaleup_title'}, "");

	foreach $id (@d) {
                $scalegroup = &get_scalegroup($id);
		next if (!$scalegroup);
		&$first_print(&text('scaleup_doing',
				    "<tt>$scalegroup->{'host'}</tt>"));
		&obtain_lock_scalegroup($scalegroup);
		&$indent_print();
		my ($err, $newserver) = &create_scalegroup_system($scalegroup);
		&release_lock_scalegroup($scalegroup);
		&$outdent_print();
		if ($err) {
			&$second_print(&text('scaleup_failed', $err));
			}
		else {
			$newserver->{'scalegroup_reason'} = 'web';
			&save_managed_server($newserver);
			&$second_print(&text('scaleup_done',
					     $newserver->{'host'}));
			}
		}
	&webmin_log("scaleup", "scalegroups", scalar(@d));
	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
	}
elsif ($in{'down'}) {
	# Scale down selected groups
	&error_setup($text{'scaledown_err'});
	@d || &error($text{'dscalegroups_enone'});
	&ui_print_header(undef, $text{'scaledown_title'}, "");

	foreach $id (@d) {
                $scalegroup = &get_scalegroup($id);
		next if (!$scalegroup);
		&$first_print(&text('scaledown_doing',
				    "<tt>$scalegroup->{'host'}</tt>"));
		&obtain_lock_scalegroup($scalegroup);
		my ($err, $server) = &delete_scalegroup_system($scalegroup);
		&release_lock_scalegroup($scalegroup);
		if ($err) {
			&$second_print(&text('scaledown_failed', $err));
			}
		else {
			&$second_print(&text('scaledown_done',
					     $server->{'host'}));
			}
		}
	&webmin_log("scaledown", "scalegroups", scalar(@d));
	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
	}


