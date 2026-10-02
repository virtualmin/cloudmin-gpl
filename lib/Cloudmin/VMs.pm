package Cloudmin::VMs;

# VM creation policy and orchestration shared by the UI and controller API.
use strict;
use warnings;
use WebminCore qw(convert_to_json make_dir
	check_ipaddress check_ip6address);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(decode_base64);
use Socket qw(AF_INET AF_INET6 inet_pton inet_ntop);
use POSIX qw(ceil);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/Images.pm');
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/Software.pm');
require(dirname(__FILE__).'/NetworkPreflight.pm');

# new(class, jobs => store, images => store, catalogue => reader,
#     adapter => factory, [host_memory => callback], [worker => runner],
#     [ssh_keys => key_store], [virtualmin_enabled => boolean],
#     [register_webmin => callback])
# Receives an adapter factory so each worker opens its own libvirt connection
# instead of reusing the request's. host_memory() returns available host
# bytes; worker defaults to Cloudmin::Worker. Virtualmin installation is allowed
# unless virtualmin_enabled is false.
# register_webmin(job, address) optionally registers a completed installation.
sub new
{
my ($class, %options) = @_;
return bless(\%options, $class);
}

# options(self)
# Returns current host capabilities and usable images, pools and network
# attachments. Missing cloud-init tools are reported without blocking ISO use.
sub options
{
my ($self) = @_;
Cloudmin::Jobs::dependencies();
my $adapter = $self->{'adapter'}->();
# Workers, storage paths and provisioning files belong to this compute
# host.
die "Virtual machine creation requires the local qemu:///system connection\n"
	if ($adapter->uri() ne 'qemu:///system');
my $caps = $adapter->get_host_capabilities();
# The controller supplies current free memory separately from host
# capacity.
$caps->{'free_memory'} = $self->{'host_memory'}->() if ($self->{'host_memory'});
# Report missing cloud-init tools; prepare() blocks cloud creation without them.
# Check the worker's fixed executable paths rather than the controller's PATH.
my $cloud_init_error = !-x '/usr/bin/xorriso'
	? 'Install xorriso to prepare cloud-init disks' : '';
# Public-key validation and optional host-key generation both use
# OpenSSH.
$cloud_init_error ||= 'Install OpenSSH client tools to validate SSH public keys'
	if (!-x '/usr/bin/ssh-keygen');
my $pools = $adapter->list_storage_pools(1);
my @pools = grep { $_->{'active'} && Cloudmin::Libvirt::disk_pool($_->{'type'}) }
	@$pools;
my %volumes = map { my $pool = $_;
	map { $pool->{'id'}.':'.$_->{'name'} => $_ } @{$pool->{'volumes'}} }
	@pools;
my @images;
# Offer only completed imports whose original volumes still exist on this host.
foreach my $job (@{$self->{'images'}->list()}) {
	next if ($job->{'state'} ne 'ready');
	my $volume = $volumes{$job->{'pool'}.':'.$job->{'volume'}} || next;
	# A replacement volume with the same name is not the imported
	# image.
	next if (!$job->{'volume_key'} || $volume->{'key'}
		ne $job->{'volume_key'});
	my $metadata = $self->image_metadata($job);
	# Keep custom imports without architecture metadata available. Cloud disks
	# are inspected after selection; the user must choose a compatible ISO.
	next if ($metadata->{'architecture'} && $metadata->{'architecture'}
		ne $caps->{'architecture'});
	push(@images, { %$job, map { $_ => $metadata->{$_} }
		qw(architecture firmware cloud_init guest_agent min_disk_bytes) });
	}
# Merge active libvirt networks with usable bridges not owned by those networks.
my $networks = $adapter->list_networks();
my @networks = map { { %$_, key => 'network:'.$_->{'id'}, type => 'network',
	source => $_->{'name'} } }
	grep { $_->{'active'} } @$networks;
push(@networks, map { { %$_, key => 'bridge:'.$_->{'name'}, type => 'bridge',
	source => $_->{'name'}, forward => 'bridge' } }
	grep { $_->{'state'} eq 'up' }
	@{$adapter->list_host_bridges($networks)});
my @catalogue;
# Catalogue choices remain available before their first download.
foreach my $entry (@{$self->{'catalogue'}->list_images($caps->{'architecture'})}) {
	# Cloud disks need first-boot provisioning; installer media do not.
	next if ($entry->{'format'} ne 'iso' && !$entry->{'cloud_init'});
	my $request = Cloudmin::Images::catalogue_request($entry, {});
	my ($ready) = grep { Cloudmin::Images::matches_download($_, $request) } @images;
	push(@catalogue, { %$entry, id => 'catalogue:'.$entry->{'id'},
		catalogue_id => $entry->{'id'}, downloaded => $ready ? 1 : 0,
		virtual_size => $ready ? $ready->{'virtual_size'} : $entry->{'min_disk_bytes'} });
}
return { capabilities => $caps, images => \@images, catalogue_images => \@catalogue, pools => \@pools,
	cloud_init_error => $cloud_init_error,
	networks => \@networks, domains => $adapter->list_domains(1) };
}

# image_metadata(self, image)
# Fills missing metadata from the exact downloaded catalogue asset, not its
# name.
sub image_metadata
{
my ($self, $image) = @_;
if (!$image->{'architecture'} && ($image->{'source'} || '') eq 'download') {
	# One catalogue ID can identify different architectures and different
	# files.
	my ($entry) = grep { $_->{'id'} eq ($image->{'slug'} || '') &&
		$_->{'url'} eq ($image->{'url'} || '') && $_->{'format'}
		eq $image->{'format'} }
		@{$self->{'catalogue'}->list_entries()};
	# Use catalogue metadata only when ID, URL and disk format all
	# match.
	return $entry if ($entry);
	}
return $image;
}

# disk_volume_name(vm_name, role, id, [pool_type])
# Uses short LV names for logical/lvmthin pools; other or omitted types get
# readable filenames. Existing volumes keep their original names.
sub disk_volume_name
{
my ($name, $role, $id, $type) = @_;
# LVM combines escaped group and volume names in one bounded mapper name.
return "cloudmin-$id-$role" if (($type || '') =~ /\A(?:logical|lvmthin)\z/);
$name =~ s/[^a-zA-Z0-9_.-]+/-/g;
$name =~ s/^[^a-zA-Z0-9]+//;
$name = substr($name || 'vm', 0, 63);
return "cloudmin-$name-$role-$id.".($role eq 'seed' ? 'iso' : 'qcow2');
}

# prepare(self, input, [options], [password_hash])
# Validates creation settings without creating a VM or its volumes. Custom cloud
# images with missing metadata may need isolated inspection; ISOs skip it.
# Password hashes come from the controller's private store, never public input.
# Omitted options trigger a fresh inventory; callers may pass one already
# loaded.
sub prepare
{
my ($self, $input, $options, $password_hash) = @_;
# Reject disabled installers before probing the host or allocating resources.
die "Virtualmin installation is disabled in Module Configuration. ".
	"Re-enable it to install Virtualmin.\n"
	if (defined($self->{'virtualmin_enabled'}) && !$self->{'virtualmin_enabled'} &&
		!ref($input->{'software'}) &&
		($input->{'software'} || '') =~ /\Avirtualmin-(?:gpl|pro)\z/);
$options ||= $self->options();
my $caps = $options->{'capabilities'};
my %r;
# Normalize only the accepted text fields before building the durable request.
foreach my $field (qw(name image install_source pool network username ssh_keys hostname
		     firmware ipv4 gateway4 ipv6 gateway6 dns mac
		     description require_fqdn)) {
	my $value = defined($input->{$field}) ? $input->{$field} : '';
	# Reject lists and objects where the form expects one text value.
	die "Invalid $field\n" if (ref($value));
	$value =~ s/^\s+|\s+$//g;
	# Bound text and exclude control bytes before storing or
	# rendering it.
	die "Invalid $field\n"
		if (ref($value) || $value =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/ ||
		length($value) > 16384);
	$r{$field} = $value;
	}
# Keep the hostname rule in the saved request for worker revalidation.
$r{'require_fqdn'} = 0 if ($r{'require_fqdn'} eq '');
die "Invalid fully qualified hostname requirement\n"
	if ($r{'require_fqdn'} !~ /\A[01]\z/);
# Default to cloud images for API clients that omit the installation source.
$r{'install_source'} ||= 'cloud';
die "Select a cloud image or installer ISO source\n"
	if ($r{'install_source'} !~ /\A(?:cloud|iso)\z/);
my $installer = $r{'install_source'} eq 'iso';
# Display names have a small, filesystem-independent character set.
die "Enter a virtual machine name using letters, numbers, spaces, dots, dashes or underscores\n"
	if ($r{'name'} !~ /\A[a-zA-Z0-9][a-zA-Z0-9_. -]{0,62}\z/);
# Libvirt domain names are unique across this host's managed inventory.
die "A virtual machine with this name already exists\n"
	if (grep { $_->{'name'} eq $r{'name'} } @{$options->{'domains'}});
my ($image) = grep { $_->{'id'} eq $r{'image'} }
	(@{$options->{'images'}}, @{$options->{'catalogue_images'} || []});
# Catalogue selections must still be enabled and compatible with this host.
die "Select an available image\n" if (!$image);
# Restrict destinations to the supported active pools returned by options().
my ($pool) = grep { $_->{'id'} eq $r{'pool'} } @{$options->{'pools'}};
die "Select an active storage pool\n" if (!$pool);
$r{'pool_type'} = $pool->{'type'} || 'dir';
if ($image->{'catalogue_id'}) {
	# Keep catalogue identity for retries and a fixed asset for the download worker.
	my $cache = $pool;
	if ($r{'pool_type'} =~ /\A(?:logical|lvmthin)\z/) {
		# Downloaded images stay reusable files, separate from the guest's LV.
		($cache) = grep { $_->{'type'} =~ /\A(?:dir|fs|netfs)\z/ } @{$options->{'pools'}};
		die "An active file storage pool is required to cache installation images\n" if (!$cache);
		}
	$r{'image_download'} = Cloudmin::Images::catalogue_request(
		{ %$image, id => $image->{'catalogue_id'} }, $cache);
	my ($ready) = grep { Cloudmin::Images::matches_download($_, $r{'image_download'}) }
		@{$options->{'images'}};
	$image = $ready if ($ready);
}
# Cloud disks require compatibility metadata or inspection. ISOs use any known
# catalogue constraints, without parsing their contents.
if ($installer) {
	# ISO contents are not inspected; the administrator selects native media.
	die "Select an installer ISO\n"
		if (($image->{'format'} || '') ne 'iso');
	# Enforce catalogue architecture when available, even without inspection.
	die "This ISO's CPU architecture does not match the host\n"
		if ($image->{'architecture'} && $image->{'architecture'} ne $caps->{'architecture'});
	}
else {
	# Cloud images need compatible metadata or a successful inspection.
	die "Select a cloud image, or choose the Installer ISO source\n"
		if (($image->{'format'} || '') eq 'iso');
	# Cloud-init dependencies are optional only for the installer path.
	die "$options->{cloud_init_error}\n" if ($options->{'cloud_init_error'});
	$self->check_image_compatibility($image, $caps->{'architecture'});
	}
# Save the selected volume's identity for the worker to recheck before use.
$r{'source_image'} = { map { $_ => $image->{$_} }
	qw(id name pool volume volume_key volume_path format virtual_size prepared_vm) };
# Captured Virtualmin installations need a qualified application hostname.
$r{'require_fqdn'} = 1 if ($image->{'prepared_vm'} && $image->{'virtualmin'});
$r{'image_name'} = $image->{'name'};
$r{'architecture'} = $caps->{'architecture'};
$r{'machine'} = $caps->{'machine'};
$r{'emulator'} = $caps->{'emulator'};
$r{'pool_name'} = $pool->{'name'};
# Enforce host capacity and the image's minimum size before allocating a disk.
my $cpus = $input->{'cpus'} || '';
die "Enter a whole CPU count from 1 to $caps->{cpus}\n"
	if ($cpus !~ /\A[1-9][0-9]{0,8}\z/);
$r{'cpus'} = int($cpus);
# Unit selectors override the API's default MiB and GiB input units.
$r{'memory_mib'} = size_bytes($input, 'memory_mib', 1024**2,
	'memory') / 1024**2;
# Domain memory and later job validation use whole MiB values.
die "Memory must be a whole number of MiB\n"
	if ($r{'memory_mib'} != int($r{'memory_mib'}));
my $disk_bytes = size_bytes($input, 'disk_gib', 1024**3, 'disk size');
# Thick LVM uses whole extents; thin and file disks use sectors. Save that size.
my $unit = $pool->{'allocation_unit'} || 512;
$r{'disk_gib'} = sprintf('%.17g', ceil($disk_bytes / $unit) * $unit / 1024**3);
# Limit this guest's CPU count to the host's logical CPU count.
die "Enter a whole CPU count from 1 to $caps->{cpus}\n"
	if ($r{'cpus'} > $caps->{'cpus'});
# Reserve CPU slots without assigning them to the guest at startup.
$r{'cpu_limit'} = $r{'cpus'} * 2 < $caps->{'cpus'}
	? $r{'cpus'} * 2 : $caps->{'cpus'};
# Every guest needs a usable minimum while leaving a basic host reserve.
die "Select at least 256 MiB and leave 256 MiB of host memory free\n"
	if ($r{'memory_mib'} < 256 ||
	$r{'memory_mib'} > $caps->{'memory_kib'}/1024 - 256);
# An empty installer disk needs at least 1 GiB, regardless of the ISO's size.
my $minimum = $installer ? 1024**3 : $image->{'virtual_size'} || 0;
# Apply any larger minimum required by the publisher to either disk type.
$minimum = $image->{'min_disk_bytes'}
	if (($image->{'min_disk_bytes'} || 0) > $minimum);
# Enforce the disk minimum; clones cannot shrink existing filesystems.
die "The disk must be at least ".int(($minimum + 1024**3 - 1)/1024**3)." GiB\n"
	if ($r{'disk_gib'} * 1024**3 < $minimum);
# Require full disk capacity on file and thick pools, including sparse files.
die "The storage pool needs enough free space for the disk plus 256 MiB\n"
	if ($r{'pool_type'} ne 'lvmthin' && $r{'disk_gib'} * 1024**3 > $pool->{'available'} - 256*1024**2);
# Thin capacity can exceed physical space, but data and metadata need headroom.
die "Extend the thin pool before creating another virtual machine\n"
	if ($r{'pool_type'} eq 'lvmthin' && ($pool->{'available'} < 256*1024**2 ||
		($pool->{'data_percent'} // 100) >= 95 || ($pool->{'metadata_percent'} // 100) >= 90));
if ($image->{'catalogue_id'}) {
	# A file destination also holds the download; LVM uses a separate file cache.
	my $download = $image->{'download_size_bytes'} || $image->{'min_disk_bytes'} || 0;
	die "The storage pool needs space for both the downloaded image and the virtual machine disk\n"
		if ($r{'pool_type'} !~ /\A(?:logical|lvmthin)\z/ &&
			$r{'disk_gib'} * 1024**3 + $download > $pool->{'available'} - 256*1024**2);
}
$r{'start'} = $input->{'start'} ? 1 : 0;
$r{'autostart'} = $input->{'autostart'} ? 1 : 0;
# Immediate startup also needs free memory now, not just installed
# capacity.
die "Not enough free host memory to start this virtual machine\n"
	if ($r{'start'} &&
	$r{'memory_mib'} * 1024**2 > $caps->{'free_memory'} - 256*1024**2);

# Resolve firmware from image constraints, with an explicit advanced override.
if (!$r{'firmware'} || $r{'firmware'} eq 'auto') {
	$r{'firmware'} = ($image->{'firmware'} || '') eq 'bios' ? 'bios'
		: $caps->{'efi'} ? 'efi' : 'bios';
	}
# Overrides still have to name firmware that this host can supply.
die "The selected firmware is unavailable on this host\n"
	if ($r{'firmware'} !~ /\A(?:efi|bios)\z/ || !$caps->{$r{'firmware'}});
# UEFI-only images cannot use a BIOS override.
die "This image requires UEFI firmware\n"
	if (($image->{'firmware'} || '') eq 'uefi' && $r{'firmware'} ne 'efi');
# BIOS-only images cannot use the host's preferred UEFI firmware.
die "This image requires BIOS firmware\n"
	if (($image->{'firmware'} || '') eq 'bios' && $r{'firmware'} ne 'bios');
my ($network) = grep { $_->{'key'} eq $r{'network'} } @{$options->{'networks'}};
# Form input selects existing attachments; it cannot invent a host
# device.
die "Select an active libvirt network or host bridge\n" if (!$network);
$r{'attachment'} = { map { $_ => $network->{$_} }
	qw(type source forward dhcp) };
# ISO installers set guest addresses; Cloudmin attaches the network interface.
$r{'address_mode'} = $installer ? 'manual' : $input->{'address_mode'} || 'dhcp';
# Cloud-init generation handles only DHCP or explicit static
# configuration.
die "Select automatic or static addressing\n"
	if (!$installer && $r{'address_mode'} !~ /\A(?:dhcp|static)\z/);
if ($r{'address_mode'} eq 'static') {
	# Canonical addresses make duplicate detection independent of IPv6
	# spelling.
	die "Enter a static IPv4 or IPv6 address with a prefix length\n"
		if (!$r{'ipv4'} && !$r{'ipv6'});
	# Either address family may be omitted when the other is
	# configured.
	$r{'ipv4'} = address($r{'ipv4'}, 4, 1) if ($r{'ipv4'});
	# Normalize IPv6 spelling before checking for duplicate
	# addresses.
	$r{'ipv6'} = address($r{'ipv6'}, 6, 1) if ($r{'ipv6'});
	foreach my $family (4, 6) {
		# A static guest can use a directly connected subnet
		# without a gateway.
		next if (!$r{'gateway'.$family});
		# An IPv4 gateway cannot provide a route for an
		# IPv6-only guest.
		die "A gateway needs a static address of the same family\n"
			if (!$r{'ipv'.$family});
		$r{'gateway'.$family} = address($r{'gateway'.$family}, $family,
			0);
		}
	my @dns = grep { length } split(/[\s,]+/, $r{'dns'});
	# Keep the seed's resolver configuration within the supported
	# form limit.
	die "Enter at most three DNS server addresses\n" if (@dns > 3);
	$r{'dns'} = join(' ',
		map { address($_, index($_, ':') >= 0 ? 6 : 4, 0) } @dns);
	}
else {
	# Hidden static fields must not affect DHCP or installer-managed addressing.
	$r{$_} = '' for qw(ipv4 ipv6 gateway4 gateway6 dns);
	# An installer can configure a static address on a network without DHCP.
	die "This libvirt network has no DHCP service; use static addressing\n"
		if (!$installer && $network->{'type'} eq 'network' && !$network->{'dhcp'});
	}
$r{'mac'} ||= '52:54:00:'.
	join(':', substr(Cloudmin::Images::generate_id(), 0, 6) =~ /../g);
$r{'mac'} = lc($r{'mac'});
# NIC identities must be valid unicast addresses, never all-zero
# placeholders.
die "Enter a unicast MAC address\n"
	if ($r{'mac'} !~ /\A(?:[a-f0-9]{2}:){5}[a-f0-9]{2}\z/ ||
	(hex(substr($r{'mac'}, 0, 2)) & 1) || $r{'mac'} eq '00:00:00:00:00:00');
foreach my $domain (@{$options->{'domains'}}) {
	# MACs are host-wide; recorded static IP conflicts matter per
	# attachment.
	die "This MAC address is already used by a virtual machine\n"
		if (grep { lc($_) eq $r{'mac'} } @{$domain->{'macs'}});
	my $metadata = $domain->{'cloudmin'} || {};
	# The same static address may be valid on a different network
	# attachment.
	next if (($metadata->{'network'} || '') ne $r{'network'});
	foreach my $field (qw(ipv4 ipv6)) {
		# Compare host addresses without their prefixes inside
		# one attachment.
		die "This static address is already assigned to a Cloudmin virtual machine\n"
			if ($r{$field} &&
			(split('/',
			$metadata->{$field} || ''))[0] eq (split('/',
			$r{$field}))[0]);
		}
	}

if ($installer) {
	# The installer configures accounts and networking. Discard hidden cloud
	# fields so they cannot become credentials or guest metadata.
	$r{$_} = '' for qw(username ssh_keys hostname auth_type);
	}
else {
	# Cloud-init needs a valid account; root is allowed and other users get sudo.
	die "Enter a Linux username of up to 32 lowercase letters, digits, dashes or underscores\n"
		if ($r{'username'} !~ /\A[a-z_][a-z0-9_-]{0,31}\z/ ||
			$r{'username'} =~ /\A(?:daemon|bin|sys|nobody|sshd)\z/);
	$r{'auth_type'} = $input->{'auth_type'} || 'keys';
	# Unknown authentication choices must not enable password login by
	# accident.
	die "Select an authentication method\n" if (ref($r{'auth_type'}) ||
		$r{'auth_type'} !~ /\A(?:keys|password|both)\z/);
	$r{'ssh_keys'} = $r{'auth_type'}
		eq 'password' ? '' : join("\n", public_keys($r{'ssh_keys'}));
	if ($r{'auth_type'} ne 'keys') {
		# Cloud-init receives the controller's validated password hash.
		die "Enter an initial password\n"
			if (!$password_hash || ref($password_hash) ||
			$password_hash !~ /\A\$6\$rounds=500000\$[a-f0-9]{16}\$[.\/A-Za-z0-9]{86}\z/);
		$r{'password_hash'} = $password_hash;
		}
	if (!length($r{'hostname'})) {
		# Derive the guest hostname from the display name, which may contain
		# separators that are not valid at the edges of hostname labels.
		my $hostname = lc($r{'name'});
		$hostname =~ s/[ _]+/-/g;
		$r{'hostname'} = join('.', grep { length }
			map { s/\A-+|-+\z//gr } split(/\.+/, $hostname));
		}
	# VM display names allow spaces and underscores; guest hostnames do not.
	$r{'hostname'} =~ s/[ _]+/-/g;
	die "Enter a valid guest hostname\n"
		if (!length($r{'hostname'}) || length($r{'hostname'}) > 253 ||
		grep { length($_) > 63 ||
		$_ !~ /\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/ }
		split(/\./, $r{'hostname'}, -1));
	}
# Limit the description stored in job records and domain XML.
die "Description is too long\n" if (length($r{'description'}) > 2000);
# Validate guest setup and snapshot selected scripts before allocating resources.
Cloudmin::Software::prepare($input, \%r);
if (Cloudmin::Software::enabled(\%r)) {
	# Refuse missing host tools before downloading an image or creating disks.
	my $error = Cloudmin::Libvirt::setup_agent_error();
	die "$error\n" if ($error);
	# An active libvirt network can have lost its rules after a firewall restart.
	Cloudmin::NetworkPreflight::check($network)
		if ($r{'address_mode'} eq 'dhcp' || $r{'ipv4'});
}
return \%r;
}

# check_image_compatibility(self, image, host_architecture)
# Validates recorded metadata or inspects missing metadata under the image lock.
sub check_image_compatibility
{
my ($self, $image, $host_architecture) = @_;
my %metadata = %$image;
# Explicit incompatibility is decisive and does not warrant disk
# inspection.
die "This image does not support cloud-init\n"
	if (defined($metadata{'cloud_init'}) && !$metadata{'cloud_init'});
# The local KVM creation path does not emulate another CPU architecture.
die "This image's CPU architecture does not match the host\n"
	if ($metadata{'architecture'} && $metadata{'architecture'}
	ne $host_architecture);
if (!$metadata{'architecture'} || !defined($metadata{'cloud_init'})) {
	# Inspect only the selected custom image; ordinary form views do no disk
	# scanning.
	my $detected = $self->inspect_custom_image($image);
	%metadata = (%metadata, %$detected);
	}
# A successful inspection still needs a usable architecture result.
die "Cannot determine this image's CPU architecture\n"
	if (!$metadata{'architecture'});
# Validate newly discovered architecture just as strictly as saved
# metadata.
die "This image's CPU architecture does not match the host\n"
	if ($metadata{'architecture'} ne $host_architecture);
# Provisioning relies on the guest consuming the NoCloud seed at first
# boot.
die "This image does not support cloud-init\n" if (!$metadata{'cloud_init'});
return 1;
}

# inspect_custom_image(self, image)
# Prevents deletion while an isolated helper reads the selected imported volume.
sub inspect_custom_image
{
my ($self, $image) = @_;
my $store = $self->{'images'};
return $store->with_lock($store->path($image->{'id'}, 'json'), 0, sub {
	my $current = $store->get($image->{'id'});
	# Recheck ownership and readiness after waiting for the image
	# lock.
	die "Source image is no longer ready\n"
	if (!$current || $current->{'state'} ne 'ready' ||
		$current->{'volume_key'} ne $image->{'volume_key'});
	# The parser and appliance inspect a copy in an unprivileged sandbox.
	my $worker = Cloudmin::Worker->new();
	# Clear an orphan from an earlier inspection before starting
	# another one.
	$worker->cleanup($current->{'worker'}) if ($current->{'worker'});
	my $result = $worker->run('inspect',
	{ format => $image->{'format'}, guest => 1 },
		files => { image => $image->{'volume_path'} },
		started => sub { $current->{'worker'} = $_[0];
		$store->save($image->{'id'}, $current); });
	delete($current->{'worker'});
	# Malformed helper output cannot become cached compatibility
	# metadata.
	die "Cannot determine image compatibility\n"
	if (ref($result) ne 'HASH');
	# Keep the detected metadata with the image so later forms and worker
	# preflights do not copy and inspect the same volume again.
	@{$current}{qw(architecture cloud_init)} =
		@{$result}{qw(architecture cloud_init)}
		if ($result->{'architecture'});
	$store->save($image->{'id'}, $current);
	return $result;
	});
}

# size_bytes(input, field, default_units, label)
# Validates ui_bytesbox values while retaining the fixed-unit API defaults.
sub size_bytes
{
my ($input, $field, $default, $label) = @_;
my $value = $input->{$field};
my $units = exists($input->{$field.'_units'}) ? $input->{$field.'_units'}
	: $default;
# Accept positive decimal input without exponent syntax or structured
# values.
die "Enter a positive number for $label\n"
	if (!defined($value) || ref($value) ||
	length($value) > 32 || $value !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ ||
	$value <= 0);
# Units are one of the binary multipliers offered by ui_bytesbox.
die "Select valid units for $label\n" if (!defined($units) || ref($units) ||
	!grep { $units eq int(1024**$_) } 0..5);
my $bytes = $value * $units;
# Keep values exact when the browser and JSON exchange them as numbers.
die "The $label is too large\n" if ($bytes > 2**53);
return $bytes;
}

# address(value, family, cidr)
# Canonicalizes an IPv4 or IPv6 literal. cidr requires a prefix when true and
# forbids one when false; family is 4 or 6.
sub address
{
my ($value, $family, $cidr) = @_;
my ($address, $prefix, @extra) = split('/', $value, -1);
my $valid = $family == 4 ? check_ipaddress($address)
	: check_ip6address($address);
die "Invalid IPv$family address: $value\n" if (!$valid || @extra ||
	($cidr ? !defined($prefix) || $prefix !~ /\A\d+\z/ ||
	$prefix > ($family == 4 ? 32 : 128)
		: defined($prefix)));
my $af = $family == 4 ? AF_INET : AF_INET6;
my $packed = inet_pton($af, $address) || die "Invalid IP address\n";
return inet_ntop($af, $packed).($cidr ? '/'.int($prefix) : '');
}

# public_keys(text)
# Accepts plain OpenSSH public keys, without authorized_keys options or private
# keys.
sub public_keys
{
my ($text) = @_;
my @keys = grep { /\S/ } split(/\r?\n/, $text);
# Bound both the number of installed keys and the validation workload.
die "Enter one to five SSH public keys\n" if (!@keys || @keys > 5);
foreach my $key (@keys) {
	# Check both the displayed key type and the type inside the decoded
	# blob.
	my ($type,
		$data) = $key =~ /\A(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519\@openssh\.com|sk-ecdsa-sha2-nistp256\@openssh\.com) ([A-Za-z0-9+\/=]+)(?: [^\r\n]*)?\z/;
	die "Enter an OpenSSH public key, such as ssh-ed25519; private keys and key options are not accepted\n"
		if (!$type || length($key) > 8192);
	my $bytes = decode_base64($data);
	my $length = length($bytes) >= 4 ? unpack('N', substr($bytes, 0, 4))
		: 0;
	# Reject truncated blobs and headers whose embedded type
	# contradicts them.
	die "Invalid SSH public key\n" if (!$length || $length > 64 ||
		substr($bytes, 4, $length) ne $type ||
		length($bytes) < $length + 36);
	}
return @keys;
}

# seed_data(request, uuid)
# Generates NoCloud data as JSON (valid YAML), including /32 on-link gateways.
sub seed_data
{
my ($r, $uuid) = @_;
my $password = ($r->{'auth_type'} || 'keys') ne 'keys';
my $root = $r->{'username'} eq 'root';
# References to 1 and 0 encode as JSON booleans with either Webmin JSON backend.
my $user = { name => $r->{'username'}, shell => '/bin/sh',
	lock_passwd => $password ? \0 : \1 };
# Ordinary guest administrators need sudo; root already has those
# privileges.
$user->{'sudo'} = [ 'ALL=(ALL) NOPASSWD:ALL' ] if (!$root);
# Include user-supplied keys only when key authentication was selected.
$user->{'ssh_authorized_keys'} = [ public_keys($r->{'ssh_keys'}) ]
	if ($r->{'ssh_keys'});
# Host access is additional to the user's selected password or SSH keys.
push(@{$user->{'ssh_authorized_keys'}}, public_keys($r->{'host_public_key'}))
	if ($r->{'host_public_key'});
# Only password-enabled accounts receive the controller's retained hash.
$user->{'hashed_passwd'} = $r->{'password_hash'} if ($password);
# Apply the requested identity and expand the image's root filesystem at boot.
my $data = { users => [ $user ],
	disable_root => $root ? \0 : \1,
	ssh_pwauth => $password ? \1 : \0,
	chpasswd => { expire => \0 },
	preserve_hostname => \0,
	hostname => $r->{'hostname'}, manage_etc_hosts => \1,
	growpart => { mode => 'auto', devices => ['/'],
	ignore_growroot_disabled => \0 },
	resize_rootfs => \1 };
if ($root && $password) {
	# Vendor images usually prohibit root passwords independently of
	# ssh_pwauth.
	$data->{'write_files'} = [ { path =>
		'/etc/ssh/sshd_config.d/00-cloudmin.conf',
		owner => 'root:root', permissions => '0600',
		content => "PermitRootLogin yes\n" } ];
	# Refresh a running daemon; socket-activated SSH will load this on
	# startup.
	$data->{'runcmd'} = [ [ 'sh', '-c',
		'systemctl try-reload-or-restart ssh.service 2>/dev/null || systemctl try-reload-or-restart sshd.service' ] ];
	}
# Add guest setup files only when software installation is requested.
Cloudmin::Software::seed($data, $r, $uuid);
# Match the NIC by MAC without renaming a device the image may already use.
my $nic = { match => { macaddress => $r->{'mac'} },
	dhcp4 => $r->{'address_mode'}
	eq 'dhcp' ? \1 : \0,
	dhcp6 => \0 };
if ($r->{'address_mode'} eq 'static') {
	# Explicit addresses disable router advertisements.
	$nic->{'accept-ra'} = \0;
	$nic->{'addresses'} = [ grep { length } @{$r}{qw(ipv4 ipv6)} ];
	my @routes;
	foreach my $family (4, 6) {
		# Reach the gateway directly even with /32 or /128 addresses. The
		# Netplan-only on-link flag is rejected by other cloud-init renderers.
		my $gateway = $r->{'gateway'.$family} || next;
		push(@routes, { to => $gateway.($family == 4 ? '/32' : '/128') },
			{ to => $family == 4 ? '0.0.0.0/0' : '::/0', via => $gateway });
		}
	# A directly connected guest needs no empty default-route
	# section.
	$nic->{'routes'} = \@routes if (@routes);
	# Leave resolver selection to the image when no static servers
	# were given.
	$nic->{'nameservers'} = { addresses => [ split(' ', $r->{'dns'}) ] }
		if ($r->{'dns'});
	}
return {
	'user-data' => "#cloud-config\n".convert_to_json($data, 0, 1),
	'meta-data' => convert_to_json({ 'instance-id' => $uuid,
	'local-hostname' => $r->{'hostname'} }, 0, 1),
	'network-config' => convert_to_json({ version => 2,
	ethernets => { eth0 => $nic } }, 0, 1),
};
}

# domain_xml(request, uuid, job_id, disk, seed, console_password)
# Builds native KVM hardware with a private console. disk and seed are volume
# paths; pass undef in the seed position for an ISO install. request supplies
# the installer volume path, when needed, and job_id marks guest ownership.
sub domain_xml
{
my ($r, $uuid, $id, $disk, $seed, $password) = @_;
my $installer = ($r->{'install_source'} || '') eq 'iso';
my $x = \&Cloudmin::Libvirt::xml_escape;
# Let libvirt choose a GIC version supported by this host.
my $features = $r->{'architecture'}
	eq 'aarch64' ? '<acpi/><gic/>' : '<acpi/><apic/>';
# The virt board has no built-in keyboard or mouse, so the VNC console needs
# USB input devices. PC machine types get PS/2 devices from libvirt.
my $inputs = $r->{'architecture'} eq 'aarch64'
	? "<controller type='usb' model='qemu-xhci' ports='8'/>".
	  "<input type='keyboard' bus='usb'/><input type='tablet' bus='usb'/>"
	: '';
# Keep UEFI variables across boots and exclude stateless SEV/TDX firmware.
# Libvirt still selects the firmware and its variable-store template.
my $firmware = $r->{'firmware'} eq 'efi'
	? "<firmware><feature enabled='no' name='secure-boot'/><feature enabled='no' name='enrolled-keys'/></firmware>".
	  "<loader stateless='no'/>" : '';
my $source = $r->{'attachment'}->{'type'} eq 'network' ? 'network' : 'bridge';
my $os_firmware = $r->{'firmware'} eq 'efi' ? " firmware='efi'" : '';
my $metadata = join('',
	map { '<cloudmin:'.$_.'>'.$x->($r->{$_} || '').'</cloudmin:'.$_.'>' }
	qw(image network ipv4 ipv6 username template));
# Persist ownership with the guest so recovery can distinguish a replacement VM.
my $xml = "<domain type='kvm'><name>".$x->($r->{'name'}).
	"</name><uuid>$uuid</uuid>".
	'<description>'.$x->($r->{'description'}).'</description>'.
	"<metadata><cloudmin:vm xmlns:cloudmin='urn:cloudmin:vm:1'><cloudmin:job>$id</cloudmin:job>$metadata</cloudmin:vm></metadata>".
	"<memory unit='MiB'>$r->{memory_mib}</memory><vcpu>$r->{cpus}</vcpu>".
	"<os$os_firmware><type arch='$r->{architecture}' machine='".
	$x->($r->{'machine'})."'>hvm</type>".
	# Installer media boots first; an ejected drive falls back to the system disk.
	$firmware.($installer ? "<boot dev='cdrom'/>" : '').
	"<boot dev='hd'/></os><features>$features</features><cpu mode='host-passthrough'/>".
	"<clock offset='utc'/><on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>destroy</on_crash>".
	# Every guest has a writable system disk; only cloud images get a seed disk.
	'<devices><emulator>'.$x->($r->{'emulator'}).'</emulator>'.
	"<disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='".$x->($disk)."'/>".
	"<target dev='vda' bus='virtio'/></disk>".
	($installer ? '' :
	"<disk type='file' device='disk'><driver name='qemu' type='raw'/><source file='".$x->($seed)."'/>".
	"<target dev='vdb' bus='virtio'/><readonly/></disk>").
	"<interface type='$source'><mac address='$r->{mac}'/><source $source='".
	$x->($r->{'attachment'}->{'source'})."'/>".
	"<model type='virtio'/></interface>".
	# Expose guest-agent transport and a password-protected local-only
	# console.
	"<channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>".
	"<serial type='pty'/><console type='pty'/>".
	"<graphics type='vnc' autoport='yes' websocket='-1' listen='127.0.0.1' passwd='".$x->($password)."'>".
	"<listen type='address' address='127.0.0.1'/></graphics><video><model type='virtio'/></video>$inputs".
	"<rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>".
	"<memballoon model='virtio'><stats period='10'/></memballoon></devices></domain>";
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
# LVM destinations expose raw block devices, including the read-only seed.
if (($r->{'pool_type'} || '') =~ /\A(?:logical|lvmthin)\z/) {
	foreach my $node ($doc->findnodes('/domain/devices/disk[@device="disk"]')) {
		$node->setAttribute('type', 'block');
		my ($source) = $node->findnodes('source');
		$source->setAttribute('dev', $source->getAttribute('file'));
		$source->removeAttribute('file');
		my ($driver) = $node->findnodes('driver');
		$driver->setAttribute('type', 'raw');
		$driver->setAttribute('cache', 'none');
		}
	}
# Reserve future device capacity after building the guest's initial hardware.
add_hardware_headroom($doc, $r->{'cpu_limit'} || $r->{'cpus'});
if ($installer) {
	# Reuse the standard removable drive; the imported ISO stays read-only.
	my ($cdrom) = $doc->findnodes('/domain/devices/disk[@device="cdrom"]');
	$cdrom->addNewChild(undef, 'source')->setAttribute('file',
		$r->{'source_image'}->{'volume_path'});
	}
return $doc->toString();
}

# add_hardware_headroom(doc, cpu_limit)
# Adds CPU slots, spare PCIe ports and a read-only rescue-media drive offline.
sub add_hardware_headroom
{
my ($doc, $limit) = @_;
my ($vcpu) = $doc->findnodes('/domain/vcpu');
my $current = $vcpu->getAttribute('current') || $vcpu->textContent();
# Expansion never lowers the existing maximum or enables additional CPUs.
$limit = $vcpu->textContent() if ($limit < $vcpu->textContent());
$vcpu->removeChildNodes();
$vcpu->appendText($limit);
$vcpu->setAttribute('current', $current);
my ($devices) = $doc->findnodes('/domain/devices');
my $machine = $doc->findvalue('/domain/os/type/@machine');
if ($machine =~ /q35|^virt(?:-|$)/) {
	# Ports must exist at boot; initial virtio devices consume some of them.
	my @pci = $devices->findnodes('controller[@type="pci"]');
	my %indexes = map { $_->getAttribute('index') => 1 } @pci;
	if (!@pci) {
		# Explicit ports need a root controller when
		# libvirt has not added one yet.
		my $root = $devices->addNewChild(undef, 'controller');
		$root->setAttribute($_, { type => 'pci', index => 0,
			model => 'pcie-root' }->{$_}) foreach qw(type index model);
		$indexes{0} = 1;
		}
	my @ports = $devices->findnodes('controller[@model="pcie-root-port"]');
	my $ports = scalar(@ports);
	# Reuse existing ports and choose unused
	# controller indexes for new ones.
	for (my $index = 1; $ports < 16; $index++) {
		next if ($indexes{$index});
		my $port = $devices->addNewChild(undef, 'controller');
		$port->setAttribute($_, { type => 'pci', index => $index,
			model => 'pcie-root-port' }->{$_}) foreach qw(type index model);
		$ports++;
		}
	}
if (!$devices->findnodes('disk[@device="cdrom"]')) {
	# A SCSI drive works on both native x86-64 and ARM64 guests.
	my %controllers = map { $_->getAttribute('index') => 1 }
		$devices->findnodes('controller[@type="scsi"]');
	my $index = 0;
	$index++ while ($controllers{$index});
	my $controller = $devices->addNewChild(undef, 'controller');
	$controller->setAttribute($_, { type => 'scsi', index => $index,
		model => 'virtio-scsi' }->{$_}) foreach qw(type index model);
	my %targets = map { $_->getValue() => 1 }
		$devices->findnodes('disk/target/@dev');
	# Keep existing disk targets intact when
	# adding the empty removable drive.
	my ($target) = grep { !$targets{$_} } map { 'sd'.$_ } 'a'..'z';
	die "No free CD drive target\n" if (!$target);
	my $disk = $devices->addNewChild(undef, 'disk');
	$disk->setAttribute('type', 'file');
	$disk->setAttribute('device', 'cdrom');
	my $driver = $disk->addNewChild(undef, 'driver');
	$driver->setAttribute('name', 'qemu');
	$driver->setAttribute('type', 'raw');
	my $node = $disk->addNewChild(undef, 'target');
	$node->setAttribute('dev', $target);
	$node->setAttribute('bus', 'scsi');
	$disk->addNewChild(undef, 'readonly');
	# Bind the drive to the new SCSI controller instead
	# of relying on auto-placement.
	my $address = $disk->addNewChild(undef, 'address');
	$address->setAttribute($_, { type => 'drive', controller => $index,
		bus => 0, target => 0, unit => 0 }->{$_})
		foreach qw(type controller bus target unit);
	}
}

# step(self, id, name, callback)
# Publishes a progress event, runs callback(), and marks that event complete.
# The enclosing run() supplies the creation timeout.
sub step
{
my ($self, $id, $name, $callback) = @_;
$self->checkpoint($id);
$self->{'jobs'}->update($id, sub {
	my ($job) = @_;
	$job->{'phase'} = $name;
	push(@{$job->{'events'}}, { step => $name, state => 'running' });
	});
my $result = $callback->();
$self->{'jobs'}->update($id,
	sub { $_[0]->{'events'}->[-1]->{'state'} = 'done'; });
return $result;
}

# checkpoint(self, id)
# Observes cancellation between libvirt calls, when rollback can run safely.
sub checkpoint
{
my ($self, $id) = @_;
die "Virtual machine creation cancelled\n"
	if ($self->{'jobs'}->get($id)->{'cancel'});
}

# ensure_image(self, id) reuses or downloads a catalogue image before disk work.
# Cancelling a creation leaves the shared import available to other requests.
sub ensure_image
{
my ($self, $id) = @_;
my $jobs = $self->{'jobs'};
my $job = $jobs->get($id);
my $request = $job->{'request'}->{'image_download'};
# Imported images and creations already past preparation need no download.
return if (!$request || $job->{'state'} ne 'queued');
$self->checkpoint($id);
my $images = $self->{'images'};
# One short reservation lets concurrent creations share an import in this pool.
my $key = sha256_hex(convert_to_json($request, 0, 1, 1));
my $image = $jobs->lock('image-'.$key, sub {
	# Completed sources can be cloned across pools; active imports stay
	# pool-bound.
	my ($ready) = grep { Cloudmin::Images::matches_download($_, $request) }
		@{$self->options()->{'images'}};
	return $ready if ($ready);
	my ($active) = grep { $_->{'pool'} eq $request->{'pool'} &&
		Cloudmin::Images::matches_download($_, $request) }
		@{$images->list(undef, 1)};
	return $active if ($active);
	return $images->create($job->{'owner'}, $images->form_token($job->{'owner'}), $request);
});
$jobs->update($id, sub {
	my ($record) = @_;
	$record->{'image_job'} = $image->{'id'};
	$record->{'phase'} = 'image';
	# Reattaching a queued creation retains its existing progress event.
	push(@{$record->{'events'}}, {step => 'image', state => 'running'})
		if (!@{$record->{'events'}} || $record->{'events'}->[-1]->{'step'} ne 'image');
});
# Joining an active import must not start another transfer.
$images->start($image->{'id'}) if ($image->{'state'} eq 'queued');
# Publish shared transfer progress while observing this creation's cancellation.
my $cached = $image->{'state'} eq 'ready' ? 1 : 0;
my $deadline = time()+3700;
while (1) {
	$self->checkpoint($id);
	$image = $images->get($image->{'id'});
	$jobs->update($id, sub { $_[0]->{'image_progress'} = { cached => $cached,
		map { $_ => $image->{$_} } qw(name state bytes total) }; });
	last if ($image->{'state'} eq 'ready');
	die "Image download failed: ".($image->{'error'} || $image->{'state'})."\n"
		if ($image->{'state'} =~ /\A(?:failed|cancelled|deleted)\z/);
	die "Timed out waiting for the image download\n" if (time() >= $deadline);
	# An interrupted import cannot complete by itself. Keep its error visible.
	if ($image->{'state'} ne 'queued' && !$images->{'test_lock'}->($images->path($image->{'id'}, 'json'))) {
		my $latest = $images->get($image->{'id'});
		die "Image download was interrupted; retry creation\n"
			if ($latest->{'state'} eq $image->{'state'});
	}
	sleep(1);
}
# Re-read libvirt inventory rather than trusting a stale ready marker.
my ($ready) = grep { $_->{'id'} eq $image->{'id'} &&
	Cloudmin::Images::matches_download($_, $request) } @{$self->options()->{'images'}};
die "Downloaded image is no longer available\n" if (!$ready);
$jobs->update($id, sub {
	$_[0]->{'request'}->{'source_image'} = { map { $_ => $ready->{$_} }
		qw(id name pool volume volume_key volume_path format virtual_size) };
	$_[0]->{'events'}->[-1]->{'state'} = 'done';
});
}

# finish(self, id, adapter)
# Handles cancellation arriving between the last libvirt call and the final
# commit.
sub finish
{
my ($self, $id, $adapter) = @_;
my $job;
my $ok = eval { $job = $self->complete($id); 1 };
# Cancellation before commit still rolls back the newly allocated guest.
return $self->fail($id, $adapter, "$@") if (!$ok);
# Creation is successful even when optional software setup later fails.
# Once committed, an audit failure must not destroy the completed VM.
my $logged = eval { $self->{'jobs'}->audit('complete', {%$job, state => 'complete'}); 1 };
if (!$logged) {
	# Show an audit warning while preserving a successfully created guest.
	my $warning = 'Could not write the completion audit log: '.
		Cloudmin::Libvirt::error_message($@);
	$self->{'jobs'}->update($id,
		sub { $_[0]->{'audit_warning'} = $warning; });
	}
return 1;
}

# complete(self, id)
# Commits the final result and removes temporary provisioning inputs.
sub complete
{
my ($self, $id) = @_;
my $clean = eval { $self->cleanup_work($id); 1 };
my $warning = $clean ? '' : Cloudmin::Libvirt::error_message($@);
my $job = $self->{'jobs'}->update($id, sub {
	# Completion and cancellation share this final atomic store
	# update.
	die "Virtual machine creation cancelled\n" if ($_[0]->{'cancel'});
	$_[0]->{'cleanup_warning'} = $warning;
	$_[0]->{'cleanup_pending'} = 0;
	$_[0]->{'state'} = 'complete';
	delete($_[0]->{'request'}->{'password_hash'});
	$_[0]->{'events'}->[-1]->{'state'} = 'done';
	if (Cloudmin::Software::enabled($_[0]->{'request'})) {
		# Commit the VM before provisioning; later failures must preserve it.
		$_[0]->{'state'} = 'running';
		$_[0]->{'resource'} = 'software:'.$id;
		$_[0]->{'resources'}->{'software'} = 1;
		$_[0]->{'resources'}->{'software_deadline'} = time() + 8100;
		$_[0]->{'phase'} = 'software_boot';
		push(@{$_[0]->{'events'}}, {step => 'software_boot', state => 'running'});
		}
	});
return $job;
}

# fail(self, id, adapter, error)
# Rolls back only journalled resources; retained resources are reported
# explicitly.
sub fail
{
my ($self, $id, $adapter, $error) = @_;
my $job = $self->{'jobs'}->get($id);
my $r = $job->{'request'};
# Attempt both kinds of cleanup even when one subsystem is unavailable.
my $work_clean = eval { $self->cleanup_work($id); 1 };
my $work_error = $@;
my $cleanup = eval {
	# Disks must stay intact if removing the job-owned guest fails.
	$adapter->remove_created_guest($r->{'uuid'}, $id)
		if ($job->{'resources'}->{'domain'});
	# A failed VM may have a key even if it never reached domain definition.
	$self->{'ssh_keys'}->remove($r->{'uuid'}, $id)
		if ($job->{'resources'}->{'ssh_key'});
	foreach my $kind (qw(seed disk)) {
		my $volume = $job->{'resources'}->{$kind} || next;
		$adapter->remove_created_volume($r->{'pool'}, $volume->{'name'},
			$volume->{'key'});
		}
	1;
	};
# Preserve unfinished cleanup for recovery and redact provisioning secrets.
$error .= "; cleanup needs attention: $work_error$@"
	if (!$cleanup || !$work_clean);
$cleanup = $cleanup && $work_clean;
# Libvirt errors can echo domain XML containing the console credential.
$error =~ s/\Q$r->{console_password}\E/[redacted]/g
	if ($r->{'console_password'});
# Provisioning failures must not expose the password hash in history or
# logs.
$error =~ s/\Q$r->{password_hash}\E/[redacted]/g if ($r->{'password_hash'});
$error = Cloudmin::Libvirt::error_message($error);
# Persist the terminal error before writing the failure audit entry.
$job = $self->{'jobs'}->update($id, sub {
	my ($record) = @_;
	$record->{'state'} = $record->{'cancel'} &&
	$cleanup ? 'cancelled' : 'failed';
	$record->{'error'} = substr($error, 0, 4000);
	$record->{'cleanup_pending'} = $cleanup ? 0 : 1;
	# Explicit cleanup no longer exposes a link to the deleted committed guest.
	$record->{'resources'}->{'domain'} = 0 if ($cleanup && $record->{'cleanup_created'});
	# Keep recovery state, but discard password and license credentials.
	delete(@{$record->{'request'}}{qw(password_hash webmin_password virtualmin_serial virtualmin_key)});
	# Early failures may occur before the first progress event was
	# recorded.
	$record->{'events'}->[-1]->{'state'} = 'failed'
	if (@{$record->{'events'}});
	});
# Audit the outcome that was recorded, which may be a clean cancellation.
$self->{'jobs'}->audit($job->{'state'} eq 'cancelled' ? 'cancelled' : 'failed',
	$job);
return 0;
}

# cleanup_creation(self, id)
# Removes a committed creation only after explicit cancellation. The caller
# holds the worker lock; shared storage or later history prevents deletion.
sub cleanup_creation
{
my ($self, $id) = @_;
my $jobs = $self->{'jobs'};
# Serialize disk cleanup and prevent new host operations from taking the guest.
return $jobs->lock('vm-work', sub {
	return $jobs->lock('create-host', sub {
		my $job = $jobs->get($id);
		# A setup failure alone must never delete an already committed
		# guest.
		die "Creation cleanup was not requested\n" if (!$job->{'cleanup_created'} ||
			!$job->{'cancel'} || $job->{'request'}->{'operation'});
		my $adapter;
		my $ok = eval {
			$adapter = $self->{'adapter'}->();
			# Stop the owned sandbox before inspecting or deleting its inputs.
			($self->{'worker'} || Cloudmin::Worker->new())->cleanup($job->{'worker'})
				if ($job->{'worker'});
			$adapter->check_creation_cleanup($job);
			1;
		};
		if (!$ok) {
			# Keep the reservation and journal when ownership cannot be proven.
			my $error = Cloudmin::Libvirt::error_message($@);
			$jobs->update($id, sub {
				$_[0]->{'state'} = 'failed'; $_[0]->{'cleanup_pending'} = 1;
				$_[0]->{'error'} = $error;
				# Discard credentials even if cancellation fails.
				delete(@{$_[0]->{'request'}}{qw(password_hash webmin_password virtualmin_serial virtualmin_key)});
			});
			return 0;
		}
		# Existing rollback rechecks guest ownership and every volume reference.
		$self->fail($id, $adapter, 'Virtual machine creation cancelled');
		return !$jobs->get($id)->{'cleanup_pending'};
	});
});
}

# cleanup_work(self, id)
# Removes only this job's fixed temporary filenames, retaining successful VM
# volumes.
sub cleanup_work
{
my ($self, $id) = @_;
my $job = $self->{'jobs'}->get($id);
# Stop a surviving task before deleting any provisioning data it may
# use.
Cloudmin::Worker->new()->cleanup($job->{'worker'}) if ($job->{'worker'});
my $work = "$self->{jobs}->{directory}/$id";
foreach my $name (qw(keys user-data meta-data network-config seed.iso disk0)) {
	# Repeated cleanup also handles steps that failed before
	# producing a file.
	unlink("$work/$name") ||
		die "Cannot clean virtual machine work file: $!\n"
		if (-e "$work/$name");
	}
# Remove only an empty job directory; unexpected files remain visible as
# errors.
rmdir($work) || die "Cannot clean virtual machine work directory: $!\n"
	if (-d $work);
}

# worker_task(self, id, task, request, [options])
# Records the sandbox for crash recovery and forwards cancellation while it
# runs. options are named Cloudmin::Worker::run options, such as output => path.
sub worker_task
{
my ($self, $id, $task, $request, %opts) = @_;
my $worker = $self->{'worker'} || Cloudmin::Worker->new();
my $result = $worker->run($task, $request, %opts,
	started => sub { my $unit = $_[0];
	$self->{'jobs'}->update($id, sub { $_[0]->{'worker'} = $unit; }); },
	progress => sub { $self->checkpoint($id); });
$self->{'jobs'}->update($id, sub { delete($_[0]->{'worker'}); });
return $result;
}

1;
