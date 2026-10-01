package Cloudmin::ImageInspector;

# Read-only inspection of custom disk images inside a libguestfs appliance.
use strict;
use warnings;

# inspect(path, format, [appliance_only])
# Opens a standalone local disk without booting it or mounting it on the host.
# appliance_only verifies appliance boot for installation readiness and skips
# inspection of the disk's operating system.
sub inspect
{
my ($path, $format, $appliance_only) = @_;
# Refuse missing disks and implicit format detection for untrusted input.
die "Select a readable local image\n" if (!$path || !-f $path);
# Select the disk parser explicitly instead of guessing from image headers.
die "Select QCOW2 or raw image format\n" if ($format !~ /\A(?:qcow2|raw)\z/);
eval { require Sys::Guestfs; 1 }
	|| die "Install libguestfs and its Perl bindings to check custom image compatibility\n";
my $g = Sys::Guestfs->new();
my $result;
my $ok = eval {
	# Read the disk through a KVM appliance with networking disabled.
	$g->set_backend('direct');
	$g->set_backend_setting('force_kvm', '1');
	$g->set_network(0);
	$g->set_trace(0);
	$g->set_verbose(0);
	$g->add_drive_opts($path, format => $format, readonly => 1);
	$g->launch();
	$result = $appliance_only ? { appliance => 1 } : inspect_guest($g);
	1;
	};
my $error = $@;
# Always release the appliance, without replacing the original inspection error.
eval { $g->close(); };
die $error if (!$ok);
return $result;
}

# inspect_guest(guestfs)
# Requires one Linux installation, a known CPU architecture and usable
# cloud-init files.
sub inspect_guest
{
my ($g) = @_;
my @roots = $g->inspect_os();
# Multi-boot and non-Linux disks cannot use the current cloud-init creation
# flow.
die "The image must contain one installed Linux operating system\n"
	if (@roots != 1 || $g->inspect_get_type($roots[0]) ne 'linux');
my $root = $roots[0];
my $architecture = $g->inspect_get_arch($root);
# An unknown architecture cannot be matched safely to the compute host.
die "Cannot determine this image's CPU architecture\n"
	if (!$architecture || $architecture eq 'unknown');
my %mounts = $g->inspect_get_mountpoints($root);
# Mount parents before children so a separate /usr does not hide installed
# software.
foreach my $mount (sort { length($a) <=> length($b) || $a cmp $b }
	keys %mounts) {
	$g->mount_ro($mounts{$mount}, $mount);
	}
# A configuration file alone is insufficient if cloud-init is disabled or
# absent.
die "Cloud-init is disabled in this image\n"
	if ($g->exists('/etc/cloud/cloud-init.disabled'));
# Require cloud-init's configuration and program file, not a package
# marker.
die "Cloud-init is not installed in this image\n"
	if (!$g->is_file('/etc/cloud/cloud.cfg', followsymlinks => 1) ||
		!grep { $g->is_file($_, followsymlinks => 1) }
		qw(/usr/bin/cloud-init /usr/local/bin/cloud-init));
# A masked first-boot service prevents the supplied login and network settings.
foreach my $unit (qw(cloud-init-local.service cloud-init.service
		    cloud-init-network.service cloud-config.service
		    cloud-final.service)) {
	my $path = '/etc/systemd/system/'.$unit;
	die "Cloud-init is disabled in this image because $unit is masked\n"
		if ($g->is_symlink($path) &&
		$g->readlink($path) eq '/dev/null');
	}
check_cloud_config($g);
return { architecture => $architecture, cloud_init => 1 };
}

# check_cloud_config(guestfs)
# Rejects explicit datasource or network settings that ignore Cloudmin's seed
# disk.
sub check_cloud_config
{
my ($g) = @_;
eval { require YAML::XS; YAML::XS->VERSION(0.69); 1 }
	|| die "Install YAML::XS to check custom cloud-init configuration\n";
my @files = ('/etc/cloud/cloud.cfg',
	sort $g->glob_expand('/etc/cloud/cloud.cfg.d/*.cfg'));
# Bound both fragment count and total bytes before parsing guest-controlled
# YAML.
die "Too many cloud-init configuration files to inspect\n" if (@files > 128);
my ($sources, $sources_set, $network, $bytes);
foreach my $file (@files) {
	# Limit input and disable Perl object/code construction in
	# guest-supplied YAML.
	$bytes += $g->filesize($file);
	die "Cloud-init configuration is too large to inspect\n"
		if ($bytes > 1024*1024);
	my $config = eval {
		no warnings 'once';
		local $YAML::XS::LoadBlessed = 0;
		local $YAML::XS::LoadCode = 0;
		local $YAML::XS::UseCode = 0;
		my @documents = YAML::XS::Load($g->read_file($file));
		# A fragment may be empty but cannot contain several YAML
		# documents.
		die "Multiple documents\n" if (@documents > 1);
		$documents[0] || {};
		};
	# Require a parsed mapping before reading datasource and network
	# settings.
	die "Cannot read cloud-init configuration in $file\n"
		if ($@ || ref($config) ne 'HASH');
	# Later config fragments override explicit datasource and network
	# choices.
	if (exists($config->{'datasource_list'})) {
		$sources = $config->{'datasource_list'};
		$sources_set = 1;
		}
	if (ref($config->{'network'}) eq 'HASH' &&
		exists($config->{'network'}->{'config'})) {
		# Preserve the last explicit network switch in cloud-init's load
		# order.
		$network = $config->{'network'}->{'config'};
		}
	}
# Explicit datasource lists must allow the seed format Cloudmin writes.
die "This image disables the NoCloud datasource required by Cloudmin\n"
	if ($sources_set &&
	(ref($sources) ne 'ARRAY' ||
	!grep { defined($_) && !ref($_) && $_ eq 'NoCloud' } @$sources));
# A disabled network stage would ignore the addresses chosen during creation.
die "Cloud-init network configuration is disabled in this image\n"
	if (defined($network) && $network eq 'disabled');
}

1;
