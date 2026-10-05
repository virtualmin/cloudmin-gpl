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

# installed_edition(self, document) reads recorded setup, not the guest's name.
# Offline inspection later checks what is actually installed on the copied disk.
sub installed_edition
{
my ($self, $doc) = @_;
# Trust only a journal record whose destination UUID matches this domain.
my $id = $doc->findvalue('/domain/metadata/*[namespace-uri()="urn:cloudmin:vm:1"]/*[local-name()="job"]');
return '' if ($id !~ /\A[a-f0-9]{32}\z/);
my $job = $self->{'jobs'}->get($id) || return '';
return '' if (($job->{'request'}->{'uuid'} || '') ne $doc->findvalue('/domain/uuid'));
# Clones and captured images record the inspected edition; restores retain it.
return $job->{'resources'}->{'virtualmin'} || '' if (($job->{'request'}->{'operation'} || '') =~ /\A(?:clone|restore)\z/ ||
	$job->{'request'}->{'source_image'}->{'prepared_vm'});
return $1 if ($job->{'resources'}->{'software'} && $job->{'state'} eq 'complete' &&
	($job->{'request'}->{'software'} || '') =~ /\Avirtualmin-(gpl|pro)\z/);
return '';
}

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

# choices(self, uuid) exposes source defaults without secure XML or disk paths.
sub choices
{
my ($self, $uuid) = @_;
my ($adapter, $domain, $doc, $disks, $nvram) = $self->source($uuid);
my $settings = $self->manager()->settings($uuid);
my $options = $self->options();
# Match the source's first interface to a currently available attachment.
my $nic = $settings->{'interfaces'}->[0] || {};
my ($network) = grep { $_->{'type'} eq ($nic->{'type'} || '') &&
	$_->{'source'} eq ($nic->{'source'} || '') } @{$options->{'networks'}};
return { id => $uuid, name => $domain->get_name(), revision => Cloudmin::Snapshots::revision($domain),
	active => $domain->is_active() ? 1 : 0, nvram => $nvram ? 1 : 0,
	virtualmin => $self->installed_edition($doc),
	cpus => $settings->{'cpus'}, memory_mib => $settings->{'memory_mib'},
	pool => (grep { !$_->{'readonly'} } @$disks)[0]->{'volume'}->{'pool'},
	network => $network ? $network->{'key'} : '',
	disks => [map { {target => $_->{'target'}, bytes => $_->{'volume'}->{'capacity'}} } grep { !$_->{'readonly'} } @$disks],
	options => $options };
}

# prepare(self, input, job_id, [password_hash]) validates before reserving disks.
# Prepared copies accept creation's access/network options; unchanged copies
# retain guest settings except host ID and Pro credentials, and stay stopped.
sub prepare
{
my ($self, $input, $id, $hash) = @_;
my ($adapter, $domain, $doc, $disks, $nvram) = $self->source($input->{'id'});
my $revision = Cloudmin::Snapshots::revision($domain);
# Refuse stale forms before resolving defaults or allocating a destination.
die "The source virtual machine changed; reload the clone page\n"
	if (($input->{'revision'} || '') ne $revision);
my $mode = $input->{'clone_mode'} || 'prepared';
die "Select prepared or unchanged cloning\n" if ($mode !~ /\A(?:prepared|unchanged)\z/);
foreach my $field (qw(start autostart shutdown confirm_unchanged confirm_license host_ssh_key)) {
	die "Invalid clone $field option\n" if (defined($input->{$field}) &&
		(ref($input->{$field}) || $input->{$field} !~ /\A[01]\z/));
}
# Copies that keep guest settings must stay stopped for manual review.
die "Confirm that this copy keeps guest settings but resets its host ID and Pro license credentials\n"
	if ($mode eq 'unchanged' && !$input->{'confirm_unchanged'});
die "Copies that keep guest settings must remain stopped with automatic startup disabled\n"
	if ($mode eq 'unchanged' && ($input->{'start'} || $input->{'autostart'}));
die "Prepared cloning supports Cloudmin seed disks only; detach other read-only disks or choose an unchanged copy\n"
	if ($mode eq 'prepared' && grep { $_->{'readonly'} && $_->{'volume'} && !$_->{'seed'} } @$disks);
my $edition = $self->installed_edition($doc);
# Both modes must remove copied Pro credentials inside the offline appliance.
die "Confirm that the clone's Virtualmin Pro license credentials will be removed; add a separate Pro license or downgrade manually to GPL\n"
	if ($edition eq 'pro' && !$input->{'confirm_license'});
die "Cloning requires libguestfs and its Perl bindings to reset the host ID and remove copied Pro credentials\n"
	if (!eval { require Sys::Guestfs; 1 });
die "Prepared cloning requires YAML::XS 0.69 or later\n"
	if ($mode eq 'prepared' && !eval { require YAML::XS; YAML::XS->VERSION(0.69); 1 });
die "Install bsdtar for cloning\n" if (!-x '/usr/bin/bsdtar');
# Prepared network configuration currently addresses exactly one interface.
my @interfaces = $doc->findnodes('/domain/devices/interface');
die "Prepared cloning currently requires one network interface; choose an unchanged copy instead\n"
	if ($mode eq 'prepared' && @interfaces != 1);
my $firmware = $input->{'nvram_mode'} ||
	($domain->is_active() && !$input->{'shutdown'} ? 'fresh' : 'copy');
die "Select copied or fresh UEFI variables\n" if ($firmware !~ /\A(?:copy|fresh)\z/);
if ($domain->is_active() && !$input->{'shutdown'}) {
	# A filesystem freeze does not make a live firmware-variable file immutable.
	die "Shut down the source to copy its UEFI variables, or explicitly select fresh variables\n"
		if ($nvram && $firmware eq 'copy');
	Cloudmin::Snapshots::check_agent($domain);
}
my $options = $self->options();
my ($primary) = grep { !$_->{'readonly'} } @$disks;
my $settings = $self->manager()->settings($input->{'id'});
my ($nic) = @interfaces;
my $network = $nic && $nic->getAttribute('type') eq 'bridge' ? 'bridge:'.$nic->findvalue('source/@bridge') : '';
if ($nic && !$network) {
	# Resolve a libvirt network name to the selector's stable network key.
	my ($match) = grep { $_->{'source'} eq $nic->findvalue('source/@network') } @{$options->{'networks'}};
	$network = $match->{'key'} if ($match);
}
# Reuse creation validation with the source disk standing in for an image.
my %values = (cpus => $settings->{'cpus'}, memory_mib => $settings->{'memory_mib'},
	disk_gib => $primary->{'volume'}->{'capacity'}/1024**3,
	pool => $primary->{'volume'}->{'pool'}, network => $network, username => 'cloudmin',
	auth_type => 'password', address_mode => 'dhcp', start => 0, autostart => 0, %$input,
	image => 'clone-source', install_source => $mode eq 'prepared' ? 'cloud' : 'iso',
	firmware => $doc->exists('/domain/os/loader') ? 'efi' : 'bios', software => 'none');
# Templates cannot schedule installation or scripts on a copied guest.
delete(@values{Cloudmin::Software::fields()});
$values{'require_fqdn'} = 1 if ($edition && $mode eq 'prepared');
my $image = { id => 'clone-source', name => $domain->get_name(),
	format => $mode eq 'prepared' ? 'qcow2' : 'iso', cloud_init => 1,
	architecture => $doc->findvalue('/domain/os/type/@arch'),
	virtual_size => $primary->{'volume'}->{'capacity'},
	min_disk_bytes => $primary->{'volume'}->{'capacity'} };
my $r = $self->SUPER::prepare(\%values, { %$options, images => [$image], catalogue_images => [] }, $hash);
# Count secondary disks and retained read-only disks in the destination budget.
my ($pool) = grep { $_->{'id'} eq $r->{'pool'} } @{$options->{'pools'}};
my $bytes = $r->{'disk_gib'} * 1024**3;
$bytes += $_->{'volume'}->{'capacity'} foreach grep { $_->{'volume'} && $_ != $primary &&
	(!$_->{'readonly'} || $mode eq 'unchanged') } @$disks;
# File and thick pools need room for full disk capacities after flattening.
# The LVM driver checks thin-pool data and metadata usage during allocation.
die "The destination pool needs space for all cloned disks plus 256 MiB\n"
	if (($pool->{'type'} || '') ne 'lvmthin' && $bytes > $pool->{'available'} - 256*1024**2);
my $hex;
# Virtualmin uses the first eight DMI UUID digits, not the full domain UUID.
my %oldids = map { lc(substr($_, 0, 8)) => 1 }
	map { $_->textContent() } $doc->findnodes('/domain/uuid | /domain/hwuuid | /domain/sysinfo/system/entry[@name="uuid" or @name="serial"]');
do { $hex = Cloudmin::Images::generate_id(); } while ($oldids{substr($hex, 0, 8)});
# Persist source identity and copy choices so recovery needs no browser input.
@$r{qw(operation clone_mode source_uuid source_name source_revision source_xml disks nvram nvram_mode shutdown active confirm_license)} =
	('clone', $mode, $input->{'id'}, $domain->get_name(), $revision, $doc->toString(),
	$disks, $nvram, $firmware, $input->{'shutdown'} ? 1 : 0, $domain->is_active() ? 1 : 0,
	$input->{'confirm_license'} ? 1 : 0);
$r->{'uuid'} = join('-', substr($hex,0,8), substr($hex,8,4), '4'.substr($hex,13,3), '8'.substr($hex,17,3), substr($hex,20,12));
# VNC permits at most eight characters, as in ordinary VM creation.
$r->{'console_password'} = substr(Cloudmin::Images::generate_id(), 0, 8);
$r->{'virtualmin'} = $edition;
$r->{'nvram_identity'} = Cloudmin::VMManage::file_identity($nvram) if ($nvram);
# Copied firmware stays in a file pool even when guest disks move to LVM.
$r->{'auxiliary_pool'} = Cloudmin::Libvirt::file_pool($adapter, $r->{'pool'})->get_uuid_string()
	if ($nvram && $firmware eq 'copy');
$r->{'nvram_format'} = $doc->findvalue('/domain/os/nvram/@format') || 'raw';
# Preserve preset IDs for reporting; workers consume the resolved values.
$r->{'host_ssh_key'} = $mode eq 'prepared' && $input->{'host_ssh_key'} ? 1 : 0;
$r->{$_} = $input->{$_} for grep { $input->{$_} } qw(template plan);
delete($r->{'source_image'});
return $r;
}

# checkpoint(self, id) observes cancellation between safe disk-operation steps.
sub checkpoint
{
die "Virtual machine operation cancelled\n" if ($_[0]->{'jobs'}->get($_[1])->{'cancel'});
}

# set_text(document, xpath, value) updates a required scalar XML element.
sub set_text
{
my ($doc, $xpath, $value) = @_;
my ($node) = $doc->findnodes($xpath);
die "Missing cloned domain field $xpath\n" if (!$node);
$node->removeChildNodes(); $node->appendText($value);
}

# domain_xml(request, id, volumes, [seed], [nvram]) rewrites host identities.
# Inactive secure XML supplies hardware; runtime paths and credentials are reset.
sub domain_xml
{
my ($r, $id, $volumes, $seed, $nvram) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($r->{'source_xml'});
# Replace the domain identity and discard source-specific resource constraints.
set_text($doc, '/domain/name', $r->{'name'});
set_text($doc, '/domain/uuid', $r->{'uuid'});
set_text($doc, '/domain/memory', $r->{'memory_mib'});
($doc->findnodes('/domain/memory'))[0]->setAttribute('unit', 'MiB');
foreach my $node ($doc->findnodes('/domain/currentMemory | /domain/vcpus | /domain/cputune | /domain/numatune | /domain/cpu/topology | /domain/cpu/numa | /domain/sysinfo | /domain/hwuuid | /domain/genid | /domain/seclabel | /domain/metadata')) {
	$node->unbindNode();
}
# Do not expose the source or physical host's DMI identity in the clone.
$_->setAttribute('mode', 'emulate') foreach $doc->findnodes('/domain/os/smbios');
set_text($doc, '/domain/vcpu', $r->{'cpus'});
($doc->findnodes('/domain/vcpu'))[0]->removeAttribute('current');
my $meta = $doc->documentElement()->addNewChild(undef, 'metadata');
# Bind Cloudmin metadata to this job and its new guest access settings.
my $vm = $meta->addNewChild('urn:cloudmin:vm:1', 'vm');
foreach my $field (qw(job template network ipv4 ipv6 username)) {
	$vm->addNewChild('urn:cloudmin:vm:1', $field)->appendText($field eq 'job' ? $id : $r->{$field} || '');
}
my $index = 0;
foreach my $disk ($doc->findnodes('/domain/devices/disk')) {
	if ($disk->exists('readonly') && (($r->{'clone_mode'} || 'prepared') ne 'unchanged' || $disk->getAttribute('device') ne 'disk') || !$disk->exists('source')) {
		# Discard the old seed and detach installation media from the new machine.
		# Remove disk devices that have no source in the copy.
		if ($disk->getAttribute('device') eq 'disk') { $disk->unbindNode(); }
		# Keep removable drives, but detach their source media.
		else { $_->unbindNode() foreach $disk->findnodes('source | backingStore'); }
		next;
	}
	# Use independent copies in source order, without backing links or disk IDs.
	$_->unbindNode() foreach $disk->findnodes('source | backingStore | serial | wwn');
	my $volume = $volumes->[$index++];
	$disk->setAttribute('type', $volume->{'block'} ? 'block' : 'file');
	$disk->addNewChild(undef, 'source')->setAttribute($volume->{'block'} ? 'dev' : 'file', $volume->{'path'});
	($disk->findnodes('driver'))[0]->setAttribute('type', $volume->{'format'} || 'qcow2');
	($disk->findnodes('driver'))[0]->setAttribute('cache', 'none') if ($volume->{'block'});
}
if ($seed) {
	# Assign the new seed the first free virtio target after the system disk.
	my %used = map { $_->getValue() => 1 } $doc->findnodes('/domain/devices/disk/target/@dev');
	my ($target) = grep { !$used{$_} } map { 'vd'.$_ } 'b'..'z';
	die "No free target for the clone seed\n" if (!$target);
	# Present NoCloud data as a read-only raw disk on the existing virtio bus.
	my ($devices) = $doc->findnodes('/domain/devices');
	my $disk = $devices->addNewChild(undef, 'disk');
	$disk->setAttribute('type', $seed->{'block'} ? 'block' : 'file'); $disk->setAttribute('device','disk');
	my $driver = $disk->addNewChild(undef,'driver');
	$driver->setAttribute('name','qemu'); $driver->setAttribute('type','raw');
	$disk->addNewChild(undef,'source')->setAttribute($seed->{'block'} ? 'dev' : 'file',$seed->{'path'});
	my $t = $disk->addNewChild(undef,'target');
	$t->setAttribute('dev',$target); $t->setAttribute('bus','virtio');
	$disk->addNewChild(undef,'readonly');
}
$index = 0;
# Every NIC gets a fresh MAC; unchanged copies may retain additional NICs.
foreach my $nic ($doc->findnodes('/domain/devices/interface')) {
	$_->unbindNode() foreach $nic->findnodes('mac | target | alias | filterref');
	my $mac = $index++ == 0 ? $r->{'mac'} : '52:54:00:'.join(':',substr(Cloudmin::Images::generate_id(),0,6) =~ /../g);
	$nic->addNewChild(undef,'mac')->setAttribute('address',$mac);
	if ($index == 1) {
		# Only the primary interface uses the clone form's selected attachment.
		$_->unbindNode() foreach $nic->findnodes('source');
		my $type = $r->{'attachment'}->{'type'};
		$nic->setAttribute('type',$type);
		$nic->addNewChild(undef,'source')->setAttribute($type,$r->{'attachment'}->{'source'});
	}
}
# Restrict the new VNC console to localhost with a fresh password and port.
foreach my $graphics ($doc->findnodes('/domain/devices/graphics')) {
	$graphics->setAttribute('passwd',$r->{'console_password'});
	$graphics->setAttribute('autoport','yes'); $graphics->setAttribute('port','-1');
	$graphics->setAttribute('listen','127.0.0.1');
	$graphics->removeAttribute($_) foreach qw(socket passwdValidTo tlsPort websocket);
	$_->unbindNode() foreach $graphics->findnodes('listen');
	my $listen = $graphics->addNewChild(undef,'listen');
	$listen->setAttribute('type','address'); $listen->setAttribute('address','127.0.0.1');
}
# Let libvirt allocate fresh terminal paths instead of reusing source files.
foreach my $serial ($doc->findnodes('/domain/devices/serial | /domain/devices/console')) {
	$serial->setAttribute('type','pty');
	$_->unbindNode() foreach $serial->findnodes('source | log');
}
foreach my $channel ($doc->findnodes('/domain/devices/channel')) {
	# Drop custom channels that do not belong to the copied guest agent.
	if ($channel->findvalue('target/@name') ne 'org.qemu.guest_agent.0') { $channel->unbindNode(); }
	# Let libvirt allocate a socket for the copied guest agent.
	else { $_->unbindNode() foreach $channel->findnodes('source'); }
}
# A copied path preserves variables; an empty node requests fresh variables.
foreach my $node ($doc->findnodes('/domain/os/nvram')) {
	$node->removeChildNodes(); $node->removeAttribute('type');
	$node->appendText($nvram->{'path'}) if ($nvram);
}
return $doc->toString();
}

# quiesce_source(self, id, adapter, [prefix]) snapshots or stops the source.
# prefix defaults to clone and distinguishes backup snapshot and overlay names.
# Journal intent before libvirt so recovery can attempt to release the source.
sub quiesce_source
{
my ($self, $id, $adapter, $prefix) = @_;
$prefix ||= 'clone';
my $jobs = $self->{'jobs'};
my $r = $jobs->get($id)->{'request'};
my $source = $adapter->find_domain($r->{'source_uuid'});
$jobs->update($id, sub { $_[0]->{'resources'}->{'started'} = 1; });
if ($source->is_active() && $r->{'shutdown'}) {
	# Journal shutdown before sending ACPI so cancellation can restore it.
	$jobs->update($id, sub { $_[0]->{'resources'}->{'shutdown_requested'} = 1; });
	$source->shutdown();
	# Keep cancellation responsive while waiting for the guest to shut down.
	my $deadline = time()+120;
	while ($source->is_active()) {
		die "The source virtual machine did not shut down\n" if (time() >= $deadline);
		$self->checkpoint($id); sleep(1);
	}
	$jobs->update($id, sub { $_[0]->{'resources'}->{'shutdown_complete'} = 1; });
}
# Capture a running source without shutting it down.
elsif ($source->is_active()) {
	my @writable = grep { !$_->{'readonly'} } @{$r->{'disks'}};
	if (grep { $_->{'volume'}->{'block'} } @writable) {
		# Native LVM snapshots keep guest writes on the original logical volumes.
		die "Shut down the source to copy mixed file-backed and LVM disks\n"
			if (grep { !$_->{'volume'}->{'block'} } @writable);
		# Reject an unresponsive agent before pausing the guest or allocating volumes.
		Cloudmin::Snapshots::check_agent($source);
		$r->{'native_lvm'} = 1;
		$r->{'snapshot'} = 'cloudmin-'.$id;
		$r->{'mode'} = 'prepared';
		$r->{'description'} = 'Temporary full '.$prefix;
		$jobs->update($id, sub { $_[0]->{'request'} = $r; $_[0]->{'resources'}->{'snapshot'} = 1; });
		$self->snapshots()->apply_native($id, $adapter, $source, undef, 1);
		return;
		}
	# Freeze via the agent and move writes to temporary external overlays.
	Cloudmin::Snapshots::check_agent($source);
	$r->{'snapshot'} = 'cloudmin-'.$prefix.'-'.$id;
	foreach my $disk (@{$r->{'disks'}}) {
		# Read-only media cannot receive writes and need no temporary
		# overlay.
		next if ($disk->{'readonly'});
		$disk->{'overlay'} = dirname($disk->{'volume'}->{'path'}).'/cloudmin-'.$prefix.'-'.$id.'-'.$disk->{'target'}.'.qcow2';
		die "Temporary snapshot overlay already exists\n" if (-e $disk->{'overlay'} || -l $disk->{'overlay'});
	}
	$jobs->update($id, sub { $_[0]->{'request'} = $r; $_[0]->{'resources'}->{'snapshot'} = 1; $_[0]->{'resources'}->{'quiescing'} = 1; });
	# Disk-only, atomic, quiesced snapshots leave the copied bases stable.
	$source->create_snapshot(Cloudmin::Snapshots::snapshot_xml({ %$r, description => 'Temporary full '.$prefix }), 16|128|64);
	$jobs->update($id, sub { delete($_[0]->{'resources'}->{'quiescing'}); });
}
}

1;
