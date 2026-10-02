package Cloudmin::VMManage;

# Hardware changes share creation's disk-work lock and durable job store.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);
use WebminCore qw(convert_to_json);
require(dirname(__FILE__).'/Libvirt.pm');
require(dirname(__FILE__).'/Images.pm');
require(dirname(__FILE__).'/VMs.pm');
require(dirname(__FILE__).'/VMHotplug.pm');

# new(class, jobs => store, images => store, adapter => factory)
# Opens libvirt connections in the process that performs each operation.
sub new
{
my ($class, %options) = @_;
return bless(\%options, $class);
}

# get_guest(self, id, [public])
# Loads persistent XML, omitting protected fields for read-only inventory.
# Edits keep secure XML, including console credentials, unless public is true.
sub get_guest
{
my ($self, $id, $public) = @_;
# Resolve only UUIDs on the local system connection, never names or remote guests.
die "Invalid virtual machine ID\n" if (!defined($id) || ref($id) ||
	$id !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
my $adapter = $self->{'adapter'}->();
die "Virtual machine management requires the local qemu:///system connection\n"
	if ($adapter->uri() ne 'qemu:///system');
my $domain = $adapter->find_domain($id) || die "Virtual machine not found\n";
die "Only persistent KVM virtual machines can be edited or deleted\n"
	if (!$domain->is_persistent());
# Edits retain secure fields; read-only callers receive only public XML.
my $xml = $domain->get_xml_description($public ? 2 : 3); # inactive, optionally secure
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
die "Only KVM virtual machines can be managed here\n"
	if ($doc->documentElement()->getAttribute('type') ne 'kvm');
return ($adapter, $domain, $doc, sha256_hex($xml));
}

1;
