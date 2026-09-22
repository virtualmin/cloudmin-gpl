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

# parse_xml_document(xml)
# Parses libvirt XML without resolving external entities or reading DTDs.
sub parse_xml_document
{
require XML::LibXML;
return XML::LibXML->load_xml(string => $_[0], no_network => 1,
	load_ext_dtd => 0, expand_entities => 0);
}

1;
