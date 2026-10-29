#!/usr/bin/perl
# check-snapshots.pl
# Exercises native snapshot data and configuration on an isolated two-disk VM.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Test::More;
use Digest::SHA qw(sha256_hex);
my $root;
BEGIN {
	die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
	$root = abs_path("$Bin/../../..");
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	# CLI runs need the theme path normally supplied by miniserv for CGI output.
	$ENV{'THEME_ROOT'} = "$root/authentic-theme" if (-d "$root/authentic-theme");
	chdir("$root/server-manager") or die $!;
	unshift(@INC, $root);
	$0 = "$root/server-manager/check-snapshots.pl";
}
require './server-manager-lib.pl';
require './lib/Cloudmin/Snapshots.pm';
$| = 1;
my $adapter = get_libvirt(1);
my $conn = $adapter->connect();
my $expect_delete_error = @ARGV && $ARGV[0] eq '--expect-delete-error';
my $dir = tempdir('/var/lib/libvirt/images/cloudmin-snapshot-check-XXXXXX', CLEANUP => 1);
chmod(0755, $dir) or die $!;
make_path("$dir/disks", {mode => 0755});
my $name = 'cloudmin-snapshot-check-'.substr(sha256_hex($dir), 0, 10);
my $jobs = get_vm_jobs();
$jobs->{'directory'} = "$dir/jobs";
my $service = Cloudmin::Snapshots->new(jobs => $jobs, images => get_image_jobs(), adapter => sub { get_libvirt(1) });
my $manager = Cloudmin::VMManage->new(jobs => $jobs, images => get_image_jobs(), adapter => sub { get_libvirt(1) });
my ($pool, $domain, $uuid, $shared);
my $serial = 0;

# edit(fields)
# Changes real hardware through the same manager used by the editor and API.
sub edit
{
my ($fields) = @_;
my $id = substr(sha256_hex($dir.++$serial), 0, 32);
my $r = $manager->prepare('update', {id => $uuid,
	revision => sha256_hex($domain->get_xml_description(3)), %$fields}, $id);
$jobs->submit($id, 'root', 'guest:'.$uuid, $r);
$manager->run($id);
# Stop the fixture scenario on failure instead of testing a partially edited VM.
my $job = $jobs->get($id);
is($job->{'state'}, 'complete', 'hardware edit with snapshots completed') or diag($job->{'error'} || 'unknown error');
die "Hardware edit failed\n" if ($job->{'state'} ne 'complete');
}

# operation(action, fields, [failure])
# Uses the real preparation, reservation, worker and reconciliation code.
# failure is true for a native permission error, or 'lost_reply' for recovery.
sub operation
{
my ($action, $fields, $failure) = @_;
my $id = substr(sha256_hex($dir.++$serial), 0, 32);
my $r = $service->prepare('snapshot_'.$action, { id => $uuid,
	revision => Cloudmin::Snapshots::revision($domain), confirm => 1, %$fields }, $id);
$jobs->submit($id, 'root', 'guest:'.$uuid, $r);
if (($failure || '') eq 'lost_reply') {
	# Drop the successful native reply, then prove recovery does not replay it.
	my $method = $action eq 'create' ? 'Sys::Virt::Domain::create_snapshot' :
		'Sys::Virt::DomainSnapshot::'.($action eq 'restore' ? 'revert_to' : 'delete');
	no strict 'refs';
	no warnings 'redefine';
	my $native = \&{$method};
	my $calls = 0;
	local *{$method} = sub { $calls++; $native->(@_); die "Fixture lost native reply\n"; };
	$service->run($id);
	is($jobs->get($id)->{'state'}, 'failed', "$action records the lost reply");
	ok($jobs->get($id)->{'cleanup_pending'}, "$action retains its reservation until recovery");
	$jobs->update($id, sub { $_[0]->{'state'} = 'recovering'; });
	$service->run($id);
	is($calls, 1, "$action recovery uses native metadata instead of replaying the operation");
	}
# Run normally when no lost-reply fault is being injected.
else {
	$service->run($id);
	}
my $job = $jobs->get($id);
if ($failure && $failure ne 'lost_reply') {
	# A failing host must reach the worker and preserve libvirt's real error.
	is($job->{'state'}, 'failed', "$action failed through the worker");
	like($job->{'error'}, qr/Permission denied/, 'the native permission error is retained');
	is_deeply($job->{'events'}, [{step => 'snapshot_'.$action, state => 'failed'}],
		'the actual operation owns the failed progress step');
	return $job;
	}
is($job->{'state'}, 'complete', "$action completed") or diag($job->{'error'} || 'unknown error');
die "Snapshot job failed\n" if ($job->{'state'} ne 'complete');
return $r->{'snapshot'};
}

# disk_paths()
# Reads libvirt's current disk paths, including overlays created during restore.
sub disk_paths
{
my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(2));
return map { $_->getAttribute('file') } $doc->findnodes('/domain/devices/disk/source');
}

# pattern(mode, byte)
# Writes or verifies actual guest-visible sectors while the fixture is stopped.
sub pattern
{
my ($mode, $byte) = @_;
die "Fixture must be stopped before qemu-io\n" if ($domain->is_active());
foreach my $path (disk_paths()) {
	my @args = ('qemu-io', '-f', 'qcow2', $mode eq 'read' ? ('-r') : (),
		'-c', "$mode -P $byte 0 4096", $path);
	is(system(@args), 0, "$mode pattern $byte in a guest disk");
	}
}

my $ok = eval {
	$pool = $conn->define_storage_pool("<pool type='dir'><name>$name</name><target><path>$dir/disks</path></target></pool>");
	$pool->create();
	my @paths;
	foreach my $index (1, 2) {
		my $v = $pool->create_volume("<volume><name>disk$index.qcow2</name><capacity unit='MiB'>32</capacity><target><format type='qcow2'/></target></volume>");
		push(@paths, $v->get_path());
		}
	my $caps = Cloudmin::Libvirt::parse_xml_document($conn->get_capabilities());
	my $arch = $caps->findvalue('/capabilities/host/cpu/arch');
	my $machine = $arch eq 'aarch64' ? 'virt' : 'q35';
	$domain = $conn->define_domain("<domain type='kvm'><name>$name</name><memory unit='MiB'>256</memory><vcpu>1</vcpu>".
		"<cpu mode='host-passthrough'/><os firmware='efi'><type arch='$arch' machine='$machine'>hvm</type></os><features><acpi/></features><devices>".
		join('', map { "<disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='$paths[$_]'/><target dev='vd".('a','b')[$_]."' bus='virtio'/></disk>" } (0,1))."</devices></domain>");
	$uuid = $domain->get_uuid_string();
	$domain->create(); $domain->destroy();
	# A real resize followed by a refused definition must have a safe exit.
	# Only the definition call is fault-injected; storage and recovery are native.
	{
		my $manager = Cloudmin::VMManage->new(jobs => $jobs, images => get_image_jobs(),
			adapter => sub { get_libvirt(1) });
		my $before = $domain->get_xml_description(2 | 1);
		my $id = substr(sha256_hex($dir.++$serial), 0, 32);
		my $request = $manager->prepare('update', {id => $uuid, revision => sha256_hex($before),
			cpus => 2, memory_mib => 256, changes => [{action => 'grow_disk', target => 'vda', disk_gib => 1}]}, $id);
		$jobs->submit($id, 'root', 'guest:'.$uuid, $request);
		{
			no warnings qw(redefine once);
			local *Sys::Virt::define_domain = sub { die "Fixture refused hardware definition\n"; };
			$manager->run($id);
			}
		ok($jobs->get($id)->{'cleanup_pending'}, 'completed growth reserves the failed settings job');
		ok($manager->discard_change($id), 'remaining settings can be discarded after native disk growth');
		ok(!$jobs->get($id)->{'cleanup_pending'}, 'discard releases the reservation');
		is($domain->get_xml_description(2 | 1), $before, 'discard preserves the original hardware definition');
		is($pool->get_volume_by_name('disk1.qcow2')->get_info()->{'capacity'}, 1024**3, 'discard keeps the completed disk growth');
		}
	pattern('write', 17);
	ok(!$service->inventory($uuid)->{'unavailable'}, 'the host version does not block snapshot controls');
	my $first = operation('create', {label => 'Before update <safe>', description => 'First point'},
		$expect_delete_error ? undef : 'lost_reply');
	# Read-only libvirt can list saved history but refuses secure guest XML.
	my $reader = Cloudmin::Snapshots->new(jobs => $jobs, images => get_image_jobs(),
		readonly => 1, adapter => sub { get_libvirt(0) });
	my $read_history = $reader->inventory($uuid);
	is($read_history->{'guest'}->{'uuid'}, $uuid, 'read-only libvirt can load individual guest history');
	is($read_history->{'snapshots'}->[0]->{'id'}, $first, 'read-only history retains the saved snapshot');
	ok(!$read_history->{'revision'}, 'read-only history does not request a protected revision');
	# A second definition adopting an old layer must protect all saved data,
	# even though the first guest now writes to a private overlay.
	my $shared_xml = $domain->get_xml_description(2);
	$shared_xml =~ s{<uuid>.*?</uuid>}{}s;
	$shared_xml =~ s{<name>.*?</name>}{<name>$name-shared</name>}s;
	$shared_xml =~ s{<nvram\b.*?</nvram>}{}s;
	my $shared_doc = Cloudmin::Libvirt::parse_xml_document($shared_xml);
	($shared_doc->findnodes('/domain/devices/disk/source'))[0]->setAttribute('file', $paths[0]);
	$shared = $conn->define_domain($shared_doc->toString());
	foreach my $action (qw(create restore delete)) {
		ok(!eval { $service->prepare('snapshot_'.$action, {id => $uuid,
			revision => Cloudmin::Snapshots::revision($domain), snapshot => $first,
			label => 'Shared base', confirm => 1}, 'f'x32); 1 }, "$action refuses a saved disk adopted by another guest");
		like($@, qr/used by virtual machine/, 'shared saved storage is identified');
		}
	$shared->undefine(); undef($shared);
	if ($expect_delete_error) {
		# Check recovery from an expected native merge permission failure.
		pattern('write', 34);
		my $failed = operation('delete', {snapshot => $first}, 1);
		ok($failed->{'cleanup_pending'}, 'failed native merge remains recoverable');
		is($service->inventory()->{'recovery_count'}, 1, 'host overview counts the failed native operation');
		ok(Cloudmin::Snapshots::find_snapshot($domain, $first), 'failed merge retains snapshot metadata');
		# Retrying the unchanged native failure must reach libvirt again.
		$jobs->update($failed->{'id'}, sub { $_[0]->{'state'} = 'recovering'; });
		$service->run($failed->{'id'});
		$failed = $jobs->get($failed->{'id'});
		like($failed->{'error'}, qr/Permission denied/, 'recovery retries the native merge without a false stale-state refusal');
		ok($failed->{'cleanup_pending'}, 'persistent host failure keeps recovery responsibility');
		pattern('read', 34);
		# Render the real progress CGI against only this fixture's job store.
		my $html = '';
		open(my $output, '>', \$html) or die $!;
		{
			no warnings 'redefine';
			local *main::get_vm_jobs = sub { $jobs };
			local $ENV{'REQUEST_METHOD'} = 'GET';
			local $ENV{'QUERY_STRING'} = 'job='.$failed->{'id'};
			local $ENV{'SCRIPT_NAME'} = '/server-manager/progress.cgi';
			local *STDOUT = $output;
			do './progress.cgi';
			die $@ if ($@);
			}
		close($output);
		like($html, qr/Deleting snapshot/, 'the progress page names the attempted operation');
		like($html, qr/Permission denied/, 'the progress page displays the actual native error');
		like($html, qr/block-commit/, 'the underlying failing command remains visible');
		like($html, qr/jobs.cgi/, 'the progress page links to recovery in Active Jobs');
		unlike($html, qr/Upgrade libvirt|12\.1 or newer/, 'progress never substitutes a guessed version explanation');
		diag('Native deletion error: '.$failed->{'error'});
		}
	else {
		# Edits through Cloudmin must leave the older snapshot restorable.
		edit({cpus => 2, memory_mib => 384, description => 'Edited with snapshots', boot => 'disk:vdb'});
		pattern('write', 34);
		my $second = operation('create', {label => 'After update'});
		pattern('write', 51);
		operation('restore', {snapshot => $first}, 'lost_reply');
		is(Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(2))->findvalue('/domain/vcpu'), 1, 'restore reinstates saved CPU configuration');
		my $restored = $manager->settings($uuid);
		is($restored->{'memory_mib'}, 256, 'restore reinstates saved memory');
		is($restored->{'description'}, '', 'restore reinstates saved description');
		ok(!Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(2))->exists('/domain/devices/disk/boot'),
			'restore reinstates saved boot order');
		pattern('read', 17);
		my $branch = operation('create', {label => 'Another branch'});
		my $inventory = $service->inventory($uuid);
		my ($saved) = grep { $_->{'id'} eq $first } @{$inventory->{'snapshots'}};
		my $saved_xml = Cloudmin::Libvirt::parse_xml_document(Cloudmin::Snapshots::find_snapshot($domain, $first)->get_xml_description(0));
		my $allocated = 0;
		$allocated += (stat($_->getAttribute('file')))[12]*512 foreach $saved_xml->findnodes('/domainsnapshot/domain/devices/disk/source');
		is($saved->{'allocation'}, $allocated, 'inventory size matches saved disk allocation on the host');
		is(scalar(@{$inventory->{'snapshots'}}), 3, 'all branches are listed');
		is((grep { $_->{'id'} eq $branch } @{$inventory->{'snapshots'}})[0]->{'parent'}, $first, 'new branch has the restored parent');
		is((grep { $_->{'id'} eq $first } @{$inventory->{'snapshots'}})[0]->{'label'}, 'Before update <safe>', 'label is retained independently of libvirt name');
		ok(!eval { $manager->prepare('detach_disk', {id => $uuid, target => 'vda',
			revision => sha256_hex($domain->get_xml_description(3))}, 'd'x32); 1 },
			'disk detachment stays blocked while snapshots exist');
		like($@, qr/before changing writable disks/, 'disk guard identifies the protected operation');
		# A later resource edit must survive deletion
		# of the saved restore points.
		edit({cpus => 2, memory_mib => 384, description => 'Keep after deleting snapshots'});
		operation('delete', {snapshot => $second}, 'lost_reply');
		pattern('read', 17);
		$domain->create();
		# A firmware-only guest cannot cooperate with shutdown. Shorten only
		# this fixture's timeout and prove Cloudmin does not force it off.
		{
			local $service->{'shutdown_timeout'} = 2;
			my $id = substr(sha256_hex($dir.++$serial), 0, 32);
			my $r = $service->prepare('snapshot_create', {id => $uuid,
				revision => Cloudmin::Snapshots::revision($domain), label => 'Shutdown timeout',
				shutdown => 1, restart => 1}, $id);
			$jobs->submit($id, 'root', 'guest:'.$uuid, $r);
			$service->run($id);
			my $failed = $jobs->get($id);
			like($failed->{'error'}, qr/did not shut down/, 'uncooperative guest times out cleanly');
			ok(!$failed->{'cleanup_pending'}, 'shutdown timeout releases the reservation');
			ok($domain->is_active(), 'shutdown timeout never forces the guest off');
			ok(!Cloudmin::Snapshots::find_snapshot($domain, $r->{'snapshot'}), 'shutdown timeout leaves no snapshot');
			}
		my $preflight = eval { $service->prepare('snapshot_create', {id => $uuid,
			revision => Cloudmin::Snapshots::revision($domain), label => 'No agent'}, 'f'x32); 1 };
		ok(!$preflight, 'missing guest agent rejects prepared live snapshot');
		like($@, qr/Guest Agent is not responding/, 'missing agent has an actionable message');
		my $live = operation('create', {label => 'Live point', mode => 'unprepared'});
		ok($domain->is_active(), 'live snapshot preserves running state');
		ok(!eval { $service->prepare('snapshot_restore', {id => $uuid, revision => Cloudmin::Snapshots::revision($domain), snapshot => $live, confirm => 1}, 'e'x32); 1 }, 'running restore is refused');
		operation('delete', {snapshot => $live});
		ok($domain->is_active(), 'live deletion preserves running state');
		$domain->destroy();
		operation('delete', {snapshot => $branch});
		operation('delete', {snapshot => $first});
		pattern('read', 17);
		my @remaining = $domain->list_all_snapshots(0);
		is(scalar(@remaining), 0, 'native metadata is gone after full deletion');
		# Snapshot deletion merges disks without
		# restoring old resource settings.
		my $kept = $manager->settings($uuid);
		is($kept->{'cpus'}, 2, 'snapshot deletion preserves later CPU edits');
		is($kept->{'memory_mib'}, 384, 'snapshot deletion preserves later memory edits');
		is($kept->{'description'}, 'Keep after deleting snapshots', 'snapshot deletion preserves later description');
		}
	1;
	};
my $error = $@;
# Cleanup is limited to this unique fixture, including any failed native jobs.
eval { $shared->undefine(); } if ($shared);
# Stop the fixture before removing its snapshot metadata and definition.
if ($domain) {
	eval { $domain->destroy() if ($domain->is_active()); };
	eval { $_->delete(2) foreach $domain->list_all_snapshots(0); $domain->undefine(4); };
	}
# Remove only the pool allocated for this fixture.
if ($pool) {
	eval { $pool->destroy() if ($pool->is_active()); $pool->undefine(); };
	}
die $error if (!$ok);
done_testing();
