#!/usr/local/bin/perl
# Delete multiple VM snapshots

require './server-manager-lib.pl';
&ReadParse();
&error_setup($text{'snapshot_derr'});

# Get the server
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "snapshots");

# Validate inputs
@d = split(/\0/, $in{'d'});
@d || &error($text{'snapshot_enone'});

# Get the snapshots
$snaps = &list_snapshots($server); 
ref($snaps) || &error(&text('snapshots_elist', $snaps));
my @del;
foreach my $sid (@d) {
	($snapshot) = grep { $_->{'id'} eq $sid } @$snaps;
	$snapshot || &error(&text('snapshot_egone', $sid));
	push(@del, $snapshot);
	}

# Delete each one
&ui_print_header(&server_in($server), $text{'snapshot_dtitle'}, "");

&obtain_lock_server($server);
foreach my $snapshot (@del) {
	&$first_print(&text('snapshot_deleting', "<tt>$snapshot->{'id'}</tt>"));
	$err = &delete_snapshot($server, $snapshot);
	if ($err) {
		&$second_print(&text('snapshot_edelete', $err));
		}
	else {
		&$second_print($text{'create_done'});
		}
	}
&save_managed_server($server);
&release_lock_server($server);
if (@del == 1) {
	&webmin_log("delete", "snapshot", $server->{'host'},
		    { 'snapid' => $del[0]->{'id'} });
	}
else {
	&webmin_log("delete", "snapshots", $server->{'host'},
		    { 'count' => scalar(@del) });
	}

&ui_print_footer("list_snapshots.cgi?id=$in{'id'}", $text{'snapshots_return'});
