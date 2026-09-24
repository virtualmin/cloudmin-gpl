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

1;
