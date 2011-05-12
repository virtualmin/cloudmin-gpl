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
	&error_setup($text{'scaleeval_err'});
	@d || &error($text{'dscalegroups_enone'});
	&ui_print_header(undef, $text{'scaleeval_title'}, "");

	foreach $id (@d) {
                $scalegroup = &get_scalegroup($id);
                next if (!$scalegroup);
                &$first_print(&text('scaleeval_doing',
                                    "<tt>$scalegroup->{'host'}</tt>"));
		&obtain_lock_scalegroup($scalegroup);
		# XXX set $why
		my $rv = &evaluate_scalegroup($scalegroup);
		if ($rv->{'action'} eq 'ok') {
			&$second_print($text{'scaleeval_ok'});
			}
		elsif ($rv->{'action'} eq 'inc' && $rv->{'error'}) {
			&$second_print(&text('scaleeval_finc',
				$why, $rv->{'error'}));
			}
		elsif ($rv->{'action'} eq 'inc' && $rv->{'enabled'}) {
			&$second_print(&text('scaleeval_inc',
				$rv->{'server'}->{'host'}, $why));
			}
		elsif ($rv->{'action'} eq 'inc') {
			&$second_print(&text('scaleeval_noinc', $why));
			}
		elsif ($rv->{'action'} eq 'over') {
			&$second_print(&text('scaleeval_over', $why));
			}
		elsif ($rv->{'action'} eq 'dec' && $rv->{'error'}) {
			&$second_print(&text('scaleeval_fdec',
				$why, $rv->{'error'}));
			}
		elsif ($rv->{'action'} eq 'dec' && $rv->{'enabled'}) {
			&$second_print(&text('scaleeval_dec',
				$rv->{'server'}->{'host'}, $why));
			}
		elsif ($rv->{'action'} eq 'dec') {
			&$second_print(&text('scaleeval_nodec', $why));
			}
		else {
			&$second_print($text{'scaleeval_unknown'});
			}
		&release_lock_scalegroup($scalegroup);
		}
	&webmin_log("scaleup", "scalegroups", scalar(@d));
	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
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


