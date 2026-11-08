use strict;
use warnings;
no warnings 'once';
use Test::More;
use FindBin qw($Bin);
use Storable qw(dclone);

# Keep the real preparation code inside a fake appliance; no host files mount.

BEGIN
{
$INC{'Sys/Guestfs.pm'} = __FILE__;
}
package Sys::Guestfs;
our ($source, $last, $fail, $retain, $no_marker);

# new(class) gives each fake appliance an independent copy of the fixture.

sub new
{
$last = bless { files => Storable::dclone($source), calls => [ ] },
	shift;
}

# is_file(self, path, [options...]) recognizes files in the fake guest only.

sub is_file
{
exists $_[0]->{files}->{$_[1]}
}

# is_dir(self, path, [options...]) models an installed Pro module directory.

sub is_dir
{
$_[1] eq '/usr/share/webmin/virtual-server/pro'
}

# exists(self, path) checks the fake guest's file map.

sub exists
{
exists $_[0]->{files}->{$_[1]}
}

# filesize(self, path) exposes the stored length for the bounded-read guard.

sub filesize
{
length($_[0]->{files}->{$_[1]})
}

# read_file(self, path) returns in-memory guest contents.

sub read_file
{
$_[0]->{files}->{$_[1]}
}

# write(self, path, content) changes only this appliance's copied file map.

sub write
{
$_[0]->{files}->{$_[1]} = $_[2];
}

# rm(self, path) removes one copied file.

sub rm
{
delete $_[0]->{files}->{$_[1]};
}

# rm_rf(self, path) models removal without touching a real filesystem.

sub rm_rf
{
shift->rm(@_);
}

# is_symlink(self, path) models a fixture containing regular files only.

sub is_symlink
{
0
}

# glob_expand(self, pattern) matches literal fixture paths used by these tests.

sub glob_expand
{
exists $_[0]->{files}->{$_[1]} ? ($_[1]) : ()
}

# inspect_os(self) reports one fake system root.

sub inspect_os
{
('/dev/sda1')
}

# inspect_get_type(self, root) makes the fixture eligible for Linux preparation.

sub inspect_get_type
{
'linux'
}

# inspect_get_mountpoints(self, root) supplies one mount for the fake appliance.

sub inspect_get_mountpoints
{
( '/' => '/dev/sda1' )
}

# inspect_get_arch(self, root) includes the fixture architecture in the result.

sub inspect_get_arch
{
'aarch64'
}

# set_network(self, enabled) fails if preparation enables appliance networking.

sub set_network
{
die 'Network enabled' if $_[1];
}

# command(self, argv) simulates hostname setup and the
# offline Virtualmin helper.

sub command
{
my ($self, $args) = @_;
push(@{$self->{calls}}, $args);
return if $args->[0] eq '/bin/hostname';
# Exercise helper failure, misleading success and retained credentials.
die "Offline license reset failed\n" if $fail;
$self->{files}->{'/etc/virtualmin-license'} =
	"SerialNumber=CLONE_REQUIRES_LICENSE\nLicenseKey=CLONE_REQUIRES_LICENSE\n" unless $retain;
return $no_marker ? "Webmin error\n" : "CLOUDMIN_CLONE_READY\n";
}
our $AUTOLOAD;

# AUTOLOAD(self, [arguments...]) accepts appliance setup and cleanup calls only.

sub AUTOLOAD
{
my ($method) = $AUTOLOAD =~ /::([^:]+)$/;
die "Unexpected appliance call: $method"
	unless $method =~ /^(?:set_backend|set_backend_setting|set_trace|set_verbose|add_drive_opts|launch|mount|mkdir_p|chmod|chown|sync|umount_all|shutdown|close|DESTROY)$/;
return 1;
}
package Cloudmin::WorkerTasks;

# disk_info(format, [path]) gives the fake disk its expected fixed capacity.

sub disk_info
{
return { 'virtual-size' => 4096 };
}
package main;
require "$Bin/../lib/Cloudmin/CloneGuest.pm";
$Sys::Guestfs::source = {
	'/etc/hostid' => pack('V', 0x11223344), '/etc/hostname' =>
							"source.example.test\n",
	'/etc/hosts' => "127.0.1.1 source.example.test\n", '/etc/machine-id' =>
								   'old-machine-id',
	'/usr/share/webmin/virtual-server/virtual-server-lib.pl' => 'fixture',
	'/etc/virtualmin-license' =>
		"SerialNumber=GPL\nLicenseKey=SOURCE_FIXTURE_KEY\n",
	'/etc/cloud/cloud.cfg' => 'fixture', '/usr/bin/cloud-init' => 'fixture',
	'/etc/passwd' => "cloudmin:x:1000:1000::/home/cloudmin:/bin/sh\n",
	'/home/cloudmin/.ssh/authorized_keys' => 'old key',
	'/var/lib/systemd/random-seed' => 'source-random-seed',
};
my $before = dclone($Sys::Guestfs::source);
# Deliberately collide with the saved hostid and disguise Pro with a GPL serial.
my $request =
	{ disks => [ { name => 'disk0', format => 'qcow2', capacity => 4096 } ],
	  uuid => '11223344-1234-4123-8123-123456789abc',
	  confirm_license => 1,
	  settings =>
		  { hostname => 'copy.example.test',
		    username => 'cloudmin',
		    ssh_keys => '' } };
{
	no warnings 'redefine';
	local *Cloudmin::ImageInspector::check_cloud_config = sub { 1 };
	for my $mode ( 'prepared', 'unchanged' ) {
		my $result =
			Cloudmin::CloneGuest::prepare({ %$request,
							mode => $mode });
		is($result->{virtualmin}, 'pro',
		   "$mode detects installed Pro despite a GPL serial");
		isnt($Sys::Guestfs::last->{files}->{'/etc/hostid'},
		     $before->{'/etc/hostid'},
		     "$mode avoids a colliding host ID");
		like($Sys::Guestfs::last->{files}->{'/etc/virtualmin-license'},
		     qr/CLONE_REQUIRES_LICENSE/,
		     "$mode removes copied credentials");
		is($Sys::Guestfs::last->{files}->{'/etc/machine-id'},
		   $mode eq 'prepared' ? '' : 'old-machine-id',
		   "$mode changes only intended identity fields");
		is(
			exists(
				$Sys::Guestfs::last->{files}->{'/var/lib/systemd/random-seed'})
					? 1
					: 0,
			$mode eq 'prepared' ? 0 : 1,
			"$mode clears random seed only during identity preparation");
		is($Sys::Guestfs::last->{files}->{'/etc/hostname'},
		   $mode eq 'prepared'
			   ? "copy.example.test\n"
			   : "source.example.test\n",
		   "$mode preserves or replaces hostname");
		is_deeply($Sys::Guestfs::source, $before,
			  "$mode never changes the source");
		is(
			$Sys::Guestfs::last->{files}->{'/home/cloudmin/.ssh/authorized_keys'},
			$mode eq 'prepared' ? "\n" : 'old key',
			"$mode keeps the existing clone key policy");
		}
	# Capture must leave account files for the Pro all-or-none policy.
	Cloudmin::CloneGuest::prepare({ %$request, capture_image => 1 });
	is(
		$Sys::Guestfs::last->{files}->{'/home/cloudmin/.ssh/authorized_keys'},
		'old key',
		'shared capture preparation does not replace user keys');
	# License removal needs consent and must fail closed
	# in either copy mode.
	ok(!eval { Cloudmin::CloneGuest::prepare({ %$request, confirm_license =>
								      0 }); 1 },
	   'Pro license reset requires acknowledgment');
	like($@, qr/downgrade manually to GPL/,
	     'confirmation error explains the manual choice');
	local $Sys::Guestfs::fail = 1;
	ok(!eval { Cloudmin::CloneGuest::prepare({ %$request, mode =>
								      'unchanged' }); 1 },
	   'failed helper blocks copies without guest setup too');
	}
{
	# Webmin can exit successfully after printing an error
	# instead of the marker.
	local $Sys::Guestfs::no_marker = 1;
	ok(!eval { Cloudmin::CloneGuest::prepare({ %$request, mode =>
								      'unchanged' }); 1 },
	   'zero-exit helper errors without completion marker are rejected');
	}
{
	# A completion marker alone cannot prove that copied
	# credentials were erased.
	local $Sys::Guestfs::retain = 1;
	ok(!eval { Cloudmin::CloneGuest::prepare({ %$request, mode =>
								      'unchanged' }); 1 },
	   'helper success with retained credentials is rejected');
	like($@, qr/credentials were not removed/,
	     'retained credentials are reported');
	}
done_testing();
