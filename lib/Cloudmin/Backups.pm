package Cloudmin::Backups;

# Full backups preserve guest identity; only clones prepare a new identity.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use WebminCore qw(convert_to_json convert_from_json);
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
make_path($dir, { mode => 0700 }) if (!-e $dir);
my @st = lstat($dir);
die "Unsafe backup metadata directory\n"
	if (!@st || !-d _ || -l _ || $st[4] != $> || ($st[2] & 0077));
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
	my ($fh, $temp) =
		tempfile('.record-XXXXXXXX', DIR => $self->directory(),
			 UNLINK =>
				 1);
	print($fh convert_to_json($value, 0, 1)) && close($fh) or
		die "Cannot write backup record\n";
	rename($temp, $path) or die "Cannot save backup record\n";
	return $value;
	}
# Missing records are normal for unfinished jobs; malformed records must fail.
return undef if (!-f $path);
open(my $fh, '<', $path) or die "Cannot read backup record\n";
local $/;
return convert_from_json(<$fh>);
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
return [ sort { $b->{'created'} <=> $a->{'created'} } map {
	my $r = $self->record($_);
	+{ map { $_ =>
		$r->{$_} } qw(id name uuid created size sha256 filename destination schedule deleted) }
	} @ids ];
}

# purge_inspections(self) expires unused downloads after a day, under a lock.
# Active restores retain their inspection even if its confirmation page is old.
sub purge_inspections
{
my ($self) = @_;
# Use the submission lock so a restore cannot reserve a download during expiry.
$self->{'jobs'}->lock('create-host', sub {
	my %used =
		map { ($_->{'request'}->{'inspection'} || '') =>
			1 } @{$self->{'jobs'}->list_pending()};
	opendir(my $dh, $self->directory()) or
		die "Cannot read backup staging directory\n";
	my @ids = map { /^work-([a-f0-9]{32})$/ ? $1 : () } readdir($dh);
	closedir($dh);
	foreach my $id (@ids) {
		# Preserve active restores and any cache still
		# needed for recovery.
		next if ($used{$id});
		my $job = $self->{'jobs'}->get($id) || next;
		next
			if (($job->{'request'}->{'operation'} ||
			     '') ne 'backup_inspect' ||
			    $job->{'state'} ne 'complete' ||
			    $job->{'cleanup_pending'} ||
			    $job->{'updated'} >= time() - 86400);
		$self->clean_work($id);
		}
	});
}

# prepare(self, input, job_id) validates a backup before reserving the source.
sub prepare
{
my ($self, $in, $id) = @_;
die "Install Python 3 before backing up virtual machines\n"
	if (!-x '/usr/bin/python3');
# Reject structured or non-boolean options before reading the source guest.
foreach my $field (qw(shutdown compression)) {
	die "Invalid backup option: $field\n"
		if (defined($in->{$field}) &&
		    (ref($in->{$field}) || $in->{$field} !~ /\A[01]\z/));
	}
# Reuse cloning's managed-disk checks without changing guest identity.
my ($adapter, $domain, $doc, $disks, $nvram) = $self->source($in->{'id'});
check_external_state($doc);
die "Select guest-agent preparation or clean shutdown\n"
	if (($in->{'shutdown'} // 0) !~ /\A[01]\z/);
Cloudmin::Snapshots::check_agent($domain)
	if ($domain->is_active() && !$in->{'shutdown'});
# Attached installer media must be managed file volumes too, never host devices.
foreach my $disk (@$disks) {
	next if ($disk->{'volume'});
	my ($node) =
		grep { $_->findvalue(
			'target/@dev') eq $disk->{'target'} } $doc->findnodes(
				'/domain/devices/disk');
	next if (!$node->exists('source'));
	$disk->{'volume'} = $self->manager()->volume_for($adapter, $node);
	}
die "A backup can contain at most 64 disks and attached media files in total\n"
	if (@$disks > 64);
# Check destination requirements before reserving or stopping the source.
my $target = $self->{'validate_target'}->($in->{'target'}, 0);
Cloudmin::BackupTransport::preflight($target, 0);
# Include managed SSH access only when its ownership marker matches this guest.
my $meta = Cloudmin::Libvirt::extract_metadata($doc->toString());
my $key = ($meta->{'job'} || '') =~ /\A[a-f0-9]{32}\z/
	? $self->{'ssh_keys'}->find($domain->get_uuid_string(),
				    $meta->{'job'})
	: undef;
return { operation => 'backup', uuid => $domain->get_uuid_string(), name =>
									    $domain->get_name(),
	 source_uuid => $domain->get_uuid_string(), source_revision =>
							    Cloudmin::Snapshots::revision($domain),
	 virtualmin => $self->installed_edition($doc),
	 source_xml => $doc->toString(), disks => $disks, nvram => $nvram,
	 ssh_key => $key,
	 nvram_format => $doc->findvalue('/domain/os/nvram/@format') || 'raw',
	 nvram_identity => $nvram
		 ? Cloudmin::VMManage::file_identity($nvram)
		 : '',
	 active => $domain->is_active() ? 1 : 0,
	 shutdown => $in->{'shutdown'} ? 1 : 0,
	 target => $target, compression => $in->{'compression'} ? 1 : 0,
	 schedule => $in->{'schedule'} || '', filename =>
						      archive_filename($domain->get_name(), $id, time(),
								       $in->{'compression'}) };
}

# archive_filename(name, job_id, timestamp, compressed) makes archives
# identifiable. The full job ID still prevents collisions between
# simultaneous submissions.
sub archive_filename
{
my ($name, $id, $time, $compressed) = @_;
$name =~ s/[^a-zA-Z0-9_.-]+/-/g;
$name = substr($name, 0, 100) || 'machine';
return 'cloudmin-'.$name.'-'.strftime('%Y%m%dT%H%M%SZ',
				      gmtime($time))."-$id.tar".($compressed ? '.gz' : '');
}

# firmware_digest(path, identity) hashes a bounded regular NVRAM file. Checking
# both file metadata and content catches writes and replacements.
sub firmware_digest
{
my ($path, $identity) = @_;
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or
	die "Cannot read firmware variables\n";
# Match the opened inode to the source validated before quiescing.
my @before = stat($fh);
die "Invalid firmware variables file\n"
	if (!-f $fh || !$before[7] || $before[7] > 64 * 1024**2 ||
	    join(':', @before[0, 1]) ne $identity);
my $hash = Digest::SHA->new(256);
my ($bytes, $buffer) = ( 0, '' );
# Bound reads even if the live firmware file grows while it is being hashed.
while (1) {
	my $n = read($fh, $buffer, 65536);
	die "Cannot read firmware variables\n" if (!defined($n));
	last if (!$n);
	$bytes += $n;
	die "Firmware variables grew during backup\n"
		if ($bytes > 64 * 1024**2);
	$hash->add($buffer);
	}
# Reject metadata or length changes observed during this read.
my @after = stat($fh); close($fh);
die "Firmware variables changed during backup; retry or choose clean shutdown\n"
	if ($bytes != $before[7] ||
	    join(':', @before[0, 1, 7, 9, 10]) ne join(':',
						       @after[0, 1, 7, 9, 10]));
return $hash->hexdigest();
}

# copy_firmware(source, destination, identity, [before]) accepts only stable
# bytes. For live backup, before is captured immediately
# before the disk snapshot.
sub copy_firmware
{
my ($source, $dest, $identity, $before) = @_;
$before ||= firmware_digest($source, $identity);
Cloudmin::Worker::copy_file($source, $dest, 64 * 1024**2);
die "Firmware variables changed during backup; retry or choose clean shutdown\n"
	if (firmware_digest($source, $identity) ne $before ||
	    firmware_digest($dest,
			    Cloudmin::VMManage::file_identity($dest)) ne $before);
}

# work(self, id) returns this job's private staging path.
sub work
{
Cloudmin::Jobs::validate_id($_[1]); return $_[0]->directory().
					   '/work-'.$_[1];
}

# clean_work(self, id) removes only the job's private staging directory.
sub clean_work
{
my ($self, $id) = @_;
my $work = $self->work($id);
die "Unsafe backup staging directory\n" if (-l $work);
my $errors;
remove_tree($work, { error => \$errors }) if (-d $work);
die "Cannot remove backup staging files\n" if ($errors && @$errors);
}

# cleanup(self, id, adapter) releases the source or removes
# an incomplete restore.
sub cleanup
{
my ($self, $id, $adapter) = @_;
my $job = $self->{'jobs'}->get($id);
my $r = $job->{'request'};
# Stop isolated writers before touching files or reversing libvirt changes.
Cloudmin::Worker->new()->cleanup($job->{'worker'}) if ($job->{'worker'});
if ($r->{'operation'} eq 'backup') {
	# A failed merge or pending shutdown keeps the source
	# reserved for recovery.
	$self->release_source($id, $adapter)
		if ($job->{'resources'}->{'started'});
	}
elsif ($r->{'operation'} eq 'restore') {
	# Rollback may remove only the new guest carrying this
	# restore job's marker.
	$adapter->remove_created_guest($r->{'uuid'}, $id)
		if ($job->{'resources'}->{'domain'});
	$self->{'ssh_keys'}->remove($r->{'uuid'}, $id)
		if ($job->{'resources'}->{'ssh_key'});
	}
# Recovery uses the journalled names even if creation never returned a key.
foreach my $v (@{$job->{'resources'}->{'volumes'} || [ ]}) {
	$adapter->remove_created_volume($v->{'pool'}, $v->{'name'},
					$v->{'key'});
	}
$self->clean_work($id);
}

# backup(self, id, adapter) copies stable disk states, then
# publishes an archive.
sub backup
{
my ($self, $id, $adapter) = @_;
my $jobs = $self->{'jobs'};
my $r = $jobs->get($id)->{'request'};
my $work = $self->work($id);
$self->step($id, 'preflight', sub {
	# A queued job must still have its destination
	# available before quiescing.
	$self->{'validate_target'}->($r->{'target'}, 0);
	my (undef, $source) = $self->source($r->{'source_uuid'});
	die "The virtual machine changed after backup submission\n"
		if (
			Cloudmin::Snapshots::revision(
				$source) ne $r->{'source_revision'});
	# Pools on one filesystem share free space; live disks
	# also need overlay room.
	my (%needed, %paths);
	foreach my $d (grep { $_->{'volume'} } @{$r->{'disks'}}) {
		my $v = $d->{'volume'};
		# Logical volumes use VG or thin-pool space, not
		# the filesystem at /dev.
		next if ($v->{'block'});
		my $path = dirname($v->{'path'});
		my @st = stat($path);
		die "Cannot check backup storage\n" if (!@st);
		$paths{$st[0]} = $path;
		$needed{$st[0]} += $v->{'capacity'} * ($r->{'active'} &&
						       !$r->{'shutdown'} && !$d->{'readonly'}
							       ? 2
							       : 1);
		}
	die "Not enough storage for backup copies and temporary snapshot growth\n"
		if (
			grep { Cloudmin::Worker::free_space(
				$paths{$_}) <
				$needed{$_} + 256 * 1024**2 } keys %needed);
	});
my (%files, @disks);
my $manifest =
	{ format => 'cloudmin-full-1', name => $r->{'name'},
	  uuid => $r->{'uuid'},
	  created => time(), disks => \@disks,
	  virtualmin => $r->{'virtualmin'} };
$self->step($id, 'backup_quiesce', sub {
	# Keep firmware consistent with the disk snapshot, not a
	# later disk-copy time.
	my $before = $r->{'nvram'} && $r->{'active'} && !$r->{'shutdown'}
		? firmware_digest($r->{'nvram'}, $r->{'nvram_identity'})
		: undef;
	$self->quiesce_source($id, $adapter, 'backup');
	# BIOS has no variable store; UEFI needs bytes stable
	# across the snapshot.
	if ($r->{'nvram'}) {
		copy_firmware($r->{'nvram'}, "$work/nvram",
			      $r->{'nvram_identity'}, $before);
		$files{'nvram'} = "$work/nvram";
		$manifest->{'nvram_format'} = $r->{'nvram_format'};
		}
	});
# Clone each stable base into an independent volume, flattening backing chains.
$self->step($id, 'backup_disks', sub {
	foreach my $d (grep { $_->{'volume'} } @{$r->{'disks'}}) {
		$self->checkpoint($id);
		my $v = $self->stable_volume($id, $adapter, $d);
		die "A backup source disk was replaced\n"
			if (
				Cloudmin::VMManage::file_identity(
					$v->{'path'}) ne $v->{'identity'});
		my $i = scalar(@disks);
		my $name = "cloudmin-backup-$id-$i";
		my $format = $v->{'format'} eq 'qcow2' ? 'qcow2' : 'raw';
		# journal() records intent before libvirt can
		# leave a volume behind.
		my $copy = $adapter->clone_disk($v->{'pool'}, $name,
						{ pool => $v->{'pool'},
						  volume => $v->{'name'},
						  volume_key => $v->{'key'} },
						$v->{'capacity'},
						$format, sub {
				$jobs->update($id,
					      sub {
						$_[0]->{'resources'}->{'volumes'}->[$i] = { pool => $v->{'pool'}, name => $name }; });
				});
		$copy->{'pool'} = $v->{'pool'};
		$jobs->update($id,
			      sub { $_[0]->{'resources'}->{'volumes'}->[$i] = $copy; });
		# Verify the copied disk in isolation before adding
		# its manifest mapping.
		$self->worker_task($id, 'inspect', { format => $format },
				   files =>
					   { image => $copy->{'path'} });
		$files{"disk$i"} = $copy->{'path'};
		push(@disks,
		     { file => "disk$i", target => $d->{'target'}, format =>
									   $format, capacity => $v->{'capacity'} });
		}
	});
# Merge overlays or restart the source before compression and remote transfer.
$self->step($id, 'backup_release', sub { $self->release_source($id,
							       $adapter); });
Cloudmin::Worker::write_data("$work/domain.xml", $r->{'source_xml'});
$files{'domain.xml'} = "$work/domain.xml";
$files{'ssh-key'} = $r->{'ssh_key'} if ($r->{'ssh_key'});
# Pack secure metadata and disks together, allowing a free-space margin.
my $packed = $self->step($id, 'backup_archive', sub {
	return $self->worker_task($id, 'backup_archive',
				  { mode => 'pack', manifest => $manifest,
				    members => [ sort keys %files ],
				    compression =>
					    $r->{'compression'},
				    limit =>
					    Cloudmin::Worker::free_space(
						    $work) - 256 * 1024**2 },
				  files => \%files,
				  output => "$work/archive");
	});
$self->step($id, 'backup_upload', sub {
	$self->transfer_file($id, 'put', $r->{'target'}, $r->{'filename'},
			     "$work/archive");
	# Publish the inventory record only after the destination
	# accepts the archive.
	$self->record($id,
		      { id => $id, name => $r->{'name'}, uuid => $r->{'uuid'},
			created =>
				$manifest->{'created'},
			size => $packed->{'size'}, sha256 =>
							   $packed->{'sha256'},
			filename => $r->{'filename'},
			target => $r->{'target'}, destination =>
							  $self->{'target_label'}->($r->{'target'}),
			schedule => $r->{'schedule'} });
	});
# A completed archive no longer needs temporary volumes, even after a restart.
$jobs->update($id, sub { $_[0]->{'resources'}->{'published'} = 1; });
$self->cleanup($id, $adapter);
}

# transfer_file(self, id, operation, target, filename, local)
# journals remote workers.
sub transfer_file
{
my ($self, $id, @args) = @_;
$self->{'transfer'}->(@args, {
	# started(worker_id) lets cancellation locate and stop
	# the transfer service.
	started =>
		sub { my $worker =
			$_[0]; $self->{'jobs'}->update($id,
						       sub { $_[0]->{'worker'} = $worker; }); },
	# progress(...) checks cancellation while the worker
	# is still transferring.
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
$self->step($id, 'backup_download',
	    sub { $self->transfer_file($id, 'get', $r->{'target'},
				       $r->{'filename'},
				       "$work/archive"); });
my $result = $self->step($id, 'backup_verify', sub {
	return $self->worker_task($id, 'backup_archive',
				  { limit => Cloudmin::Worker::free_space($work) - 256 * 1024**2 },
				  files => { archive => "$work/archive" });
	});
# Listed backups must still match their recorded checksum; external ones bind
# confirmation to the checksum observed during this inspection.
validate_manifest($result->{'manifest'});
die "The archive differs from the completed backup\n"
	if ($r->{'expected_sha256'} &&
	    $result->{'sha256'} ne $r->{'expected_sha256'});
$jobs->update($id,
	      sub { $_[0]->{'resources'}->{'manifest'} = $result->{'manifest'};
		$_[0]->{'resources'}->{'archive_sha256'} =
			$result->{'sha256'}; });
}

# validate_manifest(manifest) checks restore identities and disk mappings.
sub validate_manifest
{
my ($m) = @_;
die "Invalid backup machine identity\n" if (($m->{'uuid'} ||
					     '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/ ||
					    ($m->{'name'} || '') !~ /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/);
die "Invalid backup disk list\n"
	if (ref($m->{'disks'}) ne 'ARRAY' || !@{$m->{'disks'}} ||
	    @{$m->{'disks'}} > 64);
# Require a one-to-one mapping between archive members and guest devices.
my (%files, %targets);
foreach my $d (@{$m->{'disks'}}) {
	die "Invalid backup disk mapping\n" if (ref($d) ne 'HASH' ||
						($d->{'file'} || '') !~ /\Adisk\d{1,2}\z/ ||
						($d->{'target'} || '') !~ /\A[a-zA-Z0-9_-]+\z/ ||
						($d->{'format'} ||
						 '') !~ /\A(?:raw|qcow2)\z/ ||
						!$m->{'files'}->{$d->{'file'}} || $files{$d->{'file'}}++ ||
						$targets{$d->{'target'}}++);
	Cloudmin::Worker::byte_limit($d->{'capacity'});
	}
# Only supported firmware formats and known edition markers reach restore.
die "Invalid backup firmware format\n"
	if ($m->{'files'}->{'nvram'} &&
	    ($m->{'nvram_format'} || '') !~ /\A(?:raw|qcow2)\z/);
die "Invalid Virtualmin edition in backup\n"
	if (($m->{'virtualmin'} || '') !~ /\A(?:gpl|pro)?\z/);
die "A backup disk has no device mapping\n"
	if (grep { /^disk\d+$/ && !$files{$_} } keys %{$m->{'files'}});
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
	$names{$disk->{'file'}} = $role =~ /\A(?:system|seed)\z/ &&
				  $counts{$role} == 1
					  ? Cloudmin::VMs::disk_volume_name($manifest->{'name'}, $role,
									    $id,
									    $type)
					  : "cloudmin-$id-$disk->{file}";
	}
return \%names;
}

# prepare_restore(self, input, job_id) binds confirmation to a verified archive.
sub prepare_restore
{
my ($self, $in, $id) = @_;
# A successful inspection is usable only while its verified download remains.
my $inspection = $self->{'jobs'}->get($in->{'inspection'}) ||
		 die "Backup inspection not found\n";
die "Inspect the backup before restoring it\n"
	if (($inspection->{'request'}->{'operation'} ||
	     '') ne 'backup_inspect' ||
	    $inspection->{'state'} ne 'complete');
die "Inspect the backup again; its temporary download has expired\n"
	if (!-f $self->work($inspection->{'id'}).'/archive');
die "Confirm that this restore preserves the original guest identity and will remain stopped\n"
	if (($in->{'confirm'} || '') ne '1');
my $m = $inspection->{'resources'}->{'manifest'};
validate_manifest($m);
# Restore preserves identity and therefore cannot coexist with the original.
my $adapter = $self->{'adapter'}->();
die "A virtual machine with this name or UUID already exists; remove it before restoring this backup\n"
	if (grep { $_->get_name() eq $m->{'name'} ||
		$_->get_uuid_string() eq $m->{'uuid'} }
	    $adapter->connect()->list_all_domains());
my ($pool) =
	grep { $_->{'uuid'} eq ($in->{'pool'} || '') && $_->{'active'} &&
		Cloudmin::Libvirt::disk_pool($_->{'type'}) }
	@{$adapter->list_storage_pools(1)};
die "Select an active storage pool\n" if (!$pool);
# Guest disks use the chosen backend; UEFI variables still need file storage.
return { operation => 'restore', name => $m->{'name'}, uuid => $m->{'uuid'},
	 pool => $pool->{'uuid'}, pool_type => $pool->{'type'},
	 auxiliary_pool => $m->{'files'}->{'nvram'}
		 ? Cloudmin::Libvirt::file_pool($adapter,
						$pool->{'uuid'})->get_uuid_string()
		 : '',
	 inspection => $inspection->{'id'}, manifest => $m, archive_sha256 =>
								    $inspection->{'resources'}->{'archive_sha256'}, start => 0 };
}

# check_external_state(document) rejects host files and devices absent from
# archives. Apply the same boundary before creating a backup and
# before restoring its XML.
sub check_external_state
{
my ($doc) = @_;
# Reject external host resources before handing restored XML to privileged QEMU.
die "The backup contains unsupported external host resources\n"
	if ($doc->exists(
		'//*[local-name()="commandline"] | /domain/devices/filesystem | /domain/devices/hostdev | /domain/devices/tpm | /domain/devices/memory | /domain/devices/shmem | /domain/launchSecurity | /domain/os/varstore | /domain/os/kernel | /domain/os/initrd | /domain/os/dtb | /domain/os/acpi/table | /domain/sysinfo[@type="fwcfg"]/entry[@file] | /domain/devices/disk/source/dataStore'));
die "The backup contains unsupported host devices or extensions\n"
	if ($doc->exists(
		'/domain/bootloader | /domain/bootloader_args | /domain/devices/*[not(self::emulator or self::disk or self::controller or self::interface or self::input or self::graphics or self::video or self::channel or self::serial or self::console or self::rng or self::memballoon or self::watchdog or self::panic or self::audio)] | /domain/*[namespace-uri()!=""] | /domain/devices/*[namespace-uri()!=""] | /domain/devices/*/rom[@file] | /domain/devices/input/source | /domain/devices/audio[@type!="none"]'));
}

# restore_xml(xml, manifest, job_id, volumes, [nvram]) rebinds host resources.
# Guest IDs, MACs, firmware and cloud-init bytes retain their original identity.
sub restore_xml
{
my ($xml, $m, $id, $volumes, $nvram) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
die "The backup XML does not match its manifest\n"
	if ($doc->findvalue('/domain/name') ne $m->{'name'} ||
	    $doc->findvalue('/domain/uuid') ne $m->{'uuid'});
check_external_state($doc);
my %disks = map { $_->{'target'} => $_ } @{$m->{'disks'}};
my %used;
# Replace storage paths and drop backing chains; leave empty media drives empty.
foreach my $disk ($doc->findnodes('/domain/devices/disk')) {
	my $d = $disks{$disk->findvalue('target/@dev')};
	die "The backup is missing a disk from its domain definition\n"
		if (!$d && $disk->exists('source'));
	$_->unbindNode() foreach $disk->findnodes(
		'source | backingStore | mirror | auth | encryption | seclabel');
	next if (!$d);
	die "Duplicate disk target in backup XML\n"
		if ($used{$d->{'target'}}++);
	my $volume = $volumes->{$d->{'file'}};
	$disk->setAttribute('type', $volume->{'block'} ? 'block' : 'file');
	$disk->addNewChild(undef, 'source')->setAttribute($volume->{'block'}
		? 'dev'
		: 'file', $volume->{'path'});
	my ($driver) = $disk->findnodes('driver');
	$driver ||= $disk->addNewChild(undef, 'driver');
	$driver->setAttribute('name', 'qemu'); $driver->setAttribute('type',
								     $volume->{'format'} || $d->{'format'});
	$driver->setAttribute('cache', 'none') if ($volume->{'block'});
	}
die "A backed-up disk is missing from the domain definition\n"
	if (keys(%used) != keys(%disks));
die "The backup firmware has no matching domain device\n"
	if ($nvram && !$doc->exists('/domain/os/nvram'));
# Use the archived variables and verified format, never a host template.
foreach my $node ($doc->findnodes('/domain/os/nvram')) {
	die "The backup is missing its UEFI variables\n" if (!$nvram);
	$node->removeChildNodes(); $node->removeAttribute('type');
	$node->removeAttribute($_) for qw(template templateFormat);
	$node->appendText($nvram->{'path'});
	$node->setAttribute('format', $m->{'nvram_format'});
	}
# Only the ordinary host random source can be rebound safely.
foreach my $node ($doc->findnodes('/domain/devices/rng/backend')) {
	die "The backup contains an unsupported random source\n"
		if (($node->getAttribute('model') || '') ne 'random');
	$node->removeChildNodes(); $node->appendText('/dev/urandom');
	}
# Libvirt allocates fresh host sockets, ports and console paths on restore.
foreach my $node (
	$doc->findnodes('/domain/devices/serial | /domain/devices/console')) {
	$node->setAttribute('type',
			    'pty'); $_->unbindNode() foreach $node->findnodes(
				    'source | log');
	}
foreach my $node ($doc->findnodes('/domain/devices/channel')) {
	die "The backup contains an unsupported channel\n"
		if ($node->findvalue(
			'target/@name') ne 'org.qemu.guest_agent.0');
	$node->setAttribute('type',
			    'unix'); $_->unbindNode() foreach $node->findnodes(
				    'source | log');
	}
foreach my $node ($doc->findnodes('/domain/devices/interface')) {
	die "The backup contains an unsupported network interface\n"
		if ($node->getAttribute('type') !~ /\A(?:network|bridge)\z/ ||
		    $node->exists('filterref | script | backend'));
	# Copy only the attachment name, excluding arbitrary
	# host device attributes.
	my $attribute = $node->getAttribute('type') eq 'bridge'
		? 'bridge'
		: 'network';
	my $attachment = $node->findvalue('source/@'.$attribute);
	$_->unbindNode() foreach $node->findnodes(
		'target | virtualport | source');
	$node->addNewChild(undef, 'source')->setAttribute($attribute,
							  $attachment);
	}
# Restored VNC consoles must not expose an old address or reuse host ports.
foreach my $node ($doc->findnodes('/domain/devices/graphics')) {
	die "The backup contains an unsupported graphical console\n"
		if ($node->getAttribute('type') ne 'vnc');
	$node->setAttribute('listen', '127.0.0.1'); $node->setAttribute('port',
									'-1'); $node->setAttribute('autoport', 'yes');
	$node->removeAttribute($_) for qw(socket websocket tlsPort);
	$_->unbindNode() foreach $node->findnodes('listen');
	my $listen =
		$node->addNewChild(undef,
				   'listen'); $listen->setAttribute('type',
								    'address'); $listen->setAttribute('address',
												      '127.0.0.1');
	}
# Let libvirt regenerate host labels and aliases; mark ownership for rollback.
$_->unbindNode() foreach $doc->findnodes(
	'/domain/seclabel | /domain/devices/*/alias');
my ($metadata) = $doc->findnodes('/domain/metadata');
$metadata ||= $doc->documentElement()->addNewChild(undef, 'metadata');
my ($cloudmin) = $metadata->findnodes('*[namespace-uri()="urn:cloudmin:vm:1"]');
$cloudmin ||= $metadata->addNewChild('urn:cloudmin:vm:1', 'vm');
$_->unbindNode() foreach $cloudmin->findnodes('*[local-name()="job"]');
$cloudmin->addNewChild('urn:cloudmin:vm:1', 'job')->appendText($id);
return $doc->toString();
}

# host_xml(self, xml, adapter) validates host-specific hardware before import.
sub host_xml
{
my ($self, $xml, $adapter) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
my $caps =
	$adapter->get_host_capabilities($doc->findvalue(
		'/domain/os/type/@arch'));
my $machine = $doc->findvalue('/domain/os/type/@machine');
my $domain =
	Cloudmin::Libvirt::parse_xml_document(
		$adapter->connect()->get_domain_capabilities(
			undef, $caps->{'architecture'}, $machine || undef,
			'kvm',
			0));
# Firmware must come from this host's supported loader list, not archive paths.
my %loaders =
	map { $_->textContent() =>
		1 } $domain->findnodes('/domainCapabilities/os/loader/value');
foreach my $loader ($doc->findnodes('/domain/os/loader')) {
	die "This host does not provide the backup's firmware\n"
		if (!$loaders{$loader->textContent()});
	$loader->setAttribute('readonly', 'yes');
	}
# Use the destination host's emulator for the archived guest architecture.
my ($devices) = $doc->findnodes('/domain/devices');
$_->unbindNode() foreach $devices->findnodes('emulator');
$devices->addNewChild(undef, 'emulator')->appendText($caps->{'emulator'});
return $doc->toString();
}

# restore(self, id, adapter) imports verified disks and defines a stopped guest.
sub restore
{
my ($self, $id, $adapter) = @_;
my $jobs = $self->{'jobs'};
my $r = $jobs->get($id)->{'request'};
my $m = $r->{'manifest'};
my $work = $self->work($id);
# Worker output names come from the validated manifest, never archive paths.
my %outputs = map { $_ => "$work/$_" } keys %{$m->{'files'}};
my $xml;
$self->step($id, 'backup_verify', sub {
	# Re-verify during extraction so confirmation cannot
	# authorize changed bytes.
	my $result =
		$self->worker_task($id, 'backup_archive',
				   { extract => 1, limit =>
							   Cloudmin::Worker::free_space(
								   $work) - 256 * 1024**2 },
				   files =>
					   { archive => $self->work($r->{'inspection'}).
							'/archive' },
				   outputs => \%outputs);
	die "The backup changed since inspection\n"
		if ($result->{'sha256'} ne $r->{'archive_sha256'});
	open(my $fh, '<', "$work/domain.xml") or
		die "Cannot read restored domain XML\n";
	local $/; $xml = <$fh>; close($fh);
	$xml = $self->host_xml($xml, $adapter);
	# Validate all device mappings before allocating destination volumes.
	restore_xml(
		$xml, $m, $id,
		{ map { $_ => { path => "$work/$_" } } keys %outputs },
		$m->{'files'}->{'nvram'} ? { path => "$work/nvram" } : undef);
	});
my (%volumes, $nvram);
$self->step($id, 'restore_disks', sub {
	# File and thick destinations need room for full disk capacities. Thin
	# disks check data and metadata usage during allocation and uploads.
	my $pool = Cloudmin::Libvirt::storage_pool($adapter, $r->{'pool'});
	my $names = restore_volume_names($xml, $m, $id, $r->{'pool_type'});
	my $needed = 0; $needed += $_->{'capacity'} for @{$m->{'disks'}};
	die "Not enough space to restore these disks\n"
		if (($r->{'pool_type'} || '') ne 'lvmthin' &&
		    $pool->get_info()->{'available'} <
		    $needed + 256 * 1024**2);
	foreach my $d ( @{$m->{'disks'}}, $m->{'files'}->{'nvram'}
		? ({ file => 'nvram', format => $m->{'nvram_format'} })
		: () ) {
		$self->checkpoint($id);
		my $f = $d->{'file'};
		my $info =
			$self->worker_task($id, 'inspect',
					   { format => $d->{'format'} },
					   files => { image => "$work/$f" });
		die "Restored disk capacity differs from the backup manifest\n"
			if ($d->{'capacity'} &&
			    $info->{'virtual-size'} != $d->{'capacity'});
		my $name = $names->{$f} || "cloudmin-$id-$f";
		my $destination = $f eq 'nvram'
			? $r->{'auxiliary_pool'} || $r->{'pool'}
			: $r->{'pool'};
		my $slot =
			scalar(@{$jobs->get(
				$id)->{'resources'}->{'volumes'} ||
				[ ]});
		# journal() covers interrupted imports before the
		# final volume key exists.
		my $volume =
			$adapter->upload_seed($destination, $name,
					      "$work/$f", sub {
					$jobs->update($id,
						      sub { $_[0]->{'resources'}->{'volumes'}->[$slot] =
							{ pool => $destination,
							  name => $name }; });
					}, $d->{'format'}, $d->{'capacity'} ||
					      $info->{'virtual-size'});
		$volume->{'pool'} = $destination;
		$jobs->update($id,
			      sub {
				$_[0]->{'resources'}->{'volumes'}->[$slot] =
					$volume; });
		# Firmware is attached under os/nvram; ordinary
		# members map to disks.
		if ($f eq 'nvram') { $nvram = $volume; }
		# Keep disk members indexed by manifest name
		# for XML replacement.
		else { $volumes{$f} = $volume; }
		}
	});
$self->step($id, 'define', sub {
	$xml = restore_xml($xml, $m, $id, \%volumes, $nvram);
	# Restore managed SSH access only when the archive
	# contains its private key.
	if ($m->{'files'}->{'ssh-key'}) {
		$jobs->update($id,
			      sub { $_[0]->{'resources'}->{'ssh_key'} = 1; });
		Cloudmin::Worker::copy_file("$work/ssh-key",
					    $self->{'ssh_keys'}->destination($r->{'uuid'}, $id),
					    16384);
		}
	# Record intent before definition; a recovered guest must stay stopped.
	$jobs->update($id, sub { $_[0]->{'resources'}->{'domain'} = 1; });
	$adapter->define_guest($xml);
	$adapter->set_domain_autostart($r->{'uuid'}, 0);
	$jobs->update($id,
		      sub { $_[0]->{'resources'}->{'virtualmin'} =
			$m->{'virtualmin'} ||
			      ''; });
	});
$self->clean_work($id);
# The successful restore no longer needs its confirmed download.
$self->clean_work($r->{'inspection'});
}

# run(self, id) uses the durable job journal for completion,
# rollback and recovery.
sub run
{
my ($self, $id) = @_;
my $jobs = $self->{'jobs'};
# The shared VM work lock serializes disk work across manual and scheduled jobs.
return $jobs->run_worker($id, sub {
	my $job = $jobs->get($id);
	my $r = $job->{'request'};
	my $adapter = $self->{'adapter'}->();
	# Record conversion leases in this backup/restore job for safe recovery.
	$adapter->{'disk_worker'} = sub { $self->worker_task($id, @_); };
	my $ok = eval {
		# Re-entered jobs roll back; replaying a partly
		# completed copy is unsafe.
		die "Backup operation was interrupted\n"
			if ($job->{'state'} ne 'queued');
		$jobs->update($id, sub { $_[0]->{'state'} = 'running'; });
		make_path($self->work($id), { mode => 0700 });
		# Backups must release their source before publishing
		# a completed archive.
		if ($r->{'operation'} eq 'backup') {
			$self->backup($id, $adapter);
			}
		# Restores import only the previously inspected archive.
		elsif ($r->{'operation'} eq 'restore') {
			$self->restore($id, $adapter);
			}
		# Inspection keeps its download for a later
		# confirmation request.
		else { $self->inspect_backup($id); }
		# Completion and a late cancellation compete in
		# one job transaction.
		$self->checkpoint($id);
		$jobs->update($id,
			      sub { die "Backup operation cancelled\n"
				if ($_[0]->{'cancel'});
				$_[0]->{'state'} =
					'complete'; delete(
						$_[0]->{'request'}->{'source_xml'}); });
		1;
		};
	my $error = $@;
	# Provider diagnostics must not expose credentials saved in the request.
	foreach my $field (
		qw(password secret session_token refresh_token access)) {
		my $secret = ($r->{'target'} || { })->{$field};
		$error =~ s/\Q$secret\E/[redacted]/g if ($secret);
		}
	# Failed cleanup keeps reservations held for an
	# explicit recovery attempt.
	if (!$ok) {
		my $clean = eval { $self->cleanup($id, $adapter); 1 };
		$error .= "; cleanup needs attention: $@" if (!$clean);
		$jobs->update($id, sub {
			$_[0]->{'state'} = $_[0]->{'cancel'} && $clean
				? 'cancelled'
				: 'failed';
			$_[0]->{'cleanup_pending'} = $clean ? 0 : 1;
			$_[0]->{'error'} =
				substr(Cloudmin::Libvirt::error_message($error),
				       0,
				       2000);
			$_[0]->{'events'}->[-1]->{'state'} = $_[0]->{'state'}
				if (@{$_[0]->{'events'}});
			delete($_[0]->{'request'}->{'source_xml'});
			});
		}
	# Audit failure must not undo a completed archive or
	# successful rollback.
	eval { $jobs->audit($r->{'operation'}.($ok
		? '_complete'
		: '_failed'), $jobs->get($id)); };
	return $ok ? 1 : 0;
	});
}

1;
