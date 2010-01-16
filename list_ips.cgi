#!/usr/local/bin/perl
# Show a table of all known IPs and their uses

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'ips_title'}, "");

# Find IPs from allocation ranges
@allservers = &list_managed_servers();
%ips = ( );
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
				$ips{$ip} ||= { 'hosts' => [ ],
						'servers' => [ ] };
				push(@{$ips{$ip}->{'hosts'}}, $s->{'id'});
				}
			}
		}
	}

# Find IPs from systems
foreach $s (@allservers) {
	foreach $ip (&get_server_ip($s)) {
		$ips{$ip} ||= { 'hosts' => [ ],
				'servers' => [ ] };
		push(@{$ips{$ip}->{'servers'}}, $s->{'id'});
		}
	}

# Get IPs in sorted order
@ips = keys %ips;
foreach $ip (@ips) {
	$ips{$ip}->{'integer'} = &net::ip_to_integer($ip);
	}
@ips = sort { $ips{$a}->{'integer'} <=> $ips{$b}->{'integer'} } @ips;

# Show all the IPs we know about
print &ui_columns_start([ $text{'ips_ip'}, $text{'ips_use'},
			  $text{'ips_host'} ], 100);

# XXX
