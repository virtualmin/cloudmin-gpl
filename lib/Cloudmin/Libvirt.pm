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

# disk_pool(type) identifies supported writable disk backends.
sub disk_pool { return ($_[0] || '') =~ /\A(?:dir|fs|netfs|logical|lvmthin)\z/; }

# block_pool(pool) identifies LVM destinations that store raw block devices.
sub block_pool
{
my ($type) = parse_pool_xml($_[0]->get_xml_description(0));
return $type eq 'logical' || $type eq 'lvmthin';
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

# setup_agent_error() reports missing host tools before guest allocation.
sub setup_agent_error
{
return 'Guest software setup requires virsh and timeout on the Cloudmin host'
	if (!-x '/usr/bin/virsh' || !-x '/usr/bin/timeout');
return '';
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
