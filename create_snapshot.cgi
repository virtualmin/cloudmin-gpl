#!/usr/local/bin/perl
# Create a new snapshot for a VM

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'snapshot_cerr'});
&ReadParse();

# Get the server
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "snapshots");

# Validate inputs
$in{'snapid'} =~ /^[a-z0-9\.\-]+$/i ||
	&error($text{'shapshot_esnapid'});
$in{'percent'} =~ /^\d+$/ && $in{'percent'} > 0 && $in{'percent'} <= 100 ||
	&error($text{'shapshot_epercent'});

# Check for clash
$snaps = &list_snapshots($server); 
ref($snaps) || &error(&text('snapshots_elist', $snaps));
($clash) = grep { $_->{'id'} eq $in{'snapid'} } @$snaps;
$clash && &error($text{'snapshot_eclash'});

# Validate additional disk size
$limits = &get_owner_limits();
$snapsize = &new_snapshot_size($server, $in{'percent'});
if ($limits && $limits->{'max_disk'} &&
    $limits->{'disk'} + $snapsize > $limits->{'max_disk'}) {
	&error(&text('snapshot_elimit',
	       &nice_size($limits->{'max_disk'}),
	       &nice_size($limits->{'disk'})));
	}

&ui_print_header(&server_in($server), $text{'snapshot_ctitle'}, "");

# Create it
&$first_print(&text('snapshot_creating', $server->{'host'}));
&obtain_lock_server($server);
$err = &create_snapshot($server, $in{'snapid'}, $in{'percent'});
&save_managed_server($server);
&release_lock_server($server);
if ($err) {
	&$second_print(&text('snapshot_ecreate', $err));
	}
else {
	&$second_print($text{'create_done'});
	&webmin_log("create", "snapshot", $server->{'host'},
		    { 'snapid' => $in{'snapid'} });
	}

&ui_print_footer("list_snapshots.cgi?id=$in{'id'}",
		 $text{'snapshots_return'});


