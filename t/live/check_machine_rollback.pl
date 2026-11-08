#!/usr/bin/perl
# Exercise real libvirt rollback and worker-crash recovery on a disposable host.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
use File::Temp qw(tempdir);
use POSIX ();

BEGIN
{
$webmin_root = abs_path("$FindBin::Bin/../../..");
die "Run on a disposable Linux VM as root\n" unless $^O eq 'linux' &&
	$< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$webmin_root/server-manager") || die $!;
$0 = "$webmin_root/server-manager/api.pl";
}
require './server-manager-lib.pl';
{
	package FixtureStartFailure;
	our @ISA = ('Cloudmin::Libvirt');

	# start_domain(self, uuid) Fails after the production worker
	# defines a real guest.
	sub start_domain
	{
	die "fixture start failure\n";
	}
	package FixtureWorkerCrash;
	our @ISA = ('Cloudmin::Libvirt');

	# define_guest(self, xml) Simulates abrupt worker loss after
	# both disk allocations.
	sub define_guest
	{
	POSIX::_exit(0);
	}
	package FixtureStartedCrash;
	our @ISA = ('Cloudmin::Libvirt');

	# start_domain(self, uuid) Stops the job process after
	# libvirt starts the guest.
	sub start_domain
	{
	my ($self, $uuid) = @_;
	$self->SUPER::start_domain($uuid);
	POSIX::_exit(0);
	}
	package FixtureStoppedCrash;
	our @ISA = ('Cloudmin::Libvirt');

	# start_domain(self, uuid) Leaves an owned, stopped
	# guest after worker loss.
	sub start_domain
	{
	my ($self, $uuid) = @_;
	$self->SUPER::start_domain($uuid);
	$self->destroy_domain($uuid);
	POSIX::_exit(0);
	}
	}

my $service = get_vm_service();
my $jobs = $service->{'jobs'};
my $adapter = $service->{'adapter'}->();
my $options = $service->options();
my ($image) = grep { $_->{'name'} =~ /^Ubuntu/ } @{$options->{'images'}};
my ($pool) = grep { $_->{'name'} eq 'default' } @{$options->{'pools'}};
my ($network) = grep { $_->{'name'} eq 'default' } @{$options->{'networks'}};
die "Fixture requires Ubuntu image and default storage/network\n"
	if (!$image || !$pool || !$network);
my $work = tempdir('cloudmin-rollback-XXXXXX', TMPDIR => 1, CLEANUP => 1);
system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f',
       "$work/identity") == 0 || die "Fixture key generation failed\n";
my $public = read_file_contents("$work/identity.pub");
foreach my $kind (qw(start crash cancel started stopped audit)) {
	my $id = substr(Cloudmin::Images::generate_id(), 0, 32);
	my $r =
		$service->prepare({ name => 'cloudmin-create-check-'.$kind.'-'.
					    substr($id, 0, 8),
				    image => $image->{'id'},
				    pool => $pool->{'id'},
				    network => $network->{'key'},
				    cpus => 1, memory_mib => 512,
				    disk_gib => 12,
				    username => 'vmfixture',
				    ssh_keys => $public, start => 1,
				    autostart => 0 });
	$r->{'uuid'} = join('-', substr($id, 0, 8), substr($id, 8, 4),
			    '4'.substr($id, 13, 3),
			    '8'.substr($id, 17, 3), substr($id, 20, 12));
	$r->{'host_ssh_key'} = 1;
	$r->{'console_password'} =
		substr(Cloudmin::Images::generate_id(), 0, 8);
	$jobs->submit($id, 'cloudmin-ui-check', 'vm:'.$r->{'name'}, $r);
	my $ok = eval {
		if ($kind eq 'start') {
			# Actual clone, resize, upload and define must all be
			# undone on start failure.
			local $service->{'adapter'} =
				sub { FixtureStartFailure->new(uri =>
								       'qemu:///system', readonly => 0) };
			$service->run($id);
			}
		# Crash cases need a child so abrupt exit leaves the
		# test process running.
		elsif ($kind eq 'crash' || $kind eq 'started' ||
		       $kind eq 'stopped') {
			my $pid = fork();
			die "Cannot fork fixture\n" if (!defined($pid));
			# Only the child runs the deliberately
			# interrupted creation job.
			if (!$pid) {
				my $class = $kind eq 'crash'
					? 'FixtureWorkerCrash'
					: $kind eq 'stopped'
						? 'FixtureStoppedCrash'
						: 'FixtureStartedCrash';
				$service->{'adapter'} =
					sub { $class->new(
						uri => 'qemu:///system',
						readonly => 0) };
				$service->run($id);
				POSIX::_exit(1);
				}
			waitpid($pid, 0);
			die "Crash fixture failed before allocation\n"
				if ($? || $jobs->get($id)->{'phase'}
				    ne ($kind eq 'crash' ? 'define' : 'start'));
			die "Dead worker still holds lock\n"
				if ($jobs->busy($id));
			$service->run($id);
			}
		elsif ($kind eq 'audit') {
			# A broken completion logger must preserve the
			# successfully created guest.
			my $log = $jobs->{'log'};
			local $jobs->{'log'} = sub {
				die "fixture completion audit failure\n"
					if ($_[0] eq 'complete');
				$log->(@_);
				};
			$service->run($id);
			}
		else {
			# A queued cancellation should make
			# no libvirt resources.
			$jobs->update($id, sub { $_[0]->{'cancel'} = 1; });
			$service->run($id);
			}
		my $job = $jobs->get($id);
		my $complete = $kind eq 'started' || $kind eq 'stopped' ||
			       $kind eq 'audit';
		die "Wrong final state\n"
			if ($job->{'state'}
			    ne ($complete
				    ? 'complete'
				    : $kind eq 'cancel'
					    ? 'cancelled'
					    : 'failed'));
		die "Cleanup is incomplete: $job->{error}\n"
			if ($job->{'cleanup_pending'});
		my $guest = $adapter->get_domain($r->{'uuid'});
		die "Completed guest was removed or its power state changed\n"
			if ($complete &&
			    (!$guest ||
			     $guest->{'active'} != ($kind ne 'stopped')));
		# Recovery must report the changed power state without
		# destroying the disk.
		die "Stopped guest recovery warning missing\n"
			if ($kind eq 'stopped' &&
			    ($job->{'cleanup_warning'} ||
			     '') !~ /check its power state/);
		die "Orphaned domain\n" if (!$complete && $guest);
		my $key = get_ssh_keys()->find($r->{'uuid'}, $id);
		die "Wrong host key cleanup state\n"
			if (($key ? 1 : 0) != ($complete ? 1 : 0));
		die "Audit warning was not retained\n"
			if ($kind eq 'audit' &&
			    ($job->{'audit_warning'} ||
			     '') !~ /fixture completion audit failure/);
		foreach my $name (
			map { Cloudmin::VMs::disk_volume_name($r->{'name'}, $_,
							      $id) }
			qw(system seed)) {
			my (undef, $volume) =
				$adapter->volume($pool->{'id'},
						 $name);
			die "Completed guest volume was removed\n"
				if ($complete && !$volume);
			die "Orphaned volume\n" if (!$complete &&
						    $volume);
			}
		my (undef,
		    $source) =
			$adapter->volume(
				@$image{qw(pool volume volume_key)});
		die "Source image was removed\n" if (!$source);
		die "Provisioning directory remains\n"
			if (-d "$jobs->{directory}/$id");
		print "$kind: real libvirt ".
			($complete
				? 'completion preserved'
				: 'rollback passed')."\n";
		1;
		};
	my $error = $@;
	# Even a failed assertion must remove only this fixture's
	# identified resources.
	$adapter->remove_created_guest($r->{'uuid'}, $id);
	foreach my $name (map { Cloudmin::VMs::disk_volume_name($r->{'name'},
								$_,
								$id) }
			  qw(seed system)) {
		$adapter->remove_created_volume($pool->{'id'}, $name);
		}
	$service->cleanup_work($id);
	die "Host key survived VM removal\n"
		if (get_ssh_keys()->find($r->{'uuid'}, $id));
	die $error if (!$ok);
	}
