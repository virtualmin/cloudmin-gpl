package Cloudmin::CloneGuest;

# Clone preparation runs inside the unprivileged worker. Libguestfs mounts only
# independent copies, never source volumes or host filesystems.
use strict;
use warnings;
use File::Basename qw(dirname);
require(dirname(__FILE__).'/ImageInspector.pm');

# read_small(guestfs, path) bounds guest-controlled text before parsing it.
sub read_small
{
my ($g, $path) = @_;
return '' if (!$g->is_file($path, followsymlinks => 1));
die "Guest configuration is too large: $path\n"
	if ($g->filesize($path) > 1024 * 1024);
return $g->read_file($path);
}

# write_private(guestfs, path, content, [mode]) writes a root-owned guest file.
# mode defaults to 0600; callers can adjust ownership after writing. Replacing a
# symlink affects only its entry, never an unrelated guest target.
sub write_private
{
my ($g, $path, $content, $mode) = @_;
$g->mkdir_p(dirname($path));
$g->rm($path) if ($g->is_symlink($path));
$g->write($path, $content);
$g->chmod($mode // 0600, $path);
$g->chown(0, 0, $path);
}

# remove_matches(guestfs, patterns...) removes state matching
# guest glob patterns.
sub remove_matches
{
my ($g, @patterns) = @_;
foreach my $pattern (@patterns) {
	$g->rm_rf($_) foreach $g->glob_expand($pattern);
	}
}

# prepare(request, [finish]) resets host ID and Pro credentials offline.
# Prepared mode also resets machine identity and cloud-init state.
# finish(guestfs, result) optionally prepares a reusable image before
# unmounting. disks is a bounded array of fixed basenames/formats; settings
# holds validated cloud-init access and hostname data. No guest
# commands run on the host.
sub prepare
{
my ($r, $finish) = @_;
my $disks = $r->{'disks'};
my $mode = $r->{'mode'} || 'prepared';
die "Invalid clone preparation mode\n"
	if ($mode !~ /\A(?:prepared|unchanged)\z/);
my $uuid = $r->{'uuid'} || '';
# Validate the appliance's disk list and identity before opening any copy.
die "Invalid clone identity\n"
	if ($uuid !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/);
die "Select one to 32 clone disks\n"
	if (ref($disks) ne 'ARRAY' || !@$disks || @$disks > 32);
require Sys::Guestfs;
my $g = Sys::Guestfs->new();
my $result;
my $ok = eval {
	# Keep guest code and filesystem access inside an
	# appliance without networking.
	$g->set_backend('direct');
	$g->set_backend_setting('force_kvm', '1');
	$g->set_network(0);
	$g->set_trace(0);
	$g->set_verbose(0);
	foreach my $index (0 .. $#$disks) {
		my $disk = $disks->[$index];
		die "Invalid prepared clone disk\n"
			if ($disk->{'name'} ne "disk$index" ||
			    $disk->{'format'} !~ /\A(?:raw|qcow2)\z/);
		# A format check rejects backing links before the
		# appliance can follow them.
		my $info =
			Cloudmin::WorkerTasks::disk_info($disk->{'format'},
							 $disk->{'name'});
		die "The copied disk capacity changed before preparation\n"
			if ($info->{'virtual-size'} != $disk->{'capacity'});
		$g->add_drive_opts($disk->{'name'}, format => $disk->{'format'},
				   readonly => 0);
		}
	$g->launch();
	# Mount parents first and reject ambiguous or non-Linux installations.
	my @roots = $g->inspect_os();
	die "Cloning requires exactly one Linux installation that libguestfs can inspect\n"
		if (@roots != 1 || $g->inspect_get_type($roots[0]) ne 'linux');
	my %mounts = $g->inspect_get_mountpoints($roots[0]);
	foreach my $mount (sort { length($a) <=> length($b) ||
		$a cmp $b } keys %mounts) {
		$g->mount($mounts{$mount}, $mount);
		}
	my $settings = $r->{'settings'};
	# Application checks use the installed files, not the
	# selected template name.
	my $hostname = $settings->{'hostname'} || '';
	die "Invalid clone hostname\n"
		if ($mode eq 'prepared' &&
		    $hostname !~ /\A[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}\z/);
	my $old = read_small($g, '/etc/hostname');
	$old =~ s/\s+\z//;
	my ($webmin) =
		grep { $g->is_file("$_/virtual-server/virtual-server-lib.pl",
				   followsymlinks => 1) }
		qw(/usr/share/webmin /usr/libexec/webmin);
	my $edition = '';
	if ($webmin) {
		# The installed Pro directory determines the edition, even if
		# its credentials have already been removed or
		# replaced with GPL markers.
		$edition =
			$g->is_dir("$webmin/virtual-server/pro",
				   followsymlinks =>
					   1) ? 'pro' : 'gpl';
		}
	die "Virtualmin requires a fully qualified hostname for the clone\n"
		if ($mode eq 'prepared' && $edition && $hostname !~ /\./);
	die "Confirm removal of the clone's Virtualmin Pro license credentials; add a separate Pro license or downgrade manually to GPL\n"
		if ($edition eq 'pro' && !$r->{'confirm_license'});
	# ARM guests and machines without DMI fall back to the hostid command.
	# Reset its on-disk value in both modes, without
	# retaining the source ID.
	my $oldid = substr(read_small($g, '/etc/hostid'), 0, 4);
	my $value = hex(substr($uuid, 0, 8));
	my $hostid = pack('V', $value);
	while ($hostid eq $oldid || !$value || $value == 0x7f0100) {
		# Skip a copied value and Virtualmin's unusable
		# hostid fallback values.
		$value = ($value + 1) & 0xffffffff;
		$hostid = pack('V', $value);
		}
	write_private($g, '/etc/hostid', $hostid, 0644);
	# Full preparation additionally resets cloud-init,
	# login and network state.
	if ($mode eq 'prepared') {
		die "Prepared cloning requires enabled cloud-init; choose an unchanged copy instead\n"
			if ($g->exists('/etc/cloud/cloud-init.disabled') ||
			    !$g->is_file('/etc/cloud/cloud.cfg',
					 followsymlinks =>
						 1) ||
			    !grep { $g->is_file($_, followsymlinks =>
							    1) } qw(/usr/bin/cloud-init /usr/local/bin/cloud-init));
		foreach my $unit (
			qw(cloud-init-local.service cloud-init.service cloud-init-network.service cloud-config.service cloud-final.service)) {
			my $path = '/etc/systemd/system/'.$unit;
			die "Prepared cloning requires unmasked cloud-init services\n"
				if ($g->is_symlink($path) &&
				    $g->readlink($path) eq '/dev/null');
			}
		Cloudmin::ImageInspector::check_cloud_config($g);
		# Remove identity and one-time provisioning state,
		# preserving applications.
		remove_matches($g, '/etc/ssh/ssh_host_*',
			       '/var/lib/cloud/instances/*',
			       '/var/lib/cloud/instance',
			       '/var/lib/cloud/data/*',
			       '/var/lib/cloud/sem/*',
			       '/var/lib/cloud/seed/*',
			       '/var/lib/dhcp/*.leases*',
			       '/var/lib/NetworkManager/*.lease*',
			       '/var/lib/NetworkManager/secret_key',
			       '/var/lib/dhcpcd/*.lease*',
			       '/var/lib/dhcpcd5/*.lease*',
			       '/var/lib/systemd/random-seed',
			       '/var/lib/systemd/network/*',
			       '/etc/udev/rules.d/70-persistent-net.rules',
			       '/var/lib/cloudmin-install',
			       '/etc/cloudmin-install.json',
			       '/var/log/qemu-ga/cloudmin-identity.json',
			       '/etc/systemd/system/cloudmin-software.service',
			       '/etc/systemd/system/multi-user.target.wants/cloudmin-software.service');
		# An empty file generates a new ID without
		# rerunning systemd first boot.
		write_private($g, '/etc/machine-id', '', 0444);
		$g->rm('/var/lib/dbus/machine-id')
			if ($g->exists('/var/lib/dbus/machine-id') ||
			    $g->is_symlink('/var/lib/dbus/machine-id'));
		write_private($g, '/etc/hostname', "$hostname\n", 0644);
		# Cloud-init must detect the new instance even if the
		# source trusted its cache.
		write_private($g,
			      '/etc/cloud/cloud.cfg.d/99-cloudmin-clone.cfg',
			      "manual_cache_clean: false\npreserve_hostname: false\nssh_deletekeys: true\n", 0644);
		my $hosts = read_small($g, '/etc/hosts');
		# Replace whole hostname references without
		# changing unrelated aliases.
		$hosts =~ s/(?<![\w.-])\Q$old\E(?![\w.-])/$hostname/g if ($old);
		write_private($g, '/etc/hosts', $hosts, 0644)
			if (length($hosts));
		# Image capture delegates optional all-account cleanup
		# to its Pro callback.
		if (!$r->{'capture_image'}) {
			# Replace the selected administrator's old keys; other
			# application accounts belong to the cloned workload and
			# are deliberately preserved.
			my $username = $settings->{'username'};
			my ($entry) = grep { (split(/:/, $_))[0] eq $username }
				      split(/\n/, read_small($g,
							     '/etc/passwd'));
			if ($entry) {
				# Existing users need old keys removed before
				# cloud-init adds new ones.
				my @fields = split(/:/, $entry);
				my $home = $fields[5];
				die "Invalid administrator home in clone\n" if (
					!$home || $home !~ m{\A/} ||
					$home =~ m{(?:\A|/)\.\.(?:/|\z)});
				my @keys =
					grep { length } @{
						$settings}{qw(ssh_keys host_public_key)};
				write_private($g, "$home/.ssh/authorized_keys",
					      join("\n", @keys)."\n");
				$g->chown($fields[2], $fields[3],
					  "$home/.ssh/authorized_keys");
				}
			}
		}
	# Use Virtualmin's APIs inside the offline appliance for licenses and
	# hostname state. With networking disabled, its helper cannot
	# contact license servers.
	if ($edition) {
		my $helper = dirname(__FILE__).'/../../clone-virtualmin.pl';
		open(my $fh, '<', $helper) or
			die "Clone application helper is missing\n";
		my $script = do { local $/; <$fh> }; close($fh);
		write_private($g, '/var/tmp/cloudmin-clone-virtualmin.pl',
			      $script, 0700);
		$g->command([ '/bin/hostname', $hostname ])
			if ($mode eq 'prepared');
		my $output =
			$g->command([ '/usr/bin/perl',
				      '/var/tmp/cloudmin-clone-virtualmin.pl',
				      $webmin,
				      $old,
				      $hostname, $mode ]);
		# Some Webmin error handlers exit without a
		# failing process status.
		die "Virtualmin clone preparation did not complete\n"
			if ($output !~ /\ACLOUDMIN_CLONE_READY\s*\z/);
		# Verify that the helper replaced both credentials
		# with the clone marker.
		if ($edition eq 'pro') {
			my $license = read_small($g, '/etc/virtualmin-license');
			die "Copied Pro credentials were not removed\n" unless
				$license =~ /^SerialNumber=[\"']?CLONE_REQUIRES_LICENSE[\"']?\s*$/m &&
				$license =~ /^LicenseKey=[\"']?CLONE_REQUIRES_LICENSE[\"']?\s*$/m;
			}
		$g->rm('/var/tmp/cloudmin-clone-virtualmin.pl');
		}
	$result = { virtualmin => $edition, hostname => $hostname,
		    architecture => $g->inspect_get_arch($roots[0]) };
	# Capture clears administrator credentials while the
	# copy is still mounted.
	$finish->($g, $result) if ($finish);
	# Flush and detach filesystems before returning disks to the controller.
	$g->sync();
	$g->umount_all();
	$g->shutdown();
	1;
	};
my $error = $@;
# Always close the appliance, preserving the original preparation failure.
eval { $g->close(); };
die $error if (!$ok);
return $result;
}

1;
