# Functions for managing virtual system DNS records

# list_bind_zones()
# Returns a list of BIND master zones that we can add vserver hostnames to
sub list_bind_zones
{
if (&foreign_installed("bind8")) {
	&foreign_require("bind8", "bind8-lib.pl");
	return sort { $a->{'name'} cmp $b->{'name'} }
		 grep { $_->{'type'} eq 'master' &&
		        $_->{'name'} !~ /in-addr|ip6.arpa/i }
		      &bind8::list_zone_names();
	}
return ( );
}

# add_bind8_record(dnsname, ip, zonename)
# Adds a DNS record for some new virtual system to the given zone, if it exists
sub add_bind8_record
{
my ($dnsname, $ip, $zonename) = @_;
&foreign_require("bind8", "bind8-lib.pl");

my @zones = &list_bind_zones();
my ($zone) = grep { $_->{'name'} eq $zonename } @zones;
if ($zone) {
	&$first_print(&text('create_vserverdns', $dnsname, $ip));
	my @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	my ($already) = grep { $_->{'name'} eq $dnsname } @recs;
	if (!$already) {
		# Need to add
		&bind8::create_record($zone->{'file'}, $dnsname, undef,
				      "IN", "A", $ip);
		&bind8::bump_soa_record($zone->{'file'}, \@recs);

		# See if we can add to a reverse too
		my ($rfn, $rrecs, undef, $rzone) =
			&get_reverse_dns_zone($ip);
		if ($rfn) {
			my $arpa = &ip_address_to_arpa($ip, $rzone);
			my ($old) = grep { $_->{'values'}->[0] eq $dnsname }
					 @$rrecs;
			if (!$old) {
				&bind8::create_record($rfn, $arpa, undef,
						      "IN", "PTR", $dnsname);
				&bind8::bump_soa_record($rfn, $rrecs);
				}
			}

		&bind8::restart_bind();
		&$second_print($text{'create_done'});
		return 1;
		}
	else {
		&$second_print($text{'create_vserverdnsalready'});
		}
	}
return 0;
}

# delete_bind8_record(dnsname, zonename, ip)
# Deletes the DNS record that belonged to some server
sub delete_bind8_record
{
my ($dnsname, $zonename, $ip) = @_;
&foreign_require("bind8", "bind8-lib.pl");
my @zones = &list_bind_zones();
my ($zone) = grep { $_->{'name'} eq $zonename } @zones;
if ($zone && $dnsname) {
	my @recs = &bind8::read_zone_file($zone->{'file'}, $zone->{'name'});
	my @r = grep { $_->{'name'} eq $dnsname } @recs;
	foreach my $r (reverse(@r)) {
		# Can remove
		&bind8::delete_record($zone->{'file'}, $r);
		}
	if (@r) {
		&bind8::bump_soa_record($zone->{'file'}, \@recs);
		}

	if (@r) {
		# See if we can remove a reverse too
		my ($rfn, $rrecs, undef, $rzone) =
			&get_reverse_dns_zone($ip);
		if ($ip && $rfn) {
			my ($old) = grep { $_->{'values'}->[0] eq $dnsname }
					 @$rrecs;
			if ($old) {
				&bind8::delete_record($rfn, $old);
				&bind8::bump_soa_record($rfn, $rrecs);
				}
			}
		}
	if (@r) {
		&bind8::restart_bind();
		}
	}
}

# get_reverse_dns_zone(ip)
# Returns the records file and list of records for the domain for some IP
sub get_reverse_dns_zone
{
my ($ip) = @_;
&foreign_require("bind8", "bind8-lib.pl");
my $conf = &bind8::get_config();
my @zones = &bind8::find("zone", $conf);
foreach my $v (&bind8::find("view", $conf)) {
	push(@zones, &bind8::find("zone", $v->{'members'}));
	}
my $arpa = &bind8::ip_to_arpa($ip);
$arpa =~ s/\.$//;
my ($z) = grep { $arpa =~ /\.$_->{'value'}$/i } @zones;
if (!$z) {
	# Look for a partial zone that could contain the IP. For example,
	# 1.2.3.4 could be in 0-10.2.3.4.in-addr-arpa
	my @o = split(/\./, $ip);
	foreach my $pz (@zones) {
		my $pip = &bind8::arpa_to_ip($pz->{'value'});
		next if ($pip eq $pz->{'value'});
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
my $file = &bind8::find("file", $z->{'members'});
my $fn = $file->{'values'}->[0];
my @recs = &bind8::read_zone_file($fn, $z->{'value'});
return ( $fn, \@recs, $arpa, $z->{'value'} );
}

# get_server_reverse_records(&server)
# Returns a list of reverse records for some system, each of which is a hash
# ref with 'ip' and possibly 'name' keys. If an IP is not in a zone we host,
# the 'outside' key is set.
# XXX deal with smaller-than-class-C zones
sub get_server_reverse_records
{
my ($server) = @_;
my @ips = &get_server_ip($server);
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
	my $arpa = &ip_address_to_arpa($ip, $zone);
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
if ($zone =~ /^([0-9\.]+)\.in-addr\.arpa$/) {
	# Normal class C
	return &bind8::ip_to_arpa($ip);
	}
else {
	# Assume last octet is within the zone
	my @o = split(/\./, $ip);
	return $o[3].".".$zone.".";
	}
}

sub bind_module_link
{
return "<a href=../bind8/index.cgi>$text{'index_bindlink'}</a>";
}

1;

