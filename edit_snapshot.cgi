#!/usr/local/bin/perl
# Show all details of one snapshot

require './server-manager-lib.pl';
&ReadParse();

# Get the server and snapshot
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "snapshots");
$snaps = &list_snapshots($server); 
ref($snaps) || &error(&text('snapshots_elist', $snaps));
($snapshot) = grep { $_->{'id'} eq $in{'snapid'} } @$snaps;
$snapshot || &error($text{'snapshot_egone'});

&ui_print_header(&server_in($server), $text{'snapshot_title'}, "");

print &ui_form_start("merge_snapshot.cgi");
print &ui_hidden("id", $in{'id'});
print &ui_hidden("snapid", $in{'snapid'});
print &ui_table_start($text{'snapshot_header'}, undef, 2);

# Snapshot ID
print &ui_table_row($text{'snapshots_snapid'},
	"<tt>".&html_escape($snapshot->{'id'})."</tt>");

$anyinactive = 0;
for(my $i=0; $i<@{$snapshot->{'lvs'}}; $i++) {
	print &ui_table_hr();

	print &ui_table_row($text{'snapshot_vg'},
		$snapshot->{'vgs'}->[$i]);

	print &ui_table_row($text{'snapshot_lv'},
		$snapshot->{'lvs'}->[$i]);

	print &ui_table_row($text{'snapshot_size'},
		&nice_size($snapshot->{'sizes'}->[$i]));

	if ($snapshot->{'actives'}->[$i]) {
		print &ui_table_row($text{'snapshot_status'},
			&text('snapshot_full',$snapshot->{'usages'}->[$i]."%"));
		}
	else {
		print &ui_table_row($text{'snapshot_status'},
			"<font color=red>$text{'snapshots_inactive'}</font>");
		$anyinactive = 1;
		}
	}

print &ui_table_end();
if ($anyinactive) {
	print &ui_form_end([ ]);
	print "<b>$text{'snapshot_nomerge'}</b><p>\n";
	}
else {
	print &ui_form_end([ [ undef, $text{'snapshot_merge'} ] ]);
	}

&ui_print_footer("list_snapshots.cgi?id=$in{'id'}", $text{'snapshots_return'});
