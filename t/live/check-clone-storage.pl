#!/usr/bin/perl
# check-clone-storage.pl [pool]
# Verifies full volume copies on a disposable Cloudmin host. An optional pool
# name exercises an already configured directory, filesystem or NFS pool.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Sys::Virt;

die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' &&
	$< == 0;
my $connection = Sys::Virt->new(uri => 'qemu:///system');
my $directory = tempdir('/var/tmp/cloudmin-clone-storage-XXXXXX', CLEANUP => 1);
chmod(0755, $directory) or die $!;
my $name = 'cloudmin-clone-storage-'.$$;
my ($pool, $owned, @volumes);

# command(arguments...) runs a fixture tool without shell interpolation.

sub command
{
system(@_) == 0 or die "Fixture command failed: $_[0]\n";
}

# info(path) reads only the generated fixture's qemu-img metadata.

sub info
{
open(my $fh, '-|', 'qemu-img', 'info', '--output=json', $_[0]) or die $!;
local $/;
my $data = <$fh>;
close($fh) or die "Cannot inspect fixture\n";
return decode_json($data);
}

my $ok = eval {
	if (@ARGV) {
		# Keep existing pools; remove only this test's
		# uniquely named volumes.
		$pool = $connection->get_storage_pool_by_name($ARGV[0]);
		}
	else {
		# The default fixture owns its directory pool and
		# removes it afterward.
		$pool =
			$connection->define_storage_pool(
				"<pool type='dir'><name>$name</name><target><path>$directory</path></target></pool>");
		$owned = 1;
		$pool->create();
		}
	for my $format (qw(raw qcow2)) {
		# The immutable base and overlay contain
		# different visible sectors.
		my $base =
			$pool->create_volume(
				"<volume><name>$name-$format-base</name><capacity unit='MiB'>64</capacity><target><format type='$format'/></target></volume>");
		push(@volumes, $base);
		command('qemu-io', '-f', $format, '-c', 'write -P 31 0 4096',
			$base->get_path());
		# A second pattern proves that copying includes both
		# backing-chain layers.
		my $overlay =
			$pool->create_volume(
				"<volume><name>$name-$format-overlay</name><capacity unit='MiB'>64</capacity><target><format type='qcow2'/></target><backingStore><path>".$base->get_path()."</path><format type='$format'/></backingStore></volume>");
		push(@volumes, $overlay);
		command('qemu-io', '-f', 'qcow2', '-c', 'write -P 47 4096 4096',
			$overlay->get_path());
		my $copy =
			$pool->clone_volume(
				"<volume><name>$name-$format-copy</name><capacity unit='MiB'>64</capacity><allocation>0</allocation><target><format type='qcow2'/></target></volume>", $overlay, 0);
		push(@volumes, $copy);
		ok(!info($copy->get_path())->{'backing-filename'},
		   "$format chain is flattened");
		# Write to the copy, then remove its sources
		# to prove independence.
		is(system('qemu-img', 'compare', '-f', 'qcow2', '-F', 'qcow2',
			  $overlay->get_path(), $copy->get_path()), 0,
		   'all guest-visible sectors match');
		command('qemu-io', '-f', 'qcow2', '-c', 'write -P 63 0 4096',
			$copy->get_path());
		is(system('qemu-io', '-f', $format, '-r', '-c',
			  'read -P 31 0 4096', $base->get_path()), 0,
		   'writing the clone leaves its source unchanged');
		$overlay->delete(0);
		$base->delete(0);
		splice(@volumes, -3, 2);
		is(system('qemu-io', '-f', 'qcow2', '-r', '-c',
			  'read -P 47 4096 4096', $copy->get_path()), 0,
		   'clone remains readable after both source layers are deleted');
		}
	1;
	};
my $error = $@;
# Remove only fixture-owned storage, including partially completed scenarios.
foreach my $volume (reverse @volumes) { eval { $volume->delete(0); }; }
# Retain a caller-supplied pool; only the default private pool belongs to us.
if ($owned && $pool) { eval { $pool->destroy(); $pool->undefine(); }; }
die $error if (!$ok);
done_testing();
