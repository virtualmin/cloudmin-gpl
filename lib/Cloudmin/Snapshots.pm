package Cloudmin::Snapshots;

# Disk snapshots use libvirt's tree and the existing durable VM job journal.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/VMManage.pm');

# new(class, jobs => store, images => store, adapter => factory, [readonly => bool])
# Shares VM locks, immutable-image protection and per-user job history.
sub new
{
my ($class, %options) = @_;
return bless(\%options, $class);
}

# manager(self)
# Reuses managed-volume and guest identity checks without the no-snapshots rule.
sub manager
{
my ($self) = @_;
return Cloudmin::VMManage->new(%$self);
}

# record(self, domain, snapshot, [size_cache])
# Exposes safe display fields; ownership requires the original creation journal.
sub record
{
my ($self, $domain, $snapshot, $size_cache) = @_;
# Trust display labels and preparation mode only when the journal owns the snapshot.
my $xml = $snapshot->get_xml_description(0);
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
my $name = $snapshot->get_name();
my $job = $name =~ /\Acloudmin-([a-f0-9]{32})\z/ ? $self->{'jobs'}->get($1) : undef;
my $r = $job ? $job->{'request'} : {};
my $owned = ($r->{'operation'} || '') eq 'snapshot_create' &&
	($r->{'uuid'} || '') eq $domain->get_uuid_string() &&
	($r->{'snapshot'} || '') eq $name;
return { id => $name, uuid => $domain->get_uuid_string(), vm => $domain->get_name(),
	label => $owned ? $r->{'label'} : $name,
	description => $doc->findvalue('/domainsnapshot/description'),
	created => 0+$doc->findvalue('/domainsnapshot/creationTime'),
	state => $doc->findvalue('/domainsnapshot/state'),
	parent => $doc->findvalue('/domainsnapshot/parent/name'),
	current => $snapshot->is_current() ? 1 : 0, managed => $owned ? 1 : 0,
	mode => $owned ? $r->{'mode'} : 'external', native_lvm => $owned && $r->{'native_lvm'} ? 1 : 0,
	pending => $doc->exists('//snapshotDeleteInProgress') ? 1 : 0,
	disks => 0+$doc->findvalue('count(/domainsnapshot/disks/disk[@snapshot="external" or @snapshot="manual"])'),
	(defined($size_cache) ? (allocation => disk_allocation($doc, $size_cache)) : ()),
	revision => sha256_hex($xml) };
}

# disk_allocation(document, cache)
# Reads allocated blocks in saved disk files without opening or scanning images.
# Shared backing files are excluded; deletion may merge these blocks elsewhere.
sub disk_allocation
{
my ($doc, $cache) = @_;
my @external = $doc->findnodes('/domainsnapshot/disks/disk[@snapshot="external"]');
return undef if (!@external);
my %disks = map { $_->findvalue('target/@dev') => $_ }
	$doc->findnodes('/domainsnapshot/domain/devices/disk');
my ($total, %seen) = (0);
foreach my $external (@external) {
	# The snapshot domain holds the saved files; /disks holds later write layers.
	my $disk = $disks{$external->getAttribute('name')};
	return undef if (!$disk || $disk->getAttribute('type') ne 'file');
	my $path = $disk->findvalue('source/@file');
	return undef if (!$path);
	if (!exists($cache->{$path})) {
		# Cache missing files as well, and never substitute apparent file length.
		my @stat = stat($path);
		$cache->{$path} = @stat && -f _ && defined($stat[12]) ?
			{ identity => "$stat[0]:$stat[1]", bytes => $stat[12]*512 } : undef;
		}
	my $size = $cache->{$path};
	return undef if (!$size);
	$total += $size->{'bytes'} if (!$seen{$size->{'identity'}}++);
	}
return $total;
}

# revision(domain, [offline])
# Binds forms to current state; offline omits power state for planned shutdowns.
sub revision
{
my ($domain, $offline) = @_;
my $live = '';
if (!$offline && $domain->is_active()) {
	# Status collection changes only the live balloon sampling interval.
	my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(1));
	$_->unbindNode() foreach $doc->findnodes('/domain/devices/memballoon/stats');
	$_->unbindNode() foreach $doc->findnodes('/domain/devices/memballoon/text()[normalize-space(.)=""]');
	$live = $doc->toString();
	}
return sha256_hex(join("\0", $domain->get_xml_description(3),
	$live,
	map { $_->get_xml_description(0) }
	sort { $a->get_name() cmp $b->get_name() } $domain->list_all_snapshots(0)));
}

# check_guest(domain, document)
# Refuses state that disk-only snapshots cannot capture or safely coordinate.
sub check_guest
{
# Exclude saved runtime state and devices the disk-only snapshot cannot restore.
my ($domain, $doc) = @_;
die "Remove the managed save before using snapshots\n" if ($domain->has_managed_save_image(0));
my @checkpoints = $domain->list_all_checkpoints(0);
die "Remove backup checkpoints before using snapshots\n" if (@checkpoints);
die "Snapshots do not support shared folders, passthrough devices, TPMs or persistent memory\n"
	if ($doc->exists('/domain/devices/filesystem | /domain/devices/hostdev | /domain/devices/tpm | /domain/devices/memory | /domain/devices/interface[@type="hostdev"]'));
my ($state) = $domain->get_state();
die "The virtual machine must be running or shut off\n" if ($state != 1 && $state != 2 && $state != 5);
my $info = $domain->is_active() ? $domain->get_job_info() : {};
die "Wait for the current libvirt operation to finish\n" if ($info->{'type'});
}

# check_agent(domain)
# Checks the actual guest before journalling a possible freeze, never catalogue flags.
sub check_agent
{
my ($domain) = @_;
# Use the host's agent timeout; it is shared with status and external clients.
my $info = eval { $domain->get_guest_info(2, 0) };
die "QEMU Guest Agent is not responding. Turn on Shut down before taking snapshot, or install and start the agent inside the virtual machine\n"
	if (ref($info) ne 'HASH' || !keys(%$info));
}

# check_history_storage(self, adapter, domain, [resuming_delete])
# Another VM or imported image may have adopted a saved base since creation.
sub check_history_storage
{
my ($self, $adapter, $domain, $resuming_delete) = @_;
my $manager = $self->manager();
my @xml = ($domain->get_xml_description(2),
	map { $_->get_xml_description(0) } $domain->list_all_snapshots(0));
my %paths;
foreach my $xml (@xml) {
	my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
	# These are the VM's writable tops and libvirt's own snapshot/revert layers.
	$paths{$_->getValue()} = 1 foreach $doc->findnodes(
        '/domain/devices/disk[not(readonly)]/source/@file | '.
        '/domain/devices/disk[not(readonly)]/source/@dev | '.
        '/domainsnapshot/domain/devices/disk[not(readonly)]/source/@file | '.
        '/domainsnapshot/domain/devices/disk[not(readonly)]/source/@dev');
	# Libvirt can retain names of discarded working layers after a revert.
	foreach my $source ($doc->findnodes(
		'/domainsnapshot/disks/disk[@snapshot="external"]/source[@file] | '.
		'/domainsnapshot/revertDisks/disk/source[@file]')) {
		my $path = $source->getAttribute('file');
		$paths{$path} = 1 if (-e $path);
		}
	}
my (undef, $volumes) = $manager->storage($adapter);
# Libvirt may spell an LV as /dev/VG/LV or /dev/mapper/VG-LV.
%paths = map { (Cwd::abs_path($_) || $_) => 1 } keys %paths;
my %aliases = %paths;
my @owned = grep { exists($aliases{Cwd::abs_path($_->{'path'}) || $_->{'path'}}) } @$volumes;
my %owned = map { $_->{'key'} => 1 } @owned;
my $refs = Cloudmin::Images::volume_references($adapter->connect(), $domain->get_uuid_string());
# A chain's own backing links are expected; references from other VMs or
# volumes are still checked against every layer, including indirect sharing.
my %native_paths;
# Owned native restore points are expected origin references, just like the
# backing links of owned file snapshots. Keep foreign references in the check.
foreach my $snapshot ($domain->list_all_snapshots(0)) {
    my $row = $self->record($domain, $snapshot);
    next if (!$row->{'native_lvm'});
    foreach my $item ($self->native_volumes($adapter, $snapshot, $resuming_delete)) {
        $native_paths{Cwd::abs_path($item->[1]->get_path()) || $item->[1]->get_path()} = 1;
    }
}
my @foreign = grep { (!defined($_->{'key'}) || !$owned{$_->{'key'}}) &&
    !($_->{'path'} && $native_paths{Cwd::abs_path($_->{'path'}) || $_->{'path'}}) } @$refs;
my $images = $manager->imported_file_ids($adapter);
foreach my $volume (@owned) {
	die "Imported images cannot be changed by snapshot operations\n" if ($images->{$volume->{'identity'}});
	my $reason = Cloudmin::Images::volume_use(\@foreign, @$volume{qw(path pool_name name key)});
	die "$reason\n" if ($reason);
	delete($paths{Cwd::abs_path($volume->{'path'}) || $volume->{'path'}});
	}
if ($resuming_delete) {
	# A native partial merge may already have removed a completed disk layer.
	delete($paths{$_}) foreach grep { !-e $_ && !-l $_ } keys %paths;
	}
die "Snapshot storage is missing or outside active managed pools\n" if (keys %paths);
}

# disks(self, adapter, domain, document, [allow_blocks])
# Includes every writable disk and verifies exclusive, managed storage.
# allow_blocks defaults off; native snapshots and copies enable managed raw LVs.
sub disks
{
my ($self, $adapter, $domain, $doc, $allow_blocks) = @_;
my $manager = $self->manager();
my @disks;
foreach my $disk ($doc->findnodes('/domain/devices/disk')) {
	my $target = $disk->findvalue('target/@dev');
	die "Invalid disk device in virtual machine configuration\n" if ($target !~ /\A[a-zA-Z0-9_-]+\z/);
	if ($disk->exists('readonly') || !$disk->exists('source')) {
		# Read-only media remain attached but do not need a writable overlay.
		push(@disks, { target => $target, readonly => 1 });
		next;
		}
	die "Snapshots require private raw or QCOW2 files, or managed raw LVM disks\n" if (
		($disk->getAttribute('type') ne 'file' &&
			!($allow_blocks && $disk->getAttribute('type') eq 'block' && $disk->findvalue('driver/@type') eq 'raw')) ||
		$disk->getAttribute('device') ne 'disk' ||
		$disk->findvalue('driver/@type') !~ /\A(?:raw|qcow2)\z/ ||
		$disk->exists('shareable | source/dataStore | encryption'));
	my $volume = $manager->volume_for($adapter, $disk);
	my $job = $domain->is_active() ? $domain->get_block_job_info($target, 0) : undef;
	die "Wait for the disk operation on $target to finish\n" if ($job && $job->{'type'});
	push(@disks, { target => $target, volume => $volume });
	}
die "The virtual machine has no writable disks to snapshot\n" if (!grep { !$_->{'readonly'} } @disks);
return \@disks;
}

# check_delete(domain, snapshot)
# Refuses libvirt's unsupported current-parent merge before a job is reserved.
sub check_delete
{
my ($domain, $snapshot) = @_;
return if (!$snapshot->is_current());
foreach my $child ($domain->list_all_snapshots(0)) {
	my $doc = Cloudmin::Libvirt::parse_xml_document($child->get_xml_description(0));
	die "Delete the child snapshots before deleting the current restore point\n"
		if ($doc->findvalue('/domainsnapshot/parent/name') eq $snapshot->get_name());
	}
}

# snapshot_xml(request)
# Explicitly excludes memory and read-only media, and includes every other disk.
sub snapshot_xml
{
my ($r) = @_;
my $escape = \&Cloudmin::Libvirt::xml_escape;
return '<domainsnapshot><name>'.$escape->($r->{'snapshot'}).'</name><description>'.
	$escape->($r->{'description'}).'</description><memory snapshot="no"/><disks>'.
	join('', map { '<disk name="'.$escape->($_->{'target'}).'" snapshot="'.
		($_->{'readonly'} ? 'no"/>' : $r->{'native_lvm'} ? 'manual"/>' : 'external"><driver type="qcow2"/><source file="'.
		$escape->($_->{'overlay'}).'"/></disk>') } @{$r->{'disks'}}).'</disks></domainsnapshot>';
}

# revert_disks(snapshot)
# Libvirt records fresh overlay paths after a successful external restore.
sub revert_disks
{
my ($snapshot) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($snapshot->get_xml_description(0));
return join('', map { $_->toString() } $doc->findnodes('/domainsnapshot/revertDisks'));
}

# native_volumes(self, adapter, snapshot, [deleting])
# Resolves logical volumes recorded in the journal.
# Native metadata alone never authorizes access to a logical volume.
sub native_volumes
{
my ($self, $adapter, $snapshot, $deleting) = @_;
my $name = $snapshot->get_name();
die "Unmanaged LVM snapshot\n" if ($name !~ /\Acloudmin-([a-f0-9]{32})\z/);
my $job = $self->{'jobs'}->get($1) || die "LVM snapshot journal is missing\n";
die "The LVM snapshot is incomplete\n" if (!$job->{'resources'}->{'native_complete'});
my @volumes;
foreach my $saved (@{$job->{'resources'}->{'native_volumes'} || []}) {
	my (undef, $volume) = $adapter->volume(@$saved{qw(pool name key)});
	# Deletion can resume after removing some LVs, and may discard unhealthy ones.
	next if (!$volume && $deleting);
	die "An LVM snapshot disk is missing\n" if (!$volume);
	$volume->snapshot_health() if (!$deleting);
	push(@volumes, [$saved, $volume]);
	}
die "The LVM snapshot has no disks\n" if (!@volumes && !$deleting);
return @volumes;
}

1;
