package Cloudmin::Clones;

# Full VM clones share creation's isolated workers and durable job journal.
use strict;
use warnings;
use File::Basename qw(dirname);
use Digest::SHA qw(sha256_hex);
use WebminCore qw(make_dir convert_to_json);
require(dirname(__FILE__).'/VMs.pm');
require(dirname(__FILE__).'/Snapshots.pm');
our @ISA = ('Cloudmin::VMs');

# manager(self) supplies managed-volume and domain validation.
sub manager { return Cloudmin::VMManage->new(%{$_[0]}); }

# snapshots(self) supplies file and LVM snapshot validation and operations.
sub snapshots { return Cloudmin::Snapshots->new(%{$_[0]}); }

# source(self, uuid) validates storage and hardware before copying anything.
# Returns the adapter, domain, secure XML document, disk list and NVRAM path.
sub source
{
my ($self, $uuid) = @_;
my ($adapter, $domain, $doc) = $self->manager()->get_guest($uuid);
Cloudmin::Snapshots::check_guest($domain, $doc);
# Reject unsupported consoles before inspecting or copying any storage.
die "Cloning supports VNC graphical consoles\n"
	if ($doc->exists('/domain/devices/graphics[not(@type="vnc")]'));
$self->snapshots()->check_history_storage($adapter, $domain);
Cloudmin::VMManage::check_nvram($adapter, $domain);
# Software installation must finish before its disks can become a clone source.
die "Finish guest software setup before cloning this virtual machine\n" if (grep {
	($_->{'request'}->{'uuid'} || '') eq $uuid &&
	$_->{'resources'}->{'software'} && $_->{'state'} !~ /\A(?:complete|failed|cancelled)\z/
} @{$self->{'jobs'}->list_pending()});
my $disks = $self->snapshots()->disks($adapter, $domain, $doc, 1);
my %roles = map { $_->{'target'} => $_->{'role'} } Cloudmin::Libvirt::extract_disks($doc->toString());
# Identify read-only volumes for unchanged copies and recognize removable seeds.
foreach my $disk (grep { $_->{'readonly'} } @$disks) {
	my ($node) = grep { $_->findvalue('target/@dev') eq $disk->{'target'} } $doc->findnodes('/domain/devices/disk');
	next if ($node->getAttribute('device') ne 'disk' || !$node->exists('source'));
	$disk->{'volume'} = $self->manager()->volume_for($adapter, $node);
	$disk->{'seed'} = ($roles{$disk->{'target'}} || '') eq 'seed' ? 1 : 0;
}
die "Cloning supports at most 32 writable disks\n" if (grep(!$_->{'readonly'}, @$disks) > 32);
# Reject devices whose external state cannot be copied or safely regenerated.
die "Remove custom QEMU arguments and external device state before cloning\n"
	if ($doc->exists('//*[local-name()="commandline"] | /domain/devices/shmem | /domain/launchSecurity | /domain/os/varstore'));
foreach my $nic ($doc->findnodes('/domain/devices/interface')) {
	die "Cloning supports network and bridge interfaces\n" if ($nic->getAttribute('type') !~ /\A(?:network|bridge)\z/);
	die "Remove interface filters before cloning\n" if ($nic->exists('filterref'));
}
die "Cloning does not support external device files or custom firmware state\n"
	if ($doc->exists('/domain/devices/*[not(self::disk or self::interface or self::channel or self::serial or self::console)]/source | /domain/devices/rng/backend[@model!="random"]'));
my $nvram = $doc->findvalue('/domain/os/nvram/source/@file') || $doc->findvalue('/domain/os/nvram/text()');
$nvram =~ s/^\s+|\s+$//g;
if ($doc->exists('/domain/os/nvram')) {
	# Firmware variables must be a bounded regular file, not a link or device.
	my $format = $doc->findvalue('/domain/os/nvram/@format') || 'raw';
	die "Cloning requires file-backed raw or QCOW2 UEFI variables\n"
		if (!$nvram || $format !~ /\A(?:raw|qcow2)\z/);
	my @stat = lstat($nvram);
	die "The source UEFI variables are missing or unusable\n" if (!@stat || !-f _ || -l _ ||
		$stat[7] < 1024 || $stat[7] > 64*1024**2);
}
return ($adapter, $domain, $doc, $disks, $nvram);
}

1;
