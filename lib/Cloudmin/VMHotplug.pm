package Cloudmin::VMManage;

# Loaded by VMManage.pm so live operations share its validation and job methods.
use strict;
use warnings;
use Time::HiRes qw(time sleep);

# memory_kib(doc, element) Converts libvirt memory fields to KiB, including
# omitted currentMemory.
sub memory_kib
{
return Cloudmin::Libvirt::memory_kib(@_);
}

# live_limits(domain, config) Reads limits from running XML, or from config when
# the guest is stopped.
sub live_limits
{
my ($domain, $config) = @_;
my $doc = $domain->is_active()
	? Cloudmin::Libvirt::parse_xml_document(
		$domain->get_xml_description(0))
	: $config;
return { cpus => 0 + $doc->findvalue('/domain/vcpu'),
	 min_cpus => $domain->is_active() ? live_cpu_minimum($doc) : 1,
	 memory_mib => memory_kib($doc, 'memory') / 1024,
	 pcie_ports => free_pcie_ports($doc),
	 balloon =>
		 $doc->findnodes('/domain/devices/memballoon[@model="virtio"]')
			 ? 1
			 : 0 };
}

# live_cpu_minimum(doc) Subtracts enabled, removable CPUs from the running
# count. Without individual CPU entries, conservatively treats every enabled
# CPU as non-removable.
sub live_cpu_minimum
{
my ($doc) = @_;
my $current = $doc->findvalue('/domain/vcpu/@current') ||
	      $doc->findvalue('/domain/vcpu');
my $removable =
	$doc->findvalue(
		'count(/domain/vcpus/vcpu[@enabled="yes" and @hotpluggable="yes"])');
my $minimum = $current - $removable;
return $minimum > 0 ? $minimum : 1;
}

# free_pcie_ports(doc) Counts unused root-port buses; legacy PCI guests do
# not need these ports.
sub free_pcie_ports
{
my ($doc) = @_;
return undef
	if ($doc->findvalue('/domain/os/type/@machine') !~ /q35|^virt(?:-|$)/);
my %used = map { hex($_->getValue()) => 1 }
	   $doc->findnodes('/domain/devices/*/address[@type="pci"]/@bus');
return scalar(grep { !$used{0 + $_->getAttribute('index')} }
	      $doc->findnodes(
		      '/domain/devices/controller[@model="pcie-root-port"]'));
}

# hotplug_device(doc, kind, identity) Finds a disk by target or a network
# interface by MAC without XPath input.
sub hotplug_device
{
my ($doc, $kind, $identity) = @_;
return (grep { ($kind eq 'disk'
	? $_->findvalue('target/@dev')
	: lc($_->findvalue('mac/@address'))) eq $identity }
	$doc->findnodes('/domain/devices/'.$kind))[0];
}

# device_value(node) Serializes editable fields for comparison; an absent node
# becomes ''. QEMU-assigned aliases and addresses do not identify
# an attachment change.
sub device_value
{
my ($node) = @_;
return '' if (!$node);
my %value;
foreach my $path (qw(@type @device driver/@type source/@file source/@dev
	source/@pool source/@volume source/@network target/@dev target/@bus
	mac/@address model/@type link/@state bandwidth/inbound/@average
	bandwidth/outbound/@average)) {
	# Host tap names are runtime details, unlike stable disk targets.
	next
		if ($node->nodeName() eq 'interface' && $path =~ /^target/);
	$value{$path} = ''.$node->findvalue($path);
	}
$value{'source/@bridge'} = ''.$node->findvalue('source/@bridge')
	if ($node->getAttribute('type') eq 'bridge');
$value{'readonly'} = $node->findnodes('readonly') ? 1 : 0;
# Libvirt omits the driver format for an empty live CD drive.
$value{'driver/@type'} = '' if ($value{'@device'} eq 'cdrom' &&
				!grep { length($value{'source/@'.$_}) } qw(file dev pool volume));
# Omitted link and bandwidth elements mean connected and unlimited.
$value{'link/@state'} ||= 'up';
$value{'bandwidth/'.$_.'/@average'} ||= '0' foreach qw(inbound outbound);
return convert_to_json(\%value, 0, 0, 1);
}

# prepare_hotplug(plan) Derives native operations from the validated
# before/after definitions.
sub prepare_hotplug
{
my ($plan) = @_;
my $before = Cloudmin::Libvirt::parse_xml_document($plan->{'before_xml'});
my $after =
	Cloudmin::Libvirt::parse_xml_document($plan->{'xml'} ||
					      $plan->{'before_xml'});
my @ops;
my $reason = $plan->{'offline_reason'};
# Destructive removal cannot be expressed as an ordinary live device edit.
$reason ||= 'Shut down the virtual machine before deleting it or its disk files'
	if ($plan->{'operation'} =~ /\A(?:delete|delete_disk)\z/);
# Keep scalar changes separate so partial success can be recovered per field.
foreach my $field (qw(cpus memory description)) {
	my $op = { kind => $field };
	$op->{'before'} = hotplug_value($before, $op);
	$op->{'after'} = hotplug_value($after, $op);
	push(@ops, $op) if ($op->{'before'} ne $op->{'after'});
	}
# Explicit media requests must validate the live drive even when the saved
# source already matches; otherwise ejecting live-only media reports success.
my %media_targets = map { $_->{'target'} => 1 }
		    grep { $_->{'operation'} eq 'change_media' } ( $plan,
								   @{$plan->{'changes'} || [ ]} );
# Compare both device lists to find additions, removals and in-place edits.
foreach my $kind (qw(disk interface)) {
	my %ids = map { ($kind eq 'disk'
		? $_->findvalue('target/@dev')
		: lc($_->findvalue('mac/@address'))) => 1 }
		  ( $before->findnodes('/domain/devices/'.$kind),
		    $after->findnodes('/domain/devices/'.$kind) );
	foreach my $id (sort keys %ids) {
		my $old = hotplug_device($before, $kind, $id);
		my $new = hotplug_device($after, $kind, $id);
		next if (device_value($old) eq device_value($new) &&
			 !($kind eq 'disk' && $media_targets{$id}));
		my $op = { kind => $kind, identity => $id,
			   method => !$old
				   ? 'attach_device'
				   : !$new ? 'detach_device' : 'update_device',
			   before => device_value($old), after =>
								 device_value($new),
			   xml => ($new || $old)->toString() };
		# Replacing media in a read-only CD/DVD drive preserves
		# snapshots. Adding or removing the drive still counts
		# as a storage change.
		$op->{'media_change'} = 1 if ($kind eq 'disk' && $old && $new &&
					      $old->getAttribute('device') eq 'cdrom' &&
					      $new->getAttribute('device') eq 'cdrom' &&
					      $old->exists('readonly') && $new->exists('readonly'));
		if ($kind eq 'disk' && $old && $new &&
		    $old->getAttribute('device') ne 'cdrom') {
			# Only removable media can replace an
			# existing disk source live.
			$reason ||= 'Shut down the virtual machine to change this disk attachment';
			}
		# Libvirt checks whether the selected network
		# backend can switch live.
		push(@ops, $op);
		}
	}
foreach my $step ( $plan, @{$plan->{'changes'} || [ ]} ) {
	# LVM must allocate and initialize new extents before QEMU can use them.
	# Keep that operation offline; block_resize alone cannot grow the LV.
	$reason ||= 'Shut down the virtual machine before growing an LVM disk'
		if ($step->{'operation'} eq 'grow_disk' &&
		    $step->{'volume'}->{'block'});
	# QEMU owns live image resizing; no independent
	# volume resize follows it.
	push(@ops, { kind => 'resize', identity => $step->{'target'},
		     before => $step->{'volume'}->{'capacity'}, after =>
									$step->{'bytes'},
		     volume => $step->{'volume'} })
		if ($step->{'operation'} eq 'grow_disk');
	}
$plan->{'live_ops'} = \@ops;
$plan->{'offline_reason'} = $reason if ($reason);
}

# hotplug_value(doc, operation) Reads the requested resource or device state
# without exposing secure XML.
sub hotplug_value
{
my ($doc, $op) = @_;
# Deferred groups compare saved fields together; allocations compare scalars.
return next_start_value($doc, $op->{'fields'})
	if ($op->{'kind'} eq 'next_start');
return ''.($doc->findvalue('/domain/vcpu/@current') ||
	   $doc->findvalue('/domain/vcpu'))
	if ($op->{'kind'} eq 'cpus');
return ''.memory_kib($doc, 'currentMemory') if ($op->{'kind'} eq 'memory');
return ''.$doc->findvalue('/domain/description')
	if ($op->{'kind'} eq 'description');
return device_value(hotplug_device($doc, $op->{'kind'}, $op->{'identity'}));
}

# hotplug_reason(domain, plan) Reports a device change that blocks live
# execution; resource limits defer.
sub hotplug_reason
{
my ($domain, $plan) = @_;
return $plan->{'offline_reason'} if ($plan->{'offline_reason'});
my $doc =
	Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0));
my $ports = free_pcie_ports($doc);
# Compare planned additions with the running guest's spare port count.
my $additions =
	grep { ($_->{'method'} || '') eq 'attach_device' } @{$plan->{'live_ops'}};
return 'Shut down once and enable hardware expansion before adding more devices'
	if (defined($ports) && $additions > $ports);
return undef;
}

# resource_values(doc) Returns comparable public settings for the running
# and saved definitions.
sub resource_values
{
return Cloudmin::Libvirt::resource_settings($_[0]);
}

# next_start_value(doc, fields) Compares selected resource groups without
# depending on XML units or spacing.
sub next_start_value
{
my ($doc, $fields) = @_;
my $values = resource_values($doc);
my %groups = ( cpus => [ qw(cpus cpu_limit) ],
	       memory => [ qw(memory_mib memory_limit_mib) ], boot =>
								      [ qw(boot bootmenu) ] );
return convert_to_json({ map { $_ => $values->{$_} }
			 map { @{$groups{$_}} } @$fields }, 0, 0, 1);
}

# hotplug_operations(domain, plan) Splits known next-start settings from native
# live operations before writing.
sub hotplug_operations
{
my ($domain, $plan) = @_;
my $live =
	Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0));
my $before = Cloudmin::Libvirt::parse_xml_document($plan->{'before_xml'});
my $after =
	Cloudmin::Libvirt::parse_xml_document($plan->{'xml'} ||
					      $plan->{'before_xml'});
my %deferred;
# Maximums and boot order belong to the next full start even when allocations in
# the same request can be applied live.
$deferred{'cpus'} = 1
	if (
		$before->findvalue('/domain/vcpu') != $after->findvalue(
			'/domain/vcpu'));
$deferred{'memory'} = 1
	if (memory_kib($before, 'memory') != memory_kib($after, 'memory'));
$deferred{'boot'} = 1
	if (next_start_value($before, [ 'boot' ]) ne next_start_value($after,
								      [ 'boot' ]));
my @ops;
foreach my $original (@{$plan->{'live_ops'}}) {
	my $op = { %$original };
	my $kind = $op->{'kind'};
	if ($kind eq 'cpus' || $kind eq 'memory') {
		# Existing pending allocations stay saved unless
		# the user edits them.
		my $cannot_live = $kind eq 'cpus'
			? $op->{'after'} < live_cpu_minimum($live) ||
				  $op->{'after'} > $live->findvalue('/domain/vcpu')
			: $op->{'after'} > memory_kib($live, 'memory') ||
				  !$live->exists(
					  '/domain/devices/memballoon[@model="virtio"]');
		if ($cannot_live) {
			# Keep valid allocations that this running
			# guest cannot accept yet.
			$deferred{$kind} = 1;
			next;
			}
		# A deliberate edit may replace a previously
		# deferred allocation.
		$op->{'live_before'} = hotplug_value($live, $op);
		}
	elsif ($deferred{'boot'} && $kind =~ /\A(?:disk|interface)\z/) {
		# Apply device edits with their old boot order until
		# the final config save.
		my $device =
			Cloudmin::Libvirt::parse_xml_document(
				$op->{'xml'})->documentElement();
		$_->unbindNode() foreach $device->findnodes('boot');
		my $old = hotplug_device($before, $kind, $op->{'identity'});
		$device->appendChild($_->cloneNode(1)) foreach $old
			? $old->findnodes('boot')
			: ();
		$op->{'xml'} = $device->toString();
		}
	push(@ops, $op);
	}
if (%deferred) {
	# Save these fields after live work, preserving the configuration it
	# leaves. A saved maximum may be lower than the live
	# allocation being requested.
	$_->{'defer_config'} = 1 foreach grep { $deferred{$_->{'kind'}} } @ops;
	my @fields = sort keys %deferred;
	push(@ops, { kind => 'next_start', fields => \@fields,
		     before => next_start_value($before, \@fields),
		     after => next_start_value($after, \@fields) });
	}
return \@ops;
}

# next_start_nodes(doc, fields) Selects only the XML elements owned by the
# deferred resource groups.
sub next_start_nodes
{
my ($doc, $fields) = @_;
my %paths =
	( cpus => '/domain/vcpu',
	  memory => '/domain/memory | /domain/currentMemory',
	  boot =>
		  '/domain/os/boot | /domain/os/bootmenu | /domain/devices/*/boot' );
return $doc->findnodes(join(' | ', map { $paths{$_} } @$fields));
}

# save_next_start(adapter, domain, plan, operation) Patches the latest saved
# XML; the running hardware and unrelated fields stay intact.
sub save_next_start
{
my ($adapter, $domain, $plan, $op) = @_;
my $xml = $domain->get_xml_description(3);
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
my $after = Cloudmin::Libvirt::parse_xml_document($plan->{'xml'});
$_->unbindNode() foreach next_start_nodes($doc, $op->{'fields'});
foreach my $node (next_start_nodes($after, $op->{'fields'})) {
	my $parent = $node->parentNode();
	my $target;
	if ($parent->nodeName() eq 'disk' ||
	    $parent->nodeName() eq 'interface') {
		# Device boot order belongs to an attachment, not
		# its position in XML.
		my $kind = $parent->nodeName();
		$target = hotplug_device($doc, $kind, $parent->findvalue(
			$kind eq 'disk' ? 'target/@dev' : 'mac/@address'));
		die "The selected boot device is no longer attached\n"
			if (!$target);
		}
	else {
		# Resource elements belong to domain; legacy boot
		# elements belong to os.
		$target = $parent->nodeName() eq 'os'
			? ($doc->findnodes('/domain/os'))[0]
			: $doc->documentElement();
		}
	$target->appendChild($doc->importNode($node, 1));
	}
Cloudmin::Libvirt::log_call('Sys::Virt::define_domain', {
	uuid => $domain->get_uuid_string(), flags => 1, scope =>
								'config',
	changes => audit_changes($xml, $doc->toString()) });
$adapter->connect()->define_domain($doc->toString(), 1);
}

# validate_hotplug(domain, plan) Rejects unsupported changes and detects live
# edits outside the saved definition.
sub validate_hotplug
{
my ($domain, $plan) = @_;
my $reason = hotplug_reason($domain, $plan);
die "$reason\n" if ($reason);
my $doc =
	Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0));
foreach my $op (@{hotplug_operations($domain, $plan)}) {
	# Deferred settings deliberately differ from the running hardware.
	next if ($op->{'kind'} eq 'next_start');
	# An out-of-band live edit must not be overwritten with
	# the saved definition.
	if ($op->{'kind'} eq 'resize') {
		# A live-only disk replacement must not
		# receive the queued resize.
		my $before =
			Cloudmin::Libvirt::parse_xml_document(
				$plan->{'before_xml'});
		die "The running disk differs from the saved attachment\n"
			if (device_value(hotplug_device($doc, 'disk',
							$op->{'identity'})) ne
			    device_value(hotplug_device($before, 'disk',
							$op->{'identity'})));
		next;
		}
	# Media conflicts need a shutdown, not another save of the same form.
	die($op->{'media_change'}
		? "The running CD/DVD drive differs from its saved configuration; shut down the virtual machine before changing its ISO image\n"
		: "Running hardware differs from the saved configuration; reload and resolve it before editing\n")
		if (hotplug_value($doc,
				  $op) ne ($op->{'live_before'} // $op->{'before'}));
	}
}

# hotplug_guard(xml, operation) Detects unrelated definition edits while a
# native call may have partly applied.
sub hotplug_guard
{
my ($xml, $op) = @_;
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
my @remove;
if ($op->{'kind'} eq 'next_start') {
	# Exclude only the resource groups this saved-definition write owns.
	@remove = next_start_nodes($doc, $op->{'fields'});
	}
elsif ($op->{'kind'} =~ /\A(?:disk|interface)\z/) {
	# A partial device edit may add, remove or replace this one attachment.
	my $node = hotplug_device($doc, $op->{'kind'}, $op->{'identity'});
	push(@remove, $node) if ($node);
	}
elsif ($op->{'kind'} eq 'cpus') {
	# The current count may change, but an external maximum change must not.
	($_->removeAttribute('current')) foreach $doc->findnodes(
		'/domain/vcpu');
	}
elsif ($op->{'kind'} ne 'resize') {
	# Balloon and description updates each own one
	# element; resize owns no XML.
	my %fields = ( memory => 'currentMemory',
		       description => 'description' );
	@remove = $doc->findnodes('/domain/'.$fields{$op->{'kind'}});
	}
$_->unbindNode() foreach @remove;
# Ignore serialization whitespace while retaining unrelated XML attributes.
$_->unbindNode() foreach $doc->findnodes('//text()[not(normalize-space())]');
return sha256_hex($doc->toStringC14N());
}

# read_hotplug(domain, operation, flags) Reads native disk capacity or the
# corresponding live/persistent XML field. flags selects the XML view and is
# unused for native block-capacity reads.
sub read_hotplug
{
my ($domain, $op, $flags) = @_;
return ''.$domain->get_block_info($op->{'identity'})->{'capacity'}
	if ($op->{'kind'} eq 'resize');
return hotplug_value(Cloudmin::Libvirt::parse_xml_document(
	$domain->get_xml_description($flags)), $op);
}

# call_hotplug(domain, operation, flags) Sends only the selected hardware
# operation through the native Sys::Virt API.
sub call_hotplug
{
my ($domain, $op, $flags) = @_;
my $kind = $op->{'kind'};
my $method = $kind eq 'cpus'
	? 'set_vcpus'
	: $kind eq 'memory'
		? 'set_memory'
		: $kind eq 'description'
			? 'set_metadata'
			: $kind eq 'resize' ? 'block_resize' : $op->{'method'};
if ($method eq 'update_device' &&
    ($flags & Sys::Virt::Domain::DEVICE_MODIFY_LIVE())) {
	# Keep pending boot order out of a live device edit. Split only when the
	# live and saved device XML need different boot settings.
	my $live =
		Cloudmin::Libvirt::parse_xml_document(
			$domain->get_xml_description(0));
	my $device = hotplug_device($live, $kind, $op->{'identity'});
	my $request =
		Cloudmin::Libvirt::parse_xml_document(
			$op->{'xml'})->documentElement();
	if ($device &&
	    ''.$device->findvalue('boot/@order') ne ''.
	    $request->findvalue('boot/@order')) {
		# Send the live boot order first, then save the
		# requested persistent order.
		$_->unbindNode() foreach $request->findnodes('boot');
		$request->appendChild(
			$_->cloneNode(1)) foreach $device->findnodes(
				'boot');
		call_hotplug($domain,
			     { %$op, xml => $request->toString() },
			     Sys::Virt::Domain::DEVICE_MODIFY_LIVE());
		call_hotplug($domain, $op,
			     Sys::Virt::Domain::DEVICE_MODIFY_CONFIG())
			if (
				$flags & Sys::Virt::Domain::DEVICE_MODIFY_CONFIG());
		return;
		}
	}
# Block resizing has byte-unit flags, not the live/config flag contract.
$flags = Sys::Virt::Domain::BLOCK_RESIZE_BYTES() if ($kind eq 'resize');
Cloudmin::Libvirt::log_call('Sys::Virt::Domain::'.$method, {
	uuid => $domain->get_uuid_string(), flags => $flags,
	($op->{'identity'} ? ( device => $op->{'identity'} ) : ()),
	($kind =~ /\A(?:cpus|memory|resize)\z/
		? ( value => 0 + $op->{'after'} )
		: ()) });
if ($kind eq 'resize') {
	# Let QEMU grow the open disk; storage-volume resize
	# is the offline path.
	$domain->block_resize($op->{'identity'}, $op->{'after'}, $flags);
	}
elsif ($kind eq 'description') {
	# Description metadata requires its type and unused namespace arguments.
	$domain->set_metadata(Sys::Virt::Domain::METADATA_DESCRIPTION(),
			      $op->{'after'}, undef, undef, $flags);
	}
elsif ($kind eq 'cpus' || $kind eq 'memory') {
	# CPU counts and balloon targets use their native scalar setters.
	$domain->$method($op->{'after'}, $flags);
	}
else {
	# Attachment operations use XML; removals need the
	# current device address.
	my $xml = $op->{'xml'};
	if ($method eq 'detach_device') {
		# Detach the actual live/config device, including
		# its assigned address.
		my $doc =
			Cloudmin::Libvirt::parse_xml_document(
				$domain->get_xml_description(
					$flags == Sys::Virt::Domain::DEVICE_MODIFY_CONFIG()
						? 3
						: 1));
		my $node = hotplug_device($doc, $kind, $op->{'identity'});
		return if (!$node);
		$xml = $node->toString();
		}
	$domain->$method($xml, $flags);
	}
}

# wait_hotplug(domain, operation, seconds) Polls reported live state for up to
# seconds; a timeout is not a rollback.
sub wait_hotplug
{
my ($domain, $op, $seconds) = @_;
my $deadline = time() + $seconds;
while ($domain->is_active()) {
	# An accepted request may remain pending after its API call returns.
	return 1 if (read_hotplug($domain, $op, 0) eq $op->{'after'});
	die "The guest has not confirmed the hardware change. It may still complete; use Recover to check it again\n"
		if (time() >= $deadline);
	sleep(0.2);
	}
# A stopped QEMU process has no device left to detach.
return 1 if (($op->{'method'} || '') eq 'detach_device');
die "The virtual machine stopped during the hardware change; use Recover to check its saved settings\n";
}

# run_hotplug(self, adapter, domain, job_id) Journals each operation so recovery
# can finish a live/config partial success.
sub run_hotplug
{
my ($self, $adapter, $domain, $id) = @_;
my $jobs = $self->{'jobs'};
my $job = $jobs->get($id);
my $plan = $job->{'request'};
my $journal = $job->{'resources'}->{'live'};
if (!$journal) {
	# Recheck the definition before the first live write,
	# after any storage work.
	validate_hotplug($domain, $plan);
	my $revision = sha256_hex($domain->get_xml_description(3));
	die "The virtual machine configuration changed; reload the page\n"
		if ($revision ne $plan->{'revision'});
	my $ops = hotplug_operations($domain, $plan);
	$journal = { next => 0, revision => $revision, operations => $ops };
	$jobs->update($id, sub {
		$_[0]->{'resources'}->{'live'} = $journal;
		$_[0]->{'scope'} = (grep { $_->{'kind'} ne 'next_start' } @$ops)
			? 'live'
			: 'config';
		$_[0]->{'deferred_fields'} =
			[ map { @{$_->{'fields'}} } grep {
				$_->{'kind'} eq 'next_start' } @$ops ];
		});
	}
my @ops = @{$journal->{'operations'} || $plan->{'live_ops'}};
# Recheck storage identity and other guests' use on recovery as well as startup.
foreach my $step ( $plan, @{$plan->{'changes'} || [ ]} ) {
	foreach my $record ( grep { $_ } $step->{'attach_volume'},
			     $step->{'volume'},
			     ($step->{'new_volume'}
				     ? $job->{'resources'}->{'new_volumes'}
			      ->{$step->{'new_volume'}->{'name'}}
				     : undef) ) {
		$self->check_volume($adapter, $record,
				    $plan->{'uuid'});
		}
	if (my $media = $step->{'media'}) {
		# Read-only ISOs may be shared, but must still
		# be the selected file.
		my (undef, $volume) =
			$adapter->volume(@$media{qw(pool name key)});
		die "The selected ISO media changed or was removed\n"
			if (!$volume ||
			    file_identity(
				    $volume->get_path()) ne $media->{'identity'});
		}
	}
for (my $index = $journal->{'next'} ; $index < @ops ; $index++) {
	my $op = $ops[$index];
	my $config_xml = $domain->get_xml_description(3);
	my $pending = $journal->{'pending'};
	if (!$pending) {
		# The next step may begin only with the definition
		# left by the last one.
		die "The virtual machine configuration changed during this job; review it before recovery\n"
			if (sha256_hex($config_xml) ne $journal->{'revision'});
		$pending = { guard => hotplug_guard($config_xml, $op),
			     before => $op->{'kind'} eq 'next_start'
				     ? read_hotplug($domain, $op, 3)
				     : $op->{'before'} };
		$journal->{'pending'} = $pending;
		$jobs->update($id, sub {
			$_[0]->{'events'}->[-1]->{'state'} = 'done'
				if (@{$_[0]->{'events'}} &&
				    $_[0]->{'events'}->[-1]->{'state'} eq 'running');
			$_[0]->{'resources'}->{'live'} = $journal;
			$_[0]->{'phase'} = 'live_'.$op->{'kind'};
			push(@{$_[0]->{'events'}},
			     { step => 'live_'.$op->{'kind'}, state =>
								      'running' });
			});
		}
	die "Unrelated settings changed during this job; review them before recovery\n"
		if (hotplug_guard($config_xml, $op) ne $pending->{'guard'});
	my $config = read_hotplug($domain, $op, 3);
	# Recovery accepts only the original value or this operation's target.
	die "The saved hardware no longer matches this operation\n"
		if ($config ne ($pending->{'before'} // $op->{'before'}) &&
		    $config ne $op->{'after'});
	my $active = $op->{'kind'} ne 'next_start' && $domain->is_active();
	if (!$active && $op->{'kind'} eq 'resize' &&
	    $config ne $op->{'after'}) {
		# A stopped guest uses the normal volume path when
		# completing recovery.
		require_stopped($domain);
		$self->apply_storage($adapter,
				     { operation => 'grow_disk',
				       uuid => $plan->{'uuid'},
				       volume => $op->{'volume'},
				       bytes => $op->{'after'} }, $id);
		}
	my $live = $active ? read_hotplug($domain, $op, 0) : $op->{'after'};
	my $detach = ($op->{'method'} || '') eq 'detach_device';
	if ($active && $live ne $op->{'after'}) {
		# Accepted asynchronous changes are polled, including a balloon
		# that has reached an intermediate size. Never resend
		# an uncertain unplug.
		if (!$pending->{'accepted'} &&
		    (!$detach || !$pending->{'requested'})) {
			# Persist intent before calling libvirt so a lost
			# detach reply is safe.
			die "Running hardware changed outside this job\n"
				if (
					$live ne (
						$op->{'live_before'} // $op->{'before'}));
			$pending->{'requested'} = 1;
			$jobs->update($id,
				      sub { $_[0]->{'resources'}->{'live'} =
					$journal; });
			my $flags = Sys::Virt::Domain::DEVICE_MODIFY_LIVE();
			# Detach must complete live before CONFIG;
			# deferred groups save later.
			$flags |= Sys::Virt::Domain::DEVICE_MODIFY_CONFIG()
				if (!$detach && !$op->{'defer_config'} &&
				    $config ne $op->{'after'});
			$flags = Sys::Virt::Domain::VCPU_LIVE() |
				 (!$op->{'defer_config'} &&
				  $config ne $op->{'after'}
					  ? Sys::Virt::Domain::VCPU_CONFIG()
					  : 0)
				if ($op->{'kind'} eq 'cpus');
			$flags = Sys::Virt::Domain::MEM_LIVE() |
				 (!$op->{'defer_config'} &&
				  $config ne $op->{'after'}
					  ? Sys::Virt::Domain::MEM_CONFIG()
					  : 0)
				if ($op->{'kind'} eq 'memory');
			call_hotplug($domain, $op, $flags);
			$pending->{'accepted'} = 1;
			$jobs->update($id,
				      sub { $_[0]->{'resources'}->{'live'} =
					$journal; });
			}
		wait_hotplug($domain, $op, $self->{'hotplug_timeout'} // 30);
		}
	if (!$op->{'defer_config'} && $op->{'kind'} ne 'resize' &&
	    read_hotplug($domain, $op, 3) ne $op->{'after'}) {
		# Persist only after live success; also repairs a previous
		# config-save failure.
		if ($op->{'kind'} eq 'next_start') {
			# Defining persistent XML never powers off
			# or restarts the guest.
			save_next_start($adapter, $domain, $plan, $op);
			}
		else {
			# Finish the persistent half of a successful native
			# device/resource edit.
			call_hotplug($domain, $op,
				     Sys::Virt::Domain::DEVICE_MODIFY_CONFIG());
			}
		}
	die "Libvirt did not retain the requested hardware configuration\n"
		if (!$op->{'defer_config'} &&
		    read_hotplug($domain, $op, 3) ne $op->{'after'});
	# Advance only after verification; recovery resumes
	# at the next operation.
	$journal->{'next'} = $index + 1;
	$journal->{'revision'} = sha256_hex($domain->get_xml_description(3));
	delete($journal->{'pending'});
	$jobs->update($id, sub {
		$_[0]->{'resources'}->{'live'} = $journal;
		$_[0]->{'events'}->[-1]->{'state'} = 'done';
		});
	}
$self->complete($id);
}

1;
