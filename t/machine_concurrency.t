use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use JSON::PP qw(encode_json decode_json);
use POSIX ();
require "$Bin/../lib/Cloudmin/Libvirt.pm";
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/VMs.pm";
plan skip_all => 'DBI and DBD::SQLite are required'
	if (!eval { Cloudmin::Jobs::dependencies(); 1 });

# Only temp files and fake disk operations are used; policy and SQLite are real.
my $dir = tempdir(CLEANUP => 1);
my %locks;
my $jobs = Cloudmin::Jobs->new(directory => "$dir/jobs",
			       lock_file => sub {
		open(my $fh, '>>', $_[0].'.lock') || die $!;
		flock($fh, LOCK_EX) || die $!;
		$locks{$_[0]} = $fh;
		return 1;
		},
			       unlock_file => sub { close(delete($locks{$_[0]})); },
			       test_lock => sub {
		# Observe the other process's real flock instead of
		# bypassing the queue.
		open(my $fh, '>>', $_[0].'.lock') || die $!;
		my $free = flock($fh, LOCK_EX | LOCK_NB);
		close($fh);
		return !$free;
		}, log => sub { });

# save(path, data) - Publishes a fixture marker or fake inventory record.
sub save
{
open(my $fh, '>', $_[0]) || die $!;
print $fh $_[1];
close($fh) || die $!;
}

# wait_for(path) - Bounds synchronization with the two child processes.
sub wait_for
{
my $end = time() + 10;
while (!-e $_[0]) {
	die "Fixture timed out waiting for $_[0]\n" if (time() >= $end);
	select(undef, undef, undef, 0.02);
	}
}

{
	package ConcurrentVMs;
	our @ISA = ('Cloudmin::VMs');

	# options(self) Supplies host data and the other
	# process's defined guests.
	sub options
	{
	my ($self) = @_;
	main::save("$self->{directory}/checked-$self->{name}", '')
		if ($self->{'observe'});
	my $options = { %{$self->{'fixture_options'}}, domains => [ ] };
	if (-f "$self->{directory}/domain") {
		# Only a defined guest can be seen by the real
		# prepare() conflict checks.
		open(my $fh, '<', "$self->{directory}/domain") || die $!;
		$options->{'domains'} = [ JSON::PP::decode_json(do { local $/;
			<$fh> }) ];
		close($fh);
		}
	return $options;
	}

	# worker_task(self, args...) Avoids host commands in this
	# concurrency fixture.
	sub worker_task
	{
	return '';
	}
	package ConcurrentImages;

	# path(self, id, suffix) - Supplies an unused image lock identity.
	sub path
	{
	return 'fixture-image';
	}

	# with_lock(self, path, nodiff, callback) Leaves host
	# serialization under test.
	sub with_lock
	{
	return $_[3]->();
	}

	# get(self, id) - Supplies an unchanged ready image.
	sub get
	{
	return { state => 'ready' };
	}
	package ConcurrentAdapter;

	# clone_disk(self, pool, name, source, bytes, format, journal)
	# Gates the first copy.
	sub clone_disk
	{
	my ($self, $pool, $name, $source, $bytes, $format, $journal) = @_;
	$journal->();
	if ($self->{'name'} eq 'first') {
		# Keep the first VM absent from inventory while the
		# second worker starts.
		main::save("$self->{directory}/copying", '');
		main::wait_for("$self->{directory}/release");
		}
	return { name => $name, key => $name, path => '/fixture/'.$name };
	}

	# upload_seed(self, pool, name, path, journal) Supplies
	# an owned seed volume.
	sub upload_seed
	{
	$_[4]->();
	return { name => $_[2], path => '/fixture/seed' };
	}

	# define_guest(self, xml) Makes the first VM's address
	# visible to both workers.
	sub define_guest
	{
	my ($self) = @_;
	main::save("$self->{directory}/domain",
		   JSON::PP::encode_json({ name => $self->{'name'},
					   macs => [ '52:54:00:aa:bb:cc' ] }));
	}

	# set_domain_autostart(self, uuid, enabled) - Makes no host changes.
	sub set_domain_autostart
	{
	}

	# remove_created_volume(self, pool, name, key) There are no
	# real fixture volumes.
	sub remove_created_volume
	{
	}
	}

my $options = {
	capabilities => { architecture => 'aarch64', machine => 'virt',
			  emulator => '/qemu',
			  cpus => 4, memory_kib => 4 * 1024**2, free_memory =>
									3 * 1024**3,
			  efi => 1 },
	images =>
		[ { id => 'a' x 32, name => 'Fixture',
		    architecture => 'aarch64',
		    cloud_init => 1,
		    volume_key => 'base', virtual_size => 1024**3,
		    format => 'qcow2' } ],
	pools => [ { id => 'pool', name => 'pool',
		     available => 40 * 1024**3 } ],
	networks => [ { key => 'network:nat', type => 'network',
			source => 'default', dhcp => 1 } ],
};
my @children;
my $ok = eval {
	for my $name (qw(first second)) {
		my $id = ($name eq 'first' ? 'b' : 'c') x 32;
		my $adapter = bless({ directory => $dir, name => $name },
				    'ConcurrentAdapter');
		my $service = ConcurrentVMs->new(jobs => $jobs,
						 images => bless({ },
								 'ConcurrentImages'),
						 adapter => sub { $adapter },
						 directory => $dir,
						 name => $name,
						 fixture_options => $options);
		my $request = $service->prepare({ name => $name,
						  image => 'a' x 32,
						  pool => 'pool',
						  network => 'network:nat',
						  cpus => 1, memory_mib => 512,
						  disk_gib => 2,
						  username => 'cloudmin',
						  auth_type => 'password',
						  mac => '52:54:00:aa:bb:cc' },
						undef,
						'$6$rounds=500000$'.('a' x 16).'$'.
						('b' x 86));
		$request->{'uuid'} = '11111111-2222-4333-8444-'.
				     substr($id, 0, 12);
		$request->{'console_password'} = 'fixture';
		$jobs->submit($id, 'fixture', "vm:$name", $request);
		$service->{'observe'} = 1;
		my $pid = fork();
		die $! if (!defined($pid));
		if (!$pid) {
			# Each child opens its own SQLite
			# connections and resource locks.
			main::save("$dir/started-$name", '');
			my $ran = eval { $service->run($id); 1 };
			POSIX::_exit($ran ? 0 : 1);
			}
		push(@children, $pid);
		wait_for("$dir/copying") if ($name eq 'first');
		}
	wait_for("$dir/started-second");
	select(undef, undef, undef, 0.3);
	ok(!-e "$dir/checked-second",
	   'second preflight waits while the first disk is copied');
	# Long disk copies must leave unrelated power and
	# reservation calls usable.
	open(my $host_lock, '>>', "$dir/jobs/create-host.lock") || die $!;
	ok(flock($host_lock, LOCK_EX | LOCK_NB),
	   'host lock stays available during a disk copy');
	close($host_lock);
	save("$dir/release", '');
	for my $pid (@children) {
		waitpid($pid, 0);
		is($?, 0, 'creation worker exits normally');
		}
	@children = ();
	is($jobs->get('b' x 32)->{'state'}, 'complete',
	   'first creation completes');
	is($jobs->get('c' x 32)->{'state'}, 'failed',
	   'second creation cannot reuse the same MAC');
	like($jobs->get('c' x 32)->{'error'}, qr/MAC address is already used/,
	     'the real policy reports the conflict');
	1;
	};
my $error = $@;
# Unblock and reap children even if fixture setup or an assertion helper fails.
save("$dir/release", '');
waitpid($_, 0) for @children;
die $error if (!$ok);
done_testing();
