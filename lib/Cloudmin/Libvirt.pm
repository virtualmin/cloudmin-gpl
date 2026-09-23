package Cloudmin::Libvirt;

# Cloudmin's adapter for the system-provided Sys::Virt module. It reads host,
# guest, storage and network inventory and applies VM changes through libvirt.
# Libvirt owns the domain definitions.
use strict;
use warnings;
use Time::HiRes ();
use MIME::Base64 qw(decode_base64);
use File::Basename qw(dirname);
use Cwd ();
use WebminCore qw(html_escape read_file_contents get_system_hostname
	additional_log convert_to_json convert_from_json execute_command quote_path);
require(dirname(__FILE__).'/LVM.pm');

# Keep libvirt's numeric domain states out of callers and page builders.
my %DOMAIN_STATES = (
	0 => 'nostate',
	1 => 'running',
	2 => 'blocked',
	3 => 'paused',
	4 => 'shutdown',
	5 => 'shutoff',
	6 => 'crashed',
	7 => 'pmsuspended',
);

# Keep storage-pool state values out of callers and page builders.
my %POOL_STATES = (
	0 => 'inactive',
	1 => 'building',
	2 => 'running',
	3 => 'degraded',
	4 => 'inaccessible',
);

# Pool backends do not all support the same provisioning operations.
my %EXTERNAL_STORAGE = map { $_ => 1 } qw(iscsi iscsi-direct scsi mpath);
my %MANAGED_STORAGE = map { $_ => 1 }
	qw(dir fs netfs disk logical lvmthin rbd gluster zfs vstorage);

# Libvirt flag values used with fake connections in tests, so the constants
# are spelled out here instead of being read from Sys::Virt at run time.
our $XML_INACTIVE = 2;
our $UNDEFINE_FLAGS = 1 | 2 | 4 | 16;	# managed save, snapshots, NVRAM,
					# checkpoints metadata
our $ADDRESSES_LEASE = 0;
our $ADDRESSES_AGENT = 1;
our $ADDRESSES_ARP = 2;

# new(class, [uri => value], [readonly => bool], [connection_factory => code],
#     [sys_net => directory], [on_remove => callback], [startup => tracker],
#     [serial_log => log_manager], [lvm => driver])
# Creates an adapter, defaulting to qemu:///system and read-only access.
# An optional factory receives (uri, readonly) and returns a connection object.
# sys_net defaults to /sys/class/net and can point to a bridge fixture in tests.
# on_remove(uuid, job_id) cleans controller state after local guest removal.
# serial_log optionally configures, reads and removes managed local console
# logs.
# startup tracks balloon targets across requests on the local host.
# lvm optionally supplies a driver; local LVM inventory creates one otherwise.
sub new
{
my ($class, %opts) = @_;
return bless({
	'uri' => $opts{'uri'} || 'qemu:///system',
	'readonly' => exists($opts{'readonly'}) ? $opts{'readonly'} : 1,
	'connection_factory' => $opts{'connection_factory'},
	'sys_net' => $opts{'sys_net'} || '/sys/class/net',
	'on_remove' => $opts{'on_remove'},
	'startup' => $opts{'startup'},
	'serial_log' => $opts{'serial_log'},
	'lvm' => $opts{'lvm'},
}, $class);
}

# storage_pools(self) returns native pools and discovered LVM thin destinations.
# Only local logical pools use host LVM commands; remote inventory stays native.
sub storage_pools
{
my ($self) = @_;
my @pools;
foreach my $pool ($self->connect()->list_all_storage_pools(0)) {
	my ($type) = parse_pool_xml($pool->get_xml_description(0));
	if ($type eq 'logical' && $self->uri() eq 'qemu:///system') {
		# Local VGs expose separate thick and thin allocation destinations.
		my $driver = $self->{'lvm'} ||= Cloudmin::LVM->new(readonly => $self->{'readonly'});
		my @logical = eval { $driver->pools($pool) };
		if ($@) {
			# A missing VG must not hide unrelated file storage or other guests.
			$self->{'storage_errors'}->{$pool->get_uuid_string()} = error_message($@);
			push(@pools, $pool);
			}
		else {
			# A successful reread clears a previous inventory failure.
			delete($self->{'storage_errors'}->{$pool->get_uuid_string()});
			push(@pools, @logical);
			}
		}
	else {
		# Preserve other backends and remote pools as native libvirt objects.
		push(@pools, $pool);
		}
	}
return @pools;
}

# storage_pool(self, uuid) resolves native and thin destinations consistently.
sub storage_pool
{
my ($self, $uuid) = @_;
my ($native) = grep { $_->get_uuid_string() eq $uuid }
	$self->connect()->list_all_storage_pools(0);
# Resolve ordinary pools without parsing every unrelated pool's definition.
return $native if ($native &&
	(parse_pool_xml($native->get_xml_description(0)))[0] ne 'logical');
my ($pool) = grep { $_->get_uuid_string() eq $uuid } storage_pools($self);
die $self->{'storage_errors'}->{$uuid}."\n" if ($self->{'storage_errors'}->{$uuid});
die "Storage pool is missing\n" if (!$pool);
return $pool;
}

# disk_pool(type) identifies supported writable disk backends.
sub disk_pool { return ($_[0] || '') =~ /\A(?:dir|fs|netfs|logical|lvmthin)\z/; }

# block_pool(pool) identifies LVM destinations that store raw block devices.
sub block_pool
{
my ($type) = parse_pool_xml($_[0]->get_xml_description(0));
return $type eq 'logical' || $type eq 'lvmthin';
}

# file_pool(self, [preferred_uuid]) selects file storage for images and firmware.
# These auxiliary files cannot be placed in a volume group or thin pool.
sub file_pool
{
my ($self, $preferred) = @_;
my @pools = grep { $_->is_active() &&
	(parse_pool_xml($_->get_xml_description(0)))[0] =~ /\A(?:dir|fs|netfs)\z/ }
	storage_pools($self);
my ($pool) = grep { $_->get_uuid_string() eq ($preferred || '') } @pools;
# Libvirt lists pools in no particular order. Prefer the conventional default
# pool, then the first by name, so auxiliary files land predictably.
($pool) = grep { $_->get_name() eq 'default' } @pools if (!$pool);
($pool) = sort { $a->get_name() cmp $b->get_name() } @pools if (!$pool);
die "An active file storage pool is required for images and firmware\n" if (!$pool);
return $pool;
}

# uri(self)
# Returns the configured libvirt connection URI.
sub uri
{
my ($self) = @_;
return $self->{'uri'};
}

# log_call(method, parameters)
# Attaches a libvirt API call to the next Webmin action log. Callers select
# public parameters explicitly; never pass domain XML or provisioning inputs.
sub log_call
{
my ($method, $parameters) = @_;
# Webmin's command record also carries API invocations. Identify the binding
# explicitly rather than implying that an equivalent shell command was run.
additional_log('exec', undef, "libvirt API: $method\n".
	convert_to_json($parameters, 1));
}

# module_error(self)
# Returns the Sys::Virt load error, or undef when the bindings are available
# or an injected connection factory makes them unnecessary.
sub module_error
{
my ($self) = @_;
# Injected connections allow tests to run without Sys::Virt installed.
return undef if ($self->{'connection_factory'});

# Load bindings here so the dashboard can report a missing package.
my $ok = eval { require Sys::Virt; 1 };
return $ok ? undef : error_message($@);
}

# connect(self)
# Opens and caches the configured libvirt connection.
sub connect
{
my ($self) = @_;
# Reuse this adapter's connection for host checks and guest discovery.
return $self->{'connection'} if ($self->{'connection'});

my $connection;
# Let tests provide a connection without contacting a hypervisor.
if ($self->{'connection_factory'}) {
	$connection = eval {
		$self->{'connection_factory'}->(
			$self->{'uri'}, $self->{'readonly'});
		};
	}
# Normal requests connect through the installed Perl libvirt bindings.
else {
	require Sys::Virt;
	$connection = eval {
		Sys::Virt->new(
			'uri' => $self->{'uri'},
			'readonly' => $self->{'readonly'},
		);
		};
	}

# Report failed or empty connection results before caching the handle.
die error_message($@ || 'Libvirt returned no connection')
	if (!$connection);
$self->{'connection'} = $connection;
return $connection;
}

# disconnect(self)
# Releases this adapter's connection before restarting its libvirt daemon.
sub disconnect
{
my ($self) = @_;
delete($self->{'connection'});
}

# probe(self)
# Tests the connection and returns a result hash instead of throwing an error.
sub probe
{
my ($self) = @_;
my $connection = eval { $self->connect() };
# Return connection failures as data for the readiness panel.
return {
	'ok' => 0,
	'error' => error_message($@ || 'Libvirt returned no connection'),
} if (!$connection);

return { 'ok' => 1 };
}

# get_host_info(self)
# Returns basic, read-only details about the connected hypervisor.
sub get_host_info
{
my ($self) = @_;
my $connection = $self->connect();
# Webmin resolves the local FQDN; remote connections identify their own host.
my $hostname = $self->{'uri'} =~ m{\Aqemu:///}
	? get_system_hostname() : $connection->get_hostname();
# Match the installer's preferred local daemon layout. Remote connections
# must not inherit the management host's installed binaries.
my $layout = $self->{'uri'} eq 'qemu:///system'
	? (-x '/usr/sbin/virtqemud' ? 'modular'
		: -x '/usr/sbin/libvirtd' ? 'monolithic' : undef) : undef;
return {
	'uri' => $self->{'uri'},
	'hostname' => $hostname,
	'driver' => $connection->get_type(),
	'libvirt_version' => format_version(
		$connection->get_library_version()),
	'libvirt_layout' => $layout,
	'hypervisor_version' => format_version(
		$connection->get_version()),
};
}

# get_host_capabilities(self, [architecture])
# Returns the host CPU count, memory, and the machine type and firmware
# choices libvirt offers for KVM guests of the given architecture. The
# architecture defaults to the host CPU reported in libvirt's capabilities XML.
sub get_host_capabilities
{
my ($self, $architecture) = @_;
my $connection = $self->connect();
my $node = $connection->get_node_info();
my $caps = parse_xml_document($connection->get_capabilities());
my $host_arch = $caps->findvalue('/capabilities/host/cpu/arch');
$architecture ||= $host_arch;
# Creation supports native KVM guests only, not cross-architecture emulation.
die "Only native x86-64 and ARM64 KVM guests are supported\n"
	if ($architecture !~ /\A(?:x86_64|aarch64)\z/ ||
	$architecture ne $host_arch);
my $machine = get_machine_type($architecture);
# Query firmware support for the machine type that creation will actually use.
my $domain = parse_xml_document($connection->get_domain_capabilities(
	undef, $architecture, $machine, 'kvm', 0));
my @firmware = map { $_->textContent() }
	$domain->findnodes('/domainCapabilities/os/enum[@name="firmware"]/value');
# x86 BIOS can be implicit even when the firmware enum lists only EFI.
push(@firmware, 'bios')
	if ($architecture eq 'x86_64' && !grep { $_ eq 'bios' } @firmware);
my @machines = map { $_->textContent() }
	$caps->findnodes('/capabilities/guest/arch[@name="'.$architecture.
	'"]/machine');
return {
	architecture => $architecture, host_architecture => $host_arch,
	machine => $machine, machines => \@machines,
	emulator => $domain->findvalue('/domainCapabilities/path'),
	cpus => $node->{'cpus'}, memory_kib => $node->{'memory'},
	free_memory => $connection->get_node_free_memory(),
	firmware => \@firmware,
	efi => scalar(grep { $_ eq 'efi' } @firmware) ? 1 : 0,
	bios => scalar(grep { $_ eq 'bios' } @firmware) ? 1 : 0,
};
}

# parse_xml_document(xml)
# Parses libvirt XML without resolving external entities or reading DTDs.
sub parse_xml_document
{
require XML::LibXML;
return XML::LibXML->load_xml(string => $_[0], no_network => 1,
	load_ext_dtd => 0, expand_entities => 0);
}

# get_machine_type(architecture)
# Returns the libvirt machine type alias Cloudmin uses for new guests.
sub get_machine_type
{
my ($architecture) = @_;
# These architectures use QEMU's generic virtual board instead of a PC chipset.
return 'virt' if (($architecture || '') =~ /^(?:aarch64|armv7l|riscv64)$/);
return 'q35';
}

# volume(self, pool_uuid, name, [expected_key])
# Resolves a current active pool and volume, preserving lookup failures.
# Returns (pool, volume); a missing volume is undef, while a key mismatch dies.
sub volume
{
my ($self, $pool_id, $name, $key) = @_;
my $pool = $self->storage_pool($pool_id);
# Refreshing an inactive pool cannot establish the current volume identity.
die "Storage pool is no longer active\n" if (!$pool->is_active());
refresh_pool($pool);
my ($volume) = grep { $_->get_name() eq $name } $pool->list_all_volumes();
# A replacement with the same name must not inherit the old volume's trust.
die "The selected volume has changed\n"
	if ($volume && defined($key) && $key ne $volume->get_key());
return ($pool, $volume);
}

# refresh_pool(pool, [timeout])
# Retries refresh while a libvirt storage job is busy; timeout defaults to 30
# seconds.
# Other failures propagate immediately; the caller's job deadline still applies.
sub refresh_pool
{
my ($pool, $timeout) = @_;
my $end = Time::HiRes::time() + (defined($timeout) ? $timeout : 30);
while (1) {
	return if (eval { $pool->refresh(); 1 });
	my $error = $@;
	# Libvirt rejects refresh while a volume clone or upload is running.
	die $error if (!ref($error) || !$error->isa('Sys::Virt::Error') ||
		$error->code() != 1 ||
		$error->message() !~ /pool .* has asynchronous jobs running/ ||
		Time::HiRes::time() >= $end);
	Time::HiRes::sleep(0.2);
	}
}

# clone_disk(self, pool_uuid, name, source, bytes, format, journal)
# Makes an independent libvirt volume and grows it without changing the image.
# source contains pool, volume and volume_key; journal() records cleanup intent.
sub clone_disk
{
my ($self, $pool_id, $name, $source, $bytes, $format, $journal) = @_;
my ($pool, $existing) = $self->volume($pool_id, $name);
# Native LVM allocation rounds to extents; convert to the same final capacity.
$bytes = $pool->aligned_capacity($bytes) if ($pool->isa('Cloudmin::LVM::Pool'));
# Never overwrite an existing disk, even after a retried request.
die "Destination volume already exists\n" if ($existing);
my (undef, $original) = $self->volume(@{$source}{qw(pool volume volume_key)});
# The selected import may have disappeared after request validation.
die "Source image volume is missing\n" if (!$original);
# Record intent before libvirt allocates anything, for recovery after a crash.
$journal->();
# LVM disks contain raw sectors. Convert in the existing unprivileged worker,
# then copy its checked output without asking a privileged process to parse it.
if (block_pool($pool) || $original->isa('Cloudmin::LVM::Volume')) {
	my $source_doc = parse_xml_document($original->get_xml_description(0));
	my $source_format = $source_doc->findvalue('/volume/target/format/@type') || 'raw';
	my ($files, $layers) = $self->conversion_sources($original);
	my $destination_format = block_pool($pool) ? 'raw' : $format;
	# Allocate only after validating the source chain; the journal owns cleanup.
	my $volume = $pool->create_volume('<volume><name>'.xml_escape($name).
		"</name><capacity unit='bytes'>$bytes</capacity><target><format type='$destination_format'/></target></volume>");
	my $runner = $self->{'disk_worker'} || sub { Cloudmin::Worker->new()->run(@_) };
	# Allow input-format overhead while bounding the converted virtual capacity.
	$runner->('convert', {format => $source_format, output_format => $destination_format,
		capacity => $bytes, limit => int($bytes*1.05)+16*1024**2, layers => $layers},
		files => $files, consume => sub {
			my ($file, $info) = @_;
			die "Converted disk exceeds its destination\n" if ($info->{'virtual-size'} > $bytes);
			$self->write_volume($volume, $file);
			});
	return $self->get_storage_volume_record($volume);
	}
log_call('Sys::Virt::StoragePool::clone_volume', {
	pool => $pool_id, volume => $name, source_pool => $source->{'pool'},
	source_volume => $source->{'volume'}, capacity_bytes => $bytes,
	format => $format, flags => 0 });
my $volume = $pool->clone_volume("<volume><name>".xml_escape($name)."</name>".
	"<capacity unit='bytes'>$bytes</capacity><allocation>0</allocation>".
	"<target><format type='$format'/></target></volume>", $original, 0);
# Some storage drivers clone at the original capacity despite the requested
# size.
my $capacity = $volume->get_info()->{'capacity'};
if ($capacity < $bytes) {
	# Record growth separately when the pool cloned at the source size.
	log_call('Sys::Virt::StorageVol::resize', {
		pool => $pool_id, volume => $name,
		before_bytes => $capacity,
		after_bytes => $bytes, flags => 0 });
	$volume->resize($bytes, 0);
	}
return $self->get_storage_volume_record($volume);
}

# conversion_sources(self, volume) stages a managed backing chain for conversion.
# Only libvirt-listed local volumes may supply backing bytes. The worker rewrites
# links on private copies, so guest-controlled paths never select host files.
sub conversion_sources
{
my ($self, $volume) = @_;
my (%files, %seen, @layers, %managed);
while ($volume) {
	my $path = $volume->get_path();
	die "The disk backing chain is cyclic or too deep\n" if ($seen{$path}++ || @layers >= 32);
	my $doc = parse_xml_document($volume->get_xml_description(0));
	my $format = $doc->findvalue('/volume/target/format/@type') || 'raw';
	die "Unsupported disk backing format\n" if ($format !~ /\A(?:raw|qcow2)\z/);
	# Fixed private names let the worker rebuild links without host paths.
	my $name = @layers ? 'layer'.scalar(@layers) : 'image';
	$files{$name} = $path;
	push(@layers, {name => $name, format => $format});
	my $backing = $doc->findvalue('/volume/backingStore/path');
	last if (!$backing);
	die "Raw disks cannot have backing files\n" if ($format ne 'qcow2');
	if (!%managed) {
		# Build this map only for chained images; ordinary imports need no scan.
		foreach my $pool ($self->storage_pools()) {
			next if (!$pool->is_active());
			my ($type) = parse_pool_xml($pool->get_xml_description(0));
			next if ($type !~ /\A(?:dir|fs|netfs)\z/);
			foreach my $item ($pool->list_all_volumes()) {
				my $resolved = Cwd::abs_path($item->get_path());
				$managed{$resolved} = $item if ($resolved);
				}
			}
		}
	$backing = dirname($path).'/'.$backing if ($backing !~ m{^/});
	# Resolve relative links against their layer, then require managed storage.
	my $resolved = Cwd::abs_path($backing);
	$volume = $resolved ? $managed{$resolved} : undef;
	die "The disk backing file is not in an active managed file pool\n" if (!$volume);
	}
return (\%files, @layers > 1 ? \@layers : undef);
}

# write_volume(self, volume, file) copies checked disk bytes through its backend.
sub write_volume
{
my ($self, $volume, $file) = @_;
# Block writes use verified device descriptors; files use libvirt's stream API.
return $volume->write_file($file) if ($volume->isa('Cloudmin::LVM::Volume'));
my $stream = $self->connect()->new_stream();
my $ok = eval {
	$volume->upload($stream, 0, -s $file, 0);
	open(my $fh, '<', $file) or die "Cannot read checked disk\n";
	binmode($fh);
	$stream->send_all(sub {
		my $read = read($fh, $_[1], $_[2]);
		die "Cannot read checked disk\n" if (!defined($read));
		return $read;
		});
	close($fh); $stream->finish(); 1;
	};
# Abort partial transfers without replacing the original error with cleanup.
if (!$ok) { my $error = $@; eval { $stream->abort(); }; die $error; }
}

# create_disk(self, pool_uuid, name, bytes, journal)
# Allocates an empty QCOW2 file or raw logical volume at the requested capacity.
# The required journal() callback records the volume for cleanup before allocation.
sub create_disk
{
my ($self, $pool_id, $name, $bytes, $journal) = @_;
my ($pool, $existing) = $self->volume($pool_id, $name);
# Never replace storage left by another request or an interrupted allocation.
die "Destination volume already exists\n" if ($existing);
# Record intent first so a lost allocation reply can still be cleaned up.
$journal->();
my $format = block_pool($pool) ? 'raw' : 'qcow2';
log_call('Sys::Virt::StoragePool::create_volume', {
	pool => $pool_id, volume => $name, capacity_bytes => $bytes,
	format => $format, flags => 0 });
my $volume = $pool->create_volume('<volume><name>'.xml_escape($name).
	"</name><capacity unit='bytes'>$bytes</capacity><allocation>0</allocation>".
	"<target><format type='$format'/></target></volume>", 0);
return $self->get_storage_volume_record($volume);
}

# upload_seed(self, pool_uuid, name, file, journal, [format], [capacity])
# Imports checked bytes into the backend; defaults to a raw seed sized to the file.
# journal() records cleanup intent before the destination volume is created.
sub upload_seed
{
my ($self, $pool_id, $name, $file, $journal, $format, $capacity) = @_;
# Callers may import raw seeds or verified QCOW2 disks with virtual capacity.
$format ||= 'raw';
die "Invalid volume format\n" if ($format !~ /\A(?:raw|qcow2)\z/);
my ($pool, $existing) = $self->volume($pool_id, $name);
# An existing volume name belongs to another operation; never replace it.
die "Destination seed volume already exists\n" if ($existing);
my $size = -s $file || die "Cloud-init seed is empty\n";
$capacity ||= $size;
Cloudmin::Worker::byte_limit($capacity);
$journal->();
if (block_pool($pool)) {
	# Seed and restore imports share this path; LVs always store raw sectors.
	my $volume = $pool->create_volume('<volume><name>'.xml_escape($name).
		"</name><capacity unit='bytes'>$capacity</capacity><target><format type='raw'/></target></volume>");
	if ($format eq 'raw') {
		# The caller already inspected these bytes; no format conversion is needed.
		$volume->write_file($file);
		}
	else {
		# Parse QCOW2 only in the isolated worker, then copy its raw result.
		my $runner = $self->{'disk_worker'} || sub { Cloudmin::Worker->new()->run(@_) };
		# A fully written QCOW2 file slightly exceeds its virtual capacity, so
		# budget the staged input like clone_disk; the raw output still has to fit.
		$runner->('convert', {format => $format, output_format => 'raw',
			limit => int($capacity*1.05)+16*1024**2},
			files => {image => $file}, consume => sub { $volume->write_file($_[0]); });
		}
	return $self->get_storage_volume_record($volume);
	}
log_call('Sys::Virt::StoragePool::create_volume', {
	pool => $pool_id, volume => $name, capacity_bytes => $capacity,
	format => $format });
my $volume = $pool->create_volume("<volume><name>".xml_escape($name)."</name>".
	"<capacity unit='bytes'>$capacity</capacity><target><format type='$format'/></target></volume>");
my $stream = $self->connect()->new_stream();
# Stream the input file without granting the guest access to staging files.
my $ok = eval {
	# Record the transfer size, never the seed's credentials or contents.
	log_call('Sys::Virt::StorageVol::upload', {
		pool => $pool_id, volume => $name, bytes => $size, offset => 0,
		flags => 0 });
	$volume->upload($stream, 0, $size, 0);
	open(my $fh, '<', $file) || die "Cannot read cloud-init seed: $!\n";
	binmode($fh);
	$stream->send_all(sub {
		# reader(stream, buffer, length)
		# Supplies the next seed bytes to libvirt.
		my $read = read($fh, $_[1], $_[2]);
		# An I/O error must abort the upload rather than masquerade as
		# EOF.
		die "Cannot read cloud-init seed: $!\n" if (!defined($read));
		return $read;
		});
	close($fh);
	$stream->finish();
	1;
	};
my $error = $@;
# Release an unfinished stream and preserve the original upload failure.
eval { $stream->abort() } if (!$ok);
die $error if (!$ok);
return $self->get_storage_volume_record($volume);
}

# define_guest(self, xml)
# Defines a persistent domain using libvirt's schema validation.
sub define_guest
{
my ($self, $xml) = @_;
my $document = parse_xml_document($xml);
my $uuid = $document->findvalue('/domain/uuid');
my $name = $document->findvalue('/domain/name');
# Defining existing XML could replace a guest; creation must only add one.
die "A domain with this name or UUID already exists\n" if (grep {
	$_->get_uuid_string() eq $uuid || $_->get_name() eq $name
	} $self->connect()->list_all_domains());
# Configure recording before the first boot, including clones and restores.
$xml = $self->{'serial_log'}->configure($xml) if ($self->{'serial_log'} &&
	!$self->{'readonly'} && $self->uri() eq 'qemu:///system');
log_call('Sys::Virt::define_domain', { uuid => $uuid, name => $name,
	flags => 1 });
return $self->connect()->define_domain($xml, 1);
}

# remove_created_volume(self, pool_uuid, name, [expected_key])
# Deletes a journalled volume only after checking every remaining domain
# reference.
sub remove_created_volume
{
my ($self, $pool_id, $name, $key) = @_;
my ($pool, $volume) = $self->volume($pool_id, $name, $key);
# Repeated rollback can safely pass a volume that is already gone.
return 1 if (!$volume);
# A volume used by any guest is no longer safe for automatic rollback.
Cloudmin::Images::assert_unused(undef, $self->connect(), $pool, $volume);
log_call('Sys::Virt::StorageVol::delete', {
	pool => $pool_id, volume => $name, flags => 0 });
$volume->delete(0);
return 1;
}

# setup_agent_error() reports missing host tools before guest allocation.
sub setup_agent_error
{
return 'Guest software setup requires virsh and timeout on the Cloudmin host'
	if (!-x '/usr/bin/virsh' || !-x '/usr/bin/timeout');
return '';
}

# setup_agent_command(self, uuid, command, [arguments], [final_attempt])
# Returns a decoded guest-file reply, or undef while the agent is not ready.
# final_attempt stops retrying guest file, policy and lost-handle errors.
# arguments defaults to an empty object; final_attempt defaults to false.
# Sys::Virt does not expose virDomainQemuAgentCommand; use libvirt's CLI for it.
sub setup_agent_command
{
my ($self, $uuid, $command, $arguments, $final_attempt) = @_;
# Limit this write-capable channel to the three identity file operations.
die "Guest identity lookup requires write permission\n" if ($self->{'readonly'});
die "Invalid virtual machine identifier\n" if (!defined($uuid) ||
	$uuid !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i);
die "Unsupported guest identity operation\n"
	if ($command !~ /\Aguest-file-(?:open|read|close)\z/);
my $missing = setup_agent_error();
die "$missing\n" if ($missing);
my $json = convert_to_json({ execute => $command, arguments => $arguments || {} }, 0, 1);
my $cmd = join(' ', map { quote_path($_) } '/usr/bin/timeout', '-k', '1', '5',
	'/usr/bin/virsh', '--connect', $self->uri(), 'qemu-agent-command',
	'--domain', $uuid, '--timeout', '2', '--cmd', $json);
my ($output, $error);
# Keep libvirt diagnostics stable when distinguishing boot delays from errors.
local $ENV{'LC_ALL'} = 'C';
my $status = execute_command($cmd, undef, \$output, \$error);
if ($status) {
	# A disconnected or busy agent may become available as the guest boots.
	return undef if (($status >> 8) == 124 || ($status >> 8) == 137 || $status == 9 ||
		($error || '') =~ /(?:guest agent (?:is not connected|not available|is not responding)|agent.*(?:timed out|timeout))/i);
	# Libvirt converts QGA errors to stderr and a nonzero exit status. Only
	# guest failures can be boot delays; host access errors must fail at once.
	my ($guest_error) = ($error || '') =~
		/unable to execute QEMU agent command '\Q$command\E':\s*(.*)/is;
	# Preparation publishes the identity, enables file RPCs and labels the
	# file. A restart can also lose a read handle. Keep the final diagnostic.
	return undef if (!$final_attempt && defined($guest_error) &&
		($guest_error =~ /(?:has been disabled|not allowed|Permission denied)/i ||
		 $command eq 'guest-file-open' && $guest_error =~ /No such file or directory/i ||
		 $command eq 'guest-file-read' && $guest_error =~ /(?:handle.*has not been found|invalid handle)/i));
	# Retain a bounded diagnostic without terminal control characters.
	$error = substr($error || 'virsh failed without a diagnostic', 0, 1024);
	$error =~ s/[\x00-\x1f\x7f]+/ /g;
	die "Guest identity lookup failed: $error\n";
}
# Successful virsh calls must still return a bounded, valid agent response.
die "Invalid guest agent response\n" if (length($output || '') > 16384);
my $response = eval { convert_from_json($output) };
die "Invalid guest agent response\n"
	if (ref($response) ne 'HASH' || exists($response->{'error'}));
return $response;
}

# get_setup_host_key(self, uuid, [final_attempt]) reads the public identity.
# A disconnected or busy agent returns undef. Missing files, blocked reads and
# lost handles also return undef until final_attempt requests their diagnostic.
# final_attempt defaults to false and does not disable transport retries.
sub get_setup_host_key
{
my ($self, $uuid, $final_attempt) = @_;
my $opened = $self->setup_agent_command($uuid, 'guest-file-open',
	{ path => '/var/log/qemu-ga/cloudmin-identity.json', mode => 'r' }, $final_attempt);
# No open reply means preparation or the agent is still unavailable.
return undef if (!$opened);
my $handle = $opened->{'return'};
die "Invalid guest identity handle\n" if (!defined($handle) || ref($handle) || $handle !~ /\A\d+\z/);
my ($identity, $pending);
my $ok = eval {
	my $read = $self->setup_agent_command($uuid, 'guest-file-read',
		{ handle => 0+$handle, count => 4096 }, $final_attempt);
	if (!$read) {
		# A guest reboot can close an open agent handle before its read.
		$pending = 1;
	}
	else {
		# Validate the complete record and UUID before accepting its SSH key.
		my $reply = $read->{'return'};
		die "Invalid guest identity response\n" if (ref($reply) ne 'HASH' ||
			!defined($reply->{'count'}) || $reply->{'count'} !~ /\A\d+\z/ || $reply->{'count'} >= 4096 ||
			ref($reply->{'buf-b64'}) || ($reply->{'buf-b64'} || '') !~ /\A[A-Za-z0-9+\/=\r\n]+\z/);
		my $bytes = decode_base64($reply->{'buf-b64'});
		die "Incomplete guest identity response\n" if (length($bytes) != $reply->{'count'});
		$identity = convert_from_json($bytes);
		die "The guest identity does not match this creation request\n" if (ref($identity) ne 'HASH' ||
			($identity->{'uuid'} || '') ne $uuid);
		die "Invalid guest SSH host key\n" if (ref($identity->{'key'}) ||
			($identity->{'key'} || '') !~ /\Assh-rsa [A-Za-z0-9+\/=]+(?: [^\r\n]*)?\z/);
	}
	1;
};
my $error = $@;
# Closing is required even if parsing or identity validation fails.
eval { $self->setup_agent_command($uuid, 'guest-file-close', { handle => 0+$handle }); };
die $error if (!$ok);
return $pending ? undef : $identity->{'key'};
}

# list_host_bridges(self, [networks])
# Returns Linux bridges on the host that are not owned by a libvirt network,
# read from sysfs so no interface daemon is required.
# Pass networks from list_networks() to exclude their bridges; otherwise none
# are excluded. sys_net always describes the local host, not a remote URI.
sub list_host_bridges
{
my ($self, $networks) = @_;
my %owned = map { ($_->{'bridge'} || '') => 1 } @{$networks || []};
my @bridges;
opendir(my $dh, $self->{'sys_net'}) || return [];
foreach my $name (sort readdir($dh)) {
	# Avoid hidden entries and duplicate choices already offered as
	# networks.
	next if ($name =~ /^\./ || $owned{$name});
	# The bridge directory distinguishes Linux bridges from other
	# interfaces.
	next if (!-d "$self->{'sys_net'}/$name/bridge");
	# An empty bridge has no carrier until its first guest attaches. IFF_UP
	# tells us whether the administrator enabled it, independently of
	# carrier.
	my $flags = read_file_contents("$self->{'sys_net'}/$name/flags") || '';
	my $state = $flags =~ /\A0x([0-9a-f]+)\s*\z/i
		? (hex($1) & 1 ? 'up' : 'down') : '';
	push(@bridges, { 'name' => $name, 'state' => $state });
	}
closedir($dh);
return \@bridges;
}

# get_network_record(self, network)
# Converts a Sys::Virt::Network object into a Cloudmin inventory record.
sub get_network_record
{
my ($self, $network) = @_;
my $active = eval { $network->is_active() } ? 1 : 0;
my $persistent = eval { $network->is_persistent() } ? 1 : 0;
my $autostart = $persistent && eval { $network->get_autostart() } ? 1 : 0;
my $xml = eval { $network->get_xml_description(0) } || '';
# Extract the bridge name from either accepted XML quote style.
my ($bridge) = $xml =~ /<bridge\b[^>]*\bname\s*=\s*["']([^"']+)["']/i;
my ($forward) = $xml =~ /<forward\b[^>]*\bmode\s*=\s*["']([^"']+)["']/i;
# A network without a forward element is isolated to the host.
$forward = $xml =~ /<forward\b/i ? ($forward || 'nat') : 'isolated';
my ($address, $netmask, $prefix) = $xml =~
	/<ip\b(?![^>]*family\s*=\s*["']ipv6["'])[^>]*\baddress\s*=\s*["']([^"']+)["'](?:[^>]*\bnetmask\s*=\s*["']([^"']+)["'])?(?:[^>]*\bprefix\s*=\s*["'](\d+)["'])?/i;
my $dhcp = $xml =~ /<dhcp\b/i ? 1 : 0;

# Inventory records retain inactive networks without claiming they are usable.
return {
	'id' => $network->get_uuid_string(),
	'uuid' => $network->get_uuid_string(),
	'name' => $network->get_name(),
	'active' => $active,
	'persistent' => $persistent,
	'autostart' => $autostart,
	'bridge' => $bridge,
	'forward' => $forward,
	'address' => $address,
	'netmask' => $netmask,
	'prefix' => $prefix,
	'dhcp' => $dhcp,
};
}

# memory_kib(doc, element)
# Converts libvirt memory fields to KiB, including omitted currentMemory.
sub memory_kib
{
my ($doc, $element) = @_;
my ($node) = $doc->findnodes('/domain/'.$element);
# Without currentMemory, libvirt starts with the configured memory maximum.
($node) = $doc->findnodes('/domain/memory') if (!$node && $element eq 'currentMemory');
die "Missing memory configuration\n" if (!$node);
my %units = (b => 1/1024, bytes => 1/1024, KiB => 1, k => 1,
	MiB => 1024, M => 1024, GiB => 1024**2, G => 1024**2);
my $unit = $node->getAttribute('unit') || 'KiB';
die "Unsupported memory unit\n" if (!$units{$unit});
return $node->textContent() * $units{$unit};
}

# network_attachments(doc)
# Returns an array reference of MAC, type and source records from parsed XML.
# Ignores device details that libvirt adds at runtime.
sub network_attachments
{
my ($doc) = @_;
my @interfaces;
foreach my $node ($doc->findnodes('/domain/devices/interface')) {
	my $type = $node->getAttribute('type');
	# Compare only the network and bridge attachments exposed by the editor.
	next if ($type !~ /\A(?:network|bridge)\z/);
	# Read the configured source, not libvirt's bridge/portid or <actual> data.
	push(@interfaces, { mac => lc($node->findvalue('mac/@address')),
		type => $type, source => ''.$node->findvalue('source/@'.$type) });
}
# XML device order must not make otherwise identical attachments differ.
return [sort { $a->{'mac'} cmp $b->{'mac'} } @interfaces];
}

# resource_settings(doc)
# Normalizes the public settings compared by the editor and status collector.
sub resource_settings
{
my ($doc) = @_;
die "Missing CPU configuration\n" if (!$doc->findvalue('/domain/vcpu'));
my @boot;
foreach my $node ($doc->findnodes('/domain/os/boot')) {
	# Legacy boot order selects a device class rather than an individual disk.
	push(@boot, { device => $node->getAttribute('dev') });
	}
foreach my $node ($doc->findnodes('/domain/devices/*/boot')) {
	# Per-device order identifies disks by target and interfaces by MAC.
	my $device = $node->parentNode();
	push(@boot, { device => $device->nodeName(),
		target => $device->findvalue('target/@dev | mac/@address'),
		order => $node->getAttribute('order') });
	}
return { cpus => 0 + ($doc->findvalue('/domain/vcpu/@current') || $doc->findvalue('/domain/vcpu')),
	cpu_limit => 0 + $doc->findvalue('/domain/vcpu'),
	memory_mib => memory_kib($doc, 'currentMemory') / 1024,
	memory_limit_mib => memory_kib($doc, 'memory') / 1024,
	bootmenu => $doc->findvalue('/domain/os/bootmenu/@enable') eq 'yes' ? 1 : 0,
	boot => \@boot, networks => network_attachments($doc) };
}

# pending_settings(running, saved)
# Returns differences in public resource settings without retaining guest XML.
sub pending_settings
{
my ($running, $saved) = @_;
# Canonical JSON compares boot/network arrays and scalar settings with one rule.
return { map { $_ => { running => $running->{$_}, saved => $saved->{$_} } }
	grep { convert_to_json([$running->{$_}], 0, 0, 1) ne
		convert_to_json([$saved->{$_}], 0, 0, 1) }
	keys %$saved };
}

# pending_domain_settings(self, domain, running, saved)
# Excludes a cold start's settling balloon without hiding later saved changes.
sub pending_domain_settings
{
my ($self, $domain, $running, $saved) = @_;
my $pending = pending_settings($running, $saved);
if ($self->{'startup'}) {
	# Unavailable startup state falls back to the ordinary XML comparison.
	delete $pending->{'memory_mib'} if (eval {
		$self->{'startup'}->settling($domain, $running->{'memory_mib'}, $saved->{'memory_mib'});
		});
	}
return $pending;
}

# get_domain_addresses(self, domain, record, [skip_agent])
# Collects guest IP addresses from the guest agent when it answers, otherwise
# combines libvirt DHCP leases and the host ARP table. skip_agent defaults to
# false. record is accepted for inventory callers but is not read by this
# method.
sub get_domain_addresses
{
my ($self, $domain, $record, $skip_agent) = @_;
my %seen;
my @addresses;
foreach my $source ($ADDRESSES_AGENT, $ADDRESSES_LEASE, $ADDRESSES_ARP) {
	# A failed bounded health probe should not immediately query the
	# agent again.
	next if ($skip_agent && $source == $ADDRESSES_AGENT);
	my @interfaces = eval { $domain->get_interface_addresses($source, 0) };
	foreach my $interface (@interfaces) {
		foreach my $entry (@{$interface->{'addrs'} || []}) {
			my $address = $entry->{'addr'} || next;
			# Skip loopback and IPv6 link-local addresses reported
			# by the agent.
			next if ($address =~ /^(?:127\.|::1$|fe80:)/i);
			# A lease or ARP entry must not repeat an address
			# already collected.
			next if ($seen{$address}++);
			push(@addresses, {
				'address' => $address,
				'prefix' => $entry->{'prefix'},
				'mac' => lc($interface->{'hwaddr'} || ''),
				'interface' => $interface->{'name'},
				'source' => $source == $ADDRESSES_AGENT
				? 'agent'
					: $source == $ADDRESSES_LEASE ? 'lease'
					: 'arp',
			});
			}
		}
	# Prefer any usable agent result; otherwise combine leases and ARP
	# entries.
	last if (@addresses && $source == $ADDRESSES_AGENT);
	}
return \@addresses;
}

# filesystem_space(path)
# Reads current Linux filesystem bytes, excluding reserves from available space.
sub filesystem_space
{
my ($path) = @_;
return undef if ($^O ne 'linux' || !$path || !-d $path);
open(my $stat, '-|', 'stat', '-f', '--format=%S %b %f %a', '--', $path) || return undef;
my $line = <$stat>;
my $ok = close($stat);
return undef if (!$ok || !defined($line) || $line !~ /\A(\d+) (\d+) (\d+) (-?\d+)\s*\z/);
my ($size, $blocks, $free, $available) = ($1, $2, $3, $4);
# Full filesystems may report negative availability after reserves are used.
return undef if (!$size || !$blocks || $free > $blocks || $available > $free);
$available = 0 if ($available < 0);
return { capacity => $blocks * $size, allocation => ($blocks - $free) * $size,
	available => $available * $size };
}

# get_storage_volume_record(self, volume)
# Converts a Sys::Virt::StorageVol object into a Cloudmin inventory record.
sub get_storage_volume_record
{
my ($self, $volume) = @_;
my $info = eval { $volume->get_info() } || {};
my $doc = eval { parse_xml_document($volume->get_xml_description(0)) };
return {
	'name' => $volume->get_name(),
	'key' => eval { $volume->get_key() },
	'path' => eval { $volume->get_path() },
	'type' => $info->{'type'},
	'block' => $volume->isa('Cloudmin::LVM::Volume') ? 1 : 0,
	'snapshot' => $volume->isa('Cloudmin::LVM::Volume') &&
		($volume->record()->{'lv_tags'} || '') =~ /(?:^|,)cloudmin_snapshot(?:,|$)/ ? 1 : 0,
	'capacity' => $info->{'capacity'} || 0,
	'allocation' => $info->{'allocation'} || 0,
	'format' => $doc ? $doc->findvalue('/volume/target/format/@type') : '',
};
}

# extract_macs(xml)
# Extracts normalized interface MAC addresses from a libvirt domain document.
sub extract_macs
{
my ($xml) = @_;
my @macs;
while ($xml =~ /<mac\b[^>]*\baddress\s*=\s*(["'])([^"']+)\1/ig) {
	push(@macs, lc($2));
	}
return @macs;
}

# extract_interfaces(xml)
# Returns network interfaces with their MAC, model and attachment.
sub extract_interfaces
{
my ($xml) = @_;
my @interfaces;
while ($xml =~ m{<interface\b([^>]*)>(.*?)</interface>}sg) {
	my ($attrs, $body) = ($1, $2);
	my ($type) = $attrs =~ /\btype\s*=\s*["']([^"']+)["']/i;
	my ($mac) = $body =~ m{<mac\b[^>]*\baddress\s*=\s*["']([^"']+)["']}i;
	my ($network) =
		$body =~ m{<source\b[^>]*\bnetwork\s*=\s*["']([^"']+)["']}i;
	my ($bridge) =
		$body =~ m{<source\b[^>]*\bbridge\s*=\s*["']([^"']+)["']}i;
	my ($model) = $body =~ m{<model\b[^>]*\btype\s*=\s*["']([^"']+)["']}i;
	my ($target) = $body =~ m{<target\b[^>]*\bdev\s*=\s*["']([^"']+)["']}i;
	# The page needs both the guest NIC model and its host-side attachment.
	push(@interfaces, {
		'type' => $type || '',
		'mac' => lc($mac || ''),
		'network' => $network,
		'bridge' => $bridge,
		'source' => $network || $bridge,
		'model' => $model,
		'target' => $target,
	});
	}
return @interfaces;
}

# extract_graphics(xml)
# Returns the VNC graphics device when present, otherwise the first device,
# with its type, listen address and assigned ports.
sub extract_graphics
{
my ($xml) = @_;
my @devices;
foreach my $attrs ($xml =~ m{<graphics\b([^>]*)>}gi) {
	my %device;
	while ($attrs =~ /\b([\w-]+)\s*=\s*["']([^"']*)["']/g) {
		$device{lc($1)} = $2;
		}
	push(@devices, \%device);
	}
# Headless guests have no graphics device to display.
return undef if (!@devices);
# The console opens VNC, so a guest with several displays reports that one.
my ($vnc) = grep { ($_->{'type'} || '') eq 'vnc' } @devices;
my %graphics = %{$vnc || $devices[0]};
# Ports are -1 until QEMU assigns them at start.
return {
	'type' => $graphics{'type'},
	'listen' => $graphics{'listen'},
	'port' => ($graphics{'port'} || -1) > 0 ? $graphics{'port'} : undef,
	'websocket' => ($graphics{'websocket'} || -1) > 0
		? $graphics{'websocket'} : undef,
};
}

# extract_serial_console(xml)
# Returns an alias record for the default PTY console, or undef if unsupported.
# Fall back to the first serial port only when there is no console element.
sub extract_serial_console
{
my ($xml) = @_;
my $doc = parse_xml_document($xml);
my ($device) = $doc->findnodes('/domain/devices/console');
# Older domain definitions may declare a serial port without a console element.
($device) = $doc->findnodes('/domain/devices/serial') if (!$device);
# File, socket and other backends are not supported by this console transport.
return undef if (!$device || $device->getAttribute('type') ne 'pty');
# Use an alias, never a host path. No alias means libvirt's default device.
my $alias = $device->findvalue('alias/@name');
return { alias => length($alias) ? $alias : undef };
}

# parse_pool_xml(xml)
# Extracts the backend type and target path from a libvirt pool document.
sub parse_pool_xml
{
my ($xml) = @_;
my ($quote, $type) = $xml =~
	/<pool\b[^>]*\btype\s*=\s*(["'])([^"']+)\1/i;
my ($target) = $xml =~
	m{<target\b[^>]*>.*?<path\b[^>]*>(.*?)</path>}is;
# Decode an existing target without inventing a path for non-file pools.
$target = decode_xml_text($target) if (defined($target));
return ($type, $target);
}

# decode_xml_text(value)
# Decodes the entities libvirt uses when serializing text and attributes.
sub decode_xml_text
{
my ($value) = @_;
# Missing XML values stay distinguishable from explicitly empty strings.
return undef if (!defined($value));
$value =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
$value =~ s/&#(\d+);/chr($1)/ge;
$value =~ s/&lt;/</g;
$value =~ s/&gt;/>/g;
$value =~ s/&quot;/"/g;
$value =~ s/&apos;/'/g;
$value =~ s/&amp;/&/g;
return $value;
}

# xml_escape(value)
# Escapes text for use inside libvirt XML elements and quoted attributes.
sub xml_escape
{
my ($value) = @_;
return html_escape($value);
}

# format_version(version)
# Converts libvirt's integer version format into major.minor.release.
sub format_version
{
my ($version) = @_;
# Do not format missing or nonnumeric versions as valid version numbers.
return undef if (!defined($version) || $version !~ /^\d+$/);
my $major = int($version / 1_000_000);
my $minor = int(($version % 1_000_000) / 1_000);
my $release = $version % 1_000;
return join('.', $major, $minor, $release);
}

# error_message(error)
# Converts string and Sys::Virt exception objects into one-line messages.
sub error_message
{
my ($error) = @_;
my $message = '';
# Prefer the message supplied by a Sys::Virt exception object.
if (ref($error) && eval { $error->can('message') }) {
	$message = eval { $error->message() } || "$error";
	}
# Plain errors and other objects use their string representation.
else {
	$message = defined($error) ? "$error" : '';
	}
# Remove Perl source locations and line breaks before returning UI text.
$message =~ s/\s+$//;
$message =~ s/\s+at\s+\S+\s+line\s+\d+\.?$//;
$message =~ s/\s+/ /g;
return $message || 'Unknown libvirt error';
}

1;
