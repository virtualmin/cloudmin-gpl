#!/usr/local/bin/perl
# Roll back a VM to a snapshot, after asking for confirmation

require './server-manager-lib.pl';
&ReadParse();

# Get the server and snapshot
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "snapshots");
$snaps = &list_snapshots($server); 
ref($snaps) || &error(&text('snapshots_elist', $snaps));
($snapshot) = grep { $_->{'id'} eq $in{'snapid'} } @$snaps;
$snapshot || &error(&text('snapshot_egone', $in{'snapid'}));

&ui_print_header(&server_in($server), $text{'snapshot_mtitle'}, "");

if ($in{'confirm'}) {
	&obtain_lock_server($server);

	if ($server->{'status'} ne 'down') {
		&$first_print($text{'mkimage_shutdown'});
		$err = &shutdown_server($server, 1);
		if ($err) {
			&$second_print(&text('mkimage_eshutdown', $err));
			goto FAILED;
			}
		else {
			&$second_print($text{'create_done'});
			}
		&check_server_status($server, 0, 1);
		&save_managed_server($server);
		$shutdown = 1;
		}

	# Do it
	&$first_print(&text('snapshot_revert', "<tt>$snapid</tt>",
			    $server->{'host'}));
	$err = &merge_snapshot($server, $snapshot);
	if ($err) {
		&$second_print(&text('snapshot_erevert', $err));
		goto FAILED;
		}
	else {
		&$second_print($text{'create_done'});
		}

	# Start back up again
	if ($shutdown) {
		&$first_print($text{'mkimage_startup'});
		($sok, $serr) = &startup_server($server);
		if (!$sok) {
			&$second_print(&text('mkimage_estartup', $err));
			}
		else {
			&$second_print($text{'create_done'});
			}
		}

	# Re-check status
	&$first_print($text{'save_refreshing'});
	&check_server_status($server);
	&save_managed_server($server);
	&$second_print(&text('save_refreshdone2',
			     describe_status($server, 1, 1)));

	FAILED:
	&release_lock_server($server);
	&webmin_log("merge", "snapshot", $server->{'host'},
		    { 'snapid' => $snapshot->{'id'} });
	}
else {
	print &ui_confirmation_form(
		"merge_snapshot.cgi",
		&text('snapshot_mrusure', "<tt>$in{'snapid'}</tt>"),
		[ [ "id", $in{'id'} ],
		  [ "snapid", $in{'snapid'} ] ],
		[ [ "confirm", $text{'snapshot_mok'} ] ],
		);
	}

&ui_print_footer("list_snapshots.cgi?id=$in{'id'}", $text{'snapshots_return'});
