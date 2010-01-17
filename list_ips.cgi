#!/usr/local/bin/perl
# Show a table of all known IPs and their uses

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'ips_title'}, "");
&ReadParse();

# Find IPs from allocation ranges
@allservers = &list_managed_servers();
%ips = ( );
%ranges = ( );
foreach $m (@virtual_server_management_types) {
	$cfunc = "can_host_".$m;
	next if (!defined(&$cfunc));
	foreach $s (grep { &$cfunc($_) } @allservers) {
		@starts = split(/\s+/, $s->{$m."_start"});
		@ends = split(/\s+/, $s->{$m."_end"});
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

# Get IPs in sorted order
@ips = keys %ips;
foreach $ip (@ips) {
	$ips{$ip}->{'integer'} = &net::ip_to_integer($ip);
	}
@ips = sort { $ips{$a}->{'integer'} <=> $ips{$b}->{'integer'} } @ips;

# Show tabs
@tabs = ( [ "ips", $text{'ips_tabips'}, "list_ips.cgi?mode=ips" ],
	  [ "ranges", $text{'ranges_tabranges'},
	    "list_ranges.cgi?mode=ranges" ] );
print &ui_tabs_start(\@tabs, "mode", $in{'mode'} || "ips", 1);

# Show all the IPs we know about, in a tab
print &ui_tabs_start_tab("mode", "ips");
print $text{'ips_ipsdesc'},"<p>\n";
%idmap = map { $_->{'id'}, $_ } @allservers;
print &ui_columns_start([ $text{'ips_ip'},
			  $text{'ips_use'},
			  $oc ? ( $text{'ips_owner'} ) : ( ),
			  $text{'ips_host'},
			], 100);
foreach $ip (@ips) {
	$s = $ips{$ip}->{'server'};
	@hosts = sort { $a cmp $b }
		      map { $idmap{$_}->{'host'} }
			  &unique(@{$ips{$ip}->{'hosts'}});
	if (@hosts > 4) {
		@hosts = ( @hosts[0..3],
			   &text('update_more',scalar(@hosts-4)) );
		}
	print &ui_columns_row([
		$ip,
		$s ? "<a href='edit_serv.cgi?id=$s->{'id'}'>$s->{'host'}</a>"
		   : $text{'ips_free'},
		!$oc ? ( ) :
		 !$s ? ( undef ) :
		       ( $ownermap{$s->{'id'}} ),
		&ui_links_row(\@hosts),
		]);
	}
print &ui_columns_end();
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

print &ui_tabs_end(1);

&ui_print_footer("", $text{'index_return'});

