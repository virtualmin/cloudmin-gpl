#!/usr/local/bin/perl
# Create, update or delete a DNS roundrobin

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'roundrobin_err'});
&error_if_cloudmin_replica();

# Get the roundrobin being edited
if (!$in{'new'}) {
	$roundrobin = &get_roundrobin($in{'id'});
	$roundrobin || &error($text{'roundrobin_egone'});
	}

if ($in{'delete'}) {
	# Just delete the roundrobin
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

	# Parse message
	$roundrobin->{'desc'} = $in{'desc_def'} ? undef : $in{'desc'};
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

