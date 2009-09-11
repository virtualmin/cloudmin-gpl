#!/usr/local/bin/perl
# Delete several EC2 volume snapshots, after asking for confirmation

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&error_setup($text{'dsnapshots_err'});
&ReadParse();

# Get the accounts and snapshots
@accounts = &list_ec2_accounts();
foreach $d (split(/\0/, $in{'sd'})) {
	($ec2id, $sid) = split(/\//, $d);
	($ec2) = grep { $_->{'id'} eq $ec2id } @accounts;
	$ec2 || &error(&text('dvolume_egone1', $ec2id));
	$snaps = $snapscache{$ec2id} || &list_ec2_snapshots($ec2);
	$snaps || &error($snaps);
	$snapscache{$ec2id} ||= $snaps;
	($s) = grep { $_->{'snapshotId'} eq $sid } @$snaps;
	$s || &error(&text('dsnapshot_egone2', $sid));
	push(@del, [ $ec2, $s ]);
	}
@del || &error($text{'dsnapshots_enone'});

if ($in{'confirm'}) {
	# Do it!
	&ui_print_unbuffered_header(undef, $text{'dsnapshots_title'}, "");
	&obtain_lock_anything();
	@snaps = ( );
	foreach $del (@del) {
		print &text('dsnapshots_deleting',
			    $del->[1]->{'snapshotId'}),"<br>\n";
		$err = &delete_ec2_snapshot($del->[0],
					    $del->[1]->{'snapshotId'});
		if ($err) {
			print &text('dvolumes_failed', $err),"<p>\n";
			push(@snaps, $del->[1]->{'snapshotId'});
			}
		else {
			print $text{'create_done'},"<p>\n";
			}
		}
	if (@snaps) {
		&webmin_log("delete", "snaps", scalar(@snaps),
			    { 'snap' => join(' ', @snaps) });
		}
	}
else {
	# Ask the user if he is sure first
	&ui_print_header(undef, $text{'dsnapshots_title'}, "");

	print "<center>\n";
	print &ui_form_start("delete_snapshots.cgi");
	foreach $d (split(/\0/, $in{'sd'})) {
		print &ui_hidden("sd", $d);
		}
	print &text('dsnapshots_rusure', scalar(@del)),"<p>\n";
	print &text('dsnapshots_snaps',
		join(" ", map { $_->[1]->{'snapshotId'} } @del)),"<p>\n";
	print &ui_form_end([ [ 'confirm', $text{'dsnapshots_ok'} ] ]);
	print "</center>\n";
	}

&ui_print_footer("list_volumes.cgi?mode=snaps", $text{'volumes_return2'});

