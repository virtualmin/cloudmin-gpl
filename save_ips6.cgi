#!/usr/local/bin/perl
# Save common IPv6 pools

require './server-manager-lib.pl';
&error_setup($text{'ips6_err'});
&error_if_cloudmin_replica();
&can_action_error(undef, "global");
&ReadParse();

# Find hosts using each pool
%poolmap = ( );
@pools = &list_ip6_pools();
foreach $s (&list_managed_servers()) {
	foreach $t (&is_parent_server($s)) {
		$t = "zone" if ($t eq "zones");
		foreach $p (split(/\s+/, $s->{$t.'_pool6'})) {
			$poolmap{$p} ||= [ ];
			push(@{$poolmap{$p}}, [ $s, $t ]);
			}
		}
	}

# Validate and store inputs
&lock_file($pools6_file);
@newpools = ( );
for($i=0; defined($in{"start_$i"}) || $i < scalar(@pools); $i++) {
	if (!$in{"active_$i"}) {
		# Pool deleted .. make sure this is OK
		!$pools[$i] || !$poolmap{$pools[$i]->{'id'}} ||
		    &error(&text('ips_edelete', $pools[$i]->{'start'},
			join(" ", map { $_->[0]->{'host'} }
				      @{$poolmap{$pools[$i]->{'id'}}})));
		next;
		}
	my $p = $pools[$i] || { 'id' => &server_id() };

	# Validate IPs
	@starts = split(/\s+/, $in{"start_$i"});
	@ends = split(/\s+/, $in{"end_$i"});
	@netmasks = split(/\s+/, $in{"netmask_$i"});
	@gateways = split(/\s+/, $in{"gateway_$i"});
	scalar(@starts) || &error(&text('range_estarts', $i+1));
	scalar(@ends) == scalar(@starts) ||
		&error(&text('range_eends', $i+1));
	if (scalar(@netmasks)) {
		# Repeat one netmask
		while(scalar(@netmasks) < scalar(@starts)) {
			push(@netmasks, $netmasks[$#netmasks]);
			}
		}
	scalar(@netmasks) == scalar(@starts) ||
		&error(&text('range_enetmasks', $i+1));

	# Validate each IP
	for($j=0; $j<@starts; $j++) {
		&check_ip6address($starts[$j]) ||
			&error(&text('range_estart6', $i+1));
		&check_ip6address($ends[$j]) ||
			&error(&text('range_eend6', $i+1));
		$netmasks[$j] =~ /^\d+$/ && $netmasks[$j] > 0 ||
			&error(&text('range_enetmask6', $i+1));
		$gateways[$j] eq '' || &check_ip6address($gateways[$j]) ||
			&error(&text('range_egateway', $i+1));
		$ss = $starts[$i];
		$es = $ends[$i];
		$ss =~ s/:[^:]+$//;
		$es =~ s/:[^:]+$//;
		$ss eq $es || &error(&text('range_esame6', $i+1, $ss, $es));
		}

	$p->{'desc'} = $in{"desc_$i"};
	$p->{'start'} = join(",", @starts);
	$p->{'end'} = join(",", @ends);
	$p->{'cidr'} = join(",", @netmasks);
	$p->{'gateway'} = join(",", @gateways);
	push(@newpools, $p);
	}

# Write out list of pools
&save_ip6_pools(\@newpools);
&unlock_file($pools6_file);

&webmin_log("pools");
&redirect("list_ips.cgi?mode=pools6");
