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

# require_stopped(domain)
# Offline operations require stopped hardware and no managed memory save.
sub require_stopped
{
my ($domain) = @_;
die "Shut down the virtual machine before changing or deleting it\n"
	if ($domain->is_active());
require_editable($domain);
}

# require_editable(domain, [plan])
# Rejects managed saves; with plan, also checks storage/history constraints.
sub require_editable
{
my ($domain, $plan) = @_;
die "Remove the managed save before changing this virtual machine\n"
	if ($domain->has_managed_save_image(0));
# Without a plan, only the managed-save check applies.
return if (!$plan);
# VM deletion owns a complete storage plan; ordinary disk edits still need
# snapshot-free storage. Recheck history before stopping or removing the VM.
if ($plan->{'operation'} eq 'delete') {
	my ($history, $revision) = delete_history($domain);
	# Native snapshot LVs need their own ownership-checked deletion first.
	die "Delete the LVM snapshots before deleting this virtual machine\n"
		if (grep { /snapshot=["']manual["']/ } @$history);
	die "Finish the interrupted snapshot operation before deleting this virtual machine\n"
		if (grep { /<snapshotDeleteInProgress\b/ } @$history);
	die "The snapshot or backup history changed; reload the deletion page\n"
		if (($plan->{'history_revision'} || '') ne $revision);
	if ($domain->is_active()) {
		# Deletion must not race a migration,
		# backup or active block job.
		die "Wait for the current libvirt operation to finish\n" if ($domain->get_job_info()->{'type'});
		my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0));
		foreach my $disk ($doc->findnodes('/domain/devices/disk[@device="disk"]')) {
			my $job = $domain->get_block_job_info($disk->findvalue('target/@dev'), 0);
			die "Wait for the current disk operation to finish\n" if ($job && $job->{'type'});
			}
		}
	return;
	}
my @steps = ($plan, @{$plan->{'changes'} || []});
# Resource, network and removable media edits leave snapshot chains untouched.
my $storage = grep { $_->{'operation'} =~
	/\A(?:delete_disk|grow_disk|detach_disk|attach_disk|add_disk)\z/ } @steps;
# Hardware expansion can also add a CD/DVD drive without a separate disk action.
$storage ||= grep { $_->{'kind'} eq 'disk' && !$_->{'media_change'} }
	@{$plan->{'live_ops'} || []};
return if (!$storage);
# Ordinary storage edits cannot reconcile existing snapshot/checkpoint chains.
my @snapshots = $domain->list_all_snapshots(0);
my @checkpoints = $domain->list_all_checkpoints(0);
die "Remove snapshots and backup checkpoints before changing writable disks or adding or removing drives\n"
	if (@snapshots || @checkpoints);
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

# settings(self, id)
# Supplies editable values and choices without exposing XML or passwords.
sub settings
{
my ($self, $id) = @_;
local $self->{'storage_cache'} = {};
my ($adapter, $domain, $doc, $revision) = $self->get_guest($id);
my ($pools, $volumes) = $self->storage($adapter);
my $xml = $doc->toString();
my @disks = Cloudmin::Libvirt::extract_disks($xml);
my $refs = Cloudmin::Images::volume_references($adapter->connect());
my @imports = @{$self->{'images'}->list()};
# Keep immutable image files out of the writable attachment picker, including aliases.
my %image_files;
my @images;
foreach my $image (@imports) {
	my ($volume) = grep { $_->{'pool'} eq ($image->{'pool'} || '') &&
		$_->{'key'} eq ($image->{'volume_key'} || '') } @$volumes;
	# Imports whose volumes are absent cannot supply an attachment or clone.
	next if (!$volume);
	$image_files{$volume->{'identity'}} = 1;
	# Exclude installer media even when the pool reports its format as raw.
	# Only completed disk imports can be cloned into writable guest storage.
	if (($image->{'state'} || '') eq 'ready' && ($image->{'format'} || '') ne 'iso' &&
		$volume->{'format'} =~ /\A(?:raw|qcow2)\z/) {
		push(@images, { id => $image->{'id'}, name => $image->{'name'},
			capacity => $volume->{'capacity'}, pool_name => $volume->{'pool_name'} });
		}
	}
my @attachable = grep { $_->{'format'} =~ /\A(?:raw|qcow2)\z/ &&
	!$image_files{$_->{'identity'}} &&
	!Cloudmin::Images::volume_use($refs, @{$_}{qw(path pool_name name key)}) } @$volumes;
foreach my $disk (@disks) {
	# Pool references and file paths both resolve to the same managed volume.
	my ($volume) = grep {
		($_->{'path'} eq ($disk->{'path'} || '')) ||
		($_->{'pool_name'} eq ($disk->{'pool'} || '') &&
		 $_->{'name'} eq ($disk->{'volume'} || '')) } @$volumes;
	$disk->{'volume_info'} = $volume if ($volume);
	$disk->{'imported'} = 1 if ($volume && $image_files{$volume->{'identity'}});
	}
# The form edits the saved allocation, falling back to its maximum if omitted.
my ($memory) = $doc->findnodes('/domain/currentMemory');
($memory) = $doc->findnodes('/domain/memory') if (!$memory);
my %units = (b => 1, bytes => 1, KiB => 1024, k => 1024,
	MiB => 1024**2, M => 1024**2, GiB => 1024**3, G => 1024**3);
my $unit = $memory->getAttribute('unit') || 'KiB';
die "Unsupported memory unit\n" if (!$units{$unit});
# Show the same CPU limit that submission validation enforces.
my $caps = $adapter->get_host_capabilities();
my @interfaces = Cloudmin::Libvirt::extract_interfaces($xml);
# XML defaults are a connected link and unlimited traffic in each direction.
foreach my $interface (@interfaces) {
	my $node = hotplug_device($doc, 'interface', $interface->{'mac'});
	$interface->{'link'} = $node->findvalue('link/@state') || 'up';
	$interface->{$_.'_kib'} = 0 + ($node->findvalue('bandwidth/'.$_.'/@average') || 0)
		foreach qw(inbound outbound);
	}
my ($running, %pending);
if ($domain->is_active()) {
	# Compare hardware with its saved settings without exposing domain XML.
	$running = resource_values(Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0)));
	my $saved = resource_values($doc);
	%pending = %{$adapter->pending_domain_settings($domain, $running, $saved)};
	}
return { id => $id, uuid => $id, name => $domain->get_name(),
	revision => $revision, active => $domain->is_active() ? 1 : 0,
	state => Cloudmin::Libvirt::domain_state_name(($domain->get_state())[0]),
	cpus => 0 + ($doc->findvalue('/domain/vcpu/@current') || $doc->findvalue('/domain/vcpu')),
	max_cpus => $caps->{'cpus'},
	max_memory_mib => int($caps->{'memory_kib'}/1024) - 256,
	cpu_limit => 0 + $doc->findvalue('/domain/vcpu'),
	memory_limit_mib => memory_kib($doc, 'memory') / 1024,
	live_limits => live_limits($domain, $doc),
	resource_locks => resource_locks($doc),
	running => $running, pending => \%pending,
	memory_mib => $memory->textContent() * $units{$unit} / 1024**2,
	description => $doc->findvalue('/domain/description'),
	history_revision => (delete_history($domain))[1],
	disks => \@disks, interfaces => \@interfaces,
	delete_force_blocked => !delete_can_force($domain,
		[map { $_->{'volume_info'} } grep { $_->{'volume_info'} && !$_->{'imported'} } @disks]) ? 1 : 0,
	pools => $pools, volumes => $volumes, attachable_volumes => \@attachable,
	images => \@images, networks => networks($adapter),
	bootmenu => $doc->findvalue('/domain/os/bootmenu/@enable') eq 'yes'
		? 1 : 0 };
}

# resource_locks(doc)
# Identifies fields tied to settings this editor does not rewrite.
sub resource_locks
{
my ($doc) = @_;
return {
	cpus => $doc->exists('/domain/vcpus') ? 1 : 0,
	cpu_limit => $doc->exists('/domain/cpu/topology | /domain/cpu/numa | '.
		'/domain/cputune | /domain/numatune | /domain/vcpus') ? 1 : 0,
	memory_mib => $doc->exists('/domain/devices/memory') ? 1 : 0,
	memory_limit_mib => $doc->exists('/domain/cpu/numa | /domain/numatune | '.
		'/domain/devices/memory | /domain/maxMemory') ? 1 : 0,
	};
}

# delete_can_force(domain, volumes)
# Returns true only when volumes covers every live and saved writable disk.
sub delete_can_force
{
my ($domain, $volumes) = @_;
my %selected = map { $_->{'identity'} => 1 } @$volumes;
# A live-only attachment also needs a clean shutdown if its data will be kept.
foreach my $flags (2, ($domain->is_active() ? (0) : ())) {
	my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description($flags));
	foreach my $disk ($doc->findnodes('/domain/devices/disk[source and not(readonly)]')) {
		# Unknown or unmanaged storage must be preserved through clean shutdown.
		my $path = $disk->findvalue('source/@file') || $disk->findvalue('source/@dev');
		my $identity = $path ? eval { file_identity($path) } : undef;
		my $included = $identity && $selected{$identity};
		$included ||= grep { $_->{'pool_name'} eq $disk->findvalue('source/@pool') &&
			$_->{'name'} eq $disk->findvalue('source/@volume') } @$volumes;
		return 0 if (!$included);
		}
	}
return 1;
}

# delete_history(domain)
# Returns snapshot/checkpoint XML and a stable revision for deletion preflight.
sub delete_history
{
my ($domain) = @_;
my @xml = sort map { $_->get_xml_description(0) }
	($domain->list_all_snapshots(0), $domain->list_all_checkpoints(0));
return (\@xml, sha256_hex(join("\0", @xml)));
}

# text(input, key, [default])
# Bounds scalar form fields and rejects control characters before XML use.
# An absent key uses default, or an empty string when no default is supplied.
sub text
{
my ($input, $key, $default) = @_;
my $value = exists($input->{$key}) ? $input->{$key} : $default // '';
die "Invalid $key\n" if (!defined($value) || ref($value) ||
	length($value) > 4096 || $value =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/);
return $value;
}

1;
