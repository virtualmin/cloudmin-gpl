#!/usr/local/bin/perl
# Show a table of all known IPs and their uses

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'ips_title'}, "");
&ReadParse();
%ips = ( );
%ranges = ( );

# Find IPs from pools
@pools = &list_ip_pools();
foreach $p (@pools) {
	@starts = split(/,/, $p->{'start'});
	@ends = split(/,/, $p->{'end'});
	for($i=0; $i<@starts; $i++) {
		$snum = &net::ip_to_integer($starts[$i]);
		$enum = &net::ip_to_integer($ends[$i]);
		foreach my $ip (&expand_ip_range($starts[$i], $ends[$i])) {
			$ips{$ip} ||= { 'hosts' => [ ] };
			}
		$r = $starts[$i]."-".$ends[$i];
		$ranges{$r} ||= { 'hosts' => [ ],
				  'pool' => $p->{'id'},
				  'start' => $starts[$i],
				  'end' => $ends[$i] };
		}
	}

# Find IPv6 pools and IPs from them
@pools6 = &list_ip6_pools();
foreach $p (@pools6) {
	@starts = split(/,/, $p->{'start'});
	@ends = split(/,/, $p->{'end'});
	for($i=0; $i<@starts; $i++) {
		foreach my $ip (&expand_ip_range($starts[$i], $ends[$i])) {
			$ips{$ip} ||= { 'hosts' => [ ] };
			}
		$r = $starts[$i]."-".$ends[$i];
		$ranges{$r} ||= { 'hosts' => [ ],
				  'pool' => $p->{'id'},
				  'start' => $starts[$i],
				  'end' => $ends[$i] };
		}
	}

# Find IPs from allocation ranges
@allservers = &list_managed_servers();
foreach $m (@virtual_server_management_types) {
	$cfunc = "can_host_".$m;
	next if (!defined(&$cfunc));
	$mkey = $m eq 'zones' ? 'zone' : $m;
	foreach $s (grep { &$cfunc($_) && $_->{$mkey.'_host'} } @allservers) {
		@starts = split(/[ ,]+/, $s->{$mkey."_start"});
		@ends = split(/[ ,]+/, $s->{$mkey."_end"});
		for($i=0; $i<@starts; $i++) {
			$snum = &net::ip_to_integer($starts[$i]);
			$enum = &net::ip_to_integer($ends[$i]);
			for($j=$snum; $j<=$enum; $j++) {
				$ip = &net::integer_to_ip($j);
				$ips{$ip} ||= { 'hosts' => [ ] };
				push(@{$ips{$ip}->{'hosts'}}, $s->{'id'});
				}
			$r = $starts[$i]."-".$ends[$i];
			$ranges{$r} ||= { 'hosts' => [ ],
					  'start' => $starts[$i],
					  'end' => $ends[$i] };
			push(@{$ranges{$r}->{'hosts'}}, $s->{'id'});
			}

		# Add host to IPv6 pools
		@hpools6 = split(/\s+/, $s->{$mkey."_pool6"});
		foreach $pid (@hpools6) {
			my ($r) = grep { $_->{'pool'} eq $pid } values %ranges;
			if ($r) {
				push(@{$r->{'hosts'}}, $s->{'id'});
				}
			my ($p) = grep { $_->{'id'} eq $pid } @pools6;
			if ($p) {
				@starts = split(/,/, $p->{'start'});
				@ends = split(/,/, $p->{'end'});
				for($i=0; $i<@starts; $i++) {
					foreach my $ip (&expand_ip_range(
						    $starts[$i], $ends[$i])) {
						push(@{$ips{$ip}->{'hosts'}},
						     $s->{'id'});
						}
					}
				}
			}
		}
	}

# Find owners
%ownermap = ( );
$oc = 0;
if (defined(&list_system_owners)) {
	foreach $o (&list_system_owners()) {
		foreach $id (split(/\s+/, $o->{'acl'}->{'servers'})) {
			$ownermap{$id} = $o->{'name'};
			$oc++;
			}
		}
	}

# Find IPs from systems
foreach $s (@allservers) {
	foreach $ip (&get_server_ip($s)) {
		if (&check_ipaddress($ip)) {
			$ips{$ip} ||= { 'hosts' => [ ] };
			$ips{$ip}->{'server'} = $s;
			}
		}
	foreach $ip (&get_server_ip6($s)) {
		if (&check_ip6address($ip)) {
			$ips{$ip} ||= { 'hosts' => [ ] };
			$ips{$ip}->{'server'} = $s;
			}
		}
	}

# Find IPs for DHCP
if (&foreign_installed("dhcpd")) {
	# XXX
	}

# For IPs that might be free, parallel ping them. Unless
# there are more than 1024
@ips = keys %ips;
@freeips = map { { 'id' => $_ } } grep { &check_ipaddress($_) &&
				         !$ips{$_}->{'server'} } @ips;
if (@freeips <= 1024 && $config{'show_ping'}) {
	local $config{'procs'} = 20;
	@pings = map { $_->[0] } &parallel_server_function(\@freeips,
				sub { my $p = &ping_server_host($_[0]->{'id'}, 1);
				      return $p });
	for($i=0; $i<@freeips; $i++) {
		$ips{$freeips[$i]->{'id'}}->{'ping'} = $pings[$i];
		}
	}
else {
	foreach $ip (@ips) {
		$ips{$ip}->{'ping'} = -1;
		}
	}

# Get IPs in sorted order
foreach $ip (@ips) {
	$ips{$ip}->{'integer'} = &check_ipaddress($ip) ?
					&net::ip_to_integer($ip) :
					&ip6_to_integer($ip);
	}
@ips = sort { $ips{$a}->{'integer'} <=> $ips{$b}->{'integer'} } @ips;

# Show tabs
@tabs = ( [ "ips", $text{'ips_tabips'}, "list_ips.cgi?mode=ips" ],
	  [ "ranges", $text{'ips_tabranges'}, "list_ips.cgi?mode=ranges" ],
	);
if (!$module_info{'onehost'}) {
	push(@tabs,
	  [ "pools", $text{'ips_tabpools'}, "list_ips.cgi?mode=pools" ]);
	}
push(@tabs, [ "pools6", $text{'ips_tabpools6'}, "list_ips.cgi?mode=pools6" ]);
print &ui_tabs_start(\@tabs, "mode", $in{'mode'} || "ips", 1);

# Show all the IPs we know about, in a tab
print &ui_tabs_start_tab("mode", "ips");
print $text{'ips_ipsdesc'},"<p>\n";

# Show search form to limit list
print &ui_form_start("list_ips.cgi");
print "<b>$text{'ips_ipsearch'}</b>\n",
      &ui_textbox("search", $in{'search'}, 30),"\n",
      &ui_submit($text{'ips_ipok'}),"\n";
print &ui_form_end();

# Limit the list
%idmap = map { $_->{'id'}, $_ } @allservers;
if ($in{'search'}) {
	@sips = ( );
	foreach $ip (@ips) {
		$s = $ips{$ip}->{'server'};
		if ($ip =~ /\Q$in{'search'}\E/i) {
			# Match on IP
			push(@sips, $ip);
			}
		elsif ($s && $s->{'host'} =~ /\Q$in{'search'}\E/i) {
			# Match on allocated server
			push(@sips, $ip);
			}
		else {
			# Match on host
		        foreach $h (map { $idmap{$_} }
				        &unique(@{$ips{$ip}->{'hosts'}})) {
				if ($h->{'host'} =~ /\Q$in{'search'}\E/i) {
					push(@sips, $ip);
					last;
					}
				}
			}
		}
	@ips = &unique(@sips);
	}

if ($in{'search'} && !@ips) {
	print "<p><b>$text{'ips_searchnone'}</b><p>\n";
	}
elsif (!@ips) {
	print "<p><b>$text{'ips_none'}</b><p>\n";
	}
else {
	print &ui_columns_start([ $text{'ips_ip'},
				  $text{'ips_use'},
				  $oc ? ( $text{'ips_owner'} ) : ( ),
				  $text{'ips_host'},
				], 100);
	foreach $ip (@ips) {
		$s = $ips{$ip}->{'server'};
		$p = $ips{$ip}->{'ping'};
		@hosts = sort { $a cmp $b }
			      map { $idmap{$_}->{'host'} }
				  &unique(@{$ips{$ip}->{'hosts'}});
		if (@hosts > 4) {
			@hosts = ( @hosts[0..3],
				   &text('update_more',scalar(@hosts-4)) );
			}
		if (!&check_ipaddress($ip) && !$s) {
			# Don't show un-used IPv6 addresses, as there are
			# likely to be too many.
			next;
			}
		print &ui_columns_row([
			$ip,
			$s ? "<a href='edit_serv.cgi?id=$s->{'id'}'>".
			     "$s->{'host'}</a>" :
			 $p > 0 ? $text{'ips_ping'} :
			 $p < 0 ? $text{'ips_unalloc'} :
				  $text{'ips_free'},
			!$oc ? ( ) :
			 !$s ? ( undef ) :
			       ( $ownermap{$s->{'id'}} ),
			&ui_links_row(\@hosts),
			]);
		}
	print &ui_columns_end();
	}
print &ui_tabs_end_tab();

# Show all the ranges from hosts
print &ui_tabs_start_tab("mode", "ranges");
print $text{'ips_rangesdesc'},"<p>\n";
print &ui_columns_start([ $text{'ips_range1'}, $text{'ips_range2'},
			  $text{'ips_count'},
			  $text{'ips_used'}, $text{'ips_left'},
			  $text{'ips_host'} ], 100);
@ranges = sort { $a cmp $b } keys %ranges;
foreach $r (@ranges) {
	$range = $ranges{$r};
	@ips = $range->{'start'} ? 
		&expand_ip_range($range->{'start'}, $range->{'end'}) : ( );
	$count = scalar(@ips);
	$used = 0;
	foreach $ip (@ips) {
		$used++ if ($ips{$ip}->{'server'});
		}
	@hosts = sort { $a cmp $b }
		      map { "<a href='edit_serv.cgi?id=".
			     $_->{'id'}."'>".$_->{'host'}."</a>" }
			   map { $idmap{$_} }
			       &unique(@{$range->{'hosts'}});
	if (@hosts > 4) {
		@hosts = ( @hosts[0..3],
			   &text('update_more',scalar(@hosts-4)) );
		}
	print &ui_columns_row([
		$range->{'start'},
		$range->{'end'},
		$count,
		$used,
		$count-$used,
		&ui_links_row(\@hosts),
		]);
	}

print &ui_columns_end();
print &ui_tabs_end_tab();

# Show IP pools
if (!$module_info{'onehost'}) {
	print &ui_tabs_start_tab("mode", "pools");
	print $text{'ips_poolsdesc'},"<p>\n";
	print &ui_form_start("save_ips.cgi", "post");
	print &ui_columns_start([ $text{'ips_active'},
				  $text{'ips_desc'},
				  $text{'range_start'},
				  $text{'range_end'},
				  $text{'range_netmask'},
				  $text{'range_gateway'},
				  $text{'ips_count'}, ], 100);
	$i = 0;
	foreach $p (@pools, { }) {
		@starts = split(/,/, $p->{'start'});
		@ends = split(/,/, $p->{'end'});
		@netmasks = $p->{'cidr'} ? map { &net::prefix_to_mask($_) }
					    split(/,/, $p->{'cidr'}) : ( );
		@gateways = split(/,/, $p->{'gateway'});
		$r = scalar(@starts) + 1;
		$r = 3 if ($r < 3);
		my $ipcount;
		for(my $i=0; $i<@starts; $i++) {
			$snum = &net::ip_to_integer($starts[$i]);
			$enum = &net::ip_to_integer($ends[$i]);
			$ipcount += $enum - $snum + 1;
			}
		print &ui_columns_row([
			&ui_checkbox("active_$i", 1, "", $p->{'id'}),
			&ui_textbox("desc_$i", $p->{'desc'}, 30),
			&ui_textarea("start_$i", join("\n", @starts), $r, 20),
			&ui_textarea("end_$i", join("\n", @ends), $r, 20),
			&ui_textarea("netmask_$i", join("\n",@netmasks), $r,20),
			&ui_textarea("gateway_$i", join("\n",@gateways), $r,20),
			$ipcount,
			], [ "valign=top", "valign=top" ]);
		$i++;
		}
	print &ui_columns_end();
	print &ui_form_end([ [ undef, $text{'save'} ] ]);
	print &ui_tabs_end_tab();
	}

# Show IPv6 pools
print &ui_tabs_start_tab("mode", "pools6");
print $text{'ips_pools6desc'},"<p>\n";
print &ui_form_start("save_ips6.cgi", "post");
print &ui_columns_start([ $text{'ips_active'},
			  $text{'ips_desc'},
			  $text{'range_start'},
			  $text{'range_end'},
			  $text{'range_netmask'},
			  $text{'range_gateway'},
			  $text{'ips_count'}, ], 100);
$i = 0;
foreach $p (@pools6, { }) {
	@starts = split(/,/, $p->{'start'});
	@ends = split(/,/, $p->{'end'});
	@netmasks = split(/,/, $p->{'netmask'});
	@gateways = split(/,/, $p->{'gateway'});
	$r = scalar(@starts) + 1;
	$r = 3 if ($r < 3);
	my $ipcount;
	for(my $i=0; $i<@starts; $i++) {
		$ipcount += scalar(&expand_ip_range($starts[$i], $ends[$i]));
		}
	print &ui_columns_row([
		&ui_checkbox("active_$i", 1, "", $p->{'id'}),
		&ui_textbox("desc_$i", $p->{'desc'}, 30),
		&ui_textarea("start_$i", join("\n", @starts), $r, 25),
		&ui_textarea("end_$i", join("\n", @ends), $r, 25),
		&ui_textarea("netmask_$i", join("\n", @netmasks) || 64, $r, 10),
		&ui_textarea("gateway_$i", join("\n", @gateways), $r, 25),
		$ipcount,
		], [ "valign=top", "valign=top" ]);
	$i++;
	}
print &ui_columns_end();
print &ui_form_end([ [ undef, $text{'save'} ] ]);
print &ui_tabs_end_tab();

print &ui_tabs_end(1);

&ui_print_footer("", $text{'index_return'});

