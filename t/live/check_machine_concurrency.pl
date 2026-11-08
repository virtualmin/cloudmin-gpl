#!/usr/bin/perl
# Race real creation jobs with the same MAC while the first disk is pending.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
no warnings 'once';
use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);

BEGIN
{
$webmin_root = abs_path("$FindBin::Bin/../../..");
die "Disposable Linux VM as root only\n" unless $^O eq 'linux' &&
	$< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$webmin_root/server-manager") || die $!;
$0 = "$webmin_root/server-manager/api.pl";
}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
$| = 1;
$main::error_must_die = 1;

# fixture_wait_for(callback, seconds) Bounds coordination without
# touching user guests.

sub fixture_wait_for
{
my ($code, $seconds) = @_;
my $end = time() + $seconds;
while (!$code->()) {
	die "Concurrent fixture timed out\n" if (time() >= $end);
	select(undef, undef, undef, 0.05);
	}
}
{
	package GatedClone;
	our @ISA = ('Cloudmin::Libvirt');

	# clone_disk(self, arguments...) Delays only the
	# fixture's first real copy.

	sub clone_disk
	{
	my ($self, @args) = @_;
	main::write_file_contents("$self->{gate}/copying", '1');
	main::fixture_wait_for(sub { -e "$self->{gate}/release" }, 30);
	return $self->SUPER::clone_disk(@args);
	}
	}

my $work = tempdir('cloudmin-concurrent-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $service = get_vm_service();
my $jobs = $service->{'jobs'};
my $adapter = $service->{'adapter'}->();
my $options = $service->options();
my ($image) = grep { $_->{'name'} =~ /^Ubuntu/ } @{$options->{'images'}};
my ($pool) = grep { $_->{'name'} eq 'default' } @{$options->{'pools'}};
my ($net) = grep { $_->{'name'} eq 'default' } @{$options->{'networks'}};
die "Ubuntu image and default storage/network required\n"
	if (!$image || !$pool || !$net);
system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', "$work/key") == 0 ||
	die $!;
my $key = read_file_contents("$work/key.pub");
my $mac = '52:54:00:'.
	  join(':', substr(Cloudmin::Images::generate_id(), 0, 6) =~ /../g);
my (@records, %children);
my $ok = eval {
	# Prepare both requests before any guest exists, as
	# simultaneous forms can.
	for my $which ( 0, 1 ) {
		my $id = substr(Cloudmin::Images::generate_id(), 0, 32);
		my $r = $service->prepare({ name =>
						    'cloudmin-create-check-race-'.substr($id, 0, 8),
					    image => $image->{'id'},
					    pool => $pool->{'id'},
					    network => $net->{'key'},
					    cpus => 1, memory_mib => 512,
					    disk_gib => 12,
					    username => 'vmfixture',
					    ssh_keys => $key, mac => $mac,
					    start => 0,
					    autostart => 0 });
		$r->{'uuid'} = join('-', substr($id, 0, 8), substr($id, 8, 4),
				    '4'.substr($id, 13, 3),
				    '8'.substr($id, 17, 3), substr($id, 20,
								   12));
		$r->{'console_password'} =
			substr(Cloudmin::Images::generate_id(),
			       0, 8);
		$jobs->submit($id, 'cloudmin-ui-check', 'vm:'.$r->{'name'},
			      $r);
		push(@records, [ $id, $r ]);
		}
	for my $which ( 0, 1 ) {
		my $pid = fork();
		die "Cannot fork fixture\n" if (!defined($pid));
		if (!$pid) {
			# Use new libvirt connections in each process; all
			# operations remain real.
			$service->{'adapter'} = sub {
				my $class = $which
					? 'Cloudmin::Libvirt'
					: 'GatedClone';
				my $connection = $class->new(uri =>
								     'qemu:///system', readonly => 0);
				$connection->{'gate'} = $work;
				return $connection;
				};
			my $ran = eval { $service->run($records[$which]->[0]);
				1 };
			POSIX::_exit($ran ? 0 : 1);
			}
		$children{$pid} = 1;
		fixture_wait_for(sub { -e "$work/copying" }, 30) if (!$which);
		}
	# The second worker queues on disk work; the short host lock stays free.
	fixture_wait_for(sub { $jobs->busy($records[1]->[0]) }, 15);
	ok($jobs->lock('create-host', sub { 1 }),
	   'host controls remain available during cloning');
	select(undef, undef, undef, 0.5);
	my $second = $jobs->get($records[1]->[0]);
	ok(!@{$second->{'events'} || [ ]},
	   'second preflight waits while first disk is pending');
	write_file_contents("$work/release", '1');
	fixture_wait_for(sub {
		for my $pid (keys %children) {
			# Reap only completed children; keep waiting for
			# the remaining worker.
			if (waitpid($pid, WNOHANG) == $pid) {
				is($?, 0, 'creation worker exits cleanly');
				delete($children{$pid});
				}
			}
		return !%children;
		}, 180);
	is($jobs->get($records[0]->[0])->{'state'}, 'complete',
	   'first real guest is created');
	$second = $jobs->get($records[1]->[0]);
	is($second->{'state'}, 'failed', 'conflicting real guest is rejected');
	like($second->{'error'}, qr/MAC address is already used/,
	     'conflict has a useful error');
	ok(!$adapter->get_domain($records[1]->[1]->{'uuid'}),
	   'no second guest remains');
	1;
	};
my $error = $@;
# Reap only fixture children before deleting their explicitly owned resources.
for my $pid (keys %children) { kill('TERM', $pid); waitpid($pid, 0); }
for my $record (@records) {
	my ($id, $r) = @$record;
	$adapter->remove_created_guest($r->{'uuid'}, $id);
	$adapter->remove_created_volume($pool->{'id'}, $_)
		for (Cloudmin::VMs::disk_volume_name($r->{'name'}, 'seed', $id),
		     Cloudmin::VMs::disk_volume_name($r->{'name'}, 'system',
						     $id));
	$service->cleanup_work($id);
	}
die $error if (!$ok);
done_testing();
