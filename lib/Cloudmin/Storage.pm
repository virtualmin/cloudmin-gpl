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

1;
