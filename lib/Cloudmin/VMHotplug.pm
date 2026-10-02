package Cloudmin::VMManage;

# Loaded by VMManage.pm so live operations share its validation and job methods.
use strict;
use warnings;
use Time::HiRes qw(time sleep);

# memory_kib(doc, element)
# Converts libvirt memory fields to KiB, including omitted currentMemory.
sub memory_kib
{
return Cloudmin::Libvirt::memory_kib(@_);
}

# live_limits(domain, config)
# Reads limits from running XML, or from config when the guest is stopped.
sub live_limits
{
my ($domain, $config) = @_;
my $doc = $domain->is_active()
	? Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0)) : $config;
return { cpus => 0 + $doc->findvalue('/domain/vcpu'),
	min_cpus => $domain->is_active() ? live_cpu_minimum($doc) : 1,
	memory_mib => memory_kib($doc, 'memory') / 1024,
	pcie_ports => free_pcie_ports($doc),
	balloon => $doc->findnodes('/domain/devices/memballoon[@model="virtio"]') ? 1 : 0 };
}

# live_cpu_minimum(doc)
# Subtracts enabled, removable CPUs from the running count. Without individual
# CPU entries, conservatively treats every enabled CPU as non-removable.
sub live_cpu_minimum
{
my ($doc) = @_;
my $current = $doc->findvalue('/domain/vcpu/@current') || $doc->findvalue('/domain/vcpu');
my $removable = $doc->findvalue('count(/domain/vcpus/vcpu[@enabled="yes" and @hotpluggable="yes"])');
my $minimum = $current - $removable;
return $minimum > 0 ? $minimum : 1;
}

# free_pcie_ports(doc)
# Counts unused root-port buses; legacy PCI guests do not need these ports.
sub free_pcie_ports
{
my ($doc) = @_;
return undef if ($doc->findvalue('/domain/os/type/@machine') !~ /q35|^virt(?:-|$)/);
my %used = map { hex($_->getValue()) => 1 }
	$doc->findnodes('/domain/devices/*/address[@type="pci"]/@bus');
return scalar(grep { !$used{0 + $_->getAttribute('index')} }
	$doc->findnodes('/domain/devices/controller[@model="pcie-root-port"]'));
}

# hotplug_device(doc, kind, identity)
# Finds a disk by target or a network interface by MAC without XPath input.
sub hotplug_device
{
my ($doc, $kind, $identity) = @_;
return (grep { ($kind eq 'disk' ? $_->findvalue('target/@dev') :
	lc($_->findvalue('mac/@address'))) eq $identity }
	$doc->findnodes('/domain/devices/'.$kind))[0];
}

# device_value(node)
# Serializes editable fields for comparison; an absent node becomes ''.
# QEMU-assigned aliases and addresses do not identify an attachment change.
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
	next if ($node->nodeName() eq 'interface' && $path =~ /^target/);
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

# prepare_hotplug(plan)
# Derives native operations from the validated before/after definitions.
sub prepare_hotplug
{
my ($plan) = @_;
my $before = Cloudmin::Libvirt::parse_xml_document($plan->{'before_xml'});
my $after = Cloudmin::Libvirt::parse_xml_document($plan->{'xml'} || $plan->{'before_xml'});
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
# Compare both device lists to find additions, removals and in-place edits.
foreach my $kind (qw(disk interface)) {
	my %ids = map { ($kind eq 'disk' ? $_->findvalue('target/@dev') :
		lc($_->findvalue('mac/@address'))) => 1 }
		($before->findnodes('/domain/devices/'.$kind), $after->findnodes('/domain/devices/'.$kind));
	foreach my $id (sort keys %ids) {
		my $old = hotplug_device($before, $kind, $id);
		my $new = hotplug_device($after, $kind, $id);
		next if (device_value($old) eq device_value($new));
		my $op = { kind => $kind, identity => $id,
			method => !$old ? 'attach_device' : !$new ? 'detach_device' : 'update_device',
			before => device_value($old), after => device_value($new),
			xml => ($new || $old)->toString() };
		# Replacing media in a read-only CD/DVD drive preserves snapshots.
		# Adding or removing the drive still counts as a storage change.
		$op->{'media_change'} = 1 if ($kind eq 'disk' && $old && $new &&
			$old->getAttribute('device') eq 'cdrom' &&
			$new->getAttribute('device') eq 'cdrom' &&
			$old->exists('readonly') && $new->exists('readonly'));
		if ($kind eq 'disk' && $old && $new && $old->getAttribute('device') ne 'cdrom') {
			# Only removable media can replace an
			# existing disk source live.
			$reason ||= 'Shut down the virtual machine to change this disk attachment';
			}
		# Libvirt checks whether the selected network backend can switch live.
		push(@ops, $op);
		}
	}
foreach my $step ($plan, @{$plan->{'changes'} || []}) {
	# LVM must allocate and initialize new extents before QEMU can use them.
	# Keep that operation offline; block_resize alone cannot grow the LV.
	$reason ||= 'Shut down the virtual machine before growing an LVM disk'
		if ($step->{'operation'} eq 'grow_disk' && $step->{'volume'}->{'block'});
	# QEMU owns live image resizing; no independent volume resize follows it.
	push(@ops, { kind => 'resize', identity => $step->{'target'},
		before => $step->{'volume'}->{'capacity'}, after => $step->{'bytes'},
		volume => $step->{'volume'} })
		if ($step->{'operation'} eq 'grow_disk');
	}
$plan->{'live_ops'} = \@ops;
$plan->{'offline_reason'} = $reason if ($reason);
}

# hotplug_value(doc, operation)
# Reads the requested resource or device state without exposing secure XML.
sub hotplug_value
{
my ($doc, $op) = @_;
# Deferred groups compare saved fields together; allocations compare scalars.
return next_start_value($doc, $op->{'fields'}) if ($op->{'kind'} eq 'next_start');
return ''.($doc->findvalue('/domain/vcpu/@current') || $doc->findvalue('/domain/vcpu'))
	if ($op->{'kind'} eq 'cpus');
return ''.memory_kib($doc, 'currentMemory') if ($op->{'kind'} eq 'memory');
return ''.$doc->findvalue('/domain/description') if ($op->{'kind'} eq 'description');
return device_value(hotplug_device($doc, $op->{'kind'}, $op->{'identity'}));
}

# hotplug_reason(domain, plan)
# Reports a device change that blocks live execution; resource limits defer.
sub hotplug_reason
{
my ($domain, $plan) = @_;
return $plan->{'offline_reason'} if ($plan->{'offline_reason'});
my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0));
my $ports = free_pcie_ports($doc);
# Compare planned additions with the running guest's spare port count.
my $additions = grep { ($_->{'method'} || '') eq 'attach_device' } @{$plan->{'live_ops'}};
return 'Shut down once and enable hardware expansion before adding more devices'
	if (defined($ports) && $additions > $ports);
return undef;
}

# resource_values(doc)
# Returns comparable public settings for the running and saved definitions.
sub resource_values
{
return Cloudmin::Libvirt::resource_settings($_[0]);
}

# next_start_value(doc, fields)
# Compares selected resource groups without depending on XML units or spacing.
sub next_start_value
{
my ($doc, $fields) = @_;
my $values = resource_values($doc);
my %groups = (cpus => [qw(cpus cpu_limit)],
	memory => [qw(memory_mib memory_limit_mib)], boot => [qw(boot bootmenu)]);
return convert_to_json({ map { $_ => $values->{$_} }
	map { @{$groups{$_}} } @$fields }, 0, 0, 1);
}

# hotplug_operations(domain, plan)
# Splits known next-start settings from native live operations before writing.
sub hotplug_operations
{
my ($domain, $plan) = @_;
my $live = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(0));
my $before = Cloudmin::Libvirt::parse_xml_document($plan->{'before_xml'});
my $after = Cloudmin::Libvirt::parse_xml_document($plan->{'xml'} || $plan->{'before_xml'});
my %deferred;
# Maximums and boot order belong to the next full start even when allocations in
# the same request can be applied live.
$deferred{'cpus'} = 1 if ($before->findvalue('/domain/vcpu') != $after->findvalue('/domain/vcpu'));
$deferred{'memory'} = 1 if (memory_kib($before, 'memory') != memory_kib($after, 'memory'));
$deferred{'boot'} = 1 if (next_start_value($before, ['boot']) ne next_start_value($after, ['boot']));
my @ops;
foreach my $original (@{$plan->{'live_ops'}}) {
	my $op = { %$original };
	my $kind = $op->{'kind'};
	if ($kind eq 'cpus' || $kind eq 'memory') {
		# Existing pending allocations stay saved unless the user edits them.
		my $cannot_live = $kind eq 'cpus'
			? $op->{'after'} < live_cpu_minimum($live) || $op->{'after'} > $live->findvalue('/domain/vcpu')
			: $op->{'after'} > memory_kib($live, 'memory') ||
			  !$live->exists('/domain/devices/memballoon[@model="virtio"]');
		if ($cannot_live) {
			# Keep valid allocations that this running
			# guest cannot accept yet.
			$deferred{$kind} = 1;
			next;
			}
		# A deliberate edit may replace a previously deferred allocation.
		$op->{'live_before'} = hotplug_value($live, $op);
		}
	elsif ($deferred{'boot'} && $kind =~ /\A(?:disk|interface)\z/) {
		# Apply device edits with their old boot order until the final config save.
		my $device = Cloudmin::Libvirt::parse_xml_document($op->{'xml'})->documentElement();
		$_->unbindNode() foreach $device->findnodes('boot');
		my $old = hotplug_device($before, $kind, $op->{'identity'});
		$device->appendChild($_->cloneNode(1)) foreach $old ? $old->findnodes('boot') : ();
		$op->{'xml'} = $device->toString();
		}
	push(@ops, $op);
	}
if (%deferred) {
	# Save these fields after live work, preserving the configuration it leaves.
	# A saved maximum may be lower than the live allocation being requested.
	$_->{'defer_config'} = 1 foreach grep { $deferred{$_->{'kind'}} } @ops;
	my @fields = sort keys %deferred;
	push(@ops, { kind => 'next_start', fields => \@fields,
		before => next_start_value($before, \@fields),
		after => next_start_value($after, \@fields) });
	}
return \@ops;
}

# next_start_nodes(doc, fields)
# Selects only the XML elements owned by the deferred resource groups.
sub next_start_nodes
{
my ($doc, $fields) = @_;
my %paths = (cpus => '/domain/vcpu', memory => '/domain/memory | /domain/currentMemory',
	boot => '/domain/os/boot | /domain/os/bootmenu | /domain/devices/*/boot');
return $doc->findnodes(join(' | ', map { $paths{$_} } @$fields));
}

1;
