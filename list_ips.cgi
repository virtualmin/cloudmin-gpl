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
		for($j=$snum; $j<=$enum; $j++) {
			$ip = &net::integer_to_ip($j);
			$ips{$ip} ||= { 'hosts' => [ ] };
			}
		$r = $starts[$i]."-".$ends[$i];
		$ranges{$r} ||= { 'hosts' => [ ],
				  'snum' => $snum,
				  'enum' => $enum };
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
					  'snum' => $snum,
					  'enum' => $enum };
			push(@{$ranges{$r}->{'hosts'}}, $s->{'id'});
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
	}

# For IPs that might be free, parallel ping them
@ips = keys %ips;
@freeips = map { { 'id' => $_ } } grep { !$ips{$_}->{'server'} } @ips;
local $config{'procs'} = 100;
@pings = map { $_->[0] } &parallel_server_function(\@freeips,
			sub { my $p = &ping_server_host($_[0]->{'id'}, 1);
			      return $p });
for($i=0; $i<@freeips; $i++) {
	$ips{$freeips[$i]->{'id'}}->{'ping'} = $pings[$i];
	}

# Get IPs in sorted order
foreach $ip (@ips) {
	$ips{$ip}->{'integer'} = &net::ip_to_integer($ip);
	}
@ips = sort { $ips{$a}->{'integer'} <=> $ips{$b}->{'integer'} } @ips;

# Show tabs
@tabs = ( [ "ips", $text{'ips_tabips'}, "list_ips.cgi?mode=ips" ],
	  [ "ranges", $text{'ips_tabranges'}, "list_ranges.cgi?mode=ranges" ],
	);
if (!$module_info{'onehost'}) {
	push(@tabs,
	  [ "pools", $text{'ips_tabpools'}, "list_pools.cgi?mode=pools" ]);
	}
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
		print &ui_columns_row([
			$ip,
			$s ? "<a href='edit_serv.cgi?id=$s->{'id'}'>".
			     "$s->{'host'}</a>" :
			 $p ? $text{'ips_ping'} : $text{'ips_free'},
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
	$count = $range->{'enum'}-$range->{'snum'}+1;
	$used = 0;
	for($i=$range->{'snum'}; $i<=$range->{'enum'}; $i++) {
		$used++ if ($ips{&net::integer_to_ip($i)}->{'server'});
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
		&net::integer_to_ip($range->{'snum'}),
		&net::integer_to_ip($range->{'enum'}),
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
				  $text{'range_gateway'} ], 100);
	$i = 0;
	foreach $p (@pools, { }) {
		@starts = split(/,/, $p->{'start'});
		@ends = split(/,/, $p->{'end'});
		@netmasks = $p->{'cidr'} ? map { &net::prefix_to_mask($_) }
					    split(/,/, $p->{'cidr'}) : ( );
		@gateways = split(/,/, $p->{'gateway'});
		$r = scalar(@starts) + 1;
		$r = 3 if ($rows < 3);
		print &ui_columns_row([
			&ui_checkbox("active_$i", 1, "", $p->{'id'}),
			&ui_textbox("desc_$i", $p->{'desc'}, 30),
			&ui_textarea("start_$i", join("\n", @starts), $r, 20),
			&ui_textarea("end_$i", join("\n", @ends), $r, 20),
			&ui_textarea("netmask_$i", join("\n",@netmasks), $r,20),
			&ui_textarea("gateway_$i", join("\n",@gateways), $r,20),
			], [ "valign=top", "valign=top" ]);
		$i++;
		}
	print &ui_columns_end();
	print &ui_form_end([ [ undef, $text{'save'} ] ]);
	print &ui_tabs_end_tab();
	}

print &ui_tabs_end(1);

&ui_print_footer("", $text{'index_return'});

