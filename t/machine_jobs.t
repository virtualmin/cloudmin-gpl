use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);
require "$Bin/../lib/Cloudmin/Images.pm";
require "$Bin/../lib/Cloudmin/Libvirt.pm";
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/VMs.pm";
require "$Bin/../lib/Cloudmin/SSHKeys.pm";
plan skip_all => 'DBI and DBD::SQLite are required'
	if (!eval { Cloudmin::Jobs::dependencies(); 1 });

{
	package FixtureVMs;
	our @ISA = ('Cloudmin::VMs');

	# prepare(self, request) Isolates journal tests from host policy tests.
	sub prepare
	{
	return $_[1];
	}
	package FixtureImages;

	# path(self, id, suffix) Returns an unused lock
	# identity for this fixture.
	sub path
	{
	return 'source-image';
	}

	# with_lock(self, path, nodiff, callback) Executes a
	# fake source lock scope.
	sub with_lock
	{
	return $_[3]->();
	}

	# get(self, id) - Supplies a ready, immutable source.
	sub get
	{
	return { state => 'ready' };
	}
	package FixtureAdapter;

	# clone_disk(self, pool, name, source, bytes, format, journal) Fails
	# after allocation when requested.
	sub clone_disk
	{
	my ($self, $pool, $name, $source, $bytes, $format, $journal) = @_;
	die "Destination volume already exists\n"
		if ($self->{'volumes'}->{$name});
	$journal->();
	my $volume = $self->{'volumes'}->{$name} = { name => $name,
						     key => $name,
						     path => '/fixture/'.$name };
	die "disk interrupted\n" if (($self->{'fail'} || '') eq 'disk');
	return $volume;
	}

	# upload_seed(self, pool, name, file, journal) Models a
	# partly uploaded seed.
	sub upload_seed
	{
	my ($self, $pool, $name, $file, $journal) = @_;
	$journal->();
	my $volume = $self->{'volumes'}->{$name} = { name => $name,
						     key => $name,
						     path => '/fixture/'.$name };
	die "seed interrupted\n" if (($self->{'fail'} || '') eq 'seed');
	return $volume;
	}

	# define_guest(self, xml) Preserves the ownership
	# marker used for recovery.
	sub define_guest
	{
	my ($self, $xml) = @_;
	my ($id) = $xml =~ m{<cloudmin:job>(.*?)</cloudmin:job>};
	$self->{'domain'} = { cloudmin => { job => $id }, active => 0 };
	die "definition interrupted\n"
		if (($self->{'fail'} || '') eq 'define');
	}

	# set_domain_autostart(self, uuid, enabled) No host setting
	# changes in unit tests.
	sub set_domain_autostart
	{
	return 1;
	}

	# start_domain(self, uuid) Can fail after the
	# hypervisor has started the VM.
	sub start_domain
	{
	$_[0]->{'domain'}->{'active'} = 1;
	die "start interrupted\n" if (($_[0]->{'fail'} || '') eq 'start');
	}

	# get_domain(self, uuid) - Supplies the reconciled hypervisor state.
	sub get_domain
	{
	return $_[0]->{'domain'};
	}

	# remove_created_guest(self, uuid, job) Prevents disk
	# cleanup if undefine fails.
	sub remove_created_guest
	{
	die "daemon unavailable\n" if ($_[0]->{'cleanup_failure'});
	delete($_[0]->{'domain'});
	}

	# remove_created_volume(self, pool, name, key) Removes only the
	# named fixture volume.
	sub remove_created_volume
	{
	delete($_[0]->{'volumes'}->{$_[2]});
	}
	}

my $root = tempdir(CLEANUP => 1);
my $key = 'ssh-ed25519 '.
	  encode_base64(pack('N', 11).'ssh-ed25519'.pack('N',
							 32).('A' x 32), '');
my $request = { name => 'fixture', image => 'a' x 32,
		source_image => { volume_key => 'source' },
		pool => 'pool', disk_gib => 10, architecture => 'aarch64',
		machine => 'virt', emulator => '/qemu',
		uuid => '11111111-2222-4333-8444-555555555555',
		username => 'fixture',
		ssh_keys => $key,
		mac => '52:54:00:aa:bb:cc', hostname => 'fixture',
		address_mode => 'dhcp',
		attachment => { type => 'network', source => 'default' },
		firmware => 'efi',
		description => '', memory_mib => 1024, cpus => 1, start => 1,
		autostart => 0,
		console_password => 'private', password_hash => 'fixture-hash',
		host_ssh_key => 1 };

# make_fixture(name, [failure]) Returns isolated SQLite, fake libvirt
# and service objects.
sub make_fixture
{
my ($name, $failure) = @_;
my %held;
my $jobs = Cloudmin::Jobs->new(directory => "$root/$name",
			       lock_file => sub { die 'nested lock' if ($held{$_[0]});
		$held{$_[0]} = 1 },
			       unlock_file => sub { delete($held{$_[0]}); },
			       test_lock => sub { $held{$_[0]} ? $$ : 0 },
			       log => sub { });
my $adapter = bless({ fail => $failure, volumes => { } }, 'FixtureAdapter');
my $service = FixtureVMs->new(jobs => $jobs,
			      images => bless({ }, 'FixtureImages'),
			      adapter => sub { $adapter },
			      ssh_keys => Cloudmin::SSHKeys->new("$root/$name-keys"));
$jobs->submit('b' x 32, 'owner', 'vm:fixture', { %$request });
return ( $jobs, $adapter, $service );
}

# Exercise rollback after each persistent resource
# allocation, using real SQLite.
{
	no warnings qw(redefine once);
	local *Cloudmin::VMs::worker_task = sub {
		my ($self, $id, $task, $request, %options) = @_;
		# Model the isolated task's claimed private output
		# without generating keys.
		if ($task eq 'keypair') {
			open(my $fh, '>', $options{'output'}) || die $!;
			print $fh 'fixture-private-key';
			close($fh);
			chmod(0600, $options{'output'});
			return { public_key => $key };
			}
		return { };
		};
	# Accepted jobs retain software choices if policy
	# changes before preflight.
	{
		my ($jobs, $adapter, $service) =
			make_fixture('installer-policy', 'disk');
		$jobs->update('b' x 32, sub {
			# update(job) adds installer choices
			# before policy changes.
			my $r = $_[0]->{'request'};
			@{
				$r}{qw(software hostname memory_mib disk_gib network)} =
				( 'virtualmin-gpl', 'guest.example.test', 2048,
				  20, 'network:nat' );
			});
		$service->{'virtualmin_enabled'} = 0;
		# prepare(self, input) validates against an isolated inventory.
		local *FixtureVMs::prepare = sub {
			my ($self, $input) = @_;
			return Cloudmin::VMs::prepare($self, $input, {
				capabilities => { architecture => 'aarch64',
						  machine => 'virt',
						  emulator => '/qemu',
						  cpus => 4,
						  memory_kib => 4 * 1024**2,
						  free_memory => 3 * 1024**3,
						  efi => 1 },
				images => [ { id => 'a' x 32,
					      architecture => 'aarch64',
					      cloud_init => 1,
					      format => 'qcow2',
					      volume_key => 'source' } ],
				pools => [ { id => 'pool',
					     available => 40 * 1024**3 } ],
				networks => [ { key => 'network:nat',
						type => 'network',
						source => 'default',
						dhcp => 1 } ],
				domains => [ ],
			});
			};
		# setup_agent_error() reports no missing host tools.
		local *Cloudmin::Libvirt::setup_agent_error = sub { undef };
		# check(network) skips host firewall probing for
		# this worker fixture.
		local *Cloudmin::NetworkPreflight::check = sub { };
		# Reaching the disk failure proves policy allowed preflight.
		ok(!$service->run('b' x 32),
		   'accepted installer job reaches the simulated disk failure');
		like($jobs->get('b' x 32)->{'error'}, qr/disk interrupted/,
		     'changed installer policy does not reject an accepted job');
		is($service->{'virtualmin_enabled'}, 0,
		   'new submissions still use the disabled policy');
		}
	for my $phase (qw(disk seed define start)) {
		my ($jobs, $adapter, $service) = make_fixture($phase, $phase);
		ok(!$service->run('b' x 32), "$phase failure is reported");
		is($jobs->get('b' x 32)->{'state'}, 'failed',
		   "$phase failure persists");
		ok(
			!exists(
				$jobs->get(
					'b' x 32)->{'request'}->{'password_hash'}),
			"$phase failure removes the hash from history");
		is_deeply($adapter->{'volumes'}, { },
			  "$phase failure removes every created volume");
		ok(!$adapter->{'domain'}, "$phase failure removes the domain");
		ok(!$service->{'ssh_keys'}->find($request->{'uuid'}, 'b' x 32),
		   "$phase failure removes the host SSH key");
		ok(!-d "$root/$phase/".('b' x 32),
		   "$phase failure removes provisioning inputs");
		}
	my ($jobs, $adapter, $service) = make_fixture('cancel');
	$jobs->update('b' x 32, sub { $_[0]->{'cancel'} = 1; });
	$service->run('b' x 32);
	is($jobs->get('b' x 32)->{'state'}, 'cancelled',
	   'queued cancellation allocates nothing');
	is_deeply($adapter->{'volumes'}, { },
		  'cancelled request has no volumes');
	# Disabling the module policy leaves the original user
	# authentication alone.
	($jobs, $adapter, $service) = make_fixture('keys-disabled');
	$jobs->update('b' x 32,
		      sub { $_[0]->{'request'}->{'host_ssh_key'} = 0; });
	ok($service->run('b' x 32), 'creation works with host keys disabled');
	ok(!$service->{'ssh_keys'}->find($request->{'uuid'}, 'b' x 32),
	   'disabled policy creates no host key');
	ok(!$jobs->get('b' x 32)->{'resources'}->{'ssh_key'},
	   'disabled policy journals no key');
	# A busy host must become a visible failed job, not
	# silently stay queued.
	($jobs, $adapter, $service) = make_fixture('host-lock-timeout');
	{
		my $lock = $jobs->{'lock_file'};
		local $jobs->{'lock_file'} = sub {
			die "fixture host lock timed out\n"
				if ($_[0] =~ m{/create-host\z});
			return $lock->(@_);
			};
		ok(!$service->run('b' x 32),
		   'host lock timeout fails the creation');
		}
	is($jobs->get('b' x 32)->{'state'}, 'failed',
	   'host lock timeout is recorded');
	like($jobs->get('b' x 32)->{'error'}, qr/host lock timed out/,
	     'host lock error remains visible');
	is_deeply($adapter->{'volumes'}, { },
		  'lock failure allocates no disks');
	ok(!$jobs->busy('b' x 32), 'lock failure releases worker ownership');
	($jobs, $adapter, $service) = make_fixture('complete');
	ok($service->run('b' x 32), 'normal creation completes');
	is($jobs->get('b' x 32)->{'state'}, 'complete', 'success is durable');
	ok($service->{'ssh_keys'}->find($request->{'uuid'}, 'b' x 32),
	   'successful VM retains its host key');
	ok(!exists($jobs->get('b' x 32)->{'request'}->{'password_hash'}),
	   'completed history omits the password hash');
	is(scalar(keys %{$adapter->{'volumes'}}), 2,
	   'successful guest retains only its disk and seed');
	ok($service->run('b' x 32), 'completed worker invocation is harmless');
	$jobs->update('b' x 32, sub { $_[0]->{'state'} = 'running'; });
	ok($service->run('b' x 32),
	   'interrupted final commit reconciles an already running owned VM');
	is($jobs->get('b' x 32)->{'state'}, 'complete',
	   'reconciliation commits without recreating');
	# A guest that was started and later powered off is still
	# a finished creation.
	($jobs, $adapter, $service) = make_fixture('stopped-owned');
	ok($service->run('b' x 32),
	   'creation completes before the power state changes');
	$jobs->update('b' x 32, sub { $_[0]->{'state'} = 'running'; });
	$adapter->{'domain'}->{'active'} = 0;
	ok($service->run('b' x 32),
	   'an owned guest that reached the start step is not rolled back');
	is($jobs->get('b' x 32)->{'state'}, 'complete',
	   'a power change after start keeps the completed job');
	ok($adapter->{'domain'}, 'the stopped guest is retained');
	is(scalar(keys %{$adapter->{'volumes'}}), 2,
	   'the stopped guest keeps its disks');
	like($jobs->get('b' x 32)->{'cleanup_warning'}, qr/power state/,
	     'the unexpected power state is reported');
	($jobs, $adapter, $service) = make_fixture('cleanup', 'start');
	$adapter->{'cleanup_failure'} = 1;
	$service->run('b' x 32);
	ok($jobs->get('b' x 32)->{'cleanup_pending'},
	   'cleanup failure remains visible');
	is(scalar(keys %{$adapter->{'volumes'}}), 2,
	   'failed undefine never removes attached disks');
	$adapter->{'cleanup_failure'} = 0;
	$jobs->update('b' x 32, sub { $_[0]->{'state'} = 'recovering'; });
	$service->run('b' x 32);
	ok(!$jobs->get('b' x 32)->{'cleanup_pending'},
	   'explicit cleanup retry finishes');
	is_deeply($adapter->{'volumes'}, { },
		  'retry removes retained fixture volumes');
	is($jobs->get('b' x 32)->{'error'}, 'start interrupted',
	   'retried cleanup keeps the original failure reason');
	{
		# Worker cleanup failure must not prevent
		# independent libvirt rollback.
		local *Cloudmin::VMs::cleanup_work =
			sub { die "sandbox cleanup unavailable\n"; };
		my ($failed_jobs, $failed_adapter,
		    $failed_service) = make_fixture('sandbox-cleanup',
						    'start');
		$failed_service->run('b' x 32);
		ok($failed_jobs->get('b' x 32)->{'cleanup_pending'},
		   'failed sandbox cleanup remains recoverable');
		is_deeply($failed_adapter->{'volumes'}, { },
			  'sandbox cleanup failure still removes VM volumes');
		ok(!$failed_adapter->{'domain'},
		   'sandbox cleanup failure still removes the VM');
		}
	($jobs, $adapter, $service) = make_fixture('final-cancel');
	$service->run('b' x 32);
	$jobs->update(
		'b' x 32,
		sub { $_[0]->{'state'} = 'running'; $_[0]->{'cancel'} = 1; });
	ok(!$service->finish('b' x 32, $adapter),
	   'cancellation wins before the final transaction commits');
	is($jobs->get('b' x 32)->{'state'}, 'cancelled',
	   'final cancellation persists and rolls back');
	is_deeply($adapter->{'volumes'}, { },
		  'final cancellation removes disks');
	ok(!$service->{'ssh_keys'}->find($request->{'uuid'}, 'b' x 32),
	   'final cancellation removes the host key');
	# Failure audits retain the reason after removing credentials from it.
	($jobs, $adapter, $service) = make_fixture('audit-redaction');
	my @audit;
	$jobs->{'log'} = sub { @audit = @_; };
	$service->fail('b' x 32, $adapter,
		       'Failed with private and fixture-hash');
	is($audit[3]->{'error'}, 'Failed with [redacted] and [redacted]',
	   'failure audit cannot expose the console password or guest password hash');
	is($audit[3]->{'uuid'}, $request->{'uuid'},
	   'audit retains the guest UUID from the request');
	unlike(join(' ', values %{$audit[3]}),
	       qr/private|fixture-hash|fixture-private-key/,
	       'provisioning credentials stay out of all audit fields');
	# Logging happens after commit and must never roll
	# back a completed guest.
	($jobs, $adapter, $service) = make_fixture('audit-failure');
	$jobs->{'log'} =
		sub { die "fixture audit unavailable\n" if (
			$_[0] eq 'complete'); };
	ok($service->run('b' x 32),
	   'audit failure does not fail successful provisioning');
	is($jobs->get('b' x 32)->{'state'}, 'complete',
	   'audit failure preserves the committed result');
	ok($adapter->{'domain'} && $adapter->{'domain'}->{'active'},
	   'audit failure keeps the guest running');
	is(scalar(keys %{$adapter->{'volumes'}}), 2,
	   'audit failure preserves both guest disks');
	like($jobs->get('b' x 32)->{'audit_warning'},
	     qr/fixture audit unavailable/,
	     'audit failure is visible in job status');
	}
# Installer creation journals only its own empty disk and
# preserves shared media.
{
	no warnings qw(redefine once);
	# worker_task(self, id, task, request, [options...])
	# rejects cloud provisioning.
	local *Cloudmin::VMs::worker_task =
		sub { die 'Installer invoked a provisioning worker'; };
	# get(self, id), volume(self, pool, name, key), get_path(self) Return
	# the shared ISO's job, volume and file path.
	local *FixtureImages::get =
		sub { return { state => 'ready', volume_key => 'source' }; };
	local *FixtureAdapter::volume =
		sub { return ( undef, bless({ }, 'FixtureIso') ); };
	local *FixtureIso::get_path = sub { return '/fixture/shared.iso'; };
	# clone_disk(self, pool, name, source, bytes, format, journal) Fails if
	# the installer tries to clone its ISO as a system disk.
	local *FixtureAdapter::clone_disk =
		sub { die 'Installer cloned its ISO'; };
	# create_disk(self, pool, name, bytes, journal) Models volume allocation
	# and an interrupted response.
	local *FixtureAdapter::create_disk = sub {
		my ($self, $pool, $name, $bytes, $journal) = @_;
		$journal->();
		my $v = $self->{'volumes'}->{$name} =
			{ name => $name, key => $name, path => '/fixture/'.
							       $name };
		# Fail after allocation so rollback must use the
		# previously journaled name.
		die "disk interrupted\n" if (($self->{'fail'} || '') eq 'disk');
		return $v;
		};
	# Each failure must remove owned storage without
	# allocating a seed or key.
	for my $phase ( '', 'disk', 'define', 'start' ) {
		my ($jobs, $adapter, $service) =
			make_fixture('installer-'.($phase || 'success'),
				     $phase);
		# installer_request(job) sets ISO media and
		# clears cloud credentials.
		$jobs->update('b' x 32, sub {
			my $r = $_[0]->{'request'};
			$r->{'install_source'} = 'iso';
			$r->{'source_image'}->{'volume_path'} =
				'/fixture/shared.iso';
			$r->{'ssh_keys'} = '';
			delete($r->{'password_hash'});
			});
		# Successful creation retains one disk; interrupted
		# creation retains none.
		my $success = $service->run('b' x 32);
		is($success ? 1 : 0, $phase ? 0 : 1,
		   'installer outcome at '.($phase || 'completion'));
		my $job = $jobs->get('b' x 32);
		ok(!exists($job->{'resources'}->{'seed'}),
		   'installer never allocates a cloud-init disk');
		ok(!exists($job->{'resources'}->{'ssh_key'}),
		   'installer never allocates a host access key');
		is(scalar(keys %{$adapter->{'volumes'}}), $phase ? 0 : 1,
		   'rollback removes only the allocated system disk');
		}
	}

done_testing();
