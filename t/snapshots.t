use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/Snapshots.pm";
plan skip_all => 'SQLite and XML::LibXML are required'
	if (!eval { Cloudmin::Jobs::dependencies(); require XML::LibXML; 1 });
{
	package SnapshotAdapter;
	# uri(self) models a local system connection.
	sub uri { 'qemu:///system' }
	# connect(self) reuses this object as the fake native connection.
	sub connect { $_[0] }
	# get_library_version(self) exposes the chosen libvirt version.
	sub get_library_version { $_[0]->{'version'} || 12001000 }
	# get_capabilities(self) models whether AppArmor is advertised.
	sub get_capabilities { '<capabilities><host>'.($_[0]->{'apparmor'} ? '<secmodel><model>apparmor</model></secmodel>' : '').'</host></capabilities>' }
	# find_domain(self, id) supplies the single fixture guest.
	sub find_domain { $_[0]->{'domain'} }
	# list_all_domains(self, [flags]) supplies that guest to host inventory.
	sub list_all_domains { $_[0]->{'domain'} }
	package SnapshotDomain;
	# get_name(self) supplies the guest label used by jobs.
	sub get_name { 'fixture' }
	# get_uuid_string(self) supplies a stable identity across operations.
	sub get_uuid_string { '11111111-2222-4333-8444-555555555555' }
	# is_persistent(self) models a saved guest definition.
	sub is_persistent { 1 }
	# is_active(self) reads the state controlled by shutdown and create.
	sub is_active { $_[0]->{'active'} || 0 }
	# get_state(self) models running or shut-off state and its stop reason.
	sub get_state { $_[0]->is_active() ? (1, 1) : (5, $_[0]->{'stop_reason'} // 1) }
	# shutdown(self) models clean completion, timeout, and an interrupted reply.
	sub shutdown
	{
	my ($self) = @_;
	$self->{'shutdowns'}++;
	$self->{'active'} = 0 unless $self->{'ignore_shutdown'};
	$self->{'xml'} =~ s{</domain>}{<description>Changed during shutdown</description></domain>} if ($self->{'change_on_stop'});
	die "Shutdown reply lost\n" if ($self->{'lose_shutdown'});
	}
	# create(self) can fail before boot or lose the reply after booting.
	sub create
	{
	my ($self) = @_;
	$self->{'starts'}++;
	die "Start failed\n" if ($self->{'fail_start'});
	$self->{'active'} = 1;
	die "Start reply lost\n" if ($self->{'lose_start'});
	}
	# Read-only libvirt rejects protected XML even though history is readable.
	# get_xml_description(self, flags) exposes XML subject to read-only access.
	sub get_xml_description
	{
	die "Secure XML is forbidden\n" if ($_[0]->{'readonly'} && ($_[1] & 1));
	return $_[0]->{'xml'};
	}
	# get_job_info(self) injects a conflicting native job when requested.
	sub get_job_info { { type => $_[0]->{'busy'} || 0 } }
	# list_all_checkpoints(self, [flags]) models conflicting backup history.
	sub list_all_checkpoints { $_[0]->{'checkpoint'} ? (1) : () }
	# has_managed_save_image(self) models saved guest memory.
	sub has_managed_save_image { $_[0]->{'saved'} || 0 }
	# list_all_snapshots(self, [flags]) enumerates committed fixture history.
	sub list_all_snapshots { values %{$_[0]->{'snapshots'}} }
	# set_agent_response_timeout(self, timeout) needs no timer in this mock.
	sub set_agent_response_timeout { }
	# get_guest_info(self, [types]) counts probes and models agent availability.
	sub get_guest_info { $_[0]->{'agent_probes'}++; die "No agent\n" if (!$_[0]->{'agent'}); return { os => 'Linux' }; }
	# fs_thaw(self, [mountpoints], [flags]) models thaw success or failure.
	sub fs_thaw { $_[0]->{'thaws'}++; die "Thaw failed\n" if ($_[0]->{'fail_thaw'}); $_[0]->{'frozen'} = 0; }
	# create_snapshot(self, xml, flags) can lose a reply after committing metadata.
	sub create_snapshot
	{
	my ($self, $xml, $flags) = @_;
	$self->{'flags'} = $flags;
	$self->{'calls'}++;
	$self->{'snapshot_active'} = $self->is_active();
	die $self->{'create_error'} if ($self->{'create_error'});
	$self->{'frozen'} = 1 if ($flags & 64);
	die "Freeze failed\n" if ($self->{'fail_freeze'});
	my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
	my $name = $doc->findvalue('/domainsnapshot/name');
	# Libvirt records disk-only live snapshots separately from stopped captures.
	my $state = $self->is_active() ? 'disk-snapshot' : 'shutoff';
	$xml =~ s{</domainsnapshot>}{<state>$state</state></domainsnapshot>};
	my $snapshot = bless({ domain => $self, name => $name, xml => $xml, created => $self->{'calls'}, before => $self->{'xml'} }, 'SnapshotPoint');
	$snapshot->{'parent'} = $self->{'current'};
	$self->{'snapshots'}->{$name} = $snapshot;
	$self->{'current'} = $name;
	$self->{'xml'} =~ s{</domain>}{<description>$name</description></domain>};
	die "Create reply lost\n" if ($self->{'lose_create'});
	$self->{'frozen'} = 0;
	return $snapshot;
	}
	package SnapshotPoint;
	# get_name(self) identifies this saved point.
	sub get_name { $_[0]->{'name'} }
	# is_current(self) compares this point with the simulated current branch.
	sub is_current { ($_[0]->{'domain'}->{'current'} || '') eq $_[0]->{'name'} }
	# get_xml_description(self, [flags]) includes ancestry and restore markers.
	sub get_xml_description
	{
	my ($self) = @_;
	my $xml = $self->{'xml'};
	$xml =~ s{</domainsnapshot>}{<parent><name>$self->{parent}</name></parent></domainsnapshot>} if ($self->{'parent'});
	$xml =~ s{</domainsnapshot>}{<creationTime>$self->{created}</creationTime>$self->{revert}</domainsnapshot>} if ($self->{'revert'});
	$xml =~ s{</domainsnapshot>}{<creationTime>$self->{created}</creationTime></domainsnapshot>} if (!$self->{'revert'});
	return $xml;
	}
	# delete(self, flags) models native merging, including a lost response.
	sub delete
	{
	my ($self, $flags) = @_;
	die "Metadata-only deletion is forbidden" if ($flags);
	$self->{'domain'}->{'deletes'}++;
	die $self->{'domain'}->{'delete_error'} if ($self->{'domain'}->{'delete_error'});
	die "Merge failed\n" if ($self->{'domain'}->{'fail_delete'});
	delete($self->{'domain'}->{'snapshots'}->{$self->{'name'}});
	die "Delete reply lost\n" if ($self->{'domain'}->{'lose_delete'});
	}
	# revert_to(self, flags) supplies libvirt's durable new overlay marker.
	sub revert_to
	{
	my ($self) = @_;
	$self->{'domain'}->{'restores'}++;
	$self->{'revert'} = '<revertDisks><disk name="vda"><source file="/restored/'. $self->{'domain'}->{'restores'} .'"/></disk></revertDisks>';
	$self->{'domain'}->{'current'} = $self->{'name'};
	$self->{'domain'}->{'xml'} = $self->{'before'};
	die "Restore reply lost\n" if ($self->{'domain'}->{'lose_restore'});
	}
	package SnapshotService;
	our @ISA = ('Cloudmin::Snapshots');
	# Storage itself is exercised by the native two-disk lifecycle fixture.
	# disks(self, adapter, domain, document) supplies one controlled disk.
	sub disks { [{ target => 'vda', volume => $_[0]->{'volume'} }] }
	# check_history_storage(self, adapter, domain, [resuming_delete])
	# Leaves storage dependency checks to the live fixture.
	sub check_history_storage { }
}
my $dir = tempdir(CLEANUP => 1);
my $sequence = 0;

{
	# Saved-file allocation must not count newer writes or a shared base twice.
	my $saved = "$dir/saved.qcow2";
	my $later = "$dir/later.qcow2";
	open(my $file, '>', $saved) or die $!; print $file 'a' x 8192; close($file);
	open($file, '>', $later) or die $!; print $file 'b' x 65536; close($file);
	link($saved, "$dir/alias.qcow2") or die $!;
	my $xml = '<domainsnapshot><disks><disk name="vda" snapshot="external"><source file="'.$later.'"/></disk>'.
		'<disk name="vdb" snapshot="external"/></disks><domain><devices>'.
		'<disk type="file"><source file="'.$saved.'"/><backingStore><source file="'.$later.'"/></backingStore><target dev="vda"/></disk>'.
		'<disk type="file"><source file="'.$dir.'/alias.qcow2"/><target dev="vdb"/></disk>'.
		'<disk type="file"><source file="'.$later.'"/><target dev="vdc"/><readonly/></disk>'.
		'</devices></domain></domainsnapshot>';
	is(Cloudmin::Snapshots::disk_allocation(Cloudmin::Libvirt::parse_xml_document($xml), {}),
		(stat($saved))[12]*512, 'allocation counts saved blocks once, excluding backing files, media and later writes');
	$xml =~ s{\Q$saved\E}{missing-file};
	is(Cloudmin::Snapshots::disk_allocation(Cloudmin::Libvirt::parse_xml_document($xml), {}),
		undef, 'a missing saved disk makes the size unknown');
	is(Cloudmin::Snapshots::disk_allocation(Cloudmin::Libvirt::parse_xml_document('<domainsnapshot/>'), {}),
		undef, 'unsupported snapshot storage has no invented size');
}

# fixture() provides independent persistent jobs and a controllable native API.
sub fixture
{
my $id = ++$sequence;
my $path = "$dir/source-$id";
open(my $file, '>', $path) or die $!; print $file 'fixture'; close($file);
my %held;
my $jobs = Cloudmin::Jobs->new(directory => "$dir/jobs-$id",
	lock_file => sub { die 'nested lock' if $held{$_[0]}; $held{$_[0]} = 1 },
	unlock_file => sub { delete($held{$_[0]}) }, test_lock => sub { $held{$_[0]} }, log => sub {});
my $domain = bless({ snapshots => {}, xml => '<domain type="kvm"><name>fixture</name><devices/></domain>' }, 'SnapshotDomain');
my $adapter = bless({domain => $domain}, 'SnapshotAdapter');
my $service = SnapshotService->new(jobs => $jobs, adapter => sub { $adapter }, volume => {
	path => $path, identity => Cloudmin::VMManage::file_identity($path) });
return ($service, $jobs, $domain, $adapter);
}

# submit(service, action, [fields]) queues through production validation.
sub submit
{
my ($service, $action, $fields) = @_;
my $domain = $service->{'adapter'}->()->{'domain'};
my $id = substr(sha256_hex('request'.++$sequence), 0, 32);
my $r = $service->prepare('snapshot_'.$action, { id => $domain->get_uuid_string(),
	revision => Cloudmin::Snapshots::revision($domain), label => 'Before update', %{$fields || {}} }, $id);
$service->{'jobs'}->submit($id, 'fixture', 'guest:'.$domain->get_uuid_string(), $r);
return $id;
}

# recover(service, id) models the existing owner's explicit recovery action.
sub recover
{
my ($service, $id) = @_;
$service->{'jobs'}->update($id, sub { $_[0]->{'state'} = 'recovering'; });
$service->run($id);
return $service->{'jobs'}->get($id);
}
{
	my ($service, $jobs, $domain) = fixture();
	my $id = submit($service, 'create');
	$service->run($id);
	$domain->{'readonly'} = $service->{'readonly'} = $domain->{'active'} = 1;
	my $history = $service->inventory($domain->get_uuid_string());
	is($history->{'guest'}->{'uuid'}, $domain->get_uuid_string(), 'read-only users can open individual guest history');
	is(scalar(@{$history->{'snapshots'}}), 1, 'read-only inventory retains saved snapshots');
	ok(!$history->{'revision'}, 'read-only inventory does not request a protected mutation revision');
	ok(!$domain->{'agent_probes'}, 'read-only history does not send guest-agent commands');
}
{
	my ($service, $jobs, $domain, $adapter) = fixture();
	$adapter->{'version'} = 11003000; $adapter->{'apparmor'} = 1;
	ok(!$service->inventory($domain->get_uuid_string())->{'unavailable'},
		'older AppArmor hosts expose snapshot controls instead of predicting failure');
	my $id = submit($service, 'create'); $service->run($id);
	is($domain->{'calls'}, 1, 'snapshot creation reaches libvirt on an older AppArmor host');
	is($jobs->get($id)->{'state'}, 'complete', 'successful creation is not rejected by a version threshold');
	my $snapshot = $jobs->get($id)->{'request'}->{'snapshot'};
	my $restore = submit($service, 'restore', {snapshot => $snapshot, confirm => 1});
	$service->run($restore);
	is($jobs->get($restore)->{'state'}, 'complete', 'restore is attempted on the same host');
	$domain->{'delete_error'} = "internal error: unable to execute QEMU command 'block-commit': Could not open '/fixture/disk.qcow2': Permission denied\n";
	my $delete = submit($service, 'delete', {snapshot => $snapshot, confirm => 1});
	$service->run($delete);
	my $failed = $jobs->get($delete);
	is($domain->{'deletes'}, 1, 'delete is attempted rather than preemptively refused');
	is($failed->{'error'}, $domain->{'delete_error'}, 'the actual native error is preserved');
	is_deeply($failed->{'events'}, [{step => 'snapshot_delete', state => 'failed'}],
		'progress attributes a native deletion failure to the deletion step');
	ok($failed->{'cleanup_pending'}, 'a possibly partial merge retains recovery responsibility');
	ok(Cloudmin::Snapshots::find_snapshot($domain, $snapshot), 'failure never discards snapshot metadata');
	my $inventory = $service->inventory();
	is($inventory->{'recovery_count'}, 1, 'host recovery total includes a failed merge with no native progress marker');
	ok($inventory->{'snapshots'}->[0]->{'pending'}, 'failed merge is marked in snapshot history');
	delete($domain->{'delete_error'});
	my $original_xml = $domain->{'xml'};
	$domain->{'xml'} =~ s{</domain>}{<description>Changed outside Cloudmin</description></domain>};
	is(recover($service, $delete)->{'state'}, 'failed', 'recovery refuses changed configuration without a native partial merge marker');
	is($domain->{'deletes'}, 1, 'stale deletion is not sent to libvirt again');
	$domain->{'xml'} = $original_xml;
	is(recover($service, $delete)->{'state'}, 'complete', 'recovery can retry after the host error is resolved');
	is($service->inventory()->{'recovery_count'}, 0, 'successful recovery clears the host total');
}
{
	my ($service, $jobs, $domain, $adapter) = fixture();
	$adapter->{'version'} = 9000000;
	$domain->{'create_error'} = "unsupported configuration: external snapshots are not supported by this driver\n";
	my $id = submit($service, 'create'); $service->run($id);
	my $failed = $jobs->get($id);
	is($failed->{'state'}, 'failed', 'unsupported creation fails through the worker');
	is($failed->{'error'}, $domain->{'create_error'}, 'driver support errors retain their actual cause');
	is_deeply($failed->{'events'}, [{step => 'snapshot_create', state => 'failed'}],
		'progress identifies the failed creation step');
	ok(!$failed->{'cleanup_pending'}, 'an unchanged creation failure releases the guest');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = 1;
	ok(!eval { submit($service, 'create'); 1 }, 'live default rejects an absent agent');
	like($@, qr/Guest Agent/, 'absence is explained before reserving a job');
	$domain->{'agent'} = 1;
	my $id = submit($service, 'create'); $service->run($id);
	is($domain->{'flags'}, 16|128|64, 'prepared operation requests atomic quiesced disk snapshot');
	ok(!$domain->{'frozen'}, 'guest writes resume');
	is($jobs->get($id)->{'state'}, 'complete', 'prepared snapshot completes');
	is($service->inventory($domain->get_uuid_string())->{'snapshots'}->[0]->{'mode'}, 'prepared', 'inventory reports actual chosen preparation');
	$domain->{'active'} = 0;
	is($service->inventory($domain->get_uuid_string())->{'snapshots'}->[0]->{'state'}, 'disk-snapshot',
		'inventory retains live capture state after the guest stops');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = 1;
	my $id = submit($service, 'create', {mode => 'unprepared'}); $service->run($id);
	is($domain->{'flags'}, 16|128, 'only explicit unprepared choice omits quiescing');
	is($jobs->get($id)->{'state'}, 'complete', 'explicit unprepared snapshot works without an agent');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'agent'} = $domain->{'fail_freeze'} = 1;
	my $id = submit($service, 'create'); $service->run($id);
	is($jobs->get($id)->{'state'}, 'failed', 'freeze failure cannot become a successful snapshot');
	is($domain->{'calls'}, 1, 'failure is never retried without quiescing');
	ok(!$domain->{'frozen'}, 'failure path thaws the guest');
	ok(!$jobs->get($id)->{'cleanup_pending'}, 'unchanged failed creation releases its reservation');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'agent'} = $domain->{'fail_freeze'} = $domain->{'fail_thaw'} = 1;
	my $id = submit($service, 'create'); $service->run($id);
	ok($jobs->get($id)->{'cleanup_pending'}, 'failed thaw retains recovery responsibility');
	my $inventory = $service->inventory();
	is($inventory->{'recovery_count'}, 1, 'a failed thaw counts even before a snapshot exists');
	is_deeply($inventory->{'pending_guests'}, [$domain->get_uuid_string()], 'failed thaw identifies the affected guest without exposing job details');
	ok(!eval { $jobs->assert_guest_available($domain->get_uuid_string()); 1 }, 'uncertain freeze blocks competing mutations');
	ok(eval { $jobs->assert_guest_available($domain->get_uuid_string(), 'shutdown'); 1 }, 'a failed thaw still allows an explicit guest stop');
	$domain->{'fail_thaw'} = $domain->{'fail_freeze'} = 0;
	is(recover($service, $id)->{'state'}, 'complete', 'explicit recovery thaws and completes safely');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'agent'} = $domain->{'fail_freeze'} = $domain->{'fail_thaw'} = 1;
	my $id = submit($service, 'create'); $service->run($id);
	# Stopping a frozen guest ends the freeze without retrying a live request.
	$domain->{'active'} = 0;
	my $recovered = recover($service, $id);
	is($recovered->{'state'}, 'failed', 'stopping the guest does not silently retry as a stopped snapshot');
	ok(!$recovered->{'cleanup_pending'}, 'stopping the unchanged guest allows recovery to release its reservation');
	ok(eval { $jobs->assert_guest_available($domain->get_uuid_string()); 1 }, 'guest changes resume after stopped recovery');
	is($domain->{'calls'}, 1, 'stopped recovery does not repeat snapshot creation');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'lose_create'} = 1;
	my $id = submit($service, 'create'); $service->run($id);
	ok($jobs->get($id)->{'cleanup_pending'}, 'lost creation response remains recoverable');
	is(recover($service, $id)->{'state'}, 'complete', 'native metadata reconciles committed creation');
	is($domain->{'calls'}, 1, 'recovery does not duplicate the snapshot');
	my $snapshot = $jobs->get($id)->{'request'}->{'snapshot'};
	$domain->{'lose_restore'} = 1;
	my $restore = submit($service, 'restore', {snapshot => $snapshot, confirm => 1}); $service->run($restore);
	is(recover($service, $restore)->{'state'}, 'complete', 'native revert marker reconciles lost restore response');
	is($domain->{'restores'}, 1, 'restore is not repeated after a committed result');
	$domain->{'lose_delete'} = 1;
	my $delete = submit($service, 'delete', {snapshot => $snapshot, confirm => 1}); $service->run($delete);
	is(recover($service, $delete)->{'state'}, 'complete', 'missing native metadata reconciles completed deletion');
}
{
	my ($service, $jobs, $domain) = fixture();
	my $id = submit($service, 'create');
	$domain->{'xml'} =~ s{</domain>}{<description>Changed elsewhere</description></domain>};
	$service->run($id);
	is($jobs->get($id)->{'state'}, 'failed', 'queued stale configuration is rejected');
	ok(!$domain->{'calls'}, 'stale request performs no snapshot operation');
	my $cancel = submit($service, 'create');
	$jobs->update($cancel, sub { $_[0]->{'cancel'} = 1 }); $service->run($cancel);
	is($jobs->get($cancel)->{'state'}, 'cancelled', 'queued job can be cancelled before its first write');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = 1;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	is($jobs->get($id)->{'state'}, 'complete', 'shutdown snapshot and restart complete without an agent');
	is($domain->{'shutdowns'}, 1, 'one normal shutdown is requested');
	ok(!$domain->{'snapshot_active'}, 'snapshot is taken only after the VM stops');
	is($domain->{'flags'}, 16|128, 'offline creation does not freeze an absent agent');
	ok($domain->is_active(), 'the VM starts again after successful creation');
	is($service->inventory($domain->get_uuid_string())->{'snapshots'}->[0]->{'state'}, 'shutoff',
		'shutdown fallback records stopped capture even after the guest restarts');
	is_deeply([map { $_->{'step'} } @{$jobs->get($id)->{'events'}}],
		[qw(snapshot_shutdown snapshot_create snapshot_restart)], 'progress preserves all three stages');
	my $snapshot = $jobs->get($id)->{'request'}->{'snapshot'};
	ok(!eval { submit($service, 'restore', {snapshot => $snapshot, confirm => 1}); 1 }, 'running restore requires explicit shutdown consent');
	my $restore = submit($service, 'restore', {snapshot => $snapshot, confirm => 1, shutdown => 1});
	$service->run($restore);
	is($jobs->get($restore)->{'state'}, 'complete', 'restore can shut down the VM as one confirmed operation');
	ok(!$domain->is_active(), 'restore leaves the VM off when restart is not selected');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'ignore_shutdown'} = 1;
	$service->{'shutdown_timeout'} = 0;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	my $job = $jobs->get($id);
	like($job->{'error'}, qr/did not shut down/, 'shutdown timeout is explained');
	ok(!$domain->{'calls'} && !$domain->{'starts'}, 'timeout neither takes a snapshot nor starts the VM');
	ok($domain->is_active(), 'timeout never forces the VM off');
	ok(!$job->{'cleanup_pending'}, 'timeout with no disk changes releases the reservation');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = 1; $domain->{'stop_reason'} = 2;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	like($jobs->get($id)->{'error'}, qr/without a clean shutdown/, 'a forced stop cannot masquerade as a clean shutdown');
	ok(!$domain->{'calls'} && !$domain->{'starts'}, 'unclean shutdown aborts before disk changes or restart');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'change_on_stop'} = 1;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	like($jobs->get($id)->{'error'}, qr/changed during shutdown/, 'hardware is revalidated after shutdown');
	ok(!$domain->{'calls'}, 'changed hardware is never snapshotted with stale inputs');
	ok(!$jobs->get($id)->{'cleanup_pending'}, 'pre-snapshot validation failure releases its reservation');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'lose_shutdown'} = 1;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	ok($jobs->get($id)->{'cleanup_pending'}, 'lost shutdown reply keeps the job recoverable');
	is(recover($service, $id)->{'state'}, 'complete', 'recovery confirms shutdown and finishes the request');
	is($domain->{'shutdowns'}, 1, 'recovery does not send a second shutdown');
	is($domain->{'calls'}, 1, 'shutdown recovery takes exactly one snapshot');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'lose_create'} = 1;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	is(recover($service, $id)->{'state'}, 'complete', 'offline create recovery resumes the requested restart');
	is($domain->{'calls'}, 1, 'lost snapshot reply does not duplicate the disk operation');
	is($domain->{'starts'}, 1, 'recovered offline snapshot restarts once');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'fail_start'} = 1;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	like($jobs->get($id)->{'error'}, qr/snapshot change completed/, 'start failure distinguishes a saved snapshot from an unsuccessful boot');
	ok($jobs->get($id)->{'cleanup_pending'}, 'start failure retains recovery responsibility');
	$domain->{'fail_start'} = 0;
	is(recover($service, $id)->{'state'}, 'complete', 'recovery retries only starting the VM');
	is($domain->{'calls'}, 1, 'start recovery cannot duplicate a snapshot');
	my $snapshot = $jobs->get($id)->{'request'}->{'snapshot'};
	$domain->{'lose_start'} = 1;
	my $restore = submit($service, 'restore', {snapshot => $snapshot, confirm => 1, shutdown => 1, restart => 1});
	$service->run($restore);
	my $starts = $domain->{'starts'};
	is(recover($service, $restore)->{'state'}, 'complete', 'restore recovery recognizes a successful boot with a lost reply');
	is($domain->{'restores'}, 1, 'recovery never reapplies restore after the guest has booted');
	is($domain->{'starts'}, $starts, 'recovery does not restart a VM that is already running');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = $domain->{'agent'} = 1;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$service->run($id);
	is($jobs->get($id)->{'state'}, 'complete', 'fallback consent still allows live preparation');
	ok(!$domain->{'shutdowns'} && !$domain->{'starts'}, 'a working agent never causes snapshot downtime');
	is($domain->{'flags'}, 16|128|64, 'available agent is used even if the form was rendered while missing');
}
{
	my ($service, $jobs, $domain) = fixture();
	$domain->{'active'} = 1;
	my $id = submit($service, 'create', {shutdown => 1, restart => 1});
	$domain->{'agent'} = 1;
	$service->run($id);
	ok(!$domain->{'shutdowns'}, 'an agent that starts while queued prevents unnecessary downtime');
	is($jobs->get($id)->{'request'}->{'mode'}, 'prepared', 'the journal records the preparation actually used');
}
{
	my ($service, $jobs, $domain) = fixture();
	my $first = submit($service, 'create'); $service->run($first);
	my $parent = $jobs->get($first)->{'request'}->{'snapshot'};
	my $second = submit($service, 'create'); $service->run($second);
	my $child = $jobs->get($second)->{'request'}->{'snapshot'};
	my $restore = submit($service, 'restore', {snapshot => $parent, confirm => 1});
	$service->run($restore);
	my $inventory = $service->inventory($domain->get_uuid_string());
	my ($row) = grep { $_->{'id'} eq $parent } @{$inventory->{'snapshots'}};
	ok($row->{'delete_blocked'}, 'inventory flags the unsupported current-parent deletion');
	ok(!eval { submit($service, 'delete', {snapshot => $parent, confirm => 1}); 1 }, 'current parent deletion is refused before reserving a job');
	like($@, qr/Delete the child snapshots/, 'the required deletion order is explained');
	my $delete = submit($service, 'delete', {snapshot => $child, confirm => 1});
	$service->run($delete);
	is($jobs->get($delete)->{'state'}, 'complete', 'child deletion remains available');
	$delete = submit($service, 'delete', {snapshot => $parent, confirm => 1});
	$service->run($delete);
	is($jobs->get($delete)->{'state'}, 'complete', 'parent deletion succeeds after removing children');
}

# Successful quiesced snapshots need no additional thaw call.
{
    my ($service, $jobs, $domain) = fixture();
    $domain->{active} = $domain->{agent} = $domain->{fail_thaw} = 1;
    my $id = submit($service, 'create');
    $service->run($id);
    is($jobs->get($id)->{state}, 'complete', 'successful prepared snapshot needs no redundant thaw');
    is($domain->{thaws} || 0, 0, 'success makes no manual thaw request');
}
# Balloon sampling changes live XML but not the snapshot inputs.
{
    my ($service, $jobs, $domain) = fixture();
    $domain->{active} = 1;
    $domain->{live_xml} = '<domain><devices><memballoon model="virtio"/></devices></domain>';
    no warnings 'redefine';
    my $original = \&SnapshotDomain::get_xml_description;
    local *SnapshotDomain::get_xml_description = sub { $_[1] == 1 ? $_[0]->{live_xml} : $original->(@_); };
    my $before = Cloudmin::Snapshots::revision($domain);
    $domain->{live_xml} =~ s{<memballoon model="virtio"/>}{<memballoon model="virtio">\n  <stats period="10"/>\n</memballoon>};
    is(Cloudmin::Snapshots::revision($domain), $before, 'stats and their whitespace do not invalidate forms');
    $domain->{live_xml} =~ s/virtio/none/;
    isnt(Cloudmin::Snapshots::revision($domain), $before, 'real live hardware changes still invalidate forms');
}

done_testing();
