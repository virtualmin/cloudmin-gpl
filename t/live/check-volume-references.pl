#!/usr/bin/perl
# check-volume-references.pl reproduces stale pool entries in private
# test pools.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../..", "$Bin/../../lib";
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use Sys::Virt;
use Cloudmin::Images;
use Test::More;

# This fixture changes libvirt pools and must never run on the workstation.
die "Run as root on an authorized Linux test host\n"
	if ($^O ne 'linux' || $< != 0);
my $conn = Sys::Virt->new(uri => 'qemu:///system');
my $dir =
	tempdir('cloudmin-volume-check-XXXXXX',
		DIR => '/var/lib/libvirt/images');
my @pools;
my $ok = eval {
	# Both pools belong to this run; no existing volume is
	# removed or modified.
	for my $suffix (qw(target stale)) {
		my $path = "$dir/$suffix";
		mkdir($path) or die $!;
		my $pool =
			$conn->define_storage_pool('<pool type="dir"><name>'.
						   "cloudmin-volume-check-$$-$suffix</name><target><path>$path</path></target></pool>");
		push(@pools, $pool);
		$pool->create();
		}
	my ($target, $stale) = @pools;
	# Keep one removable volume and one base protected by
	# a surviving overlay.
	my $base =
		$target->create_volume(
			'<volume><name>base.raw</name><capacity>1048576</capacity>'.
			'<target><format type="raw"/></target></volume>');
	my $unused =
		$target->create_volume(
			'<volume><name>unused.raw</name><capacity>1048576</capacity>'.
			'<target><format type="raw"/></target></volume>');
	my $overlay =
		$target->create_volume(
			'<volume><name>dependent.qcow2</name><capacity>1048576</capacity>'.
			'<target><format type="qcow2"/></target><backingStore><path>'.$base->get_path().
			'</path><format type="raw"/></backingStore></volume>');
	my $missing = "$dir/stale/removed-directory";
	# Deleting outside libvirt reproduces a cached volume
	# with unreadable XML.
	mkdir($missing) or die $!;
	$stale->refresh();
	my ($cached) = grep { $_->get_name() eq 'removed-directory' }
		       $stale->list_all_volumes();
	ok($cached, 'libvirt caches the fixture directory as a volume');
	rmdir($missing) or die $!;
	ok(!eval { $cached->get_xml_description(); 1 },
	   'removed directory reproduces the stale metadata failure');

	# The production rollback helper refreshes all pools,
	# including unrelated ones.
	my $adapter =
		Cloudmin::Libvirt->new(readonly => 0, connection_factory =>
							      sub { $conn });
	no warnings 'redefine';
	local *Cloudmin::Libvirt::log_call = sub { };
	ok($adapter->remove_created_volume($target->get_uuid_string(),
					   'unused.raw', $unused->get_key()),
	   'job cleanup succeeds despite a stale entry in another pool');
	ok(!-e "$dir/target/unused.raw",
	   'only the unused job volume was removed');
	ok(!eval { $adapter->remove_created_volume($target->get_uuid_string(),
						   'base.raw',
						   $base->get_key()); 1 },
	   'cleanup still rejects an in-use backing image');
	like($@, qr/backing file for volume dependent.qcow2/,
	     'surviving backing dependency is reported');
	ok(-f "$dir/target/base.raw", 'referenced base remains intact');
	# Once the real reference is removed, the same guarded
	# cleanup can succeed.
	$overlay->delete();
	ok($adapter->remove_created_volume($target->get_uuid_string(),
					   'base.raw', $base->get_key()),
	   'cleanup succeeds once the backing dependency is removed');
	1;
	};
my $error = $@;
# Remove only pools and files allocated above, including
# after failed assertions.
for my $pool (reverse @pools) {
	# Pool setup may have failed before activation; undefine either way.
	$pool->destroy() if ($pool->is_active());
	$pool->undefine();
	}
remove_tree($dir);
# Report the captured test error after removing owned test objects.
die $error if (!$ok);
done_testing();
