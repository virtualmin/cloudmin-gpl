use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempfile);
require "$Bin/../lib/Cloudmin/ImageInspector.pm";

{
	package InspectionGuest;

	# new(class, [overrides]) Models the guest files and
	# inspection API in use.

	sub new
	{
	return bless({ roots => [ '/dev/root' ], arch => 'aarch64',
		       type => 'linux',
		       files => { '/etc/cloud/cloud.cfg' => '{}',
				  '/usr/bin/cloud-init' => '' },
		       links => { }, mounts => [ ], %{$_[1] || { }} }, $_[0]);
	}

	# inspect_os(self) - Returns discovered operating-system roots.

	sub inspect_os
	{
	return @{$_[0]->{'roots'}};
	}

	# inspect_get_type(self, root) Returns the detected
	# operating-system family.

	sub inspect_get_type
	{
	return $_[0]->{'type'};
	}

	# inspect_get_arch(self, root) - Returns the detected CPU architecture.

	sub inspect_get_arch
	{
	return $_[0]->{'arch'};
	}

	# inspect_get_mountpoints(self, root) Includes a
	# separate /usr filesystem.

	sub inspect_get_mountpoints
	{
	return ( '/usr' => '/dev/usr',
		 '/' => '/dev/root' );
	}

	# mount_ro(self, device, path) Records mount order
	# without mounting anything.

	sub mount_ro
	{
	push(@{$_[0]->{'mounts'}}, $_[2]);
	}

	# exists(self, path) - Reports fixture files, including disable markers.

	sub exists
	{
	return exists($_[0]->{'files'}->{$_[1]});
	}

	# is_file(self, path, options) Follows the fixture's
	# known regular files.

	sub is_file
	{
	return exists($_[0]->{'files'}->{$_[1]});
	}

	# is_symlink(self, path) - Reports masked fixture services.

	sub is_symlink
	{
	return exists($_[0]->{'links'}->{$_[1]});
	}

	# readlink(self, path) - Returns the fixture symlink target.

	sub readlink
	{
	return $_[0]->{'links'}->{$_[1]};
	}

	# glob_expand(self, pattern) Supplies cloud.cfg.d
	# configuration fragments.

	sub glob_expand
	{
	return grep { m{^/etc/cloud/cloud\.cfg\.d/.*\.cfg$} }
	       keys %{$_[0]->{'files'}};
	}

	# filesize(self, path) - Bounds guest configuration reads.

	sub filesize
	{
	return length($_[0]->{'files'}->{$_[1]});
	}

	# read_file(self, path) - Returns fixture configuration bytes.

	sub read_file
	{
	return $_[0]->{'files'}->{$_[1]};
	}
	}

# Filesystem checks run without requiring workstation virtualization packages.
{
	no warnings 'redefine';
	local *Cloudmin::ImageInspector::check_cloud_config = sub { return 1; };
	my $guest = InspectionGuest->new();
	is_deeply(Cloudmin::ImageInspector::inspect_guest($guest),
		  { architecture => 'aarch64', cloud_init => 1 },
		  'usable Linux image reports compatibility');
	is_deeply($guest->{'mounts'}, [ '/', '/usr' ],
		  'separate software filesystem is mounted after root');
	for my $bad (
		[ { roots => [ ] }, qr/one installed Linux/ ],
		[ { roots => [ '/dev/a', '/dev/b' ] },
		  qr/one installed Linux/ ],
		[ { type => 'unknown' }, qr/one installed Linux/ ],
		[ { arch => 'unknown' }, qr/Cannot determine/ ],
		[ { files => { } }, qr/not installed/ ],
		[ { files => { '/etc/cloud/cloud-init.disabled' => '' } },
		  qr/disabled/ ],
		[ { links => { '/etc/systemd/system/cloud-init.service' =>
				       '/dev/null' } }, qr/masked/ ],
	) {
		ok(
			!eval { Cloudmin::ImageInspector::inspect_guest(
				InspectionGuest->new($bad->[0])); 1 },
			'incompatible or unknown guest is rejected');
		like($@, $bad->[1], 'rejection explains the failed check');
		}
	}

# Parse real YAML when available; the disposable-host checks
# require this dependency.
SKIP: {
	skip 'YAML::XS is not installed', 7 if (!eval { require YAML::XS; 1 });
	my $guest = InspectionGuest->new();
	$guest->{'files'}->{'/etc/cloud/cloud.cfg'} =
		'datasource_list: [Ec2, None]';
	ok(!eval { Cloudmin::ImageInspector::check_cloud_config($guest); 1 },
	   'EC2-only image is rejected');
	like($@, qr/NoCloud/, 'datasource error names the missing support');
	$guest->{'files'}->{'/etc/cloud/cloud.cfg'} = 'datasource_list: null';
	ok(!eval { Cloudmin::ImageInspector::check_cloud_config($guest); 1 },
	   'explicit null datasources do not imply compatibility');
	$guest->{'files'}->{'/etc/cloud/cloud.cfg.d/99-local.cfg'} =
		"datasource_list:\n  - NoCloud\n";
	ok(eval { Cloudmin::ImageInspector::check_cloud_config($guest); 1 },
	   'later NoCloud configuration is accepted');
	$guest->{'files'}->{'/etc/cloud/cloud.cfg.d/99-local.cfg'} =
		'network: {config: disabled}';
	$guest->{'files'}->{'/etc/cloud/cloud.cfg'} = '{}';
	ok(!eval { Cloudmin::ImageInspector::check_cloud_config($guest); 1 },
	   'disabled networking is rejected');
	$guest->{'files'}->{'/etc/cloud/cloud.cfg'} =
		"sensitive: [private-fixture\n";
	ok(!eval { Cloudmin::ImageInspector::check_cloud_config($guest); 1 },
	   'unparseable configuration is rejected');
	unlike($@, qr/private-fixture/,
	       'configuration contents never appear in errors');
	}
# Readiness must boot the same isolated appliance, without requiring an OS on
# its empty probe disk. Failed boot still closes the handle and rejects setup.
{
	package Sys::Guestfs;
	our ($failure, $closed, $backend, $force_kvm);

	# new(class) provides an appliance handle without starting QEMU.

	sub new
	{
	bless { }, shift
	}

	# set_backend(self, backend) Records which launch
	# backend inspection selects.

	sub set_backend
	{
	$backend = $_[1]
	}

	# set_backend_setting(self, name, value) Records the
	# KVM-only requirement.

	sub set_backend_setting
	{
	$force_kvm = "$_[1]=$_[2]"
	}

	# set_network(self, enabled) Accepts policy without
	# creating a guest network.

	sub set_network
	{
	}

	# set_trace(self, enabled) Accepts the diagnostic
	# setting without output.

	sub set_trace
	{
	}

	# set_verbose(self, enabled) Accepts the diagnostic
	# setting without output.

	sub set_verbose
	{
	}

	# add_drive_opts(self, path, options...) Avoids
	# opening a real guest disk.

	sub add_drive_opts
	{
	}

	# launch(self) models a successful boot or the
	# selected appliance failure.

	sub launch
	{
	die $failure if $failure
	}

	# close(self) Counts cleanup after successful and
	# failed appliance launches.

	sub close
	{
	$closed++
	}
	}
{
	local $INC{'Sys/Guestfs.pm'} = __FILE__;
	my ($fh, $path) = tempfile(UNLINK => 1);
	close($fh);
	local $Sys::Guestfs::closed = 0;
	is_deeply(
		Cloudmin::ImageInspector::inspect($path, 'raw', 1),
		{ appliance => 1 },
		'readiness verifies appliance boot without inspecting an installed guest');
	is($Sys::Guestfs::force_kvm, 'force_kvm=1',
	   'readiness cannot silently fall back to software emulation');
	local $Sys::Guestfs::failure = "KVM boot failed\n";
	ok(!eval { Cloudmin::ImageInspector::inspect($path, 'raw', 1); 1 },
	   'failed appliance blocks readiness');
	like($@, qr/KVM boot failed/, 'boot failure reaches the caller');
	is($Sys::Guestfs::closed, 2,
	   'appliance handles close after both success and failure');
	}
done_testing();
