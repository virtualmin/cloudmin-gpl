use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use lib "$Bin/../lib";
use lib "$Bin/lib";
use CloudminTest;
use WebminCore qw(convert_to_json);

use Cloudmin::ImageCatalog;

my $catalogue = Cloudmin::ImageCatalog->new(
	'path' => "$Bin/../catalog/images.json",
);

# Only architectures actually published by each vendor belong in the list.
is($catalogue->image_count(), 21, 'catalogue contains twenty-one OS releases');
my $arm = $catalogue->list_images('arm64');
my $x86 = $catalogue->list_images('amd64');
is(scalar(@$arm), 19, 'ARM64 aliases select nineteen AArch64 assets');
is(scalar(@$x86), 21, 'AMD64 aliases select twenty-one x86-64 assets');
ok(!grep({ $_->{'architecture'} ne 'aarch64' } @$arm),
   'ARM list has no x86 assets');
ok(!$catalogue->find_image('arch-linux', 'aarch64'),
   'Arch Linux is not offered on ARM');
ok($catalogue->find_image('arch-linux', 'x86_64'),
   'Arch Linux is offered on x86-64');
ok(!$catalogue->find_image('opensuse-tumbleweed', 'aarch64'),
   'unavailable Tumbleweed ARM64 download is not offered');
ok($catalogue->find_image('opensuse-tumbleweed', 'x86_64'),
   'Tumbleweed remains available on x86-64');
is_deeply($catalogue->list_images('riscv64'), [ ],
	  'unsupported host has no downloads');
is_deeply(
	[ map { $_->{'id'} } grep { $_->{'os'} eq 'AlmaLinux' } @$arm ],
	[ qw(almalinux-10 almalinux-9 almalinux-8) ],
	'OS releases are ordered newest first',
);
# Support status must not split a distribution across the catalogue.
is_deeply([ map { $_->{'id'} } @$arm[0 .. 2] ],
	  [ qw(almalinux-10 almalinux-9 almalinux-8) ],
	  'distributions stay together across support levels');
is_deeply([ map { $_->{'name'} } @{Cloudmin::ImageChoices::sort_images([
	{ os => 'Debian', release => '9', name => 'Debian 9' },
	{ name => 'Custom image' },
	{ os => 'Debian', release => '13', name => 'Debian 13' },
	{ os => 'AlmaLinux', release => '10', name => 'AlmaLinux 10' },
])} ], [ 'AlmaLinux 10', 'Debian 13', 'Debian 9', 'Custom image' ],
	  'shared order handles numeric versions and images without metadata');
is_deeply([ map { $_->{'id'} } grep { $_->{'os'} eq 'Ubuntu' } @$arm ],
	  [ qw(ubuntu-26.04 ubuntu-24.04 ubuntu-22.04 ubuntu-20.04) ],
	  'LTS releases sort by version');

# Qualified older releases are available for both architectures, but must not be
# promoted to recommended downloads.
for my $id (qw(debian-11 ubuntu-20.04)) {
	for my $architecture (qw(aarch64 x86_64)) {
		my $image = $catalogue->find_image($id, $architecture);
		ok($image, "$id is available for $architecture");
		is($image->{'status'}, 'older', "$id remains an older release");
		ok($image->{'cloud_init'},
		   "$id supports first-boot provisioning");
		}
	}

# Each newly added family has a directly downloadable image, not an installer
# label copied from libosinfo without a corresponding cloud image.
for my $id (qw(alpine-3.24 centos-stream-10 centos-stream-9 fedora-44
		fedora-43 opensuse-leap-16.0 debian-12)) {
	ok($catalogue->find_image($id, 'aarch64'),
	   "$id is available for ARM64");
	}
for my $image (@{$catalogue->list_images()}) {
	like($image->{'url'}, qr{^https://.*\.(?:qcow2|img)$},
	     "$image->{id} $image->{architecture} uses a standalone disk image");
	# Fixed releases must have a dated support end; rolling releases do not.
	if ($image->{'release'} ne 'rolling') {
		like($image->{'end_of_life'}, qr/^\d{4}-\d{2}-\d{2}$/,
		     "$image->{id} $image->{architecture} has a support end date");
		}
	}

# Search requires every term and stays within the selected architecture.
my $matches = $catalogue->search_images('rocky 10 arm64', 'aarch64');
is(scalar(@$matches), 1, 'search matches name, release, and architecture');
is($matches->[0]->{'id'}, 'rocky-linux-10',
   'search returns the expected image');
is($matches->[0]->{'architecture'}, 'aarch64', 'search retains selected asset');
is($matches->[0]->{'format'}, 'qcow2', 'disk format is retained');
like($matches->[0]->{'url'}, qr{^https://}, 'image source requires HTTPS');
like($matches->[0]->{'signature_url'}, qr{^https://},
     'signed-checksum source is retained');
ok(!$catalogue->find_image('debian-13', 'aarch64')->{'signature_url'},
   'catalogue accepts an official checksum without a detached signature');

# Vendor searches must include the older releases as well as current ones.
ok(grep({ $_->{'id'} eq 'debian-11' }
	@{$catalogue->search_images('debian project', 'x86_64')}),
   'vendor search includes older Debian releases');
ok(grep({ $_->{'id'} eq 'ubuntu-20.04' }
	@{$catalogue->search_images('canonical', 'x86_64')}),
   'vendor search includes older Ubuntu releases');

# Stable IDs provide direct selection without accepting an incompatible asset.
ok($catalogue->find_image('ubuntu-24.04', 'aarch64'),
   'compatible image can be selected by ID');
ok(!$catalogue->find_image('missing', 'aarch64'),
   'unknown image ID is rejected');
is(Cloudmin::ImageCatalog::normalize_architecture('ARM64'), 'aarch64',
   'ARM64 is normalized');
is(Cloudmin::ImageCatalog::normalize_architecture('x86-64'), 'x86_64',
   'x86-64 is normalized');

# Optional download estimates must never accept placeholders or unsafe numbers.
my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/catalogue.json";
my $record = $catalogue->find_image('debian-13', 'aarch64');
for my $value ( undef, 123456, 0, -1, '12 MiB', '99999999999999999' ) {
	my %asset = %$record;
	delete($asset{'download_size_bytes'});
	$asset{'download_size_bytes'} = $value if defined($value);
	open(my $out, '>', $path) or die $!;
	print $out convert_to_json({ schema => 1,
				     images => [ { %$record,
					    assets => [ \%asset ] } ] });
	close($out);
	my $valid = eval { Cloudmin::ImageCatalog->new(path => $path)->load();
		1 };
	is($valid ? 1 : 0, !defined($value) || $value eq '123456' ? 1 : 0,
	   'optional download size accepts only positive byte counts');
	}

done_testing();
