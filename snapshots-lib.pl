# Functions for managing VM snapshots to LVM

# supports_snapshot(&server)
# Returns 1 if some VM type can possibly support snapshots
sub supports_snapshot
{
my ($server) = @_;
return ($server->{'manager'} eq 'kvm' ||
        $server->{'manager'} eq 'xen') &&
       $server->{'status'} ne 'nohost';
}

# check_snapshot_support(&server)
# Returns undef if snapshots can be used on a VM, or an error message if not
sub check_snapshot_support
{
my ($server) = @_;
if ($server->{'manager'} ne 'kvm' &&
    $server->{'manager'} ne 'xen') {
	return $text{'snapshot_evmtype'};
	}
elsif ($server->{'status'} eq 'nohost') {
	return $text{'snapshot_enohost'};
	}
elsif (!$server->{$server->{'manager'}.'_filesystem_vg'}) {
	return $text{'snapshot_elvmdisk'};
	}
else {
	my $vhost = &get_parent_server($server);
	foreach my $cmd ("lvconvert", "dmsetup") {
		&has_command_on_server($vhost, $cmd) ||
			return &text('snapshot_evhostcmd', "<tt>$cmd</tt>",
				     "<tt>$vhost->{'host'}</tt>");
		}
	&execute_command_on_server($vhost, "modprobe dm-snapshot");
	my ($out, $ex, $err) = &execute_command_on_server(
				$vhost, "dmsetup targets");
	if ($ex || $err) {
		return &text('snapshot_edmsetup', $err || $out,
			     "<tt>$vhost->{'host'}</tt>");
		}
	if ($out !~ /snapshot-merge/) {
		return &text('snapshot_emerge', "<tt>$vhost->{'host'}</tt>");
		}
	return undef;
	}
}

# create_snapshot(&server, snapshot_id, size_percent)
# Creates a new snapshot for the disks in some system.
sub create_snapshot
{
my ($server, $snapid, $percent) = @_;
my $vhost = &get_parent_server($server);
my $lfunc = "type_".$server->{'manager'}."_list_disks";
my $disks = &$lfunc($server, 0);
ref($disks) || return $disks;
@$disks || return $text{'snapshot_enodisks'};

# Connect to vhost
$last_remote_error = undef;
&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
return $last_remote_error if ($last_remote_error);

if (&can_ssh_status($server)) {
        # Flush buffers to disk to ensure disk copy gets everything
        &execute_command_on_server($server, "sync ; sync ; sync");
	}

# Go through all the disks, and LV snapshot each one
my $i = 0;
foreach my $d (@$disks) {
	if ($d->{'vg'}) {
		# This disk can be snapshotted .. do it
		my $snapname = $server->{'host'}."_".$i."_".$snapid."_snap";
		my $snaplv = {
			'size' => int($d->{'size'} * $percent / 100 / 1024),
			'is_snap' => 1,
			'snapof' => $d->{'lv'},
			'name' => $snapname,
			'vg' => $d->{'vg'},
			'perm' => 'rw',
			'alloc' => 'n',
			};
		my $err = &remote_foreign_call($vhost, "lvm",
                                          "create_logical_volume", $snaplv);
		$err ||= $last_remote_error;
		return $err if ($err);
		}
	$i++;
	}

return undef;
}

# list_snapshots(&server)
# Returns a list of snapshots for some server, based on snapshot LVs that exist
sub list_snapshots
{
my ($server) = @_;
my $vhost = &get_parent_server($server);

# Get all LVs on the host
$last_remote_error = undef;
&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
return $last_remote_error if ($last_remote_error);
my @vgs = &remote_foreign_call($vhost, "lvm", "list_volume_groups");
return $last_remote_error if ($last_remote_error);
my @lvs;
foreach my $vg (@vgs) {
	push(@lvs, &remote_foreign_call($vhost, "lvm",
		"list_logical_volumes", $vg->{'name'}));
	}

# Search for snapshots for the system
@lvs = sort { $a->{'name'} cmp $b->{'name'} } @lvs;
my @rv;
foreach my $lv (@lvs) {
	if ($lv->{'is_snap'} &&
	    $lv->{'name'} =~ /^(\S+)_(\d+)_(\S+)_snap$/ &&
	    $1 eq $server->{'host'}) {
		# Found an LV that is for a snapshot
		my ($disknum, $snapid) = ($2, $3);
		my $snap;
		if ($disknum == 0) {
			# First disk
			$snap = { 'id' => $snapid,
				  'sizes' => [ ],
				  'vgs' => [ ],
				  'lvs' => [ ],
				  'usages' => [ ] };
			push(@rv, $snap);
			}
		else {
			# Second disk, so add to existing snapshot
			($snap) = grep { $_->{'id'} eq $snapid } @rv;
			next if (!$snap);	# No first disk??
			}
		$lv->{'device'} =~ /^\/dev\/([^\/]+)\/\S+$/ || next;
		push(@{$snap->{'vgs'}}, $1);
		push(@{$snap->{'lvs'}}, $lv->{'name'});
		push(@{$snap->{'sizes'}}, $lv->{'size'});
		push(@{$snap->{'usages'}}, $lv->{'snapusage'});
		push(@{$snap->{'actives'}},
		     defined($lv->{'snap_active'}) ? $lv->{'snap_active'} :
		     $lv->{'snapusage'} eq '' ? 0 : 1);
		}
	}

return \@rv;
}

# delete_snapshot(&server, &snapshot)
# Delete one snapshot that was previously created, by deleting all LVs
sub delete_snapshot
{
my ($server, $snapshot) = @_;

# Connect to LVM module on host
my $vhost = &get_parent_server($server);
$last_remote_error = undef;
&remote_foreign_require($vhost, "lvm", "lvm-lib.pl");
return $last_remote_error if ($last_remote_error);

my @errs;
for(my $i=0; $i<@{$snapshot->{'lvs'}}; $i++) {
	my $snaplv = { 'name' => $snapshot->{'lvs'}->[$i],
		       'vg' => $snapshot->{'vgs'}->[$i] };
	$snaplv->{'device'} = "/dev/".$snaplv->{'vg'}."/".$snaplv->{'name'};
	my $err = &remote_foreign_call($vhost, "lvm",
			"delete_logical_volume", $snaplv);
	push(@errs, $err) if ($err);
	}

return join(" ", @errs);
}

# merge_snapshot(&server, &snapshot)
# Reset all disks for a system to the state from a snapshot
sub merge_snapshot
{
my ($server, $snapshot) = @_;
for(my $i=0; $i<@{$snapshot->{'actives'}}; $i++) {
	if (!$snapshot->{'actives'}->[$i]) {
		return &text('snapshot_eactive', $snapshot->{'lvs'}->[$i]);
		}
	}
my $vhost = &get_parent_server($server);
&execute_command_on_server($vhost, "modprobe dm-snapshot");
for(my $i=0; $i<@{$snapshot->{'lvs'}}; $i++) { 
	my $dev = "/dev/".$snapshot->{'vgs'}->[$i]."/".$snapshot->{'lvs'}->[$i];
	my ($out, $ex, $err) = &execute_command_on_server($vhost, 
		"lvconvert --merge $dev");
	return $err if ($err);
	return $out if ($ex);
	}
return undef;
}

1;
