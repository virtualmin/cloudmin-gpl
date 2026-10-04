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

1;
