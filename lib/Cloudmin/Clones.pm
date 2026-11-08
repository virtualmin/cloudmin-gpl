package Cloudmin::Clones;

# Full VM clones share creation's isolated workers and durable job journal.
use strict;
use warnings;
use File::Basename qw(dirname);
use Digest::SHA qw(sha256_hex);
use WebminCore qw(make_dir convert_to_json);
require(dirname(__FILE__).'/VMs.pm');
require(dirname(__FILE__).'/Snapshots.pm');
require(dirname(__FILE__).'/TPM.pm');
our @ISA = ('Cloudmin::VMs');

# manager(self) supplies managed-volume and domain validation.

sub manager
{
return Cloudmin::VMManage->new(%{$_[0]});
}

# snapshots(self) supplies file and LVM snapshot validation and operations.

sub snapshots
{
return Cloudmin::Snapshots->new(%{$_[0]});
}

# installed_edition(self, document) reads recorded setup, not the guest's name.
# Offline inspection later checks what is actually installed on the copied disk.

sub installed_edition
{
my ($self, $doc) = @_;
# Trust only a journal record whose destination UUID matches this domain.
my $id =
	$doc->findvalue(
		'/domain/metadata/*[namespace-uri()="urn:cloudmin:vm:1"]/*[local-name()="job"]');
return '' if ($id !~ /\A[a-f0-9]{32}\z/);
my $job = $self->{'jobs'}->get($id) || return '';
return ''
	if (($job->{'request'}->{'uuid'} ||
	     '') ne $doc->findvalue('/domain/uuid'));
# Clones and captured images record the inspected edition; restores retain it.
return $job->{'resources'}->{'virtualmin'} ||
       '' if (($job->{'request'}->{'operation'} ||
	       '') =~ /\A(?:clone|restore)\z/ ||
	      $job->{'request'}->{'source_image'}->{'prepared_vm'});
return $1
	if ($job->{'resources'}->{'software'} &&
	    $job->{'state'} eq 'complete' &&
	    ($job->{'request'}->{'software'} ||
	     '') =~ /\Avirtualmin-(gpl|pro)\z/);
return '';
}

# source(self, uuid, [copy_tpm]) validates storage before copying anything.
# copy_tpm defaults to false; backups and image capture still reject TPMs.
# Returns the adapter, domain, XML, disks, NVRAM path and optional TPM state.

sub source
{
my ($self, $uuid, $copy_tpm) = @_;
my ($adapter, $domain, $doc) = $self->manager()->get_guest($uuid);
# Cloning may accept TPM state only after its separate storage checks pass.
my $tpm = $copy_tpm ? Cloudmin::TPM::source($adapter, $domain, $doc) : undef;
Cloudmin::Snapshots::check_guest($domain, $doc, $tpm);
# Reject unsupported consoles before inspecting or copying any storage.
die "Cloning supports VNC graphical consoles\n"
	if ($doc->exists('/domain/devices/graphics[not(@type="vnc")]'));
$self->snapshots()->check_history_storage($adapter, $domain);
Cloudmin::VMManage::check_nvram($adapter, $domain);
# Software installation must finish before its disks can become a clone source.
die "Finish guest software setup before cloning this virtual machine\n"
	if (grep {
		($_->{'request'}->{'uuid'} || '') eq $uuid &&
			$_->{'resources'}->{'software'} &&
			$_->{'state'} !~ /\A(?:complete|failed|cancelled)\z/
		} @{$self->{'jobs'}->list_pending()});
my $disks = $self->snapshots()->disks($adapter, $domain, $doc, 1);
my %roles =
	map { $_->{'target'} => $_->{'role'} }
	Cloudmin::Libvirt::extract_disks($doc->toString());
# Identify read-only volumes for unchanged copies and recognize removable seeds.
foreach my $disk (grep { $_->{'readonly'} } @$disks) {
	my ($node) =
		grep { $_->findvalue(
			'target/@dev') eq $disk->{'target'} } $doc->findnodes(
				'/domain/devices/disk');
	next
		if ($node->getAttribute('device') ne 'disk' ||
		    !$node->exists('source'));
	$disk->{'volume'} = $self->manager()->volume_for($adapter, $node);
	$disk->{'seed'} = ($roles{$disk->{'target'}} || '') eq 'seed' ? 1 : 0;
	}
die "Cloning supports at most 32 writable disks\n"
	if (grep(!$_->{'readonly'}, @$disks) > 32);
# Reject devices whose external state cannot be copied or safely regenerated.
die "Remove custom QEMU arguments and external device state before cloning\n"
	if (
		$doc->exists(
			'//*[local-name()="commandline"] | /domain/devices/shmem | /domain/launchSecurity | /domain/os/varstore'));
foreach my $nic ($doc->findnodes('/domain/devices/interface')) {
	die "Cloning supports network and bridge interfaces\n"
		if ($nic->getAttribute('type') !~ /\A(?:network|bridge)\z/);
	die "Remove interface filters before cloning\n"
		if ($nic->exists('filterref'));
	}
die "Cloning does not support external device files or custom firmware state\n"
	if (
		$doc->exists(
			'/domain/devices/*[not(self::disk or self::interface or self::channel or self::serial or self::console)]/source | /domain/devices/rng/backend[@model!="random"]'));
my $nvram = $doc->findvalue('/domain/os/nvram/source/@file') ||
	    $doc->findvalue('/domain/os/nvram/text()');
$nvram =~ s/^\s+|\s+$//g;
if ($doc->exists('/domain/os/nvram')) {
	# Firmware variables must be a bounded regular file,
	# not a link or device.
	my $format = $doc->findvalue('/domain/os/nvram/@format') || 'raw';
	die "Cloning requires file-backed raw or QCOW2 UEFI variables\n"
		if (!$nvram || $format !~ /\A(?:raw|qcow2)\z/);
	my @stat = lstat($nvram);
	die "The source UEFI variables are missing or unusable\n"
		if (!@stat || !-f _ || -l _ ||
		    $stat[7] < 1024 || $stat[7] > 64 * 1024**2);
	}
return ( $adapter, $domain, $doc, $disks, $nvram, $tpm );
}

# choices(self, uuid) exposes source defaults without secure XML or disk paths.

sub choices
{
my ($self, $uuid) = @_;
my ($adapter, $domain, $doc, $disks, $nvram, $tpm) = $self->source($uuid, 1);
my $settings = $self->manager()->settings($uuid);
my $options = $self->options();
# Match the source's first interface to a currently available attachment.
my $nic = $settings->{'interfaces'}->[0] || { };
my ($network) = grep { $_->{'type'} eq ($nic->{'type'} || '') &&
	$_->{'source'} eq ($nic->{'source'} ||
			   '') } @{$options->{'networks'}};
return { id => $uuid, name => $domain->get_name(), revision =>
							   Cloudmin::Snapshots::revision($domain),
	 active => $domain->is_active() ? 1 : 0, nvram => $nvram ? 1 : 0, tpm =>
										  $tpm ? 1 : 0,
	 virtualmin => $self->installed_edition($doc),
	 cpus => $settings->{'cpus'}, memory_mib => $settings->{'memory_mib'},
	 pool => (grep { !$_->{'readonly'} } @$disks)[0]->{'volume'}->{'pool'},
	 network => $network ? $network->{'key'} : '',
	 disks =>
		 [ map { { target => $_->{'target'}, bytes =>
							     $_->{'volume'}->{'capacity'} } } grep {
				!$_->{'readonly'} } @$disks ],
	 options => $options };
}

# prepare(self, input, job_id, [password_hash]) validates before reserving
# disks. Prepared copies accept creation's access/network options; unchanged
# copies retain guest settings except host ID and Pro
# credentials, and stay stopped.

sub prepare
{
my ($self, $input, $id, $hash) = @_;
my ($adapter, $domain, $doc, $disks, $nvram, $tpm) =
	$self->source($input->{'id'}, 1);
my $revision = Cloudmin::Snapshots::revision($domain);
# Refuse stale forms before resolving defaults or allocating a destination.
die "The source virtual machine changed; reload the clone page\n"
	if (($input->{'revision'} || '') ne $revision);
my $mode = $input->{'clone_mode'} || 'prepared';
die "Select prepared or unchanged cloning\n"
	if ($mode !~ /\A(?:prepared|unchanged)\z/);
foreach my $field (
	qw(start autostart shutdown confirm_unchanged confirm_license host_ssh_key)) {
	die "Invalid clone $field option\n" if (defined(
		$input->{$field}) &&
						(ref($input->{$field}) || $input->{$field} !~ /\A[01]\z/));
	}
# Copies that keep guest settings must stay stopped for manual review.
die "Confirm that this copy keeps guest settings but resets its host ID and Pro license credentials\n"
	if ($mode eq 'unchanged' && !$input->{'confirm_unchanged'});
die "Copies that keep guest settings must remain stopped with automatic startup disabled\n"
	if ($mode eq 'unchanged' &&
	    ($input->{'start'} || $input->{'autostart'}));
die "Prepared cloning supports Cloudmin seed disks only; detach other read-only disks or choose an unchanged copy\n"
	if ($mode eq 'prepared' &&
	    grep { $_->{'readonly'} && $_->{'volume'} &&
			!$_->{'seed'} } @$disks);
my $edition = $self->installed_edition($doc);
# Both modes must remove copied Pro credentials inside the offline appliance.
die "Confirm that the clone's Virtualmin Pro license credentials will be removed; add a separate Pro license or downgrade manually to GPL\n"
	if ($edition eq 'pro' && !$input->{'confirm_license'});
die "Cloning requires libguestfs and its Perl bindings to reset the host ID and remove copied Pro credentials\n"
	if (!eval { require Sys::Guestfs; 1 });
die "Prepared cloning requires YAML::XS 0.69 or later\n"
	if ($mode eq 'prepared' &&
	    !eval { require YAML::XS; YAML::XS->VERSION(0.69); 1 });
die "Install bsdtar for cloning\n" if (!-x '/usr/bin/bsdtar');
# Prepared network configuration currently addresses exactly one interface.
my @interfaces = $doc->findnodes('/domain/devices/interface');
die "Prepared cloning currently requires one network interface; choose an unchanged copy instead\n"
	if ($mode eq 'prepared' && @interfaces != 1);
# A filesystem freeze cannot make a running emulator's TPM state safe to copy.
die "Shut down the source to clone its TPM\n"
	if ($tpm && $domain->is_active() && !$input->{'shutdown'});
# Fresh UEFI variables can change boot measurements used by TPM unlock policies.
die "TPM cloning requires copied UEFI variables\n"
	if ($tpm && $nvram && ($input->{'nvram_mode'} || 'copy') ne 'copy');
my $firmware =
	$input->{'nvram_mode'} ||
	($domain->is_active() && !$input->{'shutdown'} ? 'fresh' : 'copy');
die "Select copied or fresh UEFI variables\n"
	if ($firmware !~ /\A(?:copy|fresh)\z/);
if ($domain->is_active() && !$input->{'shutdown'}) {
	# A filesystem freeze does not make a live
	# firmware-variable file immutable.
	die "Shut down the source to copy its UEFI variables, or explicitly select fresh variables\n"
		if ($nvram && $firmware eq 'copy');
	Cloudmin::Snapshots::check_agent($domain);
	}
my $options = $self->options();
my ($primary) = grep { !$_->{'readonly'} } @$disks;
my $settings = $self->manager()->settings($input->{'id'});
my ($nic) = @interfaces;
my $network = $nic && $nic->getAttribute('type') eq 'bridge'
	? 'bridge:'.$nic->findvalue('source/@bridge')
	: '';
if ($nic && !$network) {
	# Resolve a libvirt network name to the selector's stable network key.
	my ($match) =
		grep { $_->{'source'} eq $nic->findvalue(
			'source/@network') } @{$options->{'networks'}};
	$network = $match->{'key'} if ($match);
	}
# Reuse creation validation with the source disk standing in for an image.
my %values =
	( cpus => $settings->{'cpus'}, memory_mib => $settings->{'memory_mib'},
	  disk_gib => $primary->{'volume'}->{'capacity'} / 1024**3,
	  pool => $primary->{'volume'}->{'pool'}, network => $network,
	  username =>
		  'cloudmin',
	  auth_type => 'password', address_mode => 'dhcp', start => 0,
	  autostart => 0, %$input,
	  image => 'clone-source', install_source => $mode eq 'prepared'
		  ? 'cloud'
		  : 'iso',
	  firmware => $doc->exists('/domain/os/loader') ? 'efi' : 'bios',
	  software => 'none' );
# Templates cannot schedule installation or scripts on a copied guest.
delete(@values{Cloudmin::Software::fields()});
$values{'require_fqdn'} = 1 if ($edition && $mode eq 'prepared');
my $image = { id => 'clone-source', name => $domain->get_name(),
	      format => $mode eq 'prepared' ? 'qcow2' : 'iso', cloud_init => 1,
	      architecture => $doc->findvalue('/domain/os/type/@arch'),
	      virtual_size => $primary->{'volume'}->{'capacity'},
	      min_disk_bytes => $primary->{'volume'}->{'capacity'} };
my $r =
	$self->SUPER::prepare(\%values,
			      { %$options, images => [ $image ],
				catalogue_images => [ ] },
			      $hash);
# Count secondary disks and retained read-only disks in the destination budget.
my ($pool) = grep { $_->{'id'} eq $r->{'pool'} } @{$options->{'pools'}};
my $bytes = $r->{'disk_gib'} * 1024**3;
$bytes += $_->{'volume'}->{'capacity'} foreach grep { $_->{'volume'} &&
	$_ != $primary &&
	(!$_->{'readonly'} || $mode eq 'unchanged') } @$disks;
# File and thick pools need room for full disk capacities after flattening. The
# LVM driver checks thin-pool data and metadata usage during allocation.
die "The destination pool needs space for all cloned disks plus 256 MiB\n"
	if (($pool->{'type'} || '') ne 'lvmthin' &&
	    $bytes > $pool->{'available'} - 256 * 1024**2);
my $hex;
# Virtualmin uses the first eight DMI UUID digits, not the full domain UUID.
my %oldids =
	map { lc(substr($_, 0, 8)) => 1 }
	map { $_->textContent() } $doc->findnodes(
		'/domain/uuid | /domain/hwuuid | /domain/sysinfo/system/entry[@name="uuid" or @name="serial"]');
do { $hex =
	Cloudmin::Images::generate_id(); } while ($oldids{substr($hex, 0,
								 8)});
# Persist source identity and copy choices so recovery needs no browser input.
@$r{qw(operation clone_mode source_uuid source_name source_revision source_xml disks nvram nvram_mode shutdown active confirm_license)} =
	( 'clone', $mode, $input->{'id'}, $domain->get_name(), $revision,
	  $doc->toString(),
	  $disks, $nvram, $firmware, $input->{'shutdown'} ? 1 : 0,
	  $domain->is_active() ? 1 : 0,
	  $input->{'confirm_license'} ? 1 : 0 );
$r->{'uuid'} =
	join('-', substr($hex, 0, 8), substr($hex, 8, 4), '4'.substr($hex, 13,
								     3),
	     '8'.substr($hex, 17, 3), substr($hex, 20, 12));
# VNC permits at most eight characters, as in ordinary VM creation.
$r->{'console_password'} = substr(Cloudmin::Images::generate_id(), 0, 8);
$r->{'virtualmin'} = $edition;
# Keep the validated TPM path and directory identity for the stopped copy.
$r->{'tpm'} = $tpm if ($tpm);
$r->{'nvram_identity'} = Cloudmin::VMManage::file_identity($nvram) if ($nvram);
# Copied firmware stays in a file pool even when guest disks move to LVM.
$r->{'auxiliary_pool'} =
	Cloudmin::Libvirt::file_pool($adapter, $r->{'pool'})->get_uuid_string()
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
die "Virtual machine operation cancelled\n"
	if ($_[0]->{'jobs'}->get($_[1])->{'cancel'});
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
# Inactive secure XML supplies hardware; runtime paths and
# credentials are reset.

sub domain_xml
{
my ($r, $id, $volumes, $seed, $nvram) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($r->{'source_xml'});
# Replace the domain identity and discard source-specific resource constraints.
set_text($doc, '/domain/name', $r->{'name'});
set_text($doc, '/domain/uuid', $r->{'uuid'});
set_text($doc, '/domain/memory', $r->{'memory_mib'});
($doc->findnodes('/domain/memory'))[0]->setAttribute('unit', 'MiB');
foreach my $node (
	$doc->findnodes(
		'/domain/currentMemory | /domain/vcpus | /domain/cputune | /domain/numatune | /domain/cpu/topology | /domain/cpu/numa | /domain/sysinfo | /domain/hwuuid | /domain/genid | /domain/seclabel | /domain/metadata')) {
	$node->unbindNode();
	}
# Do not expose the source or physical host's DMI identity in the clone.
$_->setAttribute('mode',
		 'emulate') foreach $doc->findnodes('/domain/os/smbios');
set_text($doc, '/domain/vcpu', $r->{'cpus'});
($doc->findnodes('/domain/vcpu'))[0]->removeAttribute('current');
my $meta = $doc->documentElement()->addNewChild(undef, 'metadata');
# Bind Cloudmin metadata to this job and its new guest access settings.
my $vm = $meta->addNewChild('urn:cloudmin:vm:1', 'vm');
foreach my $field (qw(job template network ipv4 ipv6 username)) {
	$vm->addNewChild('urn:cloudmin:vm:1',
			 $field)->appendText($field eq 'job' ? $id : $r->{$field} || '');
	}
my $index = 0;
foreach my $disk ($doc->findnodes('/domain/devices/disk')) {
	if ($disk->exists('readonly') &&
	    (($r->{'clone_mode'} || 'prepared') ne 'unchanged' ||
	     $disk->getAttribute('device') ne 'disk') ||
	    !$disk->exists('source')) {
		# Discard the old seed and detach installation media from the
		# new machine. Remove disk devices that have
		# no source in the copy.
		if (
			$disk->getAttribute('device') eq 'disk') {
			$disk->unbindNode();
			}
		# Keep removable drives, but detach their source media.
		else {
			$_->unbindNode() foreach $disk->findnodes(
				'source | backingStore');
			}
		next;
		}
	# Use independent copies in source order, without
	# backing links or disk IDs.
	$_->unbindNode() foreach $disk->findnodes(
		'source | backingStore | serial | wwn');
	my $volume = $volumes->[$index++];
	$disk->setAttribute('type', $volume->{'block'} ? 'block' : 'file');
	$disk->addNewChild(undef, 'source')->setAttribute($volume->{'block'}
		? 'dev'
		: 'file', $volume->{'path'});
	($disk->findnodes('driver'))[0]->setAttribute('type',
						      $volume->{'format'} || 'qcow2');
	($disk->findnodes('driver'))[0]->setAttribute('cache', 'none')
		if ($volume->{'block'});
	}
if ($seed) {
	# Assign the new seed the first free virtio target
	# after the system disk.
	my %used =
		map { $_->getValue() =>
			1 } $doc->findnodes('/domain/devices/disk/target/@dev');
	my ($target) = grep { !$used{$_} } map { 'vd'.$_ } 'b' .. 'z';
	die "No free target for the clone seed\n" if (!$target);
	# Present NoCloud data as a read-only raw disk on the
	# existing virtio bus.
	my ($devices) = $doc->findnodes('/domain/devices');
	my $disk = $devices->addNewChild(undef, 'disk');
	$disk->setAttribute('type', $seed->{'block'}
		? 'block'
		: 'file'); $disk->setAttribute('device', 'disk');
	my $driver = $disk->addNewChild(undef, 'driver');
	$driver->setAttribute('name', 'qemu'); $driver->setAttribute('type',
								     'raw');
	$disk->addNewChild(undef, 'source')->setAttribute($seed->{'block'}
		? 'dev'
		: 'file', $seed->{'path'});
	my $t = $disk->addNewChild(undef, 'target');
	$t->setAttribute('dev', $target); $t->setAttribute('bus', 'virtio');
	$disk->addNewChild(undef, 'readonly');
	}
$index = 0;
# Every NIC gets a fresh MAC; unchanged copies may retain additional NICs.
foreach my $nic ($doc->findnodes('/domain/devices/interface')) {
	$_->unbindNode() foreach $nic->findnodes(
		'mac | target | alias | filterref');
	my $mac = $index++ == 0
		? $r->{'mac'}
		: '52:54:00:'.join(':',
				   substr(Cloudmin::Images::generate_id(), 0,
					  6) =~ /../g);
	$nic->addNewChild(undef, 'mac')->setAttribute('address', $mac);
	if ($index == 1) {
		# Only the primary interface uses the clone form's
		# selected attachment.
		$_->unbindNode() foreach $nic->findnodes('source');
		my $type = $r->{'attachment'}->{'type'};
		$nic->setAttribute('type', $type);
		$nic->addNewChild(undef, 'source')->setAttribute($type,
								 $r->{'attachment'}->{'source'});
		}
	}
# Restrict the new VNC console to localhost with a fresh password and port.
foreach my $graphics ($doc->findnodes('/domain/devices/graphics')) {
	$graphics->setAttribute('passwd', $r->{'console_password'});
	$graphics->setAttribute('autoport',
				'yes'); $graphics->setAttribute('port', '-1');
	$graphics->setAttribute('listen', '127.0.0.1');
	$graphics->removeAttribute(
		$_) foreach qw(socket passwdValidTo tlsPort websocket);
	$_->unbindNode() foreach $graphics->findnodes('listen');
	my $listen = $graphics->addNewChild(undef, 'listen');
	$listen->setAttribute('type',
			      'address'); $listen->setAttribute('address',
								'127.0.0.1');
	}
# Let libvirt allocate fresh terminal paths instead of reusing source files.
foreach my $serial (
	$doc->findnodes('/domain/devices/serial | /domain/devices/console')) {
	$serial->setAttribute('type', 'pty');
	$_->unbindNode() foreach $serial->findnodes('source | log');
	}
foreach my $channel ($doc->findnodes('/domain/devices/channel')) {
	# Drop custom channels that do not belong to the copied guest agent.
	if (
		$channel->findvalue(
			'target/@name') ne 'org.qemu.guest_agent.0') {
		$channel->unbindNode();
		}
	# Let libvirt allocate a socket for the copied guest agent.
	else { $_->unbindNode() foreach $channel->findnodes('source'); }
	}
# The new UUID selects the copied TPM directory; never retain a source path.
foreach my $backend ($doc->findnodes('/domain/devices/tpm/backend')) {
	$_->unbindNode() foreach $backend->findnodes('source');
	# Remove clone state on undefine, even if the source
	# retained its own state.
	$backend->setAttribute('persistent_state', 'no');
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
	$jobs->update(
		$id,
		sub { $_[0]->{'resources'}->{'shutdown_requested'} = 1; });
	$source->shutdown();
	# Keep cancellation responsive while waiting for the guest to shut down.
	my $deadline = time() + 120;
	while ($source->is_active()) {
		die "The source virtual machine did not shut down\n"
			if (time() >= $deadline);
		$self->checkpoint($id); sleep(1);
		}
	$jobs->update($id,
		      sub { $_[0]->{'resources'}->{'shutdown_complete'} = 1; });
	}
# Capture a running source without shutting it down.
elsif ($source->is_active()) {
	my @writable = grep { !$_->{'readonly'} } @{$r->{'disks'}};
	if (grep { $_->{'volume'}->{'block'} } @writable) {
		# Native LVM snapshots keep guest writes on the
		# original logical volumes.
		die "Shut down the source to copy mixed file-backed and LVM disks\n"
			if (grep { !$_->{'volume'}->{'block'} } @writable);
		# Reject an unresponsive agent before pausing the guest
		# or allocating volumes.
		Cloudmin::Snapshots::check_agent($source);
		$r->{'native_lvm'} = 1;
		$r->{'snapshot'} = 'cloudmin-'.$id;
		$r->{'mode'} = 'prepared';
		$r->{'description'} = 'Temporary full '.$prefix;
		$jobs->update($id,
			      sub { $_[0]->{'request'} =
				$r; $_[0]->{'resources'}->{'snapshot'} = 1; });
		$self->snapshots()->apply_native($id, $adapter, $source, undef,
						 1);
		return;
		}
	# Freeze via the agent and move writes to temporary external overlays.
	Cloudmin::Snapshots::check_agent($source);
	$r->{'snapshot'} = 'cloudmin-'.$prefix.'-'.$id;
	foreach my $disk (@{$r->{'disks'}}) {
		# Read-only media cannot receive writes and need
		# no temporary overlay.
		next if ($disk->{'readonly'});
		$disk->{'overlay'} =
			dirname($disk->{'volume'}->{'path'}).'/cloudmin-'.
			$prefix.'-'.$id.'-'.$disk->{'target'}.
			'.qcow2';
		die "Temporary snapshot overlay already exists\n"
			if (-e $disk->{'overlay'} || -l $disk->{'overlay'});
		}
	$jobs->update($id,
		      sub { $_[0]->{'request'} =
			$r; $_[0]->{'resources'}->{'snapshot'} =
				1; $_[0]->{'resources'}->{'quiescing'} = 1; });
	# Disk-only, atomic, quiesced snapshots leave the copied bases stable.
	$source->create_snapshot(Cloudmin::Snapshots::snapshot_xml({ %$r,
								     description => 'Temporary full '.$prefix }), 16 | 128 | 64);
	$jobs->update($id,
		      sub { delete($_[0]->{'resources'}->{'quiescing'}); });
	}
}

# stable_volume(self, id, adapter, disk) Selects a native snapshot from the
# journal. Stopped sources, read-only disks and file snapshot
# bases keep their volume.

sub stable_volume
{
my ($self, $id, $adapter, $disk) = @_;
my $job = $self->{'jobs'}->get($id);
return $disk->{'volume'}
	if (!$job->{'request'}->{'native_lvm'} || $disk->{'readonly'});
# The source LV remains writable after a live native capture; copy its saved LV.
die "Native LVM capture is incomplete\n"
	if (!$job->{'resources'}->{'native_complete'});
my ($saved) = grep { $_->{'target'} eq $disk->{'target'} }
	      @{$job->{'resources'}->{'native_volumes'} || [ ]};
die "Native LVM capture disk is missing\n" if (!$saved);
my (undef, $volume) = $adapter->volume(@$saved{qw(pool name key)});
die "Native LVM capture disk is missing\n" if (!$volume);
$volume->snapshot_health();
# Downstream copying rechecks this snapshot's identity, not
# the running origin's.
return { %{$adapter->get_storage_volume_record($volume)}, pool =>
								  $saved->{'pool'},
	 identity => Cloudmin::VMManage::file_identity($volume->get_path()),
	 block => 1 };
}

# release_source(self, id, adapter) restores the source before finishing a job.
# Reservations remain held until the job completes or cleanup succeeds.

sub release_source
{
my ($self, $id, $adapter) = @_;
my $job = $self->{'jobs'}->get($id);
my $r = $job->{'request'};
return if ($job->{'resources'}->{'source_released'});
my $domain = $adapter->find_domain($r->{'source_uuid'}) ||
	     die "The clone source disappeared; recovery requires inspection\n";
if ($job->{'resources'}->{'quiescing'}) {
	# A lost snapshot reply may leave filesystems frozen even without
	# metadata. Native capture may also own a CPU pause, which
	# must end before thawing.
	if ($r->{'native_lvm'}) {
		$self->snapshots()->resume_native($id, $domain);
		}
	# File snapshots only need their filesystem freeze released.
	else { $self->snapshots()->thaw($id, $domain); }
	}
# Recover the journaled snapshot attempt, including a lost creation reply.
if ($job->{'resources'}->{'snapshot'}) {
	if ($r->{'native_lvm'}) {
		# Remove only this capture's native copies before
		# releasing its reservation.
		$self->snapshots()->resume_native($id, $domain);
		$self->snapshots()->remove_native($id, $adapter, $domain);
		}
	else {
		# File snapshots moved writes to overlays; merge
		# those through libvirt.
		my $snapshot =
			Cloudmin::Snapshots::find_snapshot($domain,
							   $r->{'snapshot'});
		if ($snapshot) {
			# Verify deletion is safe before asking libvirt
			# to merge the overlay.
			Cloudmin::Snapshots::check_delete($domain, $snapshot);
			$snapshot->delete(0);
			}
		# A lost snapshot reply must not strand a writable
		# overlay without metadata.
		my $doc =
			Cloudmin::Libvirt::parse_xml_document(
				$domain->get_xml_description(0));
		my %paths =
			map { $_->getValue() =>
				1 } $doc->findnodes(
					'/domain/devices/disk/source/@file');
		die "A temporary clone overlay still needs recovery\n"
			if (grep { $_->{'overlay'} && ($paths{$_->{'overlay'}} ||
						       -e $_->{'overlay'} ||
						       -l $_->{'overlay'}) } @{$r->{'disks'}});
		}
	}
if ($job->{'resources'}->{'shutdown_requested'} && $r->{'active'} &&
    !$domain->is_active()) {
	# Restart only a source that this job was asked to
	# shut down for copying.
	$domain->create();
	}
elsif ($job->{'resources'}->{'shutdown_requested'} &&
       !$job->{'resources'}->{'shutdown_complete'}) {
	# A delivered ACPI shutdown may still finish after a cancelled wait.
	die "The source shutdown is still pending; retry recovery after it stops\n";
	}
$self->{'jobs'}->update($id,
			sub { $_[0]->{'resources'}->{'source_released'} = 1; });
}

# cleanup(self, id, adapter) restores the source, then
# removes only owned copies.

sub cleanup
{
my ($self, $id, $adapter) = @_;
my $job = $self->{'jobs'}->get($id);
my $r = $job->{'request'};
Cloudmin::Worker->new()->cleanup($job->{'worker'}) if ($job->{'worker'});
# Restore the source first; failed restoration must keep both reservations.
$self->release_source($id, $adapter) if ($job->{'resources'}->{'started'});
# Undefining the clone can delete its TPM, so check other references first.
Cloudmin::TPM::assert_unused($adapter, $r->{'uuid'},
			     Cloudmin::TPM::path($r->{'uuid'}))
	if ($job->{'resources'}->{'tpm'});
$adapter->remove_created_guest($r->{'uuid'}, $id)
	if ($job->{'resources'}->{'domain'});
# An interrupted allocation may have state without a defined clone to remove.
Cloudmin::TPM::remove_copy($adapter, $r->{'uuid'}, $id)
	if ($job->{'resources'}->{'tpm'});
# Remove credentials and volumes only through their recorded ownership checks.
$self->{'ssh_keys'}->remove($r->{'uuid'}, $id)
	if ($job->{'resources'}->{'ssh_key'});
foreach my $volume ( @{$job->{'resources'}->{'volumes'} || [ ]},
		     map { $job->{'resources'}->{$_} || () } qw(seed nvram) ) {
	$adapter->remove_created_volume($volume->{'pool'} ||
					$r->{'pool'},
					$volume->{'name'}, $volume->{'key'});
	}
$self->clean_work($id);
}

# clean_work(self, id) removes fixed staging filenames, never source files.

sub clean_work
{
my ($self, $id) = @_;
my $work = "$self->{jobs}->{directory}/$id";
foreach my $name ( 'seed.iso', 'nvram.fd', map { "disk$_" } 0 .. 31 ) {
	unlink("$work/$name") or die "Cannot remove clone staging file\n"
		if (-e "$work/$name");
	}
rmdir($work) or die "Cannot remove clone staging directory\n" if (-d $work);
}

# run(self, id) copies immutable source states and journals every allocation.
# Interrupted jobs restore the source and roll back; they never repeat writes.

sub run
{
my ($self, $id) = @_;
my $jobs = $self->{'jobs'};
return $jobs->run_worker($id, sub {
	my $job = $jobs->get($id);
	my $r = $job->{'request'};
	my $adapter = $self->{'adapter'}->();
	# Journal conversion workers so cancellation and recovery can stop them.
	$adapter->{'disk_worker'} = sub { $self->worker_task($id, @_); };
	my $work = "$jobs->{directory}/$id";
	my $ok = eval {
		# An interrupted worker rolls back instead of
		# repeating allocation steps.
		die "Virtual machine cloning was interrupted\n"
			if ($job->{'state'} ne 'queued');
		$jobs->update($id, sub { $_[0]->{'state'} = 'running'; });
		$self->step($id, 'preflight', sub {
			# Recheck source revision and destination name after
			# waiting for a worker.
			my (undef, $source) =
				$self->source($r->{'source_uuid'}, 1);
			die "The clone source changed after submission\n"
				if (Cloudmin::Snapshots::revision($source) ne
				    $r->{'source_revision'});
			die "The clone name is already in use\n"
				if (grep { $_->get_name() eq $r->{'name'} }
				    $adapter->connect()->list_all_domains());
			# File copies and overlays share filesystem space. LVM
			# allocation is checked separately against the VG or
			# thin pool, never the /dev mount.
			my $pool =
				Cloudmin::Libvirt::storage_pool($adapter,
								$r->{'pool'});
			die "Clone destination pool is no longer active\n"
				if (!$pool->is_active());
			my $pooldoc =
				Cloudmin::Libvirt::parse_xml_document(
					$pool->get_xml_description());
			my $destination =
				$pooldoc->findvalue('/pool/target/path');
			my (%needed, %paths);
			my $index = 0;
			foreach my $disk (grep { $_->{'volume'} &&
				(!$_->{'readonly'} ||
				 $r->{'clone_mode'} eq 'unchanged') } @{$r->{'disks'}}) {
				my $capacity = $disk->{'readonly'} || $index++
					? $disk->{'volume'}->{'capacity'}
					: $r->{'disk_gib'} * 1024**3;
				foreach my $item ( Cloudmin::Libvirt::block_pool(
					$pool)
						? ()
						: ([ $destination, $capacity ]),
						   !$disk->{'volume'}->{'block'} && $r->{'active'} && !$r->{'shutdown'} && !$disk->{'readonly'}
							   ? [ dirname($disk->{'volume'}->{'path'}), $disk->{'volume'}->{'capacity'} ]
							   : () ) {
					my @stat = stat($item->[0]);
					die "Cannot check clone storage space\n" if (!@stat);
					$paths{$stat[0]} = $item->[0]; $needed{$stat[0]} += $item->[1];
					}
				}
			die "Not enough storage for cloned disks and temporary snapshot growth\n"
				if (grep { Cloudmin::Worker::free_space(
					$paths{$_}) < $needed{$_} + 256 * 1024**2 } keys %needed);
			make_dir($work, 0700, 1) or
				die "Cannot create clone staging directory\n";
			# Validate submitted keys before any source
			# snapshot or shutdown.
			$self->worker_task($id, 'keys',
					   { keys => $r->{'ssh_keys'}."\n" })
				if ($r->{'ssh_keys'});
			});
		my $source = $adapter->find_domain($r->{'source_uuid'});
		$self->step($id, 'clone_quiesce',
			    sub { $self->quiesce_source($id, $adapter); });
		my @volumes;
		$self->step($id, 'clone_disks', sub {
			my ($index, $writable) = ( 0, 0 );
			foreach my $disk (grep { $_->{'volume'} &&
				(!$_->{'readonly'} ||
				 $r->{'clone_mode'} eq 'unchanged') } @{$r->{'disks'}}) {
				$self->checkpoint($id);
				# Reject replaced sources; grow only the
				# first writable disk.
				my $v = $self->stable_volume($id, $adapter,
							     $disk);
				die "A clone source disk was replaced\n" if (
					Cloudmin::VMManage::file_identity(
						$v->{'path'}) ne $v->{'identity'});
				my $name =
					Cloudmin::VMs::disk_volume_name(
						$r->{'name'}, $disk->{'seed'}
							? 'seed'
							: !$disk->{'readonly'} && !$writable
								? 'system'
								: 'disk'.$index,
						$id, $r->{'pool_type'});
				my $capacity = $disk->{'readonly'} ||
					       $writable++
						       ? $v->{'capacity'}
						       : $r->{'disk_gib'} * 1024**3;
				my $format = $disk->{'readonly'} &&
					     $v->{'format'} ne 'qcow2'
						     ? 'raw'
						     : 'qcow2';
				my $slot = $index++;
				# Record the output name before allocation so
				# rollback can find it.
				my $copy = $adapter->clone_disk($r->{'pool'},
								$name,
								{ pool => $v->{'pool'}, volume => $v->{'name'}, volume_key => $v->{'key'} }, $capacity, $format, sub {
						$jobs->update($id,
							      sub { $_[0]->{'resources'}->{'volumes'}->[$slot] = { name => $name }; });
						});
				$format = $copy->{'format'} || $format;
				$copy->{'format'} = $format;
				$jobs->update($id,
					      sub {
						$_[0]->{'resources'}->{'volumes'}->[$slot] = $copy; });
				# Every full copy is checked in isolation
				# before a guest can use it.
				$self->worker_task($id, 'inspect',
						   { format => $format },
						   files => { image => $copy->{'path'} });
				push(@volumes, $copy);
				}
			if ($r->{'nvram'} && $r->{'nvram_mode'} eq 'copy') {
				# Copy stable firmware bytes only after
				# checking identity and size.
				die "Shut down the source before copying UEFI variables\n" if ($source->is_active());
				die "The source UEFI variables were replaced\n"
					if (Cloudmin::VMManage::file_identity($r->{'nvram'}) ne $r->{'nvram_identity'});
				my $info = $self->worker_task($id, 'inspect',
							      { format => $r->{'nvram_format'} },
							      files => { image => $r->{'nvram'} });
				die "The source UEFI variables exceed 64 MiB\n" if ($info->{'virtual-size'} > 64 * 1024**2);
				# Import opaque firmware bytes; the domain
				# retains their raw/QCOW2 format rather than
				# treating this volume as a guest system disk.
				Cloudmin::Worker::copy_file($r->{'nvram'},
							    "$work/nvram.fd",
							    64 * 1024**2);
				my $name = "cloudmin-$id-nvram.fd";
				my $volume =
					$adapter->upload_seed(
						$r->{'auxiliary_pool'} || $r->{'pool'},
						$name, "$work/nvram.fd", sub {
							$jobs->update($id,
								      sub { $_[0]->{'resources'}->{'nvram'} = { name => $name, pool => $r->{'auxiliary_pool'} || $r->{'pool'} }; });
							});
				$volume->{'pool'} = $r->{'auxiliary_pool'} ||
						    $r->{'pool'};
				$jobs->update($id,
					      sub { $_[0]->{'resources'}->{'nvram'} =
						$volume; });
				}
			});
		if ($r->{'tpm'}) {
			# Keep the source stopped until disks, firmware and
			# TPM state are copied.
			$self->step($id, 'clone_tpm', sub {
				Cloudmin::TPM::copy($r->{'tpm'}, $r->{'uuid'},
						    $id, $source, sub {
						# Journal intent before
						# creating the TPM directory.
						$jobs->update($id,
							      sub { $_[0]->{'resources'}->{'tpm'} = 1; });
						});
				});
			}
		$self->step($id, 'clone_release',
			    sub { $self->release_source($id, $adapter); });
		my $seed;

		# Use the same identity and access values for disk
		# preparation and NoCloud.
		my %seed_values = map { $_ => $r->{$_} }
				  qw(username auth_type password_hash ssh_keys hostname mac address_mode ipv4 ipv6 gateway4 gateway6 dns);
		if ($r->{'clone_mode'} eq 'prepared' && $r->{'host_ssh_key'}) {
			# Give this clone a separate managed key and
			# journal it before writing.
			$jobs->update($id,
				      sub { $_[0]->{'resources'}->{'ssh_key'} = 1; });
			$seed_values{'host_public_key'} =
				$self->worker_task($id, 'keypair', { },
						   output => $self->{'ssh_keys'}->destination($r->{'uuid'}, $id))->{'public_key'};
			die "Host SSH key generation returned no public key\n"
				if (!$seed_values{'host_public_key'});
			}
		$self->step($id, 'clone_prepare', sub {
			# Stage only the cloned volumes under fixed
			# appliance filenames.
			my (%files, %outputs, @disks);
			foreach my $i (0 .. $#volumes) {
				$files{"disk$i"} = $volumes[$i]->{'path'};
				$outputs{"disk$i"} = "$work/disk$i";
				push(@disks, { name => "disk$i",
					       format => $volumes[$i]->{'format'},
					       capacity => $volumes[$i]->{'capacity'} });
				}
			my $result = $self->worker_task($id, 'clone_prepare',
							{ disks => \@disks,
							  settings => \%seed_values,
							  confirm_license => $r->{'confirm_license'},
							  mode => $r->{'clone_mode'}, uuid => $r->{'uuid'} },
							files => \%files,
							outputs => \%outputs);
			$jobs->update($id,
				      sub { $_[0]->{'resources'}->{'virtualmin'} =
					$result->{'virtualmin'}; });
			# Write prepared copies back to this job's unused
			# destination volumes.
			foreach my $i (0 .. $#volumes) {
				# Recheck outputs in a separate read-only task
				# before libvirt can open them outside the
				# writable preparation sandbox.
				my $info = $self->worker_task($id, 'inspect',
							      { format => $volumes[$i]->{'format'} },
							      files => { image => "$work/disk$i" });
				die "Prepared clone disk capacity changed\n"
					if ($info->{'virtual-size'} != $volumes[$i]->{'capacity'});
				my ($pool, $volume) =
					$adapter->volume($r->{'pool'},
							 $volumes[$i]->{'name'},
							 $volumes[$i]->{'key'});
				# Upload only to the job's existing destination
				# volume, never its source.
				$adapter->write_volume($volume, "$work/disk$i");
				}
			});
		if ($r->{'clone_mode'} eq 'prepared') {
			# Supply new cloud-init data only when preparing
			# a new guest identity.
			$self->step($id, 'seed', sub {
				$self->worker_task($id, 'seed',
						   { request => \%seed_values,
						     uuid => $r->{'uuid'} },
						   output => "$work/seed.iso");
				my $name =
					Cloudmin::VMs::disk_volume_name(
						$r->{'name'}, 'seed', $id,
						$r->{'pool_type'});
				$seed = $adapter->upload_seed($r->{'pool'},
							      $name,
							      "$work/seed.iso",
							      sub {
						$jobs->update($id,
							      sub { $_[0]->{'resources'}->{'seed'} = { name => $name }; });
						});
				$jobs->update($id,
					      sub { $_[0]->{'resources'}->{'seed'} =
						$seed; });
				});
			}
		$self->step($id, 'define', sub {
			# Record domain ownership before define so a lost
			# reply can be cleaned up.
			$jobs->update($id,
				      sub { $_[0]->{'resources'}->{'domain'} = 1; });
			$adapter->define_guest(domain_xml($r, $id, \@volumes,
							  $seed,
							  $jobs->get($id)->{'resources'}->{'nvram'}));
			$adapter->set_domain_autostart($r->{'uuid'},
						       $r->{'autostart'});
			});
		$self->step($id, 'start',
			    sub { $adapter->start_domain($r->{'uuid'})
				if ($r->{'start'}); });
		# Cancellation wins until completion is recorded;
		# erase temporary secrets.
		$self->checkpoint($id);
		$self->clean_work($id);
		$jobs->update($id, sub {
			die "Virtual machine cloning cancelled\n"
				if ($_[0]->{'cancel'});
			$_[0]->{'state'} = 'complete';
			delete(
				@{
					$_[0]->{'request'}}{qw(password_hash source_xml console_password)});
			});
		1;
		};
	my $error = $@;
	if (!$ok) {
		# Cleanup failures retain reservations and expose a
		# recoverable job state.
		my $clean = eval { $self->cleanup($id, $adapter); 1 };
		$error .= "; cleanup needs attention: $@" if (!$clean);
		# Keep credentials out of persisted errors and
		# completed request records.
		$error =~ s/\Q$r->{password_hash}\E/[redacted]/g
			if ($r->{'password_hash'});
		$error =~ s/\Q$r->{console_password}\E/[redacted]/g
			if ($r->{'console_password'});
		$jobs->update($id, sub {
			$_[0]->{'state'} = $_[0]->{'cancel'} && $clean
				? 'cancelled'
				: 'failed';
			$_[0]->{'cleanup_pending'} = $clean ? 0 : 1;
			$_[0]->{'error'} =
				substr(Cloudmin::Libvirt::error_message($error),
				       0,
				       4000);
			$_[0]->{'events'}->[-1]->{'state'} = $_[0]->{'state'}
				if (@{$_[0]->{'events'}});
			delete(
				@{
					$_[0]->{'request'}}{qw(password_hash source_xml console_password)});
			});
		}
	my $finished = $jobs->get($id);
	# Audit failure is a warning, not a reason to undo a completed clone.
	my $logged = eval { $jobs->audit($ok
		? 'clone_complete'
		: $finished->{'state'} eq 'cancelled'
			? 'clone_cancelled'
			: 'clone_failed', $finished); 1 };
	$jobs->update($id,
		      sub { $_[0]->{'audit_warning'} =
			'Could not write the clone completion audit log'; }) if (
				!$logged);
	return $ok ? 1 : 0;
	});
}

1;
