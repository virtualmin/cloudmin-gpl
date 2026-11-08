use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;
use WebminCore qw(read_file_contents);
require "$Bin/../lib/Cloudmin/ImageCatalog.pm";

# All changes use a private fixture; the packaged catalogue must remain intact.
my $directory = tempdir(CLEANUP => 1);
my $path = "$directory/catalogue.json";
my $bundled = "$Bin/../catalog/images.json";
my $original = read_file_contents($bundled);
my ($locked, @logs);
my $catalogue = Cloudmin::ImageCatalog->new(path => $bundled,
					    custom_path => $path,
					    lock_file => sub {
		is($_[0], $path, 'settings are locked');
		is($_[3], 0,
		   'small catalogue configuration retains Webmin diffs');
		die "Nested lock\n" if ($locked);
		return $locked = 1;
		},
					    unlock_file => sub { die "Unpaired unlock\n" if (!$locked); $locked = 0;
		},
					    log => sub { ok(!$locked,
							    'action is logged after unlocking');
		push(@logs, [ @_ ]); },
);
my $entries = $catalogue->list_entries();
ok(!-e $path, 'reading bundled entries creates no settings file');
my $key = 'almalinux-10:aarch64';
my $base = $catalogue->find_entry($key);
is($base->{'catalogue_origin'}, 'bundled', 'bundled origin is explicit');

# Architecture-specific settings must not disable the other vendor asset.
$catalogue->update_entries('disable', [ $key ]);
ok(!$catalogue->find_image('almalinux-10', 'aarch64'),
   'disabled image is not downloadable');
ok($catalogue->find_image('almalinux-10', 'x86_64'),
   'other architecture remains available');
ok(!$catalogue->find_entry($key)->{'enabled'}, 'disabled entry stays editable');
is((stat($path))[2] & 0777, 0600, 'local settings are private');
is($logs[-1]->[3]->{'names'}, 'AlmaLinux 10 (aarch64)',
   'audit uses the catalogue display name and architecture');

# Supplied records can be enabled or disabled, but cannot be overwritten.
ok(!eval { $catalogue->save_entry({ %$base, name => 'Changed' }); 1 },
   'Cloudmin entries cannot be edited');
is($catalogue->find_entry($key)->{'name'}, $base->{'name'},
   'Cloudmin details stay intact');
$catalogue->update_entries('enable', [ $key ]);
ok($catalogue->find_image('almalinux-10', 'aarch64'),
   'enabling restores the download choice');

# New entries join the same architecture-filtered download list.
my $custom = { %$base, id => 'custom-fixture', name => 'Private image',
	       url => 'https://images.example.test/private.qcow2',
	       checksum_url => 'https://images.example.test/SHA256SUMS',
	       min_disk_bytes => 0 };
my $custom_key = 'custom-fixture:aarch64';
$catalogue->save_entry($custom, 1);
is($catalogue->find_image('custom-fixture', 'aarch64')->{'name'},
   'Private image',
   'custom entry is downloadable');
ok(!$catalogue->find_image('custom-fixture', 'x86_64'),
   'custom architecture is enforced');
is($catalogue->find_entry($custom_key)->{'catalogue_origin'}, 'custom',
   'custom origin is explicit');
ok(!eval { $catalogue->save_entry($custom, 1); 1 },
   'duplicate creation is rejected');
ok(!$locked, 'failed creation releases the lock');

# Custom edits survive reload and keep their source and disabled state.
$catalogue->update_entries('disable', [ $custom_key ]);
$catalogue->save_entry({ %$custom, name => "Local Caf\x{e9} <image>" });
my $fresh = Cloudmin::ImageCatalog->new(path => $bundled, custom_path => $path);
is($fresh->find_entry($custom_key)->{'name'}, "Local Caf\x{e9} <image>",
   'UTF-8 edits survive reload');
is($fresh->find_entry($custom_key)->{'catalogue_origin'}, 'custom',
   'custom source survives edits');
ok(!$fresh->find_entry($custom_key)->{'enabled'},
   'editing does not silently enable an entry');
my $stored = WebminCore::convert_from_json(read_file_contents($path));
is(scalar(@{$stored->{'images'}}), 1,
   'config catalogue contains only the custom image');
is($stored->{'images'}->[0]->{'assets'}->[0]->{'architecture'}, 'aarch64',
   'custom catalogue uses the supplied catalogue manifest format');
is($stored->{'images'}->[0]->{'assets'}->[0]->{'download_size_bytes'},
   $base->{'download_size_bytes'},
   'download estimates remain architecture-specific when saving custom entries');

# Invalid batches never apply the valid part of their selection.
my $saved = read_file_contents($path);
ok(!eval { $catalogue->update_entries('delete', [ $custom_key, $key ]); 1 },
   'mixed custom and bundled deletion is rejected');
is(read_file_contents($path), $saved, 'invalid deletion changes no entries');
ok(!eval { $catalogue->update_entries('disable',
				      [ $custom_key, 'missing:x86_64' ]); 1 },
   'stale selections are rejected');
is(read_file_contents($path), $saved, 'stale selection changes no entries');
# Reject malformed URLs, formats and checksum algorithms before writing.
for my $bad (
	{ url => 'http://images.example.test/image.qcow2' },
	{ checksum_url => 'https://user:password@images.example.test/SUMS' },
	{ url => "https://images.example.test/image\n.qcow2" },
	{ checksum_algorithm => 'md5' }, { format => 'vmdk' },
	{ min_disk_bytes => -1 },
	{ release_date => '2025-02-30' }, { end_of_life => 'tomorrow' },
	{ release_date => '2027-01-01', end_of_life => '2026-01-01' },
) {
	ok(!eval { $catalogue->save_entry({ %$custom, %$bad }); 1 },
	   'invalid catalogue data is rejected');
	is(read_file_contents($path), $saved,
	   'invalid entry preserves the saved catalogue');
	}

# Installer entries must retain their format and URL when loaded from disk.
$catalogue->save_entry({ %$custom, format => 'iso',
			 url => 'https://images.example.test/installer.iso' });
my $iso_catalogue = Cloudmin::ImageCatalog->new(
	path => $bundled, custom_path => $path);
my $iso = $iso_catalogue->find_entry($custom_key);
is($iso->{'format'}, 'iso', 'custom ISO format survives reload');
is($iso->{'url'}, 'https://images.example.test/installer.iso',
   'custom ISO download URL survives reload');

# Valid dates must remain unchanged when an existing entry is saved again.
$catalogue->save_entry({ %$custom, release_date => '2024-02-29',
			 end_of_life => '2030-01-01' });
is($catalogue->find_entry($custom_key)->{'release_date'}, '2024-02-29',
   'valid leap-day release survives reload');
is($catalogue->find_entry($custom_key)->{'end_of_life'}, '2030-01-01',
   'end-of-life date survives reload');
$catalogue->update_entries('delete', [ $custom_key ]);
ok(!$catalogue->find_entry($custom_key), 'custom entry is removed');
is($logs[-1]->[3]->{'names'}, 'Private image (aarch64)',
   'deletion audit keeps the name after removing the record');
ok(!eval { $catalogue->update_entries('delete', [ $custom_key ]); 1 },
   'replayed deletion reports the missing entry');
is(read_file_contents($bundled), $original, 'bundled catalogue is unchanged');
is(scalar(@{$catalogue->list_entries()}), scalar(@$entries),
   'fixture changes are fully removed');
done_testing();
