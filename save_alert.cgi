#!/usr/local/bin/perl
# Create, update or delete an alert

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'alert_err'});
&error_if_cloudmin_replica();

# Get the alert being edited
if (!$in{'new'}) {
	$alert = &get_alert($in{'id'});
	$alert || &error($text{'alert_egone'});
	}

if ($in{'delete'}) {
	# Just delete the alert
	&delete_alert($alert);
	&webmin_log("delete", "alert", $alert->{'id'},
		    { 'servers' => &describe_alert_servers($alert) });
	}
else {
	# Validate inputs
	$alert ||= { };
	foreach my $f ('all', 'servrers', 'groups', 'owners', 'managers') {
		delete($alert->{$f});
		}

	# Parse systems
	if ($in{'mode'} == 0) {
		# All systems
		$alert->{'all'} = 1;
		}
	elsif ($in{'mode'} == 1) {
		# Selected systems
		$alert->{'servers'} = join(" ", split(/\r?\n/, $in{'servers'}));
		$alert->{'servers'} || &error($text{'alert_eservers'});
		}
	elsif ($in{'mode'} == 2) {
		# Selected groups
		$alert->{'groups'} = join(" ", split(/\r?\n/, $in{'groups'}));
		$alert->{'groups'} || &error($text{'alert_egroups'});
		}
	elsif ($in{'mode'} == 3) {
		# Selected owners
		$alert->{'owners'} = join(" ", split(/\r?\n/, $in{'owners'}));
		$alert->{'owners'} || &error($text{'alert_eowners'});
		}
	elsif ($in{'mode'} == 4) {
		# Checked system types
		$alert->{'managers'} = join(" ", split(/\0/, $in{'managers'}));
		$alert->{'managers'} || &error($text{'alert_emanagers'});
		}
	$alert->{'uponly'} = $in{'uponly'};

	# Parse rules
	@rules = ( );
	for(my $i=0; defined($in{"name_$i"}); $i++) {
		next if (!$in{"name_$i"});
		my $r = { 'name' => $in{"name_$i"} };
		if (&is_binary_alert($r->{'name'})) {
			# Just compared to 1
			$r->{'over'} = 1;
			$r->{'value'} = 0;
			}
		else {
			# Compared to some value
			if ($in{"over_$i"}) {
				$r->{'over'} = 1;
				}
			else {
				$r->{'under'} = 1;
				}
			$in{"value_$i"} =~ s/\s//g;
			$in{"value_$i"} =~ /^[0-9\.]+((K|M|G|T)B?)?$/i ||
				&error(&text('alert_evalue', $i+1));
			$r->{'value'} = $in{"value_$i"};
			}
		$in{"for_$i"} =~ /^[0-9\.]+$/ ||
			&error(&text('alert_efor', $i+1));
		$r->{'for'} = &join_for_units($in{"forunit_$i"}, $in{"for_$i"});
		$in{"count_$i"} =~ /^[0-9]+$/ ||
			&error(&text('alert_ecount', $i+1));
		$r->{'count'} = $in{"count_$i"};
		push(@rules, $r);
		}
	@rules || &error($text{'alert_erules'});
	$alert->{'rules'} = \@rules;
	$alert->{'and'} = $in{'and'};
	$alert->{'or'} = !$in{'and'};

	# Parse message
	$alert->{'desc'} = $in{'desc_def'} ? undef : $in{'desc'};
	$alert->{'master'} = $in{'master'};
	$alert->{'owner'} = $in{'owner'};
	if ($in{'email'}) {
		$in{'emailto'} =~ /\S/ || &error($text{'alert_eemail'});
		$alert->{'email'} = $in{'emailto'};
		}
	else {
		$alert->{'email'} = '';
		}
	$in{'int'} =~ /^\d+$/ || &error($text{'alert_einterval'});
	$alert->{'interval'} = &join_for_units($in{'intunit'}, $in{'int'});

	# Save or create, and evaluate now
	&save_alert($alert);
	&evaluate_all_alerts(undef, [ $alert ], 1);
	&webmin_log($in{'new'} ? "create" : "modify", "alert", $alert->{'id'},
		    { 'servers' => &describe_alert_servers($alert) });
	}

&redirect("list_alerts.cgi");

