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

1;
