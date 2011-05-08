#!/usr/local/bin/perl
# Create, update or delete an auto-scaling group

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($in{'delete'} ? $text{'scalegroup_err2'}
			   : $text{'scalegroup_err'});
&error_if_cloudmin_replica();

# Get the scalegroup being edited
if (!$in{'new'}) {
	$scalegroup = &get_scalegroup($in{'id'});
	$scalegroup || &error($text{'scalegroup_egone'});
	}

if ($in{'delete'}) {
	# Just delete the scalegroup
	&delete_scalegroup($scalegroup);
	&webmin_log("delete", "scalegroup", $scalegroup->{'id'},
		    { 'name' => $scalegroup->{'host'} });
	}
else {
	# Validate inputs
	$scalegroup ||= { 'manager' => $in{'manager'} };

	# Group description
	$scalegroup->{'desc'} = $in{'desc'};

	# Min systems in group
	$in{'min'} =~ /^\d+$/ && $in{'min'} > 0 ||
		&error($text{'scalegroup_emin'});
	$scalegroup->{'min'} = $in{'min'};

	# Max systems in group
	$in{'max'} =~ /^\d+$/ && $in{'max'} > $in{'min'} ||
		&error($text{'scalegroup_emax'});
	$scalegroup->{'max'} = $in{'max'};

	# Hostname template
	$in{'host'} =~ /^\S+$/ || &error($text{'scalegroup_ehost'});
	$in{'host'} =~ /\$NUM/ || $in{'host'} =~ /\$\{NUM\}/ ||
		&error($text{'scalegroup_ehostnum'});
	$scalegroup->{'host'} = $in{'host'};

	# System to clone
	$scalegroup->{'clone'} = $in{'clone'};

	# Possible host systems
	delete($scalegroup->{'dest_location'});
	delete($scalegroup->{'dest_hosts'});
	if ($in{'dest_mode'} == 1) {
		$in{'dest_hosts'} eq '' &&
			&error($text{'scalegroup_edesthosts'});
		$scalegroup->{'dest_hosts'} =
			join(" ", split(/\0/, $in{'dest_hosts'}));
		}
	elsif ($in{'dest_mode'} == 2) {
		$scalegroup->{'dest_location'} = $in{'dest_location'};
		}

	# Parse scaling conditions
	@conds = ( );
	for(my $i=0; defined($in{"name_$i"}); $i++) {
		next if (!$in{"name_$i"});
		my $r = { 'name' => $in{"name_$i"} };
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
		$in{"for_$i"} =~ /^[0-9\.]+$/ ||
			&error(&text('alert_efor', $i+1));
		$r->{'for'} = &join_for_units($in{"forunit_$i"}, $in{"for_$i"});
		if ($in{"count_${i}_def"}) {
			$r->{'count'} = 0;
			}
		else {
			$in{"count_$i"} =~ /^[0-9]+$/ && $in{"count_$i"} > 0 ||
				&error(&text('alert_ecount', $i+1));
			$r->{'count'} = $in{"count_$i"};
			}
		push(@conds, $r);
		}
	@conds || &error($text{'scalegroup_econds'});
	$scalegroup->{'conds'} = \@conds;
	$alert->{'and'} = $in{'and'};
	$alert->{'or'} = !$in{'and'};

	# Parse email notification
	$scalegroup->{'notify_inc'} = $in{'notify_inc'};
	$scalegroup->{'notify_dec'} = $in{'notify_dec'};
	$scalegroup->{'notify_over'} = $in{'notify_over'};
	$scalegroup->{'master'} = $in{'master'};
	if ($in{'email'}) {
		$in{'emailto'} =~ /\S/ || &error($text{'alert_eemail'});
		$scalegroup->{'email'} = $in{'emailto'};
		}
	else {
		$scalegroup->{'email'} = '';
		}
	$in{'int'} =~ /^\d+$/ || &error($text{'alert_einterval'});
	$scalegroup->{'interval'} = &join_for_units($in{'intunit'}, $in{'int'});

	# Save or create, and evaluate now
	&save_scalegroup($scalegroup);
	&webmin_log($in{'new'} ? "create" : "modify", "scalegroup",
		    $scalegroup->{'id'},
		    { 'name' => $scalegroup->{'host'} });
	}

&redirect("list_scalegroups.cgi");

