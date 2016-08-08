# Functions for managing virtual system DNS records

# list_bind_zones([reverse-only])
# Returns a list of BIND master zones that we can add virtual system hostnames.
# May include those from the cloudmin services plugin.
sub list_bind_zones
{
my ($rev) = @_;
my @rv;
my $hasprov = &indexof("cloudmin-services", @plugins) >= 0 ? 1 : 0;
if (&foreign_installed("bind8")) {
	# Local local DNS zones
	&foreign_require("bind8");
	@rv = sort { $a->{'name'} cmp $b->{'name'} }
		 grep { $_->{'type'} eq 'master' } &bind8::list_zone_names();
	foreach my $z (@rv) {
		$z->{'local'} = 1;
		$z->{'desc'} = &show_domain_name($z->{'name'}).
			       ($hasprov ? " ".$text{'xen_localdns'} : "");
		}
	}
if ($hasprov) {
	# From services plugin
	my @history = grep { $_->{'feature'} eq 'dns' }
			   &cloudmin_services::list_provisioned_features();
	foreach my $h (@history) {
		my $hserver = &get_managed_server($h->{'server'});
		next if (!$hserver);	# Host doesn't exist?!
		push(@rv, { 'name' => $h->{'domain'},
			    'type' => 'master',
			    'desc' => &show_domain_name($h->{'domain'})." ".
				      $text{'xen_provisiondns'},
			    'provision' => 1,
			    'server' => $hserver,
			    'history' => $h });
		}
	}
if ($rev) {
	@rv = grep { $_->{'name'} =~ /in-addr|ip6.arpa/i } @rv;
	}
else {
	@rv = grep { $_->{'name'} !~ /in-addr|ip6.arpa/i } @rv;
	}
return @rv;
}

# add_bind8_record(dnsname, ip, zonename)
# Adds a DNS record for some new virtual system to the given zone, if it exists
sub add_bind8_record
{
my ($dnsname, $ip, $zonename) = @_;
&foreign_require("bind8");
my $rtype = &check_ipaddress($ip) ? "A" : "AAAA";

my @zones = &list_bind_zones();
my ($zone) = grep { $_->{'name'} eq $zonename } @zones;
my ($rfn, $rrecs, undef, $rzone) = &get_reverse_dns_zone($ip);
if ($zone && $zone->{'local'}) {
	# Add to local DNS zone
	&$first_print(&text('create_vserverdns', $dnsname, $ip));
	if (!$ip) {
		&$second_print(&text('create_vserverdnseip'));
		return 0;
		}
	my $lpath = &bind8::make_chroot(&bind8::absolute_path($zone->{'file'}));
	&lock_file($lpath);
	my @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	my ($already) = grep { $_->{'name'} eq $dnsname &&
			       $_->{'type'} eq $rtype } @recs;
	if (!$already) {
		# Need to add
		&bind8::create_record($zone->{'file'}, $dnsname, undef,
				      "IN", $rtype, $ip);
		}
	else {
		# Update existing record
		&bind8::modify_record($zone->{'file'}, $already, $dnsname,
				      undef, "IN", $rtype, $ip);
		}
	&post_records_change(\@recs, $zone->{'file'}, $zone);
	&unlock_file($lpath);
	}
elsif ($zone && $zone->{'provision'}) {
	# Add on provisioning host
	&$first_print(&text('create_vserverdnsprov', $dnsname, $ip,
			    $zone->{'server'}->{'host'}));
	if (!$ip) {
		&$second_print(&text('create_vserverdnseip'));
		return 0;
		}
	my $recs = &cloudmin_services::list_dns_records(
			$zone->{'server'}, $zone->{'name'});
	if (!ref($recs)) {
		&$second_print(&text('create_vserverdnseget', $recs));
		return 0;
		}
	elsif (!@$recs) {
		&$second_print(&text('create_vserverdnseget2'));
		return 0;
		}
	my ($already) = grep { $_->{'name'} eq $dnsname &&
			       $_->{'type'} eq $rtype } @$recs;
	if ($already) {
		# Just change the IP
		$already->{'values'}->[0] = $ip;
		}
	else {
		# Create a record
		push(@$recs, { 'name' => $dnsname,
			       'class' => 'IN',
			       'type' => $rtype,
			       'values' => [ $ip ] });
		}
	&post_records_change($recs, $zone->{'file'}, $zone);
	my $err = &cloudmin_services::validate_dns_records($zone->{'name'},
							   $recs);
	if ($err) {
		&$second_print(&text('create_vserverdnsevalid', $err));
		return 0;
		}
	my $err = &cloudmin_services::save_dns_records($zone->{'server'},
						       $zone->{'name'}, $recs);
	if ($err) {
		&$second_print(&text('create_vserverdnseset', $err));
		return 0;
		}
	}
else {
	# Zone not found
	return 0;
	}

# See if we can add to a reverse too
my $arpa = $rzone ? &ip_address_to_arpa($ip, $rzone->{'name'}) : undef;
if ($rzone && $rzone->{'local'}) {
	# Add reverse locally
	my $rlpath = &bind8::make_chroot(&bind8::absolute_path($rfn));
	&lock_file($rlpath);
	my ($old) = grep { $_->{'name'} eq $arpa } @$rrecs;
	if (!$old) {
		&bind8::create_record($rfn, $arpa, undef,
				      "IN", "PTR", $dnsname);
		&post_records_change($rrecs, $rzone->{'file'}, $rzone);
		}
	&unlock_file($rlpath);
	}
elsif ($rzone && $rzone->{'provision'}) {
	# Add reverse on provisioning host
	my $recs = &cloudmin_services::list_dns_records(
			$rzone->{'server'}, $rzone->{'name'});
	if (!ref($recs)) {
		&$second_print(&text('create_vserverrdnseget', $recs));
		return 0;
		}
	elsif (!@$recs) {
		&$second_print(&text('create_vserverrdnseget2'));
		return 0;
		}
	my ($old) = grep { $_->{'name'} eq $arpa } @$rrecs;
	if (!$old) {
		push(@$recs, { 'name' => $arpa,
			       'class' => 'IN',
			       'type' => 'PTR',
			       'values' => [ $dnsname ]});
		my $err = &cloudmin_services::save_dns_records(
			$rzone->{'server'}, $rzone->{'name'}, $recs);
		if ($err) {
			&$second_print(&text('create_vserverrdnseset', $err));
			return 0;
			}
		}
	}

&$second_print($text{'create_done'});
}

# delete_bind8_record(dnsname, zonename, ip)
# Deletes the DNS record that belonged to some server
sub delete_bind8_record
{
my ($dnsname, $zonename, $ip) = @_;
return 0 if (!$dnsname || !$ip);
&foreign_require("bind8");
my @zones = &list_bind_zones();
my ($zone) = grep { $_->{'name'} eq $zonename } @zones;
my ($rfn, $rrecs, undef, $rzone) = &get_reverse_dns_zone($ip);
my $rtype = &check_ipaddress($ip) ? "A" : "AAAA";

if ($zone && $zone->{'local'}) {
	# Remove from local DNS zone
	my $lpath = &bind8::make_chroot(&bind8::absolute_path($zone->{'file'}));
	&lock_file($lpath);
	my @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	my @r = grep { $_->{'name'} eq $dnsname &&
		       $_->{'type'} eq $rtype } @recs;
	foreach my $r (reverse(@r)) {
		# Can remove
		&bind8::delete_record($zone->{'file'}, $r);
		}
	if (@r) {
		&post_records_change(\@recs, $zone->{'file'}, $zone);
		}
	&unlock_file($lpath);
	if (!@r) {
		return "Record not found";
		}
	}
elsif ($zone && $zone->{'provision'}) {
	# Delete from provisioning host
	my $recs = &cloudmin_services::list_dns_records(
			$zone->{'server'}, $zone->{'name'});
	return $recs if (!ref($recs));
	return "No records found in $zone->{'name'}" if (!@$recs);
	my ($r) = grep { $_->{'name'} eq $dnsname &&
			 $_->{'type'} eq $rtype } @$recs;
	if ($r) {
		$recs = [ grep { $_ ne $r } @$recs ];
		&post_records_change($recs, $zone->{'file'}, $zone);
		$err = &cloudmin_services::save_dns_records($zone->{'server'},
						       $zone->{'name'}, $recs);
		return $err if ($err);
		}
	else {
		return "Record not found";
		}
	}
else {
	return "DNS zone not found";
	}

# See if we can remove a reverse too
my $arpa = $rzone ? &ip_address_to_arpa($ip, $rzone->{'name'}) : undef;
if ($ip && $rzone && $rzone->{'local'}) {
	# From local DNS server
	my $rlpath = &bind8::make_chroot(
			&bind8::absolute_path($rfn));
	&lock_file($rlpath);
	my ($old) = grep { $_->{'name'} eq $arpa } @$rrecs;
	if ($old) {
		&bind8::delete_record($rfn, $old);
		&post_records_change($rrecs, $rfn, $rzone);
		}
	&unlock_file($rlpath);
	}
elsif ($ip && $rzone && $rzone->{'provision'}) {
	# From provisioning server
	my $recs = &cloudmin_services::list_dns_records(
			$rzone->{'server'}, $rzone->{'name'});
	return $recs if (!ref($recs));
	return "No records found in $rzone->{'name'}" if (!@$recs);
	my ($r) = grep { $_->{'name'} eq $arpa } @$recs;
	if ($r) {
		$recs = [ grep { $_ ne $r } @$recs ];
		&post_records_change($recs, $rzone->{'file'}, $rzone);
		$err = &cloudmin_services::save_dns_records($rzone->{'server'},
						       $rzone->{'name'}, $recs);
		return $err if ($err);
		}
	}

return undef;
}

# modify_bind_dns_record(dnsname, zonename, old-ip, new-ip)
# Update the IP in DNS for a system
sub modify_bind_dns_record
{
my ($dnsname, $zonename, $oldip, $ip) = @_;
return undef if (!$dnsname);
&foreign_require("bind8");
my @zones = &list_bind_zones();
my ($zone) = grep { $_->{'name'} eq $zonename } @zones;
my ($rfn, $rrecs, undef, $rzone) = &get_reverse_dns_zone($oldip);
my $rtype = &check_ipaddress($ip) ? "A" : "AAAA";

if ($zone && $zone->{'local'}) {
	# Update in local DNS zone
	my $lpath = &bind8::make_chroot(&bind8::absolute_path($zone->{'file'}));
	&lock_file($lpath);
	my @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
        my @r = grep { $_->{'name'} eq $dnsname &&
		       $_->{'type'} eq $rtype } @recs;
	foreach my $r (@r) {
		&bind8::modify_record($zone->{'file'}, $r, $r->{'name'},
				      $r->{'ttl'}, $r->{'class'}, $r->{'type'},
				      $ip, $r->{'comment'});
		}
	if (@r) {
		&post_records_change(\@recs, $zone->{'file'}, $zone);
                }
	&unlock_file($lpath);
	if (!@r) {
		return "Record not found";
		}
	}
elsif ($zone && $zone->{'provision'}) {
	# Update on from provisioning host
	my $recs = &cloudmin_services::list_dns_records(
			$zone->{'server'}, $zone->{'name'});
	return $recs if (!ref($recs));
	return "No records found in zone $zone->{'name'}" if (!@$recs);
	my ($r) = grep { $_->{'name'} eq $dnsname &&
		         $_->{'type'} eq $rtype } @$recs;
	if ($r) {
		$r->{'values'}->[0] = $ip;
		&post_records_change($recs, $zone->{'file'}, $zone);
		my $err = &cloudmin_services::save_dns_records(
				$zone->{'server'}, $zone->{'name'}, $recs);
		return $err if ($err);
		}
	else {
		return "Record not found";
		}
	}
else {
	return "Zone not found";
	}

# See if we can update a reverse too
my $arpa = $ip && $rzone ? &ip_address_to_arpa($ip, $rzone->{'name'})
			 : undef;
my $oldarpa = $oldip && $rzone ? &ip_address_to_arpa($oldip, $rzone->{'name'})
			       : undef;
if ($ip && $rzone && $rzone->{'local'}) {
	# On local DNS server
	my $rlpath = &bind8::make_chroot(
			&bind8::absolute_path($rfn));
	&lock_file($rlpath);
	my ($old) = grep { $_->{'name'} eq $oldarpa } @$rrecs;
	if ($old) {
		&bind8::modify_record($rfn, $old, $arpa,
			$old->{'ttl'}, $old->{'class'},
			$old->{'type'}, $dnsname,
			$old->{'comment'});
		&post_records_change($rrecs, $rfn, $rzone);
		}
	&unlock_file($rlpath);
	}
elsif ($ip && $rzone && $rzone->{'provision'}) {
	# On provisioning server
	my $recs = &cloudmin_services::list_dns_records(
			$rzone->{'server'}, $rzone->{'name'});
	return $recs if (!ref($recs));
	return "No records found in $rzone->{'name'}" if (!@$recs);
	my ($r) = grep { $_->{'name'} eq $oldarpa } @$recs;
	if ($r) {
		$r->{'name'} = $arpa;
		&post_records_change($recs, $rzone->{'file'}, $rzone);
		$err = &cloudmin_services::save_dns_records($rzone->{'server'},
						       $rzone->{'name'}, $recs);
		return $err if ($err);
		}
	}

return undef;
}

# set_bind_dns_addresses(dnsname, zonename, &new-ips, &new-comments, ttl)
# Create or update multiple A records for a name
sub set_bind_dns_addresses
{
my ($dnsname, $zonename, $ips, $cmts, $ttl) = @_;
&foreign_require("bind8");
my @zones = &list_bind_zones();
my ($zone) = grep { $_->{'name'} eq $zonename } @zones;
if ($zone && $zone->{'local'}) {
	# Update local zone
	my $lpath = &bind8::make_chroot(&bind8::absolute_path($zone->{'file'}));
	&lock_file($lpath);
	my @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	my @oldr = grep { $_->{'name'} eq $dnsname &&
			  $_->{'type'} eq 'A' } @recs;
	my $changed = 0;
	my @delr;
	for(my $i=0; $i<@$ips || $i<@oldr; $i++) {
		my $r = $i<@oldr ? $oldr[$i] : undef;
		if ($i < @$ips && $i < @oldr) {
			# Update record
			if ($r->{'values'}->[0] ne $ips->[$i] ||
			    $r->{'ttl'} ne $ttl) {
				&bind8::modify_record(
					$zone->{'file'}, $r, $r->{'name'},
					$ttl, $r->{'class'},
					$r->{'type'}, $ips->[$i], $cmts->[$i]);
				$changed++;
				}
			}
		elsif ($i < @$ips) {
			# Add record
			&bind8::create_record(
				$zone->{'file'}, $dnsname,
				$ttl, "IN", "A", $ips->[$i], $cmts->[$i]);
			$changed++;
			}
		elsif ($i < @oldr) {
			# Delete record
			push(@delr, $r);
			$changed++;
			}
		}
	foreach my $r (reverse(@delr)) {
		&bind8::delete_record($zone->{'file'}, $r);
		}
	if ($changed) {
		&post_records_change(\@recs, $zone->{'file'}, $zone);
		}
	&unlock_file($lpath);
	return (1, $changed);
	}
elsif ($zone && $zone->{'provision'}) {
	# Update provisioned zone
	my $recs = &cloudmin_services::list_dns_records(
			$zone->{'server'}, $zone->{'name'});
	return (0, "Failed to fetch records : $recs") if (!ref($recs));
	return (0, "No records found in zone $zone->{'name'}")
		if (!@$recs);
	my @oldips = sort { $a cmp $b }
			  map { $_->{'values'}->[0] }
			      grep { $_->{'name'} eq $dnsname &&
				     $_->{'type'} eq 'A' } @$recs;
	my @newips = sort { $a cmp $b } @$ips;
	if (join(" ", @oldips) ne join(" ", @newips)) {
		$recs = [ grep { $_->{'name'} ne $dnsname ||
				 $_->{'type'} ne 'A' } @$recs ];
		for(my $i=0; $i<@$ips; $i++) {
			push(@$recs, { 'name' => $dnsname,
				       'class' => 'IN',
				       'type' => 'A',
				       'ttl' => $ttl,
				       'values' => [ $ips->[$i] ],
				       'cmt' => $cmts->[$i] });
			}
		&post_records_change($recs, $zone->{'file'}, $zone);
		my $err = &cloudmin_services::validate_dns_records(
				$zone->{'name'}, $recs);
		return (0, "New records are invalid : $err") if ($err);
		my $err = &cloudmin_services::save_dns_records(
				$zone->{'server'}, $zone->{'name'}, $recs);
		return (0, "Failed to save records : $err") if ($err);
		return (1, scalar(@newips));
		}
	return (1, 0);	# No changes needed
	}
else {
	return (0, "DNS domain $zonename not found");
	}
}

# get_reverse_dns_zone(ip)
# Returns the records file and list of records for the domain for some IP
sub get_reverse_dns_zone
{
my ($ip) = @_;
my @zones = &list_bind_zones(1);
my $arpa = &check_ipaddress($ip) ? &bind8::ip_to_arpa($ip)
				 : &bind8::net_to_ip6int($ip);
$arpa =~ s/\.$//;
my ($z) = grep { $arpa =~ /\.$_->{'name'}$/i } @zones;
if (!$z) {
	# Look for a partial zone that could contain the IP. For example,
	# 1.2.3.4 could be in 0-10.2.3.4.in-addr-arpa
	my @o = split(/\./, $ip);
	foreach my $pz (@zones) {
		my $pip = &bind8::arpa_to_ip($pz->{'name'});
		next if ($pip eq $pz->{'name'});
		my @po = split(/\./, $pip);
		if ($po[0] == $o[0] && $po[1] == $o[1] && $po[2] == $o[2] &&
		    $po[3] =~ /^(\d+)\-(\d+)$/ &&
		    $o[3] >= $1 && $o[3] <= $2) {
			# Found one that matches!
			$z = $pz;
			last;
			}
		}
	}
return ( ) if (!$z);

# Return details of the matching domain
my @recs = &bind8::read_zone_file($z->{'file'}, $z->{'name'});
return ( $z->{'file'}, \@recs, $arpa, $z );
}

# get_server_reverse_records(&server, [&ips])
# Returns a list of reverse records for some system, each of which is a hash
# ref with 'ip' and possibly 'name' keys. If an IP is not in a zone we host,
# the 'outside' key is set.
sub get_server_reverse_records
{
my ($server, $force_ips) = @_;
my @ips = $force_ips ? @$force_ips : &get_server_ip($server);
my @rv;
foreach my $ip (@ips) {
	my ($rfn, $rrecs, undef, $zone) = &get_reverse_dns_zone($ip);
	my $arpa = &ip_address_to_arpa($ip, $zone);
	if ($rfn) {
		# Can edit reverse for IP
		my ($r) = grep { $_->{'name'} eq $arpa } @$rrecs;
                my $rev = $r ? $r->{'values'}->[0] : '';
                $rev =~ s/\.$//;
		push(@rv, { 'ip' => $ip, 'name' => $rev, 'zone' => $zone });
		}
	else {
		push(@rv, { 'ip' => $ip, 'outside' => 1 });
		}
	}
return @rv;
}

# save_server_reverse_records(&server, &records)
# Updates the reverse records for a system, from a list of hash refs. Returns
# undef on success, or an error message on failure.
sub save_server_reverse_records
{
my ($server, $revs) = @_;
my @ips = &get_server_ip($server);
foreach my $rev (@$revs) {
	next if ($rev->{'outside'});	# Nothing to do here
	my $ip = $rev->{'ip'};
	my ($got) = grep { $_->{'ip'} eq $rev->{'ip'} } @$revs;
	if (!$got) {
		return &text('reverse_eip', $ip);
		}
	my ($rfn, $rrecs, undef, $zone) = &get_reverse_dns_zone($ip);
	if (!$rfn) {
		return &text('reverse_ezone', $ip);
		}
	&lock_file(&bind8::make_chroot(&bind8::absolute_path($rfn)));
	my $arpa = &ip_address_to_arpa($ip, $zone->{'name'});
	my ($r) = grep { $_->{'name'} eq $arpa } @$rrecs;
	if ($r && !$rev->{'name'}) {
		# Delete the record
		&bind8::delete_record($rfn, $r);
		}
	elsif ($r && $rev->{'name'}) {
		# Update the record
		&bind8::modify_record($rfn, $r, $r->{'name'}, $r->{'ttl'},
				      $r->{'class'}, $r->{'type'},
				      $rev->{'name'}.".");
		}
	elsif (!$r && $rev->{'name'}) {
		# Add a record
		&bind8::create_record($rfn, $arpa, undef, "IN", "PTR",
				      $rev->{'name'}.".");
		}
	&bind8::bump_soa_record($rfn, $rrecs);
	&unlock_file(&bind8::make_chroot(&bind8::absolute_path($rfn)));
	}
&bind8::restart_bind();
return undef;
}

# ip_address_to_arpa(ip, zone-name)
# Converts an IP address to a record name, taking partial reverse delegation
# into account. Includes the . at the end.
sub ip_address_to_arpa
{
my ($ip, $zone) = @_;
if (&check_ip6address($ip)) {
	# IPv6 address
	return &bind8::net_to_ip6int($ip);
	}
elsif ($zone =~ /^([0-9\.]+)\.in-addr\.arpa$/) {
	# Normal class C
	return &bind8::ip_to_arpa($ip);
	}
else {
	# Assume last octet is within the zone
	my @o = split(/\./, $ip);
	return $o[3].".".$zone.".";
	}
}

# post_records_change(&recs, file, &zone)
# Called after some records in a domain are changed, to bump to SOA
# and possibly re-sign
sub post_records_change
{
my ($recs, $fn, $zone) = @_;
if ($zone->{'local'}) {
	# Update the SOA record, locally and on disk
	sleep(1);	# Give BIND time to detect file time change
	&bind8::bump_soa_record($fn, $recs);
	if (&bind8::supports_dnssec()) {
		# Re-sign too
		eval {
			local $main::error_must_die = 1;
			&bind8::sign_dnssec_zone_if_key($zone, $recs, 0);
			};
		if ($@) {
			return "DNSSEC signing failed : $@";
			}
		}
	if (defined(&bind8::restart_zone)) {
		&bind8::restart_zone($zone->{'name'});
		}
	else {
		&bind8::restart_bind();
		}
	}
else {
	# Just find SOA and bump serial in memory
	my ($soa) = grep { $_->{'type'} eq 'SOA' } @$recs;
	if ($soa) {
		$soa->{'values'}->[2]++;
		}
	else {
		return "No SOA record found!";
		}
	}
return undef;
}

sub bind_module_link
{
return "<a href=../bind8/index.cgi>$text{'index_bindlink'}</a>";
}

1;

