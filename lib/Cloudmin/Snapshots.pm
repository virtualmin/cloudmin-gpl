package Cloudmin::Snapshots;

# Disk snapshots use libvirt's tree and the existing durable VM job journal.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
require(dirname(__FILE__).'/VMManage.pm');

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

1;
