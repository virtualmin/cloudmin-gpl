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

# file_identity(path)
# Identifies files by device/inode and LVs by VG/LV UUID, not reusable paths.
sub file_identity
{
my ($path) = @_;
my @stat = stat($path);
return Cloudmin::LVM::identity($path) if (@stat && -b _);
die "Cannot identify storage file $path: $!\n" if (!@stat || !-f _);
return join(':', @stat[0, 1]);
}

# storage(self, adapter)
# Returns managed file and LVM volumes; failed inventories must not look empty.
sub storage
{
my ($self, $adapter) = @_;
my $cache = $self->{'storage_cache'};
# One validation pass shares its refreshed inventory across all device changes.
return @{$cache->{"$adapter"}} if ($cache && $cache->{"$adapter"});
my (@pools, @volumes);
foreach my $pool (Cloudmin::Libvirt::storage_pools($adapter)) {
	# Inactive pools cannot supply volumes for these operations.
	next if (!$pool->is_active());
	my ($type) = Cloudmin::Libvirt::parse_pool_xml(
		$pool->get_xml_description(0));
	# File disks use inode identities; block disks use their LVM UUIDs.
	next if (!Cloudmin::Libvirt::disk_pool($type));
	# Report a busy pool promptly instead of blocking a form for thirty seconds.
	Cloudmin::Libvirt::refresh_pool($pool, 0);
	push(@pools, { id => $pool->get_uuid_string(),
		name => $pool->get_name(), type => $type });
	foreach my $v ($pool->list_all_volumes()) {
		# Native restore points belong to the snapshot journal, not disk pickers.
		next if ($v->isa('Cloudmin::LVM::Volume') &&
			($v->record()->{'lv_tags'} || '') =~ /(?:^|,)cloudmin_snapshot(?:,|$)/);
		# Host filesystems, swap and device stacks are never guest disk choices.
		next if ($v->isa('Cloudmin::LVM::Volume') && !eval { Cloudmin::LVM::host_use($v->record()); 1 });
		# Incomplete zeroing or a read-only allocation must not expose old bytes.
		next if ($v->isa('Cloudmin::LVM::Volume') && $v->initialization_pending());
		next if ($v->isa('Cloudmin::LVM::Volume') && $v->record()->{'lv_attr'} !~ /^.w/);
		my $doc = Cloudmin::Libvirt::parse_xml_document(
			$v->get_xml_description(0));
		my $format = $doc->findvalue('/volume/target/format/@type');
		# Only supported disks and read-only ISO media belong in this editor.
		next if ($format !~ /\A(?:raw|qcow2|iso)\z/);
		push(@volumes, { pool => $pool->get_uuid_string(),
			pool_name => $pool->get_name(), name => $v->get_name(),
			key => $v->get_key(), path => $v->get_path(),
			capacity => $v->get_info()->{'capacity'}, format => $format,
			block => Cloudmin::Libvirt::block_pool($pool) ? 1 : 0,
			identity => $v->isa('Cloudmin::LVM::Volume') ? $v->get_key() : file_identity($v->get_path()) });
		}
	}
$cache->{"$adapter"} = [\@pools, \@volumes] if ($cache);
return (\@pools, \@volumes);
}

# networks(adapter)
# Offers active libvirt networks and existing host bridges, as creation does.
sub networks
{
my ($adapter) = @_;
my $networks = $adapter->list_networks();
return [ (map { { key => 'network:'.$_->{'id'}, type => 'network',
	source => $_->{'name'} } } grep { $_->{'active'} } @$networks),
	(map { { key => 'bridge:'.$_->{'name'}, type => 'bridge',
		source => $_->{'name'} } }
	 grep { $_->{'state'} =~ /\A(?:up|unknown)\z/ }
	 @{$adapter->list_host_bridges($networks)}) ];
}

1;
