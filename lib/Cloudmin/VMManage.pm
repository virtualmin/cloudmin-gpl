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

1;
