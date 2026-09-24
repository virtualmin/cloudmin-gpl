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

1;
