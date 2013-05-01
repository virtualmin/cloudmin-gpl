#!/usr/local/bin/perl
# Show existing snapshots and a form to add one

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "snapshots");

&ui_print_header(&server_in($server), $text{'snapshots_title'}, "","snapshots");

$err = &check_snapshot_support($server);
if ($err) {
	&ui_print_endpage(&text('snapshots_echeck', $err));
	}

$snaps = &list_snapshots($server);
if (!ref($snaps)) {
	&ui_print_endpage(&text('snapshots_elist', $snaps));
	}

if (@$snaps) {
	# Show table of existing snapshots
	print &ui_form_start("delete_snapshots.cgi");
	print &ui_hidden("id", $in{'id'});
	@tds = ( "width=5" );
	print &ui_checked_columns_start([
		"",
		$text{'snapshots_id'},
		$text{'snapshots_size'},
		$text{'snapshots_disks'},
		$text{'snapshots_percent'},
		$text{'snapshots_status'},
		]);
	foreach my $s (@$snaps) {
		my ($totalsize, $maxpc, $anyinactive) = (0, 0, 0);
		for(my $i=0; $i<@{$s->{'sizes'}}; $i++) {
			$totalsize += $s->{'sizes'}->[$i];
			$maxpc = $s->{'usages'}->[$i]
				if ($s->{'usages'}->[$i] > $maxpc);
			$anyinactive = 1 if (!$s->{'actives'}->[$i]);
			}
		print &ui_checked_columns_row([
			"<a href='edit_snapshot.cgi?id=$in{'id'}&snapid=$s->{'id'}'>".&html_escape($s->{'id'})."</a>",
			&nice_size($totalsize),
			scalar(@{$s->{'lvs'}}),
			$anyinactive ? "100%" : $maxpc."%",
			$anyinactive ?
			  "<font color=red>$text{'snapshots_inactive'}</font>" :
			  $text{'snapshots_active'},
			], \@tds, "d", $s->{'id'});
		}
	print &ui_columns_end();
	print &ui_form_end([ [ undef, $text{'snapshots_delete'} ] ]);
	}
else {
	print "<b>$text{'snapshots_none'}</b><p>\n";
	}

# Get total disk size
$dfunc = "type_".$server->{'manager'}."_list_disks";
$disks = &$dfunc($server);
$total = 0;
foreach my $d (@$disks) {
	$total += $d->{'size'};
	}

# Show form to add one
print &ui_form_start("create_snapshot.cgi");
print &ui_hidden("id", $in{'id'});
print &ui_table_start($text{'snapshots_header'}, undef, 2);

# Snapshot name
print &ui_table_row($text{'snapshots_snapid'},
	&ui_textbox("snapid", undef, 20));

# Percent of VM disk to allocate
print &ui_table_row($text{'snapshots_percent'},
	&ui_textbox("percent", 20, 4)."% ".$text{'snapshots_of'}." ".
	&nice_size($total));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'create'} ] ]);

&ui_print_footer("", $text{'index_return'});

