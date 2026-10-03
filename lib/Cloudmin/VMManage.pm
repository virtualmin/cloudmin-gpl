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

# check_nvram(adapter, domain)
# A copied VM definition must not cause deletion of another guest's variables.
sub check_nvram
{
my ($adapter, $domain) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(3));
my $path = $doc->findvalue('/domain/os/nvram/source/@file') ||
	$doc->findvalue('/domain/os/nvram/text()');
$path =~ s/^\s+|\s+$//g;
# BIOS guests have no firmware variable file to protect.
return if (!$path);
my $real = abs_path($path) || $path;
foreach my $other ($adapter->connect()->list_all_domains()) {
	# Compare other guests' live and persistent definitions, excluding this guest.
	next if ($other->get_uuid_string() eq $domain->get_uuid_string());
	my @xml = ($other->get_xml_description(0));
	push(@xml, $other->get_xml_description(2)) if ($other->is_persistent());
	foreach my $xml (@xml) {
		my $other_doc = Cloudmin::Libvirt::parse_xml_document($xml);
		my $ref = $other_doc->findvalue('/domain/os/nvram/source/@file') ||
			$other_doc->findvalue('/domain/os/nvram/text()');
		$ref =~ s/^\s+|\s+$//g;
		die "UEFI variables are shared with another virtual machine\n"
			if ($ref && (abs_path($ref) || $ref) eq $real);
		}
	}
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

# delete_volumes(self, adapter, domain, document, targets, history)
# Plans selected disks and their private history, keeping shared backing files.
# targets contains guest device names; history contains snapshot/checkpoint XML.
sub delete_volumes
{
my ($self, $adapter, $domain, $doc, $targets, $history) = @_;
my %targets = map { $_ => 1 } @$targets;
my (undef, $volumes) = $self->storage($adapter);
my (%selected, %required, @kept);
foreach my $target (@$targets) {
	# Explicitly selected current disks must be removable in their entirety.
	die "Invalid disk target\n" if (ref($target));
	my $v = $self->volume_for($adapter, disk_node($doc, $target));
	$selected{$v->{'key'}} = $v;
	$required{$v->{'key'}} = 1;
	}
my @xml = ($doc->toString(), @$history);
push(@xml, $domain->get_xml_description(0)) if ($domain->is_active());
# History includes inactive branches and revert files, not just current disks.
foreach my $xml (@xml) {
	my $tree = Cloudmin::Libvirt::parse_xml_document($xml);
	foreach my $disk ($tree->findnodes('/domain/devices/disk | '.
		'/domainsnapshot/domain/devices/disk | /domainsnapshot/inactiveDomain/devices/disk | '.
		'/domainsnapshot/disks/disk | /domainsnapshot/revertDisks/disk | '.
		'/domaincheckpoint/domain/devices/disk')) {
		my $target = $disk->findvalue('target/@dev') || $disk->getAttribute('name');
		my $xml = $disk->toString();
		if (!$targets{$target || ''}) {
			# Preserve whole chains for unchecked and historical-only devices.
			push(@kept, { xml => $xml, reason => 'Storage is needed by a disk you are keeping.' });
			next;
			}
		# Unknown historical files are kept and must retain their backing files.
		my ($source) = $disk->findnodes('source');
		if ($source && !grep { Cloudmin::Images::xml_uses_volume($source->toString(),
			@$_{qw(path pool_name name)}) } @$volumes) {
			push(@kept, { xml => $xml, reason => 'Storage is needed by an unmanaged snapshot disk.' });
			}
		foreach my $v (@$volumes) {
			# Match both source and backing
			# references for a selected device.
			$selected{$v->{'key'}} = $v if (Cloudmin::Images::xml_uses_volume($xml,
				@$v{qw(path pool_name name)}));
			}
		}
	}
my $refs = Cloudmin::Images::volume_references($adapter->connect(), $domain->get_uuid_string());
my %volume_xml = map { $_->{'key'} => $_ } grep { defined($_->{'key'}) } @$refs;
# Pool metadata supplies backing links even when domain XML omits the chain.
my @queue = values %selected;
while (my $v = shift(@queue)) {
	my $ref = $volume_xml{$v->{'key'}} || next;
	foreach my $base (@$volumes) {
		next if ($selected{$base->{'key'}});
		if (Cloudmin::Images::xml_uses_volume($ref->{'xml'},
			@$base{qw(path pool_name name)}, $ref->{'base'})) {
			# Follow each newly found base until the full
			# dependency chain is known.
			$selected{$base->{'key'}} = $base;
			push(@queue, $base);
			}
		}
	}
my $imports = $self->imported_file_ids($adapter);
# Remove shared bases from the plan, then protect their own dependencies too.
my $changed = 1;
while ($changed) {
	$changed = 0;
	my @foreign = (@kept, grep { !defined($_->{'key'}) || !$selected{$_->{'key'}} } @$refs);
	foreach my $v (values %selected) {
		# Reject protected selected disks; keep optional shared bases.
		my $reason = $imports->{$v->{'identity'}} ? 'Imported images cannot be deleted.' :
			Cloudmin::Images::volume_use(\@foreign, @$v{qw(path pool_name name key)});
		next if (!$reason);
		die "$reason\n" if ($required{$v->{'key'}});
		delete($selected{$v->{'key'}});
		$changed = 1;
		}
	}
# Delete children before their backing files so every intermediate state is valid.
my @ordered;
while (%selected) {
	my @remaining = map { $volume_xml{$_} } grep { $volume_xml{$_} } keys %selected;
	my @ready = grep { !Cloudmin::Images::volume_use(\@remaining,
		@$_{qw(path pool_name name key)}) } sort { $a->{'path'} cmp $b->{'path'} } values %selected;
	die "Cannot determine the snapshot disk deletion order\n" if (!@ready);
	push(@ordered, @ready);
	delete($selected{$_->{'key'}}) foreach @ready;
	}
$self->check_delete_volumes($adapter, \@ordered, $domain, $targets);
return \@ordered;
}

# check_delete_volumes(self, adapter, volumes, [domain], [targets])
# Rechecks the frozen plan, ignoring only dependencies removed by this same job.
# Omit domain after undefine; targets defaults to no removable attachments.
sub check_delete_volumes
{
my ($self, $adapter, $volumes, $domain, $targets) = @_;
return if (!@$volumes);
# Refresh file pools before checking for overlays created outside Cloudmin.
$self->storage($adapter);
my $excluded = $domain ? $domain->get_uuid_string() : undef;
my %keys = map { $_->{'key'} => 1 } @$volumes;
my @refs = grep { !defined($_->{'key'}) || !$keys{$_->{'key'}} }
	@{Cloudmin::Images::volume_references($adapter->connect(), $excluded)};
if ($domain) {
	# Live-only attachments can change without altering the saved XML revision.
	my %targets = map { $_ => 1 } @{$targets || []};
	foreach my $flags (2, ($domain->is_active() ? (0) : ())) {
		my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description($flags));
		foreach my $disk ($doc->findnodes('/domain/devices/disk[source]')) {
			my ($source) = $disk->findnodes('source');
			next if ($targets{$disk->findvalue('target/@dev')} &&
				grep { Cloudmin::Images::xml_uses_volume($source->toString(),
					@$_{qw(path pool_name name)}) } @$volumes);
			push(@refs, { xml => $disk->toString(), reason => 'Storage is needed by a disk you are keeping.' });
			}
		}
	}
foreach my $v (@$volumes) {
	my (undef, $volume) = $adapter->volume(@$v{qw(pool name key)});
	# After undefine, recovery can encounter layers already deleted by this job.
	next if (!$volume && !defined($excluded));
	$self->check_volume($adapter, $v, $excluded, \@refs);
	}
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

# set_text(parent, name, value, [attributes])
# Replaces one element's contents while preserving its unrelated attributes.
sub set_text
{
my ($parent, $name, $value, $attrs) = @_;
my ($node) = $parent->findnodes($name);
$node ||= $parent->addNewChild(undef, $name);
$node->removeChildNodes();
$node->appendText($value);
$node->setAttribute($_, $attrs->{$_}) foreach keys %{$attrs || {}};
return $node;
}

# audit_settings(xml)
# Selects editor-visible settings for audit comparisons. Private graphics,
# authentication, metadata and unrelated XML are deliberately excluded.
sub audit_settings
{
my ($xml) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
return { %{Cloudmin::Libvirt::resource_settings($doc)},
	description => $doc->findvalue('/domain/description'),
	disks => [ Cloudmin::Libvirt::extract_disks($xml) ],
	interfaces => [ Cloudmin::Libvirt::extract_interfaces($xml) ] };
}

# audit_changes(before_xml, after_xml)
# Reports only changed public settings, with their old and requested values.
sub audit_changes
{
my ($before_xml, $after_xml) = @_;
my $before = audit_settings($before_xml);
my $after = audit_settings($after_xml);
my %changes;
foreach my $key (keys %$after) {
	# Unchanged fields add noise, especially when a Save touches only one tab.
	next if (convert_to_json([$before->{$key}], 1) eq
		convert_to_json([$after->{$key}], 1));
	$changes{$key} = { before => $before->{$key}, after => $after->{$key} };
	}
return \%changes;
}

# disk_node(doc, target)
# Resolves an exact target without accepting XPath supplied by a client.
sub disk_node
{
my ($doc, $target) = @_;
my ($disk) = grep { $_->findvalue('target/@dev') eq $target }
	$doc->findnodes('/domain/devices/disk');
die "Disk is no longer attached\n" if (!$disk);
return $disk;
}

# volume_for(self, adapter, disk)
# Resolves attached disks and media in active managed file or LVM pools.
sub volume_for
{
my ($self, $adapter, $disk) = @_;
my (undef, $volumes) = $self->storage($adapter);
my ($volume) = grep {
	($_->{'path'} eq ($disk->findvalue('source/@file') || $disk->findvalue('source/@dev')) ||
	 ($_->{'block'} && $disk->findvalue('source/@dev') &&
	  (abs_path($_->{'path'}) || $_->{'path'}) eq (abs_path($disk->findvalue('source/@dev')) || ''))) ||
	($_->{'pool_name'} eq $disk->findvalue('source/@pool') &&
	 $_->{'name'} eq $disk->findvalue('source/@volume')) } @$volumes;
die "Only managed raw, QCOW2 or ISO volumes can be selected\n"
	if (!$volume);
return $volume;
}

# imported_file_ids(self, adapter)
# Protects aliases of imported disks without requiring unrelated pools to run.
sub imported_file_ids
{
my ($self, $adapter) = @_;
my %pools = map { $_->get_uuid_string() => $_ }
	$adapter->connect()->list_all_storage_pools();
my %identities;
foreach my $image (@{$self->{'images'}->list()}) {
	my $pool = $pools{$image->{'pool'} || ''};
	my @paths = ($image->{'volume_path'});
	# Resolve current storage identity when the import still names a volume.
	if ($pool && $image->{'volume'} && $image->{'volume_key'}) {
		# An active pool can verify the imported volume against libvirt metadata.
		if ($pool->is_active()) {
			my $inventory = $self->{'storage_cache'} && $self->{'storage_cache'}->{"$adapter"};
			if ($inventory) {
				# Reuse this validation's refreshed metadata without refreshing
				# the same pool once for every imported image.
				my ($source) = grep { $_->{'pool'} eq $image->{'pool'} &&
					$_->{'name'} eq $image->{'volume'} } @{$inventory->[1]};
				die "The selected volume has changed\n" if ($source && $source->{'key'} ne $image->{'volume_key'});
				$identities{file_identity($source->{'path'})} = 1 if ($source);
				}
			else {
				# Recovery without a validation cache still checks current identity.
				my (undef, $source) = $adapter->volume(@$image{qw(pool volume volume_key)});
				$identities{file_identity($source->get_path())} = 1 if ($source);
				}
			}
		else {
			# An inactive file pool can still alias a disk in an active pool.
			my ($type, $target) = Cloudmin::Libvirt::parse_pool_xml($pool->get_xml_description(0));
			push(@paths, "$target/$image->{volume}")
				if ($target && $type =~ /\A(?:dir|fs|netfs)\z/);
			}
		}
	foreach my $path (grep { defined($_) && length($_) } @paths) {
		$identities{file_identity($path)} = 1 if (-e $path || -l $path);
		}
	}
return \%identities;
}

# check_volume(self, adapter, record, [excluded_uuid], [references])
# Protects imported images, shared disks and backing files before mutation.
sub check_volume
{
my ($self, $adapter, $record, $excluded, $refs) = @_;
my ($pool, $volume) = $adapter->volume(@$record{qw(pool name key)});
die "Storage volume is missing\n" if (!$volume);
# Host use may have changed since the volume appeared in a disk picker.
Cloudmin::LVM::host_use($volume->record(1)) if ($volume->isa('Cloudmin::LVM::Volume'));
die "The storage volume was replaced; it was not changed\n" if
	($record->{'identity'} ne file_identity($volume->get_path()));
foreach my $image (@{$self->{'images'}->list()}) {
	# Images remain immutable even if someone attached one directly to a VM.
	die "Detach this imported image without deleting or resizing it\n"
		if (($image->{'pool'} || '') eq $record->{'pool'} &&
		($image->{'volume_key'} || '') eq $record->{'key'});
	}
# The same imported file can appear under another pool or hard link.
die "Detach this imported image without deleting or resizing it\n"
	if ($self->imported_file_ids($adapter)->{$record->{'identity'}});
if ($refs) {
	# A deletion plan supplies references excluding its own removable layers.
	my $reason = Cloudmin::Images::volume_use($refs, @$record{qw(path pool_name name key)});
	die "$reason\n" if ($reason);
	}
else {
	# Ordinary disk changes exclude only their
	# guest, never other volume users.
	Cloudmin::Images::assert_unused(undef, $adapter->connect(), $pool, $volume, $excluded);
	}
return ($pool, $volume);
}

# clone_source(self, adapter, image_id, [expected])
# Resolves a completed import and detects replacement before copying its bytes.
# expected is the source record saved at submission; omit it for the first read.
sub clone_source
{
my ($self, $adapter, $id, $expected) = @_;
my $image = $self->{'images'}->get($id);
die "Select a ready imported image\n" if ($image->{'state'} ne 'ready');
my (undef, $volume) = $adapter->volume(@$image{qw(pool volume volume_key)});
die "Source image volume is missing\n" if (!$volume || !$image->{'volume_key'});
my $format = Cloudmin::Libvirt::parse_xml_document(
	$volume->get_xml_description(0))->findvalue('/volume/target/format/@type');
# Check the import type too: ISO bytes can occupy a raw libvirt volume.
die "Only raw and QCOW2 images can be cloned\n"
	if ($format !~ /\A(?:raw|qcow2)\z/ || ($image->{'format'} || '') eq 'iso');
my $source = { id => $id, pool => $image->{'pool'}, volume => $image->{'volume'},
	volume_key => $volume->get_key(), identity => file_identity($volume->get_path()),
	capacity => $volume->get_info()->{'capacity'} };
if ($expected) {
	# A queued request must copy the exact file and capacity the user selected.
	foreach my $key (qw(pool volume volume_key identity capacity)) {
		die "Source image changed after submission\n" if ($source->{$key} ne $expected->{$key});
		}
	}
return ($source, $volume);
}

# prepare(self, action, input, job_id)
# Builds a private operation plan and checks the form's configuration revision.
sub prepare
{
my ($self, $action, $in, $job_id) = @_;
# Nested edits share one inventory only during this read-only validation pass.
local $self->{'storage_cache'} = $self->{'storage_cache'} || {};
my ($adapter, $domain, $doc, $revision) = $self->get_guest($in->{'id'});
require_editable($domain);
if ($action eq 'power_cycle') {
	# Power cycling applies the latest saved definition, without editing hardware.
	my ($state) = $domain->get_state();
	die "Resume the virtual machine before requesting a power cycle\n"
		if ($domain->is_active() && $state != 1 && $state != 2);
	return { operation => $action, uuid => $in->{'id'}, name => $domain->get_name(),
		revision => $revision, scope => 'config' };
	}
my $before = $doc->toString();
die "The virtual machine configuration changed; reload the page\n"
	if (text($in, 'revision') ne $revision);
my @changes;
if ($action eq 'update' && exists($in->{'changes'})) {
	# Validate every edit against one private XML document before any writes.
	my $changes = $in->{'changes'};
	die "Invalid hardware changes\n" if (ref($changes) ne 'ARRAY' ||
		@$changes > 128);
	my (%seen, %volumes, $index);
	foreach my $change (@$changes) {
		die "Invalid hardware change\n" if (ref($change) ne 'HASH');
		my $operation = text($change, 'action');
		die "Invalid hardware action\n" if ($operation !~
			/\A(?:grow_disk|detach_disk|attach_disk|add_disk|
			add_interface|update_interface|remove_interface|change_media)\z/x);
		my $target = $operation =~ /\A(?:(?:grow|detach)_disk|change_media)\z/
			? 'disk:'.text($change, 'target')
			: $operation =~ /\A(?:update|remove)_interface\z/
			? 'nic:'.lc(text($change, 'mac')) : '';
		die "A device was selected more than once\n"
			if ($target && $seen{$target}++);
		if ($operation eq 'grow_disk') {
			# Unchanged sizes need no exclusive disk access or resize operation.
			my $disk = disk_node($doc, text($change, 'target'));
			my $v = $self->volume_for($adapter, $disk);
			my $bytes = Cloudmin::VMs::size_bytes($change,
				'disk_gib', 1024**3, 'disk');
			next if (int(($bytes + 511)/512)*512 == $v->{'capacity'});
			}
		elsif ($operation eq 'update_interface') {
			# Preserve source options on interfaces whose network did not change.
			my ($nic) = grep { lc($_->findvalue('mac/@address')) eq
				lc(text($change, 'mac')) }
				$doc->findnodes('/domain/devices/interface');
			my ($network) = grep { $_->{'key'} eq text($change, 'network') }
				@{networks($adapter)};
			next if (!exists($change->{'link'}) && !exists($change->{'inbound_kib'}) &&
				!exists($change->{'outbound_kib'}) && $nic && $network &&
				$nic->getAttribute('type') eq $network->{'type'} &&
				$nic->findvalue('source/@'.$network->{'type'}) eq
				$network->{'source'});
			}
		# Each new device gets a stable, distinct identity for job recovery.
		my $step_id = substr(sha256_hex($job_id.':'.++$index), 0, 32);
		my $step = $self->prepare_change($operation, $change, $step_id,
			$adapter, $domain, $doc, $revision);
		# Aliases in different pools must not select the same file twice.
		my $volume = $step->{'attach_volume'} || $step->{'volume'};
		die "A storage file was selected more than once\n"
			if ($volume && $volumes{$volume->{'identity'}}++);
		delete($step->{'xml'});
		push(@changes, $step);
		}
	}
# Resources and boot order are checked against the final set of devices.
my $plan = $self->prepare_change($action, $in, $job_id,
	$adapter, $domain, $doc, $revision);
$plan->{'changes'} = \@changes if (@changes);
$plan->{'before_xml'} = $before;
prepare_hotplug($plan);
require_editable($domain, $plan);
# Confirmed deletion may stop the guest before using the offline removal path.
if ($action eq 'delete' && $plan->{'shutdown'}) {
	$plan->{'scope'} = 'config';
	return $plan;
	}
$plan->{'scope'} = $domain->is_active() ? 'live' : 'config';
if ($domain->is_active()) {
	# Preserve immediate refusal for destructive actions on a running guest.
	require_stopped($domain) if ($action =~ /\A(?:delete|delete_disk)\z/);
	$plan->{'scope'} = 'offline-required' if (hotplug_reason($domain, $plan));
	if ($plan->{'scope'} eq 'live') {
		# Publish whether this plan has live work
		# or only next-start settings.
		validate_hotplug($domain, $plan);
		my $ops = hotplug_operations($domain, $plan);
		$plan->{'scope'} = 'config' if (!grep { $_->{'kind'} ne 'next_start' } @$ops);
		$plan->{'deferred_fields'} = [map { @{$_->{'fields'}} } grep { $_->{'kind'} eq 'next_start' } @$ops];
		}
	}
return $plan;
}

# prepare_change(self, action, input, job_id, adapter, domain, doc, revision)
# Edits the private document and records storage work without changing the host.
sub prepare_change
{
my ($self, $action, $in, $job_id, $adapter, $domain, $doc, $revision) = @_;
my $root = $doc->documentElement();
my $plan = { operation => $action, uuid => $domain->get_uuid_string(),
	name => $domain->get_name(), revision => $revision };
if ($action eq 'update') {
	# Validate requested allocations before checking their existing layout.
	my $caps = $adapter->get_host_capabilities();
	my $cpus = text($in, 'cpus');
	die "Enter a whole CPU count from 1 to $caps->{cpus}\n"
		if ($cpus !~ /\A[1-9][0-9]{0,4}\z/ || $cpus > $caps->{'cpus'});
	my $memory = Cloudmin::VMs::size_bytes($in, 'memory_mib',
		1024**2, 'memory') / 1024**2;
	die "Select whole MiB, at least 256 MiB, leaving 256 MiB for the host\n"
		if ($memory != int($memory) || $memory < 256 ||
		$memory > $caps->{'memory_kib'}/1024 - 256);
	my $old_limit = 0 + $doc->findvalue('/domain/vcpu');
	# Existing API callers may omit maximums;
	# retain or raise them as needed.
	my $old_cpus = $doc->findvalue('/domain/vcpu/@current') || $old_limit;
	my $limit = text($in, 'cpu_limit', $cpus > $old_limit ? $cpus : $old_limit);
	die "Select a CPU maximum between the current count and $caps->{cpus}\n"
		if ($limit !~ /\A[1-9][0-9]*\z/ || $limit < $cpus || $limit > $caps->{'cpus'});
	my $old_memory = memory_kib($doc, 'memory') / 1024;
	my $memory_limit = exists($in->{'memory_limit_mib'})
		? Cloudmin::VMs::size_bytes($in, 'memory_limit_mib', 1024**2, 'maximum memory') / 1024**2
		: $memory > $old_memory ? $memory : $old_memory;
	die "Select a whole MiB memory maximum covering the current allocation and leaving 256 MiB for the host\n"
		if ($memory_limit != int($memory_limit) || $memory_limit < $memory ||
		$memory_limit > $caps->{'memory_kib'}/1024 - 256);
	my $old_current = memory_kib($doc, 'currentMemory') / 1024;
	my $locks = resource_locks($doc);
	# Preserve topology and pinning when changing only the enabled CPU count.
	die "The CPU maximum is fixed by the existing CPU layout\n"
		if ($locks->{'cpu_limit'} && $limit != $old_limit);
	die "The CPU count is controlled by individual CPU settings\n"
		if ($locks->{'cpus'} && $cpus != $old_cpus);
	die "The memory maximum is fixed by the existing NUMA or memory-device layout\n"
		if ($locks->{'memory_limit_mib'} && $memory_limit != $old_memory);
	die "Memory allocation is controlled by the configured memory devices\n"
		if ($locks->{'memory_mib'} && $memory != $old_current);
	# An unrelated save leaves resource elements and their attributes intact.
	if ($limit != $old_limit || $cpus != $old_cpus) {
		my $vcpu = set_text($root, 'vcpu', $limit);
		$vcpu->setAttribute('current', $cpus);
		}
	if ($memory_limit != $old_memory || $memory != $old_current) {
		# Change allocation and maximum together in
		# a single, consistent unit.
		set_text($root, 'memory', $memory_limit, { unit => 'MiB' });
		set_text($root, 'currentMemory', $memory, { unit => 'MiB' });
		}
	# Omitted descriptions retain the saved text for API resource-only edits.
	set_text($root, 'description', text($in, 'description')) if (exists($in->{'description'}));
	my ($os) = $doc->findnodes('/domain/os');
	my $boot = text($in, 'boot');
	if (length($boot)) {
		# One explicit first device replaces both forms of libvirt boot order.
		my ($device) = grep {
			($_->nodeName() eq 'disk'
			 ? 'disk:'.$_->findvalue('target/@dev')
			 : 'nic:'.$_->findvalue('mac/@address')) eq $boot }
			$doc->findnodes('/domain/devices/disk | /domain/devices/interface');
		die "Select an attached boot device\n" if (!$device);
		$_->unbindNode() foreach $doc->findnodes(
			'/domain/os/boot | /domain/devices/*/boot');
		$device->addNewChild(undef, 'boot')->setAttribute('order', 1);
		}
	my $menu = text($in, 'bootmenu', $doc->findvalue('/domain/os/bootmenu/@enable') eq 'yes' ? 1 : 0);
	die "Invalid boot menu setting\n" if ($menu !~ /\A[01]\z/);
	set_text($os, 'bootmenu', '', { enable => $menu ? 'yes' : 'no' });
	if (text($in, 'enable_live', 0)) {
		# Existing guests gain ports and a CD drive only during an offline edit.
		Cloudmin::VMs::add_hardware_headroom($doc,
			$locks->{'cpu_limit'} ? $limit :
			$cpus * 2 < $caps->{'cpus'} ? $cpus * 2 : $caps->{'cpus'});
		$plan->{'offline_reason'} = 'Shut down the virtual machine to add hardware headroom';
		}
	}
elsif ($action eq 'delete') {
	# API callers must explicitly allow shutdown; the confirmation form does so.
	my $shutdown = text($in, 'shutdown', '0');
	die "Invalid shutdown option\n" if ($shutdown !~ /\A[01]\z/);
	$plan->{'shutdown'} = 0 + $shutdown;
	# Verify firmware storage ownership before planning guest deletion.
	check_nvram($adapter, $domain);
	# Explicit disk targets make keeping data the default for API callers.
	die "Type the virtual machine name to confirm deletion\n"
		if (text($in, 'confirm_name') ne $plan->{'name'});
	my $targets = $in->{'disks'} // [];
	$targets = [ grep { length } split(/\0|,/, $targets) ]
		if (!ref($targets));
	die "Invalid disk selection\n" if (ref($targets) ne 'ARRAY');
	my ($history, $history_revision) = delete_history($domain);
	# Native snapshot storage must be removed through its journal, not VM deletion.
	die "Delete the LVM snapshots before deleting this virtual machine\n"
		if (grep { /snapshot=["']manual["']/ } @$history);
	# Reject history changed since the confirmation
	# page, including old branches.
	die "The snapshot or backup history changed; reload the deletion page\n"
		if (exists($in->{'history_revision'}) && text($in, 'history_revision') ne $history_revision);
	$plan->{'history_revision'} = $history_revision;
	$plan->{'delete_targets'} = $targets;
	$plan->{'volumes'} = $self->delete_volumes($adapter, $domain, $doc, $targets, $history);
	$plan->{'creation_job'} = Cloudmin::Libvirt::extract_metadata(
		$doc->toString())->{'job'};
	return $plan;
	}
elsif ($action eq 'grow_disk') {
	# Grow only an exclusive writable disk; guest filesystems are separate.
	my $disk = disk_node($doc, text($in, 'target'));
	die "Only writable disks can be grown\n" if ($disk->findnodes('readonly') ||
		$disk->getAttribute('device') ne 'disk');
	my $v = $self->volume_for($adapter, $disk);
	die "Only raw and QCOW2 disks can be grown\n"
		if ($v->{'format'} !~ /\A(?:raw|qcow2)\z/);
	my ($pool, $volume) = $self->check_volume($adapter, $v, $plan->{'uuid'});
	my $bytes = Cloudmin::VMs::size_bytes($in, 'disk_gib', 1024**3, 'disk');
	$bytes = int(($bytes + 511)/512)*512;
	$bytes = $pool->aligned_capacity($bytes) if ($pool->isa('Cloudmin::LVM::Pool'));
	die "The new disk size must be larger than its current capacity\n"
		if ($bytes <= $volume->get_info()->{'capacity'});
	die "The pool lacks space for this disk growth\n"
		if (!($pool->isa('Cloudmin::LVM::Pool') && $pool->{'thin'}) &&
			$bytes - $v->{'capacity'} > $pool->get_info()->{'available'});
	$plan->{'volume'} = $v;
	$plan->{'bytes'} = $bytes;
	$plan->{'target'} = text($in, 'target');
	return $plan;
	}
elsif ($action eq 'detach_disk') {
	# Detaching changes the saved definition and never removes storage.
	disk_node($doc, text($in, 'target'))->unbindNode();
	}
elsif ($action eq 'delete_disk') {
	# Delete one confirmed volume only after removing its saved attachment.
	my $disk = disk_node($doc, text($in, 'target'));
	my $v = $self->volume_for($adapter, $disk);
	$self->check_volume($adapter, $v, $plan->{'uuid'});
	$disk->unbindNode();
	# Excluding this guest from shared-use checks must not hide another
	# attachment or backing reference in the same guest.
	die "This disk is still used by another device in the virtual machine\n"
		if (Cloudmin::Images::xml_uses_volume($doc->toString(),
			@$v{qw(path pool_name name)}));
	$plan->{'volumes'} = [$v];
	}
# Prepare the attachment and reserve either an existing or a new disk.
elsif ($action eq 'attach_disk' || $action eq 'add_disk') {
	my $v;
	if ($action eq 'attach_disk') {
		# Existing disks are selected by pool and name, never arbitrary paths.
		my (undef, $volumes) = $self->storage($adapter);
		($v) = grep { $_->{'pool'} eq text($in, 'pool') &&
			$_->{'name'} eq text($in, 'volume') &&
			$_->{'format'} =~ /\A(?:raw|qcow2)\z/ } @$volumes;
		die "Select an available storage volume\n" if (!$v);
		$self->check_volume($adapter, $v);
		$plan->{'attach_volume'} = $v;
		}
	else {
		# New disks are QCOW2 files or raw LVs, empty or independently cloned.
		my ($pools) = $self->storage($adapter);
		my ($choice) = grep { $_->{'id'} eq text($in, 'pool') } @$pools;
		die "Select an active storage pool\n" if (!$choice);
		my $pool = Cloudmin::Libvirt::storage_pool($adapter, $choice->{'id'});
		my (undef, $path) = Cloudmin::Libvirt::parse_pool_xml($pool->get_xml_description(0));
		my $source;
		if (length(text($in, 'image'))) {
			# Only imported images are clone sources; ordinary disks use Attach.
			($source) = $self->clone_source($adapter, text($in, 'image'));
			$plan->{'source_image'} = $source;
			}
		my $bytes = $source && !length(text($in, 'disk_gib'))
			? $source->{'capacity'}
			: Cloudmin::VMs::size_bytes($in, 'disk_gib', 1024**3, 'disk');
		die "The disk cannot be smaller than its source image\n"
			if ($source && $bytes < $source->{'capacity'});
		$bytes = int(($bytes + 511)/512)*512;
		$bytes = $pool->aligned_capacity($bytes) if ($pool->isa('Cloudmin::LVM::Pool'));
		die "The pool lacks space for this disk\n"
			if (($choice->{'type'} || '') ne 'lvmthin' && $bytes > $pool->get_info()->{'available'});
		my $name = Cloudmin::VMs::disk_volume_name($domain->get_name(), 'data', $job_id, $choice->{'type'});
		die "Destination disk already exists\n"
			if (grep { $_->get_name() eq $name } $pool->list_all_volumes());
		$v = $plan->{'new_volume'} = { pool => $choice->{'id'},
			name => $name, path => $pool->isa('Cloudmin::LVM::Pool') ?
				Cloudmin::LVM::device_path($pool->{'vg'}, $name) : "$path/$name",
			format => Cloudmin::Libvirt::block_pool($pool) ? 'raw' : 'qcow2',
			block => Cloudmin::Libvirt::block_pool($pool) ? 1 : 0,
			capacity => $bytes };
		}
	# Choose an unused virtio target for either kind of attached disk.
	my %targets = map { $_->getValue() => 1 }
		$doc->findnodes('/domain/devices/disk/target/@dev');
	my ($target) = grep { !$targets{$_} } map { 'vd'.$_ } 'a'..'z';
	die "No free virtio disk target\n" if (!$target);
	my ($devices) = $doc->findnodes('/domain/devices');
	my $disk = $devices->addNewChild(undef, 'disk');
	$disk->setAttribute('type', $v->{'block'} ? 'block' : 'file');
	$disk->setAttribute('device', 'disk');
	set_text($disk, 'driver', '', { name => 'qemu', type => $v->{'format'},
		($v->{'block'} ? (cache => 'none') : ()) });
	set_text($disk, 'source', '', { ($v->{'block'} ? 'dev' : 'file') => $v->{'path'} });
	set_text($disk, 'target', '', { dev => $target, bus => 'virtio' });
	}
elsif ($action eq 'change_media') {
	# Select managed ISO media by pool/name; never accept a client filesystem path.
	my $disk = disk_node($doc, text($in, 'target'));
	die "Select an existing CD drive\n" if ($disk->getAttribute('device') ne 'cdrom');
	my $volume = text($in, 'volume');
	$_->unbindNode() foreach $disk->findnodes('source | backingStore');
	if (length($volume)) {
		# A nonempty selection inserts a pool ISO;
		# empty leaves the drive ejected.
		my (undef, $volumes) = $self->storage($adapter);
		my ($media) = grep { $_->{'pool'} eq text($in, 'pool') && $_->{'name'} eq $volume &&
			($_->{'format'} eq 'iso' || $_->{'format'} eq 'raw' && $_->{'name'} =~ /\.iso\z/i) } @$volumes;
		die "Select ISO media from an active storage pool\n" if (!$media);
		set_text($disk, 'source', '', { file => $media->{'path'} });
		$plan->{'media'} = $media;
		}
	$disk->setAttribute('type', 'file');
	# Removable media uses a read-only raw source
	# even when the drive was empty.
	set_text($disk, 'driver', '', { name => 'qemu', type => 'raw' });
	set_text($disk, 'readonly', '');
	my ($target) = $disk->findnodes('target');
	$target->removeAttribute('tray');
	}
elsif ($action =~ /\A(?:add_interface|update_interface|remove_interface)\z/) {
	# Resolve an existing interface by its stable MAC address.
	my $mac = lc(text($in, 'mac'));
	my ($nic) = grep { lc($_->findvalue('mac/@address')) eq $mac }
		$doc->findnodes('/domain/devices/interface');
	if ($action eq 'remove_interface') {
		# The guest OS keeps its own network configuration after detachment.
		die "Network interface is no longer attached\n" if (!$nic);
		$nic->unbindNode();
		}
	else {
		# Networks and bridges must be present on this host at submission.
		my $key = text($in, 'network');
		if (!$key && $nic) {
			# Link and bandwidth edits retain the existing network attachment.
			my ($existing) = grep { $_->{'type'} eq $nic->getAttribute('type') &&
				$_->{'source'} eq $nic->findvalue('source/@'.$_->{'type'}) } @{networks($adapter)};
			$key = $existing->{'key'} if ($existing);
			}
		my ($network) = grep { $_->{'key'} eq $key }
			@{networks($adapter)};
		die "Select an active network or host bridge\n" if (!$network);
		$plan->{'network'} = $network->{'key'};
		if ($action eq 'add_interface') {
			# A generated unicast address is persisted in the job for retries.
			$mac ||= '52:54:00:'.join(':',
				unpack('(A2)3', substr($job_id, 0, 6)));
			die "Enter a unicast MAC address\n" if (
				$mac !~ /\A(?:[a-f0-9]{2}:){5}[a-f0-9]{2}\z/ ||
				(hex(substr($mac, 0, 2)) & 1) || $mac eq '00:00:00:00:00:00');
			die "This MAC address is already in use\n" if
				(grep { lc($_->findvalue('mac/@address')) eq $mac }
				$doc->findnodes('/domain/devices/interface'));
			foreach my $vm (@{$adapter->list_domains(1)}) {
				die "This MAC address is already in use\n"
					if (grep { lc($_) eq $mac } @{$vm->{'macs'}});
				}
			$plan->{'mac'} = $mac;
			my ($devices) = $doc->findnodes('/domain/devices');
			$nic = $devices->addNewChild(undef, 'interface');
			set_text($nic, 'mac', '', { address => $mac });
			set_text($nic, 'model', '', { type => 'virtio' });
			}
		else {
			# Preserve the existing MAC, model, PCI address and filter policy.
			die "Network interface is no longer attached\n" if (!$nic);
			die "Only network and bridge interfaces can be changed here\n"
				if ($nic->getAttribute('type') !~ /\A(?:network|bridge)\z/);
			}
		if (($nic->getAttribute('type') || '') ne $network->{'type'} ||
			$nic->findvalue('source/@'.$network->{'type'}) ne $network->{'source'}) {
			# Preserve source attributes unless the
			# network or bridge changes.
			$nic->setAttribute('type', $network->{'type'});
			$_->unbindNode() foreach $nic->findnodes('source');
			set_text($nic, 'source', '', { $network->{'type'} => $network->{'source'} });
			}
		if (exists($in->{'link'})) {
			# An omitted link state preserves the
			# existing virtual cable state.
			my $link = text($in, 'link');
			die "Select connected or disconnected network link\n" if ($link !~ /\A(?:up|down)\z/);
			set_text($nic, 'link', '', { state => $link });
			}
		foreach my $direction (qw(inbound outbound)) {
			# Omitted limits stay intact; a blank
			# submitted limit means unlimited.
			next if (!exists($in->{$direction.'_kib'}));
			my $rate = text($in, $direction.'_kib', 0);
			$rate = 0 if ($rate eq '');
			die "Enter a whole bandwidth limit in KiB/s, or 0 for unlimited\n"
				if ($rate !~ /\A[0-9]{1,9}\z/);
			my ($bandwidth) = $nic->findnodes('bandwidth');
			# Unchanged form values preserve externally configured peak/burst limits.
			next if ($rate == ($nic->findvalue('bandwidth/'.$direction.'/@average') || 0));
			$bandwidth ||= $nic->addNewChild(undef, 'bandwidth');
			if ($rate) {
				# A changed average replaces that
				# direction's full rate specification.
				set_text($bandwidth, $direction, '', { average => $rate });
				}
			else {
				# Remove the direction's limit while
				# retaining the opposite direction.
				$_->unbindNode() foreach $bandwidth->findnodes($direction);
				}
			}
		}
	}
else {
	# Reject actions without a validated configuration plan.
	die "Unknown virtual machine management action\n";
	}
# A private marker distinguishes a completed define from an interrupted worker.
my ($metadata) = $doc->findnodes('/domain/metadata');
$metadata ||= $root->addNewChild(undef, 'metadata');
my ($marker) = $metadata->findnodes('*[namespace-uri()="urn:cloudmin:change:1"]');
$marker->unbindNode() if ($marker);
$marker = $metadata->addNewChild('urn:cloudmin:change:1', 'change');
$marker->appendText($job_id);
$plan->{'xml'} = $doc->toString();
return $plan;
}

# check_step(self, adapter, step, job)
# Revalidates a planned edit and returns its pool and remaining space demand.
sub check_step
{
my ($self, $adapter, $step, $job) = @_;
if (my $media = $step->{'media'}) {
	# Shared read-only media are allowed, but a replaced file is not.
	my (undef, $volume) = $adapter->volume(@$media{qw(pool name key)});
	die "The selected ISO media changed or was removed\n" if (!$volume ||
		file_identity($volume->get_path()) ne $media->{'identity'});
	}
if ($step->{'mac'}) {
	# Another guest may have claimed a generated address while this job waited.
	foreach my $vm (@{$adapter->list_domains(1)}) {
		die "This MAC address is already in use\n"
			if (grep { lc($_) eq $step->{'mac'} } @{$vm->{'macs'}});
		}
	}
$self->check_volume($adapter, $step->{'attach_volume'})
	if ($step->{'attach_volume'});
die "The selected network is no longer available\n" if ($step->{'network'} &&
	!grep { $_->{'key'} eq $step->{'network'} } @{networks($adapter)});
if ($step->{'new_volume'}) {
	# Reuse an allocated disk only after its file identity was journalled.
	my $v = $step->{'new_volume'};
	my ($pool, $volume) = $adapter->volume($v->{'pool'}, $v->{'name'});
	if ($volume) {
		# An existing destination must belong to this job before reuse.
		my $saved = $job->{'resources'}->{'new_volumes'}->{$v->{'name'}};
		die "An unrecorded disk remains at $v->{path}; inspect it before recovery\n"
			if (!$saved || $saved->{'key'} ne $volume->get_key());
		$self->check_volume($adapter, $saved);
		return ($pool, 0);
		}
	$self->clone_source($adapter, $step->{'source_image'}->{'id'}, $step->{'source_image'})
		if ($step->{'source_image'});
	return ($pool, $v->{'capacity'});
	}
if ($step->{'operation'} eq 'grow_disk') {
	# A replay may see the original capacity or the completed target capacity.
	my ($pool, $v) = $self->check_volume($adapter,
		$step->{'volume'}, $step->{'uuid'});
	my $capacity = $v->get_info()->{'capacity'};
	die "Disk capacity changed since submission\n" if
		($capacity != $step->{'volume'}->{'capacity'} &&
		 $capacity != $step->{'bytes'});
	return ($pool, $step->{'bytes'} - $capacity);
	}
return;
}

# apply_storage(self, adapter, step, job_id)
# Allocates or grows a disk; retries reuse its journalled identity and size.
sub apply_storage
{
my ($self, $adapter, $step, $id) = @_;
# Allocate new storage once, reusing a volume retained by an interrupted job.
if ($step->{'new_volume'}) {
	my $v = $step->{'new_volume'};
	my ($pool, $volume) = $adapter->volume($v->{'pool'}, $v->{'name'});
	if (!$volume) {
		# Record the allocated file before attempting to attach it to the VM.
		my $x = \&Cloudmin::Libvirt::xml_escape;
		my $xml = '<volume><name>'.$x->($v->{'name'}).
			'</name><capacity unit="bytes">'.$v->{'capacity'}.
			'</capacity><allocation>0</allocation><target>'.
			'<format type="'.($v->{'format'} || 'qcow2').'"/></target></volume>';
		# allocate([original]) journals the new volume before resize or attachment.
		my $allocate = sub {
			my ($original) = @_;
			Cloudmin::Libvirt::log_call($original
				? 'Sys::Virt::StoragePool::clone_volume'
				: 'Sys::Virt::StoragePool::create_volume', {
				pool => $v->{'pool'}, volume => $v->{'name'},
				capacity_bytes => $v->{'capacity'}, format => 'qcow2',
				flags => 0, ($original ? (
					source_volume => $step->{'source_image'}->{'volume'},
					source_pool => $step->{'source_image'}->{'pool'}) : ()) });
			if (Cloudmin::Libvirt::block_pool($pool) && $original) {
				# An imported file needs worker conversion before its bytes reach an LV.
				$adapter->clone_disk($v->{'pool'}, $v->{'name'}, $step->{'source_image'},
					$v->{'capacity'}, 'raw', sub { });
				(undef, $volume) = $adapter->volume($v->{'pool'}, $v->{'name'});
				}
			else {
				# Native file cloning and empty-disk allocation use the pool API.
				$volume = $original ? $pool->clone_volume($xml, $original, 0)
					: $pool->create_volume($xml, 0);
				}
			die "The new volume has an unexpected path\n"
				if ($volume->get_path() ne $v->{'path'});
			$self->{'jobs'}->update($id, sub {
				$_[0]->{'resources'}->{'new_volumes'}->{$v->{'name'}} = {
					%$v, key => $volume->get_key(),
					identity => file_identity($volume->get_path()) };
				});
			};
		if (my $source = $step->{'source_image'}) {
			# Share creation's image lock so deletion cannot race the full copy.
			$self->{'images'}->with_lock($self->{'images'}->path($source->{'id'}, 'json'), 0, sub {
				my (undef, $original) = $self->clone_source($adapter, $source->{'id'}, $source);
				$allocate->($original);
				});
			}
		else {
			# Empty disks allocate no guest data until the guest writes to them.
			$allocate->();
			}
		}
	my $capacity = $volume->get_info()->{'capacity'};
	# Extend a clone when its driver retained the smaller source capacity.
	if ($capacity < $v->{'capacity'}) {
		Cloudmin::Libvirt::log_call('Sys::Virt::StorageVol::resize', {
			pool => $v->{'pool'}, volume => $v->{'name'},
			before_bytes => $capacity,
			after_bytes => $v->{'capacity'}, flags => 0 });
		$volume->resize($v->{'capacity'}, 0);
		}
	}
elsif ($step->{'operation'} eq 'grow_disk') {
	# Replaying completed growth never resizes twice or shrinks a disk.
	my (undef, $v) = $self->check_volume($adapter,
		$step->{'volume'}, $step->{'uuid'});
	my $capacity = $v->get_info()->{'capacity'};
	# Retry unfinished allocation or zeroing, without repeating completed growth.
	if ($capacity < $step->{'bytes'} || $v->isa('Cloudmin::LVM::Volume') && $v->initialization_pending()) {
		# QEMU may have started since preflight; offline growth needs stopped I/O.
		my $domain = $adapter->find_domain($step->{'uuid'});
		require_stopped($domain) if ($domain);
		require_editable($domain, $step) if ($domain);
		Cloudmin::Libvirt::log_call('Sys::Virt::StorageVol::resize', {
			pool => $step->{'volume'}->{'pool'}, volume => $step->{'volume'}->{'name'},
			before_bytes => $capacity,
			after_bytes => $step->{'bytes'}, flags => 0 });
		$v->resize($step->{'bytes'}, 0);
		}
	}
}

# run_shutdown(self, id, domain, [force])
# Stops the guest; clean shutdown retains its deadline across worker recovery.
# force defaults to false; callers must first verify discarded writable disks.
# Returns false when cancellation wins before the first power operation.
sub run_shutdown
{
my ($self, $id, $domain, $force) = @_;
my $jobs = $self->{'jobs'};
my $job = $jobs->get($id);
my $resources = $job->{'resources'};
my $phase = $job->{'request'}->{'operation'}.($force ? '_power_off' : '_shutdown');
if (!$resources->{'shutdown_complete'}) {
	# Recovery skips an already confirmed stop,
	# avoiding a second shutdown request.
	my ($state) = $domain->get_state();
	die "Resume the virtual machine before requesting a clean shutdown\n"
		if (!$force && $domain->is_active() && $state != 1 && $state != 2 && $state != 4);
	$job = $jobs->update($id, sub {
		# Cancellation and the first power change compete under the job lock.
		if ($_[0]->{'cancel'} && !$_[0]->{'resources'}->{'started'}) {
			$_[0]->{'state'} = 'cancelled';
			return;
			}
		$_[0]->{'state'} = 'running';
		$_[0]->{'resources'}->{'started'} = 1;
		$_[0]->{'phase'} = $phase;
		$_[0]->{'resources'}->{'stop_phase'} = $phase;
		$_[0]->{'events'} = [{ step => $phase, state => 'running' }];
		});
	return if ($job->{'state'} eq 'cancelled');
	if ($force && $domain->is_active()) {
		# The deletion plan retains no writable disks, so no guest wait is needed.
		Cloudmin::Libvirt::log_call('Sys::Virt::Domain::destroy', { uuid => $job->{'request'}->{'uuid'} });
		$domain->destroy();
		require_stopped($domain);
		}
	elsif ($domain->is_active() && !$resources->{'shutdown_deadline'}) {
		# Persist the deadline before the request; recovery never extends it.
		$job = $jobs->update($id, sub {
			$_[0]->{'resources'}->{'shutdown_deadline'} = time()+($self->{'shutdown_timeout'} // 120);
			});
		Cloudmin::Libvirt::log_call('Sys::Virt::Domain::shutdown', { uuid => $job->{'request'}->{'uuid'} });
		$domain->shutdown();
		}
	while ($domain->is_active()) {
		# Wait within the persisted deadline; expiry
		# never escalates to force-off.
		die "The virtual machine did not shut down within two minutes. It may still finish shutting down; check its power state. No forced power-off was attempted\n"
			if (time() >= $job->{'resources'}->{'shutdown_deadline'});
		sleep(1);
		}
	# Do not continue after a crash or forced stop during the shutdown wait.
	my ($stopped, $reason) = $domain->get_state();
	die "The virtual machine stopped without a clean shutdown. Check its state before retrying\n"
		if ($stopped != 5 || (!$force && $job->{'resources'}->{'shutdown_deadline'} && $reason != 1));
	$job = $jobs->update($id, sub {
		$_[0]->{'resources'}->{'shutdown_complete'} = 1;
		$_[0]->{'events'}->[0]->{'state'} = 'done';
		});
	}
return 1;
}

1;
