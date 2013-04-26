# Functions for managing VM snapshots to LVM

# supports_snapshot(&server)
# Returns 1 if some VM type can possibly support snapshots
sub supports_snapshot
{
my ($server) = @_;
return $server->{'manager'} eq 'kvm' ||
       $server->{'manager'} eq 'xen';
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

1;
