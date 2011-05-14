#!/usr/local/bin/perl
# Delete, evaluate or re-scale selected groups

$trust_unknown_referers = 1;
require './server-manager-lib.pl';
&ReadParse();
&can_action_error(undef, "global");
@d = split(/\0/, $in{'d'});
foreach $id (@d) {
	$scalegroup = &get_scalegroup($id);
	push(@scalegroups, $scalegroup) if ($scalegroup);
	}

if ($in{'delete'} && $in{'confirm'}) {
	# Remove selected groups
	&error_setup($text{'dscalegroups_err'});
	@d || &error($text{'dscalegroups_enone'});
	foreach $scalegroup (@scalegroups) {
		&delete_scalegroup($scalegroup);
		}
	$action = "delete";
	&redirect("list_scalegroups.cgi");
	}
elsif ($in{'delete'} && !$in{'confirm'}) {
	# Ask for confirmation before deleting
	&ui_print_header(undef, $text{'dscalegroups_title'}, "");

	print &ui_confirmation_form("delete_scalegroups.cgi",
		&text('dscalegroups_rusure',
		      join(" ", map { "<tt>$_->{'host'}</tt>" } @scalegroups)),
		[ [ 'delete', 1 ],
		  map { [ "d", $_ ] } @d ],
		[ [ 'confirm', $text{'dscalegroups_ok'} ] ],
		);

	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
	}
elsif ($in{'refresh'}) {
	# Evaluate selected groups
	&error_setup($text{'scaleeval_err'});
	@d || &error($text{'dscalegroups_enone'});
	&ui_print_header(undef, $text{'scaleeval_title'}, "");

	foreach $scalegroup (@scalegroups) {
                &$first_print(&text('scaleeval_doing',
                                    "<tt>$scalegroup->{'host'}</tt>"));
		&obtain_lock_scalegroup($scalegroup);
		&$indent_print();
		my $rv = &evaluate_scalegroup($scalegroup);
		&$outdent_print();

		# Generate reason for scaling
		my $st = $rv->{'why'};
		my @names = split(/,/, $st->{'names'});
		my @values = split(/,/, $st->{'values'});
		my @why;
		for(my $i=0; $i<@names; $i++) {
			my ($id, $v) = split(/:/, $values[$i], 2);
			my $s = &get_managed_server($id);
			next if (!$s);
			push(@why, &text('scaleeval_why',
					 $text{'history_stat_'.$names[$i]} ||
					   $names[$i],
					 $s->{'host'}, $v));
			}
		my $why = join(", ", @why);

		# Print message about what happened
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
	if (scalar(@scalegroups) == 1) {
		&webmin_log("eval", "scalegroup", $scalegroups[0]->{'host'});
		}
	else {
		&webmin_log("eval", "scalegroups", scalar(@scalegroups));
		}
	$action = "eval";
	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
	}
elsif ($in{'up'}) {
	# Scale up selected groups
	&error_setup($text{'scaleup_err'});
	@d || &error($text{'dscalegroups_enone'});
	&ui_print_header(undef, $text{'scaleup_title'}, "");

	foreach $scalegroup (@scalegroups) {
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
			&obtain_lock_server($newserver);
			$newserver->{'scalegroup_reason'} = 'web';
			&release_lock_server($newserver);
			&save_managed_server($newserver);
			&$second_print(&text('scaleup_done',
					     $newserver->{'host'}));
			}
		}
	$action = "scaleup";
	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
	}
elsif ($in{'down'}) {
	# Scale down selected groups
	&error_setup($text{'scaledown_err'});
	@d || &error($text{'dscalegroups_enone'});
	&ui_print_header(undef, $text{'scaledown_title'}, "");

	foreach $scalegroup (@scalegroups) {
		&$first_print(&text('scaledown_doing',
				    "<tt>$scalegroup->{'host'}</tt>"));
		&$indent_print();
		&obtain_lock_scalegroup($scalegroup);
		my ($err, $server) = &delete_scalegroup_system($scalegroup);
		&release_lock_scalegroup($scalegroup);
		&$outdent_print();
		if ($err) {
			&$second_print(&text('scaledown_failed', $err));
			}
		else {
			&$second_print(&text('scaledown_done',
					     $server->{'host'}));
			}
		}
	$action = "scaledown";
	&ui_print_footer("list_scalegroups.cgi", $text{'scalegroups_return'});
	}

# Log what was done
if ($action) {
	if (scalar(@scalegroups) == 1) {
		&webmin_log($action, "scalegroup",
			    { 'name' => $scalegroups[0]->{'host'} });
		}
	else {
		&webmin_log($action, "scalegroups", scalar(@scalegroups));
		}
	}
