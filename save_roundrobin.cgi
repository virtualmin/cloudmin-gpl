#!/usr/local/bin/perl
# Create, update or delete a DNS roundrobin

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($in{'delete'} ? $text{'roundrobin_err2'}
			   : $text{'roundrobin_err'});
&error_if_cloudmin_replica();

# Get the roundrobin being edited
if (!$in{'new'}) {
	$roundrobin = &get_roundrobin($in{'id'});
	$roundrobin || &error($text{'roundrobin_egone'});
	}

if ($in{'delete'}) {
	# Just delete the roundrobin
	$err = &delete_roundrobin_dns($roundrobin);
	&error($err) if ($err);
	&delete_roundrobin($roundrobin);
	&webmin_log("delete", "roundrobin", $roundrobin->{'id'},
	    { 'name' => $roundrobin->{'name'}.".".$roundrobin->{'dom'} });
	}
else {
	# Validate inputs
	$roundrobin ||= { };
	foreach my $f ('servers', 'groups', 'owners') {
		delete($roundrobin->{$f});
		}

	# Parse systems
	if ($in{'mode'} == 1) {
		# Selected systems
		$roundrobin->{'servers'} =
			join(" ", split(/\r?\n/, $in{'servers'}));
		$roundrobin->{'servers'} || &error($text{'alert_eservers'});
		}
	elsif ($in{'mode'} == 2) {
		# Selected groups
		$roundrobin->{'groups'} =
			join(" ", split(/\r?\n/, $in{'groups'}));
		$roundrobin->{'groups'} || &error($text{'alert_egroups'});
		}
	elsif ($in{'mode'} == 3) {
		# Selected owners
		$roundrobin->{'owners'} =
			join(" ", split(/\r?\n/, $in{'owners'}));
		$roundrobin->{'owners'} || &error($text{'alert_eowners'});
		}
	elsif ($in{'mode'} == 5) {
		# Selected auto-scaling groups
		$roundrobin->{'scalegroups'} =
			join(" ", split(/\r?\n/, $in{'scalegroups'}));
		$roundrobin->{'scalegroups'} ||
			&error($text{'alert_escalegroups'});
		}
	elsif ($in{'mode'} == 6) {
		# Entered IPs
		@iplist = split(/\s+/, $in{'iplist'});
		@iplist || &error($text{'roundrobin_eiplist'});
		foreach $ip (@iplist) {
			&check_ipaddress($ip) ||
				&error(&text('roundrobin_eip', $ip));
			}
		$roundrobin->{'iplist'} = join(" ", @iplist);
		}

	# Parse DNS record
	$roundrobin->{'desc'} = $in{'desc'};
	$in{'name'} =~ /^[a-zA-Z0-9\.\_\-]+$/ ||
		&error($text{'roundrobin_ename'});
	$in{'name'} !~ /^\./ && $in{'name'} !~ /\.$/ ||
		&error($text{'roundrobin_ename2'});
	$roundrobin->{'name'} = $in{'name'};
	$in{'dom'} || &error($text{'roundrobin_edom'});
	$roundrobin->{'dom'} = $in{'dom'};
	$in{'ttl'} =~ /^\d+[smhdw]?$/ || &error($text{'roundrobin_ettl'});
	$roundrobin->{'ttl'} = $in{'ttl'};
	$in{'dnscount_def'} || $in{'dnscount'} =~ /^[1-9][0-9]*$/ ||
		&error($text{'roundrobin_ednscount'});
	$roundrobin->{'dnscount'} = $in{'dnscount_def'} ? undef
							: $in{'dnscount'};

	# Parse conditions
	$in{'status'} || &error($text{'roundrobin_estatus'});
	$roundrobin->{'status'} = join(" ", split(/\0/, $in{'status'}));
	if ($in{'ports_def'}) {
		delete($roundrobin->{'ports'});
		}
	else {
		@ports = split(/\s+/, $in{'ports'});
		foreach $p (@ports) {
			$p =~ /^[1-9][0-9]*$/ ||
			    &error(&text('roundrobin_eport', $p));
			}
		@ports || &error($text{'roundrobin_eports'});
		$roundrobin->{'ports'} = join(" ", @ports);
		}
	if ($in{'url_def'}) {
		delete($roundrobin->{'url'});
		}
	else {
		$in{'url'} =~ /^(http|https):\/\// ||
			&error($text{'roundrobin_eurl'});
		$roundrobin->{'url'} = $in{'url'};
		}
	$roundrobin->{'alerts'} = join(" ", split(/\0/, $in{'alerts'}));

	# Parse email notification
	$in{'min'} =~ /^\d+$/ || &error($text{'roundrobin_emin'});
	$roundrobin->{'min'} = $in{'min'};
	$roundrobin->{'master'} = $in{'master'};
	if ($in{'email'}) {
		$in{'emailto'} =~ /\S/ || &error($text{'alert_eemail'});
		$roundrobin->{'email'} = $in{'emailto'};
		}
	else {
		$roundrobin->{'email'} = '';
		}
	$in{'int'} =~ /^\d+$/ || &error($text{'alert_einterval'});
	$roundrobin->{'interval'} = &join_for_units($in{'intunit'}, $in{'int'});

	# Save or create, and evaluate now
	&save_roundrobin($roundrobin);
	&evaluate_all_roundrobins(undef, [ $roundrobin ], 1);
	&save_roundrobin($roundrobin);
	&webmin_log($in{'new'} ? "create" : "modify", "roundrobin",
	    $roundrobin->{'id'},
	    { 'name' => $roundrobin->{'name'}.".".$roundrobin->{'dom'} });
	}

&redirect("list_roundrobins.cgi");

