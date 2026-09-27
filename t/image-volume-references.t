use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use Cloudmin::Images;

# Model stale inventories without a daemon or host storage changes.
{
	package Sys::Virt::Error;
	# code(self) returns the simulated libvirt failure code.
	sub code { $_[0]->{'code'} }
	package ReferenceVolume;
	# field(self, name) injects a failure at any point in volume inspection.
	sub field {
		my ($self, $name) = @_;
		# Fail only at the selected getter so later inspection races are
		# covered.
		die $self->{'error'} if (($self->{'fail_at'} || '') eq $name);
		return $self->{$name};
	}
	# get_xml_description(self, flags) supplies the volume's backing chain.
	sub get_xml_description { $_[0]->field('xml') }
	# get_key(self) supplies the stable volume key.
	sub get_key { $_[0]->field('key') }
	# get_path(self) supplies the base directory for relative backing paths.
	sub get_path { $_[0]->field('path') }
	# get_name(self) supplies the dependency's display name.
	sub get_name { $_[0]->field('name') }
	package ReferencePool;
	# is_active(self) keeps inactive pools out of refresh and enumeration.
	sub is_active { !$_[0]->{'inactive'} }
	# refresh(self) expires stale cache entries or fails before inspection.
	sub refresh {
		my ($self) = @_;
		# An unreadable pool must block cleanup rather than look empty.
		die $self->{'error'} if ($self->{'error'});
		$self->{'refreshes'}++;
		$self->{'volumes'} = $self->{'current'};
	}
	# list_all_volumes(self) returns the refreshed cache or an enumeration error.
	sub list_all_volumes {
		die "Enumeration failed\n" if ($_[0]->{'list_error'});
		return @{$_[0]->{'volumes'}};
	}
	package ReferenceConnection;
	# list_all_domains(self) isolates backing-volume references for these tests.
	sub list_all_domains { () }
	# list_all_storage_pools(self) supplies active and inactive fixture pools.
	sub list_all_storage_pools { @{$_[0]->{'pools'}} }
}
# Replace one stale entry with a real dependency while skipping inactive pools.
my $backing = bless({ name => 'dependent.qcow2', path => '/pool/dependent.qcow2',
	key => 'dependent', xml => '<volume><backingStore><path>base.qcow2</path></backingStore></volume>' },
	'ReferenceVolume');
my $missing = bless({ fail_at => 'xml', error => bless({code => 50}, 'Sys::Virt::Error') },
	'ReferenceVolume');
my $pool = bless({volumes => [$missing], current => [$backing]}, 'ReferencePool');
my $inactive = bless({inactive => 1, error => 'Inactive pool was refreshed'}, 'ReferencePool');
my $conn = bless({pools => [$pool, $inactive]}, 'ReferenceConnection');
my $refs = Cloudmin::Images::volume_references($conn);
is($pool->{'refreshes'}, 1, 'active pool is refreshed before enumeration');
ok(!$inactive->{'refreshes'}, 'inactive pool is not refreshed');
is(scalar(@$refs), 1, 'stale cache entry is replaced by current volumes');
like(Cloudmin::Images::volume_use($refs, '/pool/base.qcow2', 'default', 'base.qcow2', 'base'),
	qr/dependent.qcow2/, 'refreshed backing chain still protects the base image');

# Disappearance at any inspection step cannot hide a surviving dependency.
for my $field (qw(xml key path name)) {
	local $pool->{'current'} = [bless({%$backing, fail_at => $field,
		error => $missing->{'error'}}, 'ReferenceVolume'), $backing];
	my $found = Cloudmin::Images::volume_references($conn);
	is(scalar(@$found), 1, "$field tolerates a volume removed after refresh");
	like(Cloudmin::Images::volume_use($found, '/pool/base.qcow2', 'default', 'base.qcow2', 'base'),
		qr/dependent.qcow2/, "$field preserves the remaining backing reference");
}

# Unknown failures cannot be treated as proof that deletion is safe.
for my $error ("Permission denied\n", bless({code => 38}, 'Sys::Virt::Error')) {
	local $pool->{'current'} = [bless({fail_at => 'xml', error => $error}, 'ReferenceVolume')];
	ok(!eval { Cloudmin::Images::volume_references($conn); 1 }, 'inspection failure blocks deletion');
	is($@, $error, 'original inspection error propagates');
}
# Inventory refresh failures cannot prove that a volume has no references.
{
	local $pool->{'error'} = "Refresh failed\n";
	ok(!eval { Cloudmin::Images::volume_references($conn); 1 }, 'refresh failure blocks deletion');
	is($@, "Refresh failed\n", 'refresh failure is not hidden');
}
# A failed listing after refresh must also prevent deletion.
{
	local $pool->{'list_error'} = 1;
	ok(!eval { Cloudmin::Images::volume_references($conn); 1 }, 'enumeration failure blocks deletion');
	is($@, "Enumeration failed\n", 'enumeration failure is not hidden');
}
# Native libvirt and Cloudmin use different keys for the same logical volume.
# Its own target is not a backing dependency.
{
	my $path = '/dev/fixture/guest';
	my $refs = [{key => 'native-lv-key', path => $path,
		xml => "<volume><target><path>$path</path></target></volume>", reason => 'self'}];
	ok(!Cloudmin::Images::volume_use($refs, $path, 'fixture', 'guest', 'lvm:vg:lv'),
		'native volume path excludes its own record despite different keys');
	push(@$refs, {key => 'other-key', path => '/dev/fixture/other',
		xml => "<volume><backingStore><path>$path</path></backingStore></volume>", reason => 'dependent disk'});
	is(Cloudmin::Images::volume_use($refs, $path, 'fixture', 'guest', 'lvm:vg:lv'),
		'dependent disk', 'a different volume still protects the LVM backing disk');
}
done_testing();
