use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
require "$Bin/../lib/Cloudmin/Images.pm";

# Model libvirt's documented exception interface without contacting a daemon.

BEGIN
{
$INC{'Sys/Virt.pm'} = 1;
}
{
	package Sys::Virt::Error;

	# ERR_NO_STORAGE_POOL() Supplies a distinguishable
	# missing-pool error code.
	sub ERR_NO_STORAGE_POOL
	{
	return 49;
	}
	package PoolError;

	# code(self) - Returns the error code raised by this fixture connection.
	sub code
	{
	return $_[0]->{'code'};
	}
	package Sys::Virt;
	our $failure;

	# new(class, options...) Returns a connection that only
	# supports pool lookup.
	sub new
	{
	return bless({ }, $_[0]);
	}

	# get_storage_pool_by_uuid(self, uuid) Fails with the
	# selected libvirt error.
	sub get_storage_pool_by_uuid
	{
	die $failure;
	}
	}

my $dir = tempdir(CLEANUP => 1);
my $jobs = Cloudmin::Images->new(directory => $dir,
				 lock_file => sub { return 1; },
				 unlock_file => sub { },
				 test_lock => sub { return 0; }, log => sub { },
				 disk_free => sub { return 16 * 1024**3; });
open(my $fh, '>', "$dir/retained.qcow2") || die $!;
print $fh 'keep this fixture'; close($fh);
symlink("$dir/nonexistent", "$dir/broken-link") || die $!;

for my $case (
	[ 'absent local file', 'qemu:///system', "$dir/missing", 49, 1 ],
	[ 'existing local file', 'qemu:///system', "$dir/retained.qcow2", 49,
	  0 ],
	[ 'dangling file link', 'qemu:///system', "$dir/broken-link", 49, 0 ],
	[ 'unrecorded file path', 'qemu:///system', '', 49, 0 ],
	[ 'remote host path', 'qemu+ssh://fixture/system', "$dir/missing", 49,
	  0 ],
	[ 'other libvirt failure', 'qemu:///system', "$dir/missing", 1, 0 ],
) {
	my ($name, $uri, $path, $code, $expected) = @$case;
	local $jobs->{'uri'} = $uri;
	local $Sys::Virt::failure = bless({ code => $code }, 'PoolError');
	my $job = $jobs->create('fixture', $jobs->form_token('fixture'),
				{ source => 'upload', format => 'qcow2',
				  pool => 'missing',
				  name => $name });
	$job->{'state'} = 'ready';
	$job->{'pid'} = $$;
	$job->{'volume_path'} = $path;
	$jobs->save($job->{'id'}, $job);
	my $ok = eval { $jobs->remove($job->{'id'}); 1 };
	is($ok ? 1 : 0, $expected, $name);
	is($jobs->get($job->{'id'})->{'state'}, $expected ? 'deleted' : 'ready',
	   "$name keeps metadata unless absence is established");
	}
ok(-f "$dir/retained.qcow2", 'the existing image file is never removed');
ok(-l "$dir/broken-link", 'an unrecognized link is never removed');
done_testing();
