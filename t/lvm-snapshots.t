use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use Storable qw(dclone);
require "$Bin/../lib/Cloudmin/Snapshots.pm";

{
	package NativeJobs;

	# get(self, id) returns an independent journal view,
	# like the real store.
	sub get
	{
	Storable::dclone($_[0]->{job})
	}

	# update(self, id, callback) commits one journal mutation.
	sub update
	{
	$_[2]->($_[0]->{job}); $_[0]->get($_[1])
	}
	package NativeDomain;

	# is_active(self) distinguishes running and paused
	# guests from stopped ones.
	sub is_active
	{
	$_[0]->{state} != 5
	}

	# get_state(self) exposes the simulated libvirt state.
	sub get_state
	{
	$_[0]->{state}
	}

	# get_xml_description(self, flags) supplies a raw
	# block disk and its cache.
	sub get_xml_description
	{
	return '<domain><uuid>fixture</uuid><devices><disk type="block">'.
	       '<driver type="raw" cache="'.$_[0]->{cache}.
	       '"/><source dev="/dev/fixture"/>'.
	       '<target dev="vda"/></disk></devices></domain>';
	}

	# fs_freeze(self, mountpoints, flags) records ordering
	# before CPU suspension.
	sub fs_freeze
	{
	push(@{$_[0]->{events}}, 'freeze'); $_[0]->{frozen} = 1
	}

	# suspend(self) models the pause used to coordinate
	# native disk snapshots.
	sub suspend
	{
	push(@{$_[0]->{events}}, 'pause'); $_[0]->{state} = 3
	}

	# resume(self) models a failed or successful release of the owned pause.
	sub resume
	{
	die "Resume failed\n" if ($_[0]->{fail_resume});
	push(@{$_[0]->{events}}, 'resume'); $_[0]->{state} = 1;
	}

	# fs_thaw(self, mountpoints, flags) refuses an
	# unresponsive paused agent.
	sub fs_thaw
	{
	die "Agent cannot thaw while paused\n" if ($_[0]->{state} == 3);
	push(@{$_[0]->{events}}, 'thaw'); $_[0]->{frozen} = 0;
	}

	# list_all_snapshots(self, [flags]) returns only fixture metadata.
	sub list_all_snapshots
	{
	values %{$_[0]->{snapshots}}
	}

	# create_snapshot(self, xml, flags) publishes metadata
	# after disk allocation.
	sub create_snapshot
	{
	my ($self, $xml, $flags) = @_;
	Test::More::is(
		$flags, 3,
		'native snapshots redefine metadata without asking libvirt to copy disks');
	my $name =
		Cloudmin::Libvirt::parse_xml_document($xml)->findvalue(
			'/domainsnapshot/name');
	my $point = bless({ domain => $self, name => $name }, 'NativePoint');
	return $self->{snapshots}->{$name} = $point;
	}
	package NativePoint;

	# get_name(self) returns the fixture snapshot identifier.
	sub get_name
	{
	$_[0]->{name}
	}

	# is_current(self) models the newly published current restore point.
	sub is_current
	{
	1
	}

	# delete(self, flags) removes only fixture metadata.
	sub delete
	{
	delete($_[0]->{domain}->{snapshots}->{$_[0]->{name}})
	}
	package NativeAdapter;

	# volume(self, pool, name, [key]) enforces identity
	# in the fake inventory.
	sub volume
	{
	my ($self, $pool, $name, $key) = @_;
	my $volume = $self->{volumes}->{$name};
	die "Replaced volume\n"
		if ($volume && defined($key) && $volume->get_key() ne $key);
	return ( $self, $volume );
	}

	# connect(self) is sufficient for the independently tested usage guard.
	sub connect
	{
	$_[0]
	}
	package NativeVolume;

	# get_key(self) supplies a stable UUID-like identity
	# for cleanup ownership.
	sub get_key
	{
	$_[0]->{name}
	}

	# snapshot(self, name, journal) injects faults before or
	# after UUID persistence.
	sub snapshot
	{
	my ($self, $name, $journal) = @_;
	push(@{$self->{domain}->{events}}, 'snapshot');
	my $copy = bless({ %$self, name => $name }, ref($self));
	$self->{adapter}->{volumes}->{$name} = $copy;
	die "Allocation reply lost\n" if (($self->{fault} || '') eq 'lost');
	$journal->($copy);
	die "Activation failed\n" if (($self->{fault} || '') eq 'after');
	return $copy;
	}

	# delete(self) removes exactly the recorded fixture volume.
	sub delete
	{
	delete($_[0]->{adapter}->{volumes}->{$_[0]->{name}})
	}
	}

# fixture([fault], [cache]) creates a fresh journal, guest and native volume.
sub fixture
{
my ($fault, $cache) = @_;
my $id = 'a' x 32;
my $jobs =
	bless({ job => { request => { operation => 'snapshot_create',
				      native_lvm => 1,
				      snapshot => 'cloudmin-'.$id,
				      mode => 'prepared',
				      description => '',
				      disks => [ { target => 'vda',
						   volume => { pool => 'pool',
							       name => 'origin',
							       key => 'origin',
							       identity => 'origin' } } ] },
			 resources => { } } }, 'NativeJobs');
my $domain =
	bless({ state => 1, cache => $cache || 'none', snapshots => { },
		events =>
			[ ] }, 'NativeDomain');
my $adapter = bless({ volumes => { } }, 'NativeAdapter');
$adapter->{volumes}->{origin} = bless({ name => 'origin', domain => $domain,
					adapter => $adapter, fault => $fault },
				      'NativeVolume');
my $service = Cloudmin::Snapshots->new(jobs => $jobs);
return ( $id, $jobs, $domain, $adapter, $service );
}

{
	no warnings qw(redefine once);
	local *Cloudmin::VMManage::file_identity = sub { 'origin' };
	local *Cloudmin::Images::assert_unused = sub { 1 };
	for my $fault ( '', 'after', 'lost' ) {
		my ($id, $jobs, $domain, $adapter,
		    $service) = fixture($fault);
		my $ok =
			eval { $service->apply_native($id, $adapter,
						      $domain); 1 };
		is(!!$ok, !$fault, "capture result for $fault");
		is_deeply($domain->{events},
			  [ qw(freeze pause snapshot resume thaw) ],
			  'freeze, pause and recovery have safe ordering');
		is($domain->{state}, 1,
		   'source is running after success or allocation failure');
		ok(!$domain->{frozen}, 'source is thawed');
		if ($fault eq 'lost') {
			# An unjournalled UUID cannot safely
			# authorize automatic deletion.
			like($@, qr/no saved identity/,
			     'uncertain ownership requires inspection');
			is(scalar(keys %{$adapter->{volumes}}), 2,
			   'unconfirmed allocation is retained');
			ok($jobs->{job}->{resources}->{native_volumes},
			   'recovery intent remains durable');
			}
		elsif ($fault) {
			# A known partial allocation can be removed
			# without losing the origin.
			is(scalar(keys %{$adapter->{volumes}}), 1,
			   'known partial allocation is removed');
			ok(!$jobs->{job}->{resources}->{native_complete},
			   'failed capture cannot become a restore point');
			}
		else {
			# A completed capture remains usable until
			# explicitly released.
			ok($jobs->{job}->{resources}->{native_complete},
			   'complete capture is journalled');
			$service->remove_native($id, $adapter, $domain);
			is(scalar(keys %{$adapter->{volumes}}), 1,
			   'temporary native copies can be released');
			}
		}
	# Reject unsafe caches before freeze, pause or allocation has occurred.
	my ($id, $jobs, $domain, $adapter, $service) = fixture('',
							       'writeback');
	ok(!eval { $service->apply_native($id, $adapter, $domain); 1 },
	   'unsafe live writeback cache is rejected');
	is_deeply($domain->{events}, [ ],
		  'cache rejection precedes guest changes');
	# A resume failure retains pause ownership for a later recovery attempt.
	($id, $jobs, $domain, $adapter, $service) = fixture();
	$domain->{fail_resume} = 1;
	ok(!eval { $service->apply_native($id, $adapter, $domain); 1 },
	   'resume failure is reported');
	ok($jobs->{job}->{resources}->{native_pause},
	   'failed resume retains pause ownership');
	$domain->{fail_resume} = 0;
	$service->resume_native($id, $domain);
	is($domain->{state}, 1, 'retry releases the owned pause');
	ok(!$domain->{frozen}, 'retry thaws only after resume');
	ok(!$jobs->{job}->{resources}->{native_pause},
	   'successful recovery clears pause ownership');

	# Failed edit cleanup retains its lease until the converter is stopped.
	$jobs->{job}->{worker} = 'owned-converter';
	my $manager = Cloudmin::VMManage->new(jobs => $jobs);
	local *Cloudmin::Worker::cleanup = sub { die "Stop failed\n" };
	ok(!eval { $manager->cleanup_disk_worker($id); 1 },
	   'converter cleanup failure blocks disk cleanup');
	is($jobs->{job}->{worker}, 'owned-converter',
	   'failed converter cleanup retains recovery ownership');
	local *Cloudmin::Worker::cleanup = sub {
		is($_[1], 'owned-converter',
		   'cleanup targets only the recorded converter');
		};
	$manager->cleanup_disk_worker($id);
	ok(!$jobs->{job}->{worker},
	   'successful converter cleanup clears its lease');
	}
done_testing();
