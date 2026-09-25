package Cloudmin::Storage;

# Local storage pools share the VM controller's host lock. Libvirt owns pool
# definitions and activation; stopping a pool never deletes its files.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use Digest::SHA qw(sha256_hex);
require(dirname(__FILE__).'/Libvirt.pm');

# new(class, adapter => adapter, jobs => jobs, images => images)
# Uses the configured adapter for inventory and the shared job stores for writes.
sub new
{
my ($class, %options) = @_;
return bless(\%options, $class);
}

# revision(pool)
# Includes live state and boot policy so old forms cannot undo another change.
sub revision
{
my ($pool) = @_;
my $persistent = $pool->is_persistent();
my $doc = Cloudmin::Libvirt::parse_xml_document($pool->get_xml_description(0));
# Libvirt embeds changing filesystem counters alongside saved configuration.
# Disk I/O must not invalidate forms whose settings are otherwise unchanged.
$_->unbindNode() foreach $doc->findnodes('/pool/capacity | /pool/allocation | /pool/available');
return sha256_hex(join("\0", $doc->toStringC14N(),
	$pool->is_active(), $persistent,
	$persistent ? $pool->get_autostart() : 0));
}

# contains_path(directory, path)
# Compares complete path components, resolving existing filesystem aliases.
sub contains_path
{
my ($directory, $path) = @_;
return 0 if (!defined($directory) || !defined($path));
$directory = abs_path($directory) || $directory;
$path = abs_path($path) || $path;
$directory =~ s{/+$}{};
return $path eq $directory || index($path, "$directory/") == 0;
}

# active_guests(self, pool)
# Finds running guests using named volumes or files, including backing stores.
sub active_guests
{
my ($self, $pool) = @_;
my (undef, $target) = Cloudmin::Libvirt::parse_pool_xml($pool->get_xml_description(0));
my @guests;
foreach my $vm ($self->{'adapter'}->connect()->list_all_domains(0)) {
	# Stopped guests have no disk I/O to protect; their files remain intact.
	next if (!$vm->is_active());
	my $doc = Cloudmin::Libvirt::parse_xml_document($vm->get_xml_description(0));
	my @sources = $doc->findnodes('/domain/devices/disk//source');
	if (grep { ($_->getAttribute('pool') || '') eq $pool->get_name() ||
		contains_path($target, $_->getAttribute('file') || undef) } @sources) {
		push(@guests, { name => $vm->get_name(), uuid => $vm->get_uuid_string() });
		}
	}
return \@guests;
}

# filesystem_id(path)
# Identifies the backing filesystem, including bind mounts and Btrfs subvolumes.
# Remote pool paths must never be passed here: they belong to a different host.
sub filesystem_id
{
my ($path) = @_;
return undef if ($^O ne 'linux' || !$path || !-d $path);
open(my $stat, '-|', 'stat', '-f', '--format=%t:%i', '--', $path) || return undef;
my $id = <$stat>;
my $ok = close($stat);
return undef if (!$ok || !defined($id));
chomp($id);
return $id =~ /\A[0-9a-f]+:[0-9a-f]*[1-9a-f][0-9a-f]*\z/i ? lc($id) : undef;
}

# overview(pools)
# Counts live inventory and sums each identified filesystem only once.
sub overview
{
my ($pools) = @_;
my %counts = (pools => scalar(@$pools), active => 0, volumes => 0,
	capacity => 0, available => 0, filesystems => 0);
my %filesystems;
foreach my $pool (@$pools) {
	next if (!$pool->{'active'});
	$counts{'active'}++;
	$counts{'volumes'} += $pool->{'volume_count'} || 0;
	$counts{'volumes_unknown'} = 1 if ($pool->{'volume_error'});
	# Unknown or non-filesystem backends cannot safely contribute to a total.
	if (!$pool->{'filesystem'} || !$pool->{'capacity'}) {
		$counts{'space_unknown'} = 1;
		next;
		}
	my $key = $pool->{'filesystem'};
	# Record the first observation of this filesystem; aliases share its space.
	if (!$filesystems{$key}) {
		$filesystems{$key} = { capacity => $pool->{'capacity'}, available => $pool->{'available'} };
		}
	else {
		# Counters can move between pool reads; use the lower reported free space.
		$filesystems{$key}->{'available'} = $pool->{'available'}
			if ($pool->{'available'} < $filesystems{$key}->{'available'});
		$filesystems{$key}->{'capacity'} = $pool->{'capacity'}
			if ($pool->{'capacity'} < $filesystems{$key}->{'capacity'});
		}
	}
foreach my $fs (values %filesystems) {
	$counts{'filesystems'}++;
	$counts{'capacity'} += $fs->{'capacity'};
	$counts{'available'} += $fs->{'available'};
	}
# Avoid presenting a partial sum as all available space or an incomplete count.
delete @counts{qw(capacity available)} if ($counts{'space_unknown'});
delete $counts{'volumes'} if ($counts{'volumes_unknown'});
return \%counts;
}

# volume_reference(xml, owner, [base])
# Parses file and named-volume references once for each owner or backing disk.
sub volume_reference
{
my ($xml, $owner, $base) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
# Include boot files and firmware as well as disks when protecting storage.
my @paths = map { $_->getValue() } $doc->findnodes(
	'//@file | //@dev | //@path | //path/text() | //nvram/text() | '.
	'//loader/text() | //kernel/text() | //initrd/text() | //dtb/text()');
foreach my $path (@paths) {
	# Whitespace can be part of a filename; only discard XML indentation.
	next if ($path !~ /\S/);
	$path = "$base/$path" if ($path !~ m{^/} && $base);
	}
return { %$owner, paths => [grep { /\S/ } @paths], sources => [map {
	[ $_->getAttribute('pool'), $_->getAttribute('volume') ]
	} $doc->findnodes('//source[@pool and @volume]')] };
}

# same_file(first, second, local)
# Detects path aliases on the local host without inspecting remote host paths.
sub same_file
{
my ($first, $second, $local) = @_;
return 0 if (!defined($first) || !defined($second) || $first eq '' || $second eq '');
return 1 if ($first eq $second);
return 0 if (!$local);
return 1 if ((abs_path($first) || $first) eq (abs_path($second) || $second));
my @first = stat($first);
my @second = stat($second);
return @first && @second && $first[0] == $second[0] && $first[1] == $second[1];
}

# volume_context(self, [refresh], [excluded_pool])
# Collects owners, dependencies and pending work. Any unreadable source blocks
# deletion. Pool removal excludes its own inventory, including when inactive.
# refresh defaults to false; excluded_pool is a native pool UUID to skip.
sub volume_context
{
my ($self, $refresh, $excluded_pool) = @_;
my $conn = $self->{'adapter'}->connect();
my $context = { references => [], images => [], errors => [] };
my $ok = eval {
	foreach my $vm ($conn->list_all_domains(0)) {
		my $owner = { kind => 'vm', name => $vm->get_name(), uuid => $vm->get_uuid_string(),
			active => $vm->is_active() ? 1 : 0 };
		push(@{$context->{'references'}}, volume_reference($vm->get_xml_description(0), $owner));
		# Stopped guests, saved memory and snapshots retain their disk references.
		push(@{$context->{'references'}}, volume_reference($vm->get_xml_description(2), $owner))
			if ($vm->is_persistent());
		push(@{$context->{'references'}}, volume_reference($vm->managed_save_get_xml_description(0),
			{ %$owner, kind => 'saved' })) if ($vm->has_managed_save_image(0));
		foreach my $snapshot ($vm->list_all_snapshots(0)) {
			push(@{$context->{'references'}}, volume_reference($snapshot->get_xml_description(0),
				{ %$owner, kind => 'snapshot' }));
			}
		foreach my $checkpoint ($vm->list_all_checkpoints(0)) {
			push(@{$context->{'references'}}, volume_reference($checkpoint->get_xml_description(0),
				{ %$owner, kind => 'checkpoint' }));
			}
		}
	1;
	};
push(@{$context->{'errors'}}, "Cannot check virtual machine references: $@") if (!$ok);
$ok = eval {
	foreach my $pool ($conn->list_all_storage_pools(0)) {
		# Removing a registration preserves its data and internal backing chains.
		next if ($excluded_pool && $pool->get_uuid_string() eq $excluded_pool);
		# An inactive pool may hide a dependent disk. Never call it unused.
		if (!$pool->is_active()) {
			push(@{$context->{'errors'}}, 'Start storage pool '.$pool->get_name().' to check its volume dependencies.');
			next;
			}
		Cloudmin::Libvirt::refresh_pool($pool) if ($refresh);
		foreach my $volume ($pool->list_all_volumes(0)) {
			push(@{$context->{'references'}}, volume_reference($volume->get_xml_description(0),
				{ kind => 'backing', name => $volume->get_name(), pool => $pool->get_uuid_string(),
				  path => $volume->get_path() },
				dirname($volume->get_path())));
			}
		}
	1;
	};
push(@{$context->{'errors'}}, "Cannot check storage dependencies: $@") if (!$ok);
$ok = eval {
	# Strict image reads prevent a damaged job record from hiding ownership.
	$context->{'images'} = $self->{'images'}->list(undef, undef, 1);
	$context->{'busy'} = @{$self->{'jobs'}->list(undef, 1)} ? 1 : 0;
	foreach my $image (@{$context->{'images'}}) {
		$context->{'busy'} = 1 if ($image->{'state'} !~ /\A(?:ready|failed|deleted)\z/ ||
			$self->{'images'}->{'test_lock'}->($self->{'images'}->path($image->{'id'}, 'json')));
		}
	1;
	};
push(@{$context->{'errors'}}, "Cannot check storage operations: $@") if (!$ok);
return $context;
}

# volume_usage(self, pool_record, volume_record, context)
# Lists every known owner and explains why a volume cannot be deleted directly.
sub volume_usage
{
my ($self, $pool, $volume, $context) = @_;
# Local file identities catch aliases; remote inventories compare names only.
my $local = $self->{'adapter'}->uri() eq 'qemu:///system';
my (@owners, %seen);
foreach my $ref (@{$context->{'references'}}) {
	# A volume's own target path is not a dependency from another volume.
	# Thin destinations list native LVs under a derived pool ID, so the same
	# logical volume is also recognized by its own device, never a backing path.
	next if ($ref->{'kind'} eq 'backing' && $ref->{'name'} eq $volume->{'name'} &&
		($ref->{'pool'} eq $pool->{'uuid'} || (($volume->{'key'} || '') =~ /\Alvm:/ &&
		 same_file($ref->{'path'}, $volume->{'path'}, $local))));
	my $matches = grep { ($_->[0] eq $pool->{'name'} || $_->[0] eq $pool->{'uuid'}) &&
		$_->[1] eq $volume->{'name'} } @{$ref->{'sources'}};
	$matches ||= grep { same_file($_, $volume->{'path'}, $local) } @{$ref->{'paths'}};
	next if (!$matches || $seen{join(':', map { $ref->{$_} // '' } qw(kind uuid pool name))}++);
	push(@owners, { map { $_ => $ref->{$_} } qw(kind uuid pool name active) });
	}
foreach my $image (@{$context->{'images'}}) {
	# Match recorded paths too: imports may be registered in aliased pools.
	if ((($image->{'pool'} || '') eq $pool->{'uuid'} &&
		($image->{'volume'} || '') eq $volume->{'name'}) ||
		same_file($image->{'volume_path'}, $volume->{'path'}, $local) ||
		($image->{'volume_key'} && $image->{'volume_key'} eq ($volume->{'key'} || ''))) {
		push(@owners, { kind => 'image', name => $image->{'name'}, id => $image->{'id'} });
		}
	}
my $reason = @owners ? 'This volume is still owned or referenced. Open its virtual machine or Image Manager to manage it.'
	: $volume->{'snapshot'} ? 'Delete this restore point from the virtual machine snapshot history.'
	: @{$context->{'errors'}} ? join(' ', @{$context->{'errors'}})
	: $context->{'busy'} ? 'Wait for virtual machine operations and image imports to finish before deleting volumes.'
	: !($pool->{'manageable'} || $pool->{'volume_manageable'}) ? 'Only volumes in local persistent directory or LVM pools can be deleted here.' : '';
return { owners => \@owners, reason => $reason, checked => !@{$context->{'errors'}} };
}

# volume_revision(pool, volume)
# Binds confirmation to file identity, size and format, or an LV's UUID/capacity.
# Refresh can enrich XML without changing the disk.
sub volume_revision
{
my ($pool, $volume) = @_;
my $path = $volume->get_path();
my @stat = lstat($path);
if ($volume->isa('Cloudmin::LVM::Volume')) {
	# Device nodes can be recreated; use the LV UUID after excluding host use.
	Cloudmin::LVM::host_use($volume->record(1));
	return sha256_hex(join("\0", $pool->get_uuid_string(), $volume->get_key(),
		$volume->get_info()->{'capacity'}));
	}
die "Only regular storage files can be deleted here\n" if (!@stat || !-f _);
my $doc = Cloudmin::Libvirt::parse_xml_document($volume->get_xml_description(0));
my $info = $volume->get_info();
return sha256_hex(join("\0", $pool->get_uuid_string(), $volume->get_key(), $path,
	@stat[0,1,7,9,10], @$info{qw(type capacity)}, $doc->findvalue('/volume/target/format/@type')));
}

# review_volume(self, uuid, name, [refresh])
# Returns the native pool, volume and public review, including refusal reasons.
# uuid selects the pool; name is matched exactly. refresh defaults to false.
# A blocked review has no deletion revision. Reviews do not change the volume.
sub review_volume
{
my ($self, $uuid, $name, $refresh) = @_;
# Validate selectors before opening a local pool or reading its volumes.
$self->assert_local();
die "Invalid storage pool ID\n" if (($uuid || '') !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
die "Invalid storage volume name\n" if (!defined($name) || ref($name) ||
	!length($name) || length($name) > 4096 || $name =~ /[\x00-\x1f\x7f]/);
my $pool = Cloudmin::Libvirt::storage_pool($self->{'adapter'}, $uuid);
# Only persistent active file and LVM destinations support volume deletion.
my ($type) = Cloudmin::Libvirt::parse_pool_xml($pool->get_xml_description(0));
die "Only active local persistent directory or LVM pools can be managed here\n"
	if ($type !~ /\A(?:dir|logical|lvmthin)\z/ || !$pool->is_persistent() || !$pool->is_active());
Cloudmin::Libvirt::refresh_pool($pool) if ($refresh);
my ($volume) = grep { $_->get_name() eq $name } $pool->list_all_volumes(0);
die "Storage volume no longer exists\n" if (!$volume);
# Inventory tolerates partial native reads; deletion requires every identity
# field to succeed so a missing path cannot hide a file reference.
my $record = { name => $volume->get_name(), key => $volume->get_key(),
	path => $volume->get_path(), %{$volume->get_info()} };
$record->{'snapshot'} = 1 if ($volume->isa('Cloudmin::LVM::Volume') &&
	($volume->record()->{'lv_tags'} || '') =~ /(?:^|,)cloudmin_snapshot(?:,|$)/);
die "Cannot identify the selected storage volume\n"
	if (!$record->{'key'} || !$record->{'path'} || !defined($record->{'capacity'}));
my $context = $self->volume_context($refresh);
my $usage = $self->volume_usage({ uuid => $uuid, name => $pool->get_name(), manageable => 1 }, $record, $context);
my $revision;
if (!$usage->{'reason'}) {
	# Host mounts and non-regular files must remain visible as blocked reviews.
	$revision = eval { volume_revision($pool, $volume) };
	$usage->{'reason'} = Cloudmin::Libvirt::error_message($@) if ($@);
	}
return ($pool, $volume, { %$record, pool => $pool->get_name(), uuid => $uuid,
	usage => $usage, revision => $revision });
}

# inspect_volume(self, uuid, name, [refresh]) refuses unsafe deletion candidates.
# Returns the same tuple as review_volume; refresh defaults to false.
sub inspect_volume
{
my ($self, @args) = @_;
my @review = $self->review_volume(@args);
die $review[2]->{'usage'}->{'reason'}."\n" if ($review[2]->{'usage'}->{'reason'});
return @review;
}

# delete_volume(self, uuid, name, revision, confirmed)
# Rechecks usage and identity under the host lock immediately before removal.
sub delete_volume
{
my ($self, $uuid, $name, $revision, $confirmed) = @_;
$self->assert_local();
die "Confirm permanent volume deletion\n" if (($confirmed || '') ne '1');
return $self->{'jobs'}->lock('create-host', sub {
	my ($pool, $volume, $record) = $self->inspect_volume($uuid, $name, 1);
	die "The storage volume changed; review it again before deleting\n"
		if (!$revision || $revision ne $record->{'revision'});
	Cloudmin::Libvirt::log_call('Sys::Virt::StorageVol::delete', {
		pool => $uuid, volume => $name, flags => 0 });
	$volume->delete(0);
	return $record;
	});
}

# review_pool(self, uuid, [stop]) checks whether a registration can be removed.
# Returns the native pool and a public review without changing storage. stop
# defaults to 0; 1 permits a later stop, including whole-group LVM deactivation.
# References cover the whole VG. Blocked reviews retain their refusal reason.
sub review_pool
{
my ($self, $uuid, $stop) = @_;
# Bind only a validated stop choice and native UUID into the review.
$self->assert_local();
$stop //= 0;
die "Invalid stop-before-unregister setting\n" if ($stop !~ /\A[01]\z/);
die "Invalid storage pool ID\n" if (($uuid || '') !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
# Only native registrations can be removed; explain derived thin IDs separately.
my $pool = eval { $self->{'adapter'}->connect()->get_storage_pool_by_uuid($uuid) };
if (!$pool) {
	# Preserve the native lookup error unless this is a known thin destination.
	my $error = $@;
	my $destination = eval { Cloudmin::Libvirt::storage_pool($self->{'adapter'}, $uuid) };
	die "LVM-thin destinations cannot be unregistered separately. Unregister the parent LVM pool instead.\n"
		if ($destination && $destination->isa('Cloudmin::LVM::Pool') && $destination->{'thin'});
	die $error;
	}
# Read other pools' dependencies while excluding the registration being removed.
my ($type, $target) = Cloudmin::Libvirt::parse_pool_xml($pool->get_xml_description(0));
die "Only persistent directory or LVM pool registrations can be removed\n"
	if ($type !~ /\A(?:dir|logical)\z/ || !$pool->is_persistent());
my $context = $self->volume_context(1, $uuid);
my %ids = ($uuid => 1);
my %names = ($pool->get_name() => 1);
my @paths = ($target);
my @identity;
my ($missing_mapper, $missing_thin_prefix);
if ($type eq 'logical') {
	# Inactive LVs can lack device nodes; include both canonical LVM aliases.
	my $driver = $self->{'adapter'}->{'lvm'} || Cloudmin::LVM->new();
	my $doc = Cloudmin::Libvirt::parse_xml_document($pool->get_xml_description(0));
	my $vg = Cloudmin::LVM::name($doc->findvalue('/pool/source/name'));
	my $groups = $driver->inventory(1);
	if (!$groups->{$vg} && !$pool->is_active()) {
		# Only a successful inventory can prove a stale registration. No stop
		# is needed, but missing device nodes must not hide saved references.
		push(@identity, 'missing-group', $vg);
		push(@paths, "/dev/$vg");
		# Doubled hyphens belong to a VG name; a single one separates its LV.
		$vg =~ s/-/--/g;
		$missing_mapper = qr{\A/dev/mapper/\Q$vg\E-[^-]};
		$missing_thin_prefix = $pool->get_name().'/';
		}
	else {
		# Existing groups and every actual stop require complete LV metadata.
		my @destinations = $driver->pools($pool);
		foreach my $destination (@destinations) {
			$ids{$destination->get_uuid_string()} = 1;
			$names{$destination->get_name()} = 1;
			}
		my $group = $destinations[0]->group();
		push(@identity, $group->{'vg_uuid'});
		# Retain every LV's aliases and identity, including saved snapshots.
		foreach my $lv (values %{$group->{'volumes'}}) {
			my ($vg, $name) = ($group->{'vg_name'}, $lv->{'lv_name'});
			s/-/--/g for ($vg, $name);
			push(@paths, $lv->{'lv_path'}, "/dev/mapper/$vg-$name");
			push(@identity, join(':', map { $lv->{$_} // '' } qw(lv_uuid lv_name segtype)));
			# Snapshot history must be removed through its owning machine first.
			push(@{$context->{'errors'}}, 'Remove Cloudmin snapshots before unregistering this volume group.')
				if (($lv->{'lv_tags'} || '') =~ /(?:^|,)cloudmin_snapshot(?:,|$)/);
			}
		if ($stop && $pool->is_active()) {
			# Stopping a logical pool deactivates every LV, including host-only disks.
			my $safe = eval { $driver->group_host_use($group); 1 };
			# Show host-use failures in the review instead of offering removal.
			push(@{$context->{'errors'}}, Cloudmin::Libvirt::error_message($@)) if (!$safe);
			}
		}
	}
my (@owners, %seen);
foreach my $ref (@{$context->{'references'}}) {
	# Paths cover direct attachments; named sources also cover missing files.
	my $used = grep { $names{$_->[0]} || $ids{$_->[0]} ||
		($missing_thin_prefix && index($_->[0], $missing_thin_prefix) == 0) } @{$ref->{'sources'}};
	$used ||= grep { my $path = $_; ($missing_mapper && $path =~ $missing_mapper) ||
		grep { $_ && (contains_path($_, $path) || same_file($_, $path, 1)) } @paths } @{$ref->{'paths'}};
	# Live, saved and snapshot XML can all refer to the same owner.
	next if (!$used || $seen{join(':', map { $ref->{$_} // '' } qw(kind uuid pool name))}++);
	push(@owners, { map { $_ => $ref->{$_} } qw(kind uuid pool name active) });
	}
foreach my $image (@{$context->{'images'}}) {
	# Saved imports can refer to a thin destination or an aliased disk path.
	my $path = $image->{'volume_path'} || '';
	push(@owners, { kind => 'image', id => $image->{'id'}, name => $image->{'name'} })
		if ($ids{$image->{'pool'} || ''} || ($missing_mapper && $path =~ $missing_mapper) ||
			$path && grep { $_ && (contains_path($_, $path) || same_file($_, $path, 1)) } @paths);
	}
# Report owners first, then unreadable references, jobs or missing stop permission.
my $reason = @owners ? 'This pool is still referenced by virtual machines, images or other storage.'
	: @{$context->{'errors'}} ? join(' ', @{$context->{'errors'}})
	: $context->{'busy'} ? 'Wait for virtual machine operations and image imports to finish before unregistering a pool.'
	: $pool->is_active() && !$stop
		? 'This pool is active. Review Stop and Unregister, or use --stop with unregister-pool.' : '';
# A changed stop choice, registration or VG identity invalidates this revision.
return ($pool, { id => $uuid, uuid => $uuid, name => $pool->get_name(), type => $type,
	path => $target, stop_required => $pool->is_active() ? 1 : 0,
	revision => sha256_hex(join("\0", revision($pool), $stop, sort @identity)),
	usage => { owners => \@owners, reason => $reason, checked => !@{$context->{'errors'}} } });
}

# unregister(self, uuid, revision, confirmed, [stop]) removes a saved definition.
# confirmed must be 1; stop defaults to 0 and must match the review's choice.
# The fresh review runs under the host lock. Files and LVs are never deleted.
sub unregister
{
my ($self, $uuid, $revision, $confirmed, $stop) = @_;
# Refuse unconfirmed requests before entering the mutation path.
$self->assert_local();
die "Confirm storage pool unregistration\n" if (($confirmed || '') ne '1');
return $self->{'jobs'}->lock('create-host', sub {
	# Recheck both identity and references immediately before stopping storage.
	my ($pool, $record) = $self->review_pool($uuid, $stop);
	die "Storage settings changed; review the pool again\n"
		if (!$revision || $record->{'revision'} ne $revision);
	die $record->{'usage'}->{'reason'}."\n" if ($record->{'usage'}->{'reason'});
	if ($record->{'stop_required'}) {
		# Libvirt refuses open devices too, covering use that starts after review.
		Cloudmin::Libvirt::log_call('Sys::Virt::StoragePool::destroy', { uuid => $uuid });
		my $stopped = eval { $pool->destroy(); 1 };
		# A failed stop must leave the registration available for recovery.
		die "Could not stop the pool; its registration was kept. Check its volume activation state: ".
			Cloudmin::Libvirt::error_message($@)."\n" if (!$stopped);
		die "The pool is still active; its registration was kept\n" if ($pool->is_active());
		}
	# Unregister only after inactivity is established; report partial failure.
	Cloudmin::Libvirt::log_call('Sys::Virt::StoragePool::undefine', { uuid => $uuid });
	my $removed = eval { $pool->undefine(); 1 };
	die "The pool is stopped, but its registration could not be removed. Review and retry unregistration: ".
		Cloudmin::Libvirt::error_message($@)."\n" if (!$removed);
	return $record;
	});
}

# inventory(self)
# Lists all backends. Local directory pools have lifecycle controls; directory
# and LVM pools also allow deletion of volumes with no owners or host use.
sub inventory
{
my ($self) = @_;
my $local = $self->{'adapter'}->uri() eq 'qemu:///system';
my @pools;
foreach my $pool (Cloudmin::Libvirt::storage_pools($self->{'adapter'})) {
	my $record = $self->{'adapter'}->get_storage_pool_record($pool, 1);
	$record->{'revision'} = revision($pool);
	$record->{'unregisterable'} = $local && $record->{'persistent'} &&
		$record->{'type'} =~ /\A(?:dir|logical)\z/;
	$record->{'manageable'} = $local && $record->{'persistent'} && $record->{'type'} eq 'dir';
	$record->{'volume_manageable'} = $local && $record->{'persistent'} &&
		$record->{'type'} =~ /\A(?:logical|lvmthin)\z/;
	$record->{'guests'} = $record->{'manageable'} && $record->{'active'}
		? $self->active_guests($pool) : [];
	$record->{'filesystem'} = filesystem_id($record->{'target'})
		if ($local && $record->{'active'} && $record->{'type'} =~ /\A(?:dir|fs|netfs)\z/);
	push(@pools, $record);
	}
my $context = $self->volume_context();
my $lvm = Cloudmin::LVM->new();
foreach my $pool (@pools) {
	foreach my $volume (@{$pool->{'volumes'}}) {
		$volume->{'usage'} = $self->volume_usage($pool, $volume, $context);
		# Report unsafe storage per volume without hiding the rest of inventory.
		if (!$volume->{'usage'}->{'reason'}) {
			if ($pool->{'type'} =~ /\A(?:logical|lvmthin)\z/) {
				# Host mounts and device stacks protect LVs even without guest owners.
				my $safe = eval { Cloudmin::LVM::host_use(Cloudmin::LVM::device($volume->{'path'}, $lvm)); 1 };
				$volume->{'usage'}->{'reason'} = Cloudmin::Libvirt::error_message($@) if (!$safe);
				next;
				}
			# Directory deletion accepts only regular files, never device aliases.
			my @stat = lstat($volume->{'path'} || '');
			$volume->{'usage'}->{'reason'} = 'Only regular storage files can be deleted here.'
				if (!@stat || !-f _);
			}
		}
	}
return { pools => [sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @pools],
	local => $local, overview => overview(\@pools), usage_errors => $context->{'errors'} };
}

# lvm_groups(self) lists existing groups not already registered with libvirt.
sub lvm_groups
{
my ($self) = @_;
$self->assert_local();
my %registered;
foreach my $pool ($self->{'adapter'}->connect()->list_all_storage_pools(0)) {
	# Inactive registrations also reserve their volume group.
	my $doc = Cloudmin::Libvirt::parse_xml_document($pool->get_xml_description(0));
	$registered{$doc->findvalue('/pool/source/name')} = 1
		if ($doc->findvalue('/pool/@type') eq 'logical');
	}
my $driver = $self->{'adapter'}->{'lvm'} || Cloudmin::LVM->new();
return [sort { lc($a) cmp lc($b) || $a cmp $b }
	grep { !$registered{$_} } keys %{$driver->inventory()}];
}

# assert_local(self)
# Filesystem checks and directory creation apply only to the local system host.
sub assert_local
{
my ($self) = @_;
die "Storage changes are available only for the local qemu:///system host\n"
	if ($self->{'adapter'}->uri() ne 'qemu:///system');
}

# prepare(self, input)
# Validates a name and canonical directory without creating or changing files.
sub prepare
{
my ($self, $in) = @_;
$self->assert_local();
my $name = $in->{'name'} // '';
my $path = $in->{'path'} // '';
die "Use a pool name of up to 64 letters, numbers, dots, underscores or hyphens, starting with a letter or number\n"
	if ($name !~ /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/);
die "Enter an absolute directory path without . or .. components\n"
	if ($path !~ m{\A/[^\x00-\x1f\x7f]+\z} || length($path) > 4096 ||
		$path =~ m{(?:\A|/)\.{1,2}(?:/|\z)});
$path =~ s{/+}{/}g;
$path =~ s{/$}{};
die "Choose a dedicated storage directory, not the filesystem root\n" if (!$path);
# Resolve the parent before comparing pool paths, including not-yet-created targets.
my $exists = -e $path || -l $path;
die "The storage path must be a directory\n" if ($exists && !-d $path);
my $parent = abs_path(dirname($path));
die "The parent directory must already exist\n" if (!$parent || !-d $parent);
$path = $exists ? abs_path($path) : ($parent eq '/' ? '' : $parent).'/'.basename($path);
die "Choose a dedicated storage directory, not the filesystem root\n" if (!$path || $path eq '/');
my $autostart = $in->{'autostart'} // 0;
die "Invalid start-at-boot setting\n" if ($autostart !~ /\A[01]\z/);
foreach my $pool ($self->{'adapter'}->connect()->list_all_storage_pools(0)) {
	die "A storage pool named $name already exists\n" if ($pool->get_name() eq $name);
	my (undef, $target) = Cloudmin::Libvirt::parse_pool_xml($pool->get_xml_description(0));
	# Nested or aliased targets would present the same files as separate pools.
	die "This directory overlaps storage pool ".$pool->get_name()."; choose a separate directory\n"
		if ($target && (contains_path($target, $path) || contains_path($path, $target)));
	}
# A caller-selected UUID makes libvirt reject a name claimed concurrently by
# another administrator, rather than redefining that administrator's pool.
open(my $random, '<', '/dev/urandom') || die "Cannot open random source: $!\n";
read($random, my $bytes, 16) == 16 || die "Cannot read random source\n";
close($random);
my $uuid = unpack('H*', $bytes);
substr($uuid, 12, 1) = '4';
substr($uuid, 16, 1) = sprintf('%x', 8 | (hex(substr($uuid, 16, 1)) & 3));
$uuid =~ s/\A(.{8})(.{4})(.{4})(.{4})(.{12})\z/$1-$2-$3-$4-$5/;
my $xml = "<pool type='dir'><name>".Cloudmin::Libvirt::xml_escape($name).
	"</name><uuid>$uuid</uuid><target><path>".Cloudmin::Libvirt::xml_escape($path)."</path></target></pool>";
return { name => $name, path => $path, existing => $exists ? 1 : 0,
	autostart => 0+$autostart, xml => $xml };
}

# create(self, input)
# Registers existing VGs or creates directory pools. Existing directory contents
# and permissions are preserved; registering a VG never formats its disks.
sub create
{
my ($self, $in) = @_;
$self->assert_local();
return $self->register_lvm($in) if (($in->{'type'} || '') eq 'logical');
die "Unknown storage pool type\n" if (($in->{'type'} || 'dir') ne 'dir');
return $self->{'jobs'}->lock('create-host', sub {
	my $plan = $self->prepare($in);
	my $pool;
	my $ok = eval {
		Cloudmin::Libvirt::log_call('Sys::Virt::define_storage_pool', { name => $plan->{'name'}, path => $plan->{'path'} });
		$pool = $self->{'adapter'}->connect()->define_storage_pool($plan->{'xml'});
		# Building an existing directory could change its ownership or mode.
		$pool->build(0) if (!$plan->{'existing'});
		$pool->create();
		$pool->set_autostart($plan->{'autostart'});
		1;
		};
	my $error = $@;
	if (!$ok && $pool) {
		# Roll back only the new definition, never remove files or directories.
		my $cleaned = eval { $pool->destroy() if ($pool->is_active()); $pool->undefine(); 1 };
		$error .= " Pool definition cleanup failed: $@" if (!$cleaned);
		$error .= " Any created directory was kept at $plan->{path}." if (!$plan->{'existing'});
		}
	die $error if (!$ok);
	return $plan->{'name'};
	});
}

# register_lvm(self, input) registers an existing VG without formatting disks.
# Webmin's LVM module manages PVs, VGs and thin pools; Cloudmin discovers them.
sub register_lvm
{
my ($self, $in) = @_;
$self->assert_local();
my $name = $in->{'name'} || '';
die "Use a pool name of up to 64 letters, numbers, dots, underscores or hyphens\n"
	if ($name !~ /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/);
die "Select an existing LVM volume group\n" if (!length($in->{'group'} || ''));
my $group = Cloudmin::LVM::name($in->{'group'});
my $autostart = $in->{'autostart'} // 0;
die "Invalid start-at-boot setting\n" if ($autostart !~ /\A[01]\z/);
return $self->{'jobs'}->lock('create-host', sub {
	my $driver = Cloudmin::LVM->new();
	# Recheck the chosen group and all registrations under the mutation lock.
	$driver->group($group);
	my $connection = $self->{'adapter'}->connect();
	foreach my $pool ($connection->list_all_storage_pools(0)) {
		my $doc = Cloudmin::Libvirt::parse_xml_document($pool->get_xml_description(0));
		die "A storage pool named $name already exists\n" if ($pool->get_name() eq $name);
		die "This volume group is already registered\n" if (
			$doc->findvalue('/pool/@type') eq 'logical' && $doc->findvalue('/pool/source/name') eq $group);
		}
	# Allocate a libvirt registration ID independently of the existing VG UUID.
	open(my $random, '<', '/dev/urandom') or die "Cannot allocate storage pool identity\n";
	read($random, my $bytes, 16) == 16 or die "Cannot allocate storage pool identity\n";
	close($random);
	my $uuid = unpack('H*', $bytes);
	$uuid =~ s/\A(.{8})(.{4})(.{4})(.{4})(.{12})\z/$1-$2-$3-$4-$5/;
	my $x = \&Cloudmin::Libvirt::xml_escape;
	# Define and activate the group; libvirt build would format storage.
	my $xml = "<pool type='logical'><name>".$x->($name)."</name><uuid>$uuid</uuid>".
		'<source><name>'.$x->($group).'</name></source><target><path>/dev/'.$x->($group).'</path></target></pool>';
	my $pool = $connection->define_storage_pool($xml);
	my $ok = eval { $pool->create(); $pool->set_autostart($autostart); 1 };
	if (!$ok) {
		# Removing the new definition must never deactivate an existing host VG.
		my $error = $@;
		eval { $pool->undefine(); 1 } or $error .= " Pool definition cleanup failed: $@";
		die $error;
		}
	return $pool->get_name();
	});
}

# assert_idle(self, pool)
# Protects active disk I/O and pending jobs while holding the host mutation lock.
sub assert_idle
{
my ($self, $pool) = @_;
die "Wait for virtual machine operations to finish before stopping a storage pool\n"
	if (@{$self->{'jobs'}->list(undef, 1)});
my $images = $self->{'images'};
foreach my $job (@{$images->list()}) {
	next if (($job->{'pool'} || '') ne $pool->get_uuid_string());
	# Include waiting uploads and stale imports until explicitly cancelled.
	die "Finish or cancel image imports using this pool before stopping it\n"
		if ($job->{'state'} !~ /\A(?:ready|failed|deleted)\z/ ||
			$images->{'test_lock'}->($images->path($job->{'id'}, 'json')));
	}
die "Stop virtual machines using this pool before stopping it\n"
	if (@{$self->active_guests($pool)});
}

# change(self, action, uuid, revision, [enabled])
# Re-resolves persistent directory pools and refuses stale or unsupported writes.
sub change
{
my ($self, $action, $uuid, $revision, $enabled) = @_;
$self->assert_local();
die "Unknown storage action\n" if ($action !~ /\A(?:start|stop|autostart)\z/);
die "Invalid storage pool ID\n" if (!defined($uuid) || $uuid !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
return $self->{'jobs'}->lock('create-host', sub {
	my $pool = $self->{'adapter'}->connect()->get_storage_pool_by_uuid($uuid);
	my ($type) = Cloudmin::Libvirt::parse_pool_xml($pool->get_xml_description(0));
	die "Only persistent directory pools can be managed here\n" if ($type ne 'dir' || !$pool->is_persistent());
	die "Storage settings changed; reload the page\n" if (($revision || '') ne revision($pool));
	if ($action eq 'autostart') {
		# A missing target must never silently turn off a boot setting.
		die "Invalid start-at-boot setting\n" if (!defined($enabled) || $enabled !~ /\A[01]\z/);
		$pool->set_autostart(0+$enabled);
		}
	# Starting activates the saved pool definition without creating its directory.
	elsif ($action eq 'start') {
		die "Storage pool is already active\n" if ($pool->is_active());
		Cloudmin::Libvirt::log_call('Sys::Virt::StoragePool::create', { uuid => $uuid });
		$pool->create();
		}
	# Stopping removes access through libvirt after active users have been checked.
	else {
		die "Storage pool is already inactive\n" if (!$pool->is_active());
		$self->assert_idle($pool);
		Cloudmin::Libvirt::log_call('Sys::Virt::StoragePool::destroy', { uuid => $uuid });
		$pool->destroy();
		}
	return $pool->get_name();
	});
}

1;
