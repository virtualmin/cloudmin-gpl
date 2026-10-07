package Cloudmin::Backups;

# Full backups preserve guest identity; only clones prepare a new identity.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
require(dirname(__FILE__).'/Clones.pm');
our @ISA = ('Cloudmin::Clones');

# directory(self) creates private metadata storage outside the web root.
sub directory
{
my ($self) = @_;
my $dir = $self->{'directory'};
# Credentials and secure XML must remain private even in an existing directory.
make_path($dir, {mode => 0700}) if (!-e $dir);
my @st = lstat($dir);
die "Unsafe backup metadata directory\n" if (!@st || !-d _ || -l _ || $st[4] != $> || ($st[2] & 0077));
return $dir;
}

# record(self, id, [value]) reads or atomically saves a private backup record.
sub record
{
my ($self, $id, $value) = @_;
Cloudmin::Jobs::validate_id($id);
my $path = $self->directory()."/$id.json";
if ($value) {
	# Publish metadata only after writing a complete private file.
	my ($fh, $temp) = tempfile('.record-XXXXXXXX', DIR => $self->directory(), UNLINK => 1);
	print($fh encode_json($value)) && close($fh) or die "Cannot write backup record\n";
	rename($temp, $path) or die "Cannot save backup record\n";
	return $value;
}
# Missing records are normal for unfinished jobs; malformed records must fail.
return undef if (!-f $path);
open(my $fh, '<', $path) or die "Cannot read backup record\n";
local $/;
return decode_json(<$fh>);
}

# inventory(self) lists completed backups without transport credentials or XML.
sub inventory
{
my ($self) = @_;
# Standalone metadata readers may have no job store for cache expiry.
$self->purge_inspections() if ($self->{'jobs'});
opendir(my $dh, $self->directory()) or die "Cannot list backups\n";
my @ids = map { /^([a-f0-9]{32})\.json$/ ? $1 : () } readdir($dh);
closedir($dh);
# Newest-first order also lets retention preserve the latest backup of each VM.
return [sort { $b->{'created'} <=> $a->{'created'} } map {
	my $r = $self->record($_);
	+{map { $_ => $r->{$_} } qw(id name uuid created size sha256 filename destination schedule deleted)}
} @ids];
}

# purge_inspections(self) expires unused downloads after a day, under a lock.
# Active restores retain their inspection even if its confirmation page is old.
sub purge_inspections
{
my ($self) = @_;
# Use the submission lock so a restore cannot reserve a download during expiry.
$self->{'jobs'}->lock('create-host', sub {
	my %used = map { ($_->{'request'}->{'inspection'} || '') => 1 } @{$self->{'jobs'}->list_pending()};
	opendir(my $dh, $self->directory()) or die "Cannot read backup staging directory\n";
	my @ids = map { /^work-([a-f0-9]{32})$/ ? $1 : () } readdir($dh); closedir($dh);
	foreach my $id (@ids) {
		# Preserve active restores and any cache still needed for
		# recovery.
		next if ($used{$id});
		my $job = $self->{'jobs'}->get($id) || next;
		next if (($job->{'request'}->{'operation'} || '') ne 'backup_inspect' || $job->{'state'} ne 'complete' ||
			$job->{'cleanup_pending'} || $job->{'updated'} >= time()-86400);
		$self->clean_work($id);
	}
});
}

# archive_filename(name, job_id, timestamp, compressed) makes archives identifiable.
# The full job ID still prevents collisions between simultaneous submissions.
sub archive_filename
{
my ($name, $id, $time, $compressed) = @_;
$name =~ s/[^a-zA-Z0-9_.-]+/-/g;
$name = substr($name, 0, 100) || 'machine';
return 'cloudmin-'.$name.'-'.strftime('%Y%m%dT%H%M%SZ', gmtime($time))."-$id.tar".($compressed ? '.gz' : '');
}

# firmware_digest(path, identity) hashes a bounded regular NVRAM file.
# Checking both file metadata and content catches writes and replacements.
sub firmware_digest
{
my ($path, $identity) = @_;
sysopen(my $fh, $path, O_RDONLY|O_NOFOLLOW) or die "Cannot read firmware variables\n";
# Match the opened inode to the source validated before quiescing.
my @before = stat($fh);
die "Invalid firmware variables file\n" if (!-f $fh || !$before[7] || $before[7] > 64*1024**2 ||
	join(':', @before[0,1]) ne $identity);
my $hash = Digest::SHA->new(256);
my ($bytes, $buffer) = (0, '');
# Bound reads even if the live firmware file grows while it is being hashed.
while (1) {
	my $n = read($fh, $buffer, 65536);
	die "Cannot read firmware variables\n" if (!defined($n));
	last if (!$n);
	$bytes += $n;
	die "Firmware variables grew during backup\n" if ($bytes > 64*1024**2);
	$hash->add($buffer);
}
# Reject metadata or length changes observed during this read.
my @after = stat($fh); close($fh);
die "Firmware variables changed during backup; retry or choose clean shutdown\n"
	if ($bytes != $before[7] || join(':', @before[0,1,7,9,10]) ne join(':', @after[0,1,7,9,10]));
return $hash->hexdigest();
}

# copy_firmware(source, destination, identity, [before]) accepts only stable bytes.
# For live backup, before is captured immediately before the disk snapshot.
sub copy_firmware
{
my ($source, $dest, $identity, $before) = @_;
$before ||= firmware_digest($source, $identity);
Cloudmin::Worker::copy_file($source, $dest, 64*1024**2);
die "Firmware variables changed during backup; retry or choose clean shutdown\n"
	if (firmware_digest($source, $identity) ne $before ||
		firmware_digest($dest, Cloudmin::VMManage::file_identity($dest)) ne $before);
}

# work(self, id) returns this job's private staging path.
sub work { Cloudmin::Jobs::validate_id($_[1]); return $_[0]->directory().'/work-'.$_[1]; }

# clean_work(self, id) removes only the job's private staging directory.
sub clean_work
{
my ($self, $id) = @_;
my $work = $self->work($id);
die "Unsafe backup staging directory\n" if (-l $work);
my $errors;
remove_tree($work, {error => \$errors}) if (-d $work);
die "Cannot remove backup staging files\n" if ($errors && @$errors);
}

# cleanup(self, id, adapter) releases the source or removes an incomplete restore.
sub cleanup
{
my ($self, $id, $adapter) = @_;
my $job = $self->{'jobs'}->get($id);
my $r = $job->{'request'};
# Stop isolated writers before touching files or reversing libvirt changes.
Cloudmin::Worker->new()->cleanup($job->{'worker'}) if ($job->{'worker'});
if ($r->{'operation'} eq 'backup') {
	# A failed merge or pending shutdown keeps the source reserved for recovery.
	$self->release_source($id, $adapter) if ($job->{'resources'}->{'started'});
}
elsif ($r->{'operation'} eq 'restore') {
	# Rollback may remove only the new guest carrying this restore job's marker.
	$adapter->remove_created_guest($r->{'uuid'}, $id) if ($job->{'resources'}->{'domain'});
	$self->{'ssh_keys'}->remove($r->{'uuid'}, $id) if ($job->{'resources'}->{'ssh_key'});
}
# Recovery uses the journalled names even if creation never returned a key.
foreach my $v (@{$job->{'resources'}->{'volumes'} || []}) {
	$adapter->remove_created_volume($v->{'pool'}, $v->{'name'}, $v->{'key'});
}
$self->clean_work($id);
}

# backup(self, id, adapter) copies stable disk states, then publishes an archive.
sub backup
{
my ($self, $id, $adapter) = @_;
my $jobs = $self->{'jobs'};
my $r = $jobs->get($id)->{'request'};
my $work = $self->work($id);
$self->step($id, 'preflight', sub {
	# A queued job must still have its destination available before quiescing.
	$self->{'validate_target'}->($r->{'target'}, 0);
	my (undef, $source) = $self->source($r->{'source_uuid'});
	die "The virtual machine changed after backup submission\n" if (Cloudmin::Snapshots::revision($source) ne $r->{'source_revision'});
	# Pools on one filesystem share free space; live disks also need overlay
	# room.
	my (%needed, %paths);
	foreach my $d (grep { $_->{'volume'} } @{$r->{'disks'}}) {
		my $v = $d->{'volume'};
		# Logical volumes use VG or thin-pool space, not the filesystem at /dev.
		next if ($v->{'block'});
		my $path = dirname($v->{'path'});
		my @st = stat($path);
		die "Cannot check backup storage\n" if (!@st);
		$paths{$st[0]} = $path;
		$needed{$st[0]} += $v->{'capacity'} * ($r->{'active'} && !$r->{'shutdown'} && !$d->{'readonly'} ? 2 : 1);
	}
	die "Not enough storage for backup copies and temporary snapshot growth\n"
		if (grep { Cloudmin::Worker::free_space($paths{$_}) < $needed{$_} + 256*1024**2 } keys %needed);
});
my (%files, @disks);
my $manifest = {format => 'cloudmin-full-1', name => $r->{'name'}, uuid => $r->{'uuid'}, created => time(), disks => \@disks,
	virtualmin => $r->{'virtualmin'}};
$self->step($id, 'backup_quiesce', sub {
	# Keep firmware consistent with the disk snapshot, not a later disk-copy time.
	my $before = $r->{'nvram'} && $r->{'active'} && !$r->{'shutdown'}
		? firmware_digest($r->{'nvram'}, $r->{'nvram_identity'}) : undef;
	$self->quiesce_source($id, $adapter, 'backup');
	# BIOS has no variable store; UEFI needs bytes stable across the
	# snapshot.
	if ($r->{'nvram'}) {
		copy_firmware($r->{'nvram'}, "$work/nvram", $r->{'nvram_identity'}, $before);
		$files{'nvram'} = "$work/nvram";
		$manifest->{'nvram_format'} = $r->{'nvram_format'};
	}
});
# Clone each stable base into an independent volume, flattening backing chains.
$self->step($id, 'backup_disks', sub {
	foreach my $d (grep { $_->{'volume'} } @{$r->{'disks'}}) {
		$self->checkpoint($id);
		my $v = $self->stable_volume($id, $adapter, $d);
		die "A backup source disk was replaced\n" if (Cloudmin::VMManage::file_identity($v->{'path'}) ne $v->{'identity'});
		my $i = scalar(@disks);
		my $name = "cloudmin-backup-$id-$i";
		my $format = $v->{'format'} eq 'qcow2' ? 'qcow2' : 'raw';
		# journal() records intent before libvirt can leave a volume
		# behind.
		my $copy = $adapter->clone_disk($v->{'pool'}, $name,
			{pool => $v->{'pool'}, volume => $v->{'name'}, volume_key => $v->{'key'}}, $v->{'capacity'}, $format, sub {
				$jobs->update($id, sub { $_[0]->{'resources'}->{'volumes'}->[$i] = {pool => $v->{'pool'}, name => $name}; });
			});
		$copy->{'pool'} = $v->{'pool'};
		$jobs->update($id, sub { $_[0]->{'resources'}->{'volumes'}->[$i] = $copy; });
		# Verify the copied disk in isolation before adding its manifest
		# mapping.
		$self->worker_task($id, 'inspect', {format => $format}, files => {image => $copy->{'path'}});
		$files{"disk$i"} = $copy->{'path'};
		push(@disks, {file => "disk$i", target => $d->{'target'}, format => $format, capacity => $v->{'capacity'}});
	}
});
# Merge overlays or restart the source before compression and remote transfer.
$self->step($id, 'backup_release', sub { $self->release_source($id, $adapter); });
Cloudmin::Worker::write_data("$work/domain.xml", $r->{'source_xml'});
$files{'domain.xml'} = "$work/domain.xml";
$files{'ssh-key'} = $r->{'ssh_key'} if ($r->{'ssh_key'});
# Pack secure metadata and disks together, allowing a free-space margin.
my $packed = $self->step($id, 'backup_archive', sub {
	return $self->worker_task($id, 'backup_archive', {mode => 'pack', manifest => $manifest,
		members => [sort keys %files], compression => $r->{'compression'},
		limit => Cloudmin::Worker::free_space($work)-256*1024**2}, files => \%files, output => "$work/archive");
});
$self->step($id, 'backup_upload', sub {
	$self->transfer_file($id, 'put', $r->{'target'}, $r->{'filename'}, "$work/archive");
	# Publish the inventory record only after the destination accepts the
	# archive.
	$self->record($id, {id => $id, name => $r->{'name'}, uuid => $r->{'uuid'}, created => $manifest->{'created'},
		size => $packed->{'size'}, sha256 => $packed->{'sha256'}, filename => $r->{'filename'},
		target => $r->{'target'}, destination => $self->{'target_label'}->($r->{'target'}), schedule => $r->{'schedule'}});
});
# A completed archive no longer needs temporary volumes, even after a restart.
$jobs->update($id, sub { $_[0]->{'resources'}->{'published'} = 1; });
$self->cleanup($id, $adapter);
}

# transfer_file(self, id, operation, target, filename, local) journals remote workers.
sub transfer_file
{
my ($self, $id, @args) = @_;
$self->{'transfer'}->(@args, {
 # started(worker_id) lets cancellation locate and stop the transfer service.
 started => sub { my $worker = $_[0]; $self->{'jobs'}->update($id, sub { $_[0]->{'worker'} = $worker; }); },
 # progress(...) checks cancellation while the worker is still transferring.
 progress => sub { $self->checkpoint($id); }
});
$self->{'jobs'}->update($id, sub { delete($_[0]->{'worker'}); });
}

# inspect_backup(self, id) downloads and verifies before any guest is defined.
sub inspect_backup
{
my ($self, $id) = @_;
my $jobs = $self->{'jobs'};
my $r = $jobs->get($id)->{'request'};
my $work = $self->work($id);
$self->step($id, 'backup_download', sub { $self->transfer_file($id, 'get', $r->{'target'}, $r->{'filename'}, "$work/archive"); });
my $result = $self->step($id, 'backup_verify', sub {
	return $self->worker_task($id, 'backup_archive', {limit => Cloudmin::Worker::free_space($work)-256*1024**2},
		files => {archive => "$work/archive"});
});
# Listed backups must still match their recorded checksum; external ones bind
# confirmation to the checksum observed during this inspection.
validate_manifest($result->{'manifest'});
die "The archive differs from the completed backup\n" if ($r->{'expected_sha256'} && $result->{'sha256'} ne $r->{'expected_sha256'});
$jobs->update($id, sub { $_[0]->{'resources'}->{'manifest'} = $result->{'manifest'};
	$_[0]->{'resources'}->{'archive_sha256'} = $result->{'sha256'}; });
}

# validate_manifest(manifest) checks restore identities and disk mappings.
sub validate_manifest
{
my ($m) = @_;
die "Invalid backup machine identity\n" if (($m->{'uuid'} || '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/ ||
	($m->{'name'} || '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/);
die "Invalid backup disk list\n" if (ref($m->{'disks'}) ne 'ARRAY' || !@{$m->{'disks'}} || @{$m->{'disks'}} > 64);
# Require a one-to-one mapping between archive members and guest devices.
my (%files, %targets);
foreach my $d (@{$m->{'disks'}}) {
	die "Invalid backup disk mapping\n" if (ref($d) ne 'HASH' || ($d->{'file'} || '') !~ /\Adisk\d{1,2}\z/ ||
		($d->{'target'} || '') !~ /\A[a-zA-Z0-9_-]+\z/ || ($d->{'format'} || '') !~ /\A(?:raw|qcow2)\z/ ||
		!$m->{'files'}->{$d->{'file'}} || $files{$d->{'file'}}++ || $targets{$d->{'target'}}++);
	Cloudmin::Worker::byte_limit($d->{'capacity'});
}
# Only supported firmware formats and known edition markers reach restore.
die "Invalid backup firmware format\n" if ($m->{'files'}->{'nvram'} && ($m->{'nvram_format'} || '') !~ /\A(?:raw|qcow2)\z/);
die "Invalid Virtualmin edition in backup\n" if (($m->{'virtualmin'} || '') !~ /\A(?:gpl|pro)?\z/);
die "A backup disk has no device mapping\n" if (grep { /^disk\d+$/ && !$files{$_} } keys %{$m->{'files'}});
}

# restore_volume_names(xml, manifest, id, pool_type) preserves recognized roles.
# The new ownership ID must also appear in system and seed volume names, so
# later cloning can replace the seed without dropping unrelated read-only data.
sub restore_volume_names
{
my ($xml, $manifest, $id, $type) = @_;
my %roles = map { $_->{'target'} => $_->{'role'} }
	Cloudmin::Libvirt::extract_disks($xml);
my %counts;
$counts{$_}++ foreach values %roles;
my %names;
foreach my $disk (@{$manifest->{'disks'}}) {
	my $role = $roles{$disk->{'target'}} || '';
	# Ambiguous or unrecognized roles retain ordinary per-member names.
	$names{$disk->{'file'}} = $role =~ /\A(?:system|seed)\z/ && $counts{$role} == 1
		? Cloudmin::VMs::disk_volume_name($manifest->{'name'}, $role, $id, $type)
		: "cloudmin-$id-$disk->{file}";
	}
return \%names;
}

1;
