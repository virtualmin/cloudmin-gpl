use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;

# Load the public functions with fixtures instead of a Webmin installation.
our (%config, %text);
our ($cloudmin_last_error, $module_root_directory);
$module_root_directory = "$Bin/..";
our $module_config_directory = tempdir(CLEANUP => 1);
$config{'libvirt_uri'} = 'test:///cloudmin';

# text(key, [args...]) Supplies the positional substitutions needed by
# the Webmin-free tests.

sub text
{
my ($key, @args) = @_;
my $value = $text{$key} || $key;
$value =~ s/\$(\d+)/$args[$1 - 1]/ge;
return $value;
}

# get_system_hostname() Stands in for Webmin's hostname lookup used by
# the host system record.

sub get_system_hostname
{
return 'kvm1.example.test';
}

require "$module_root_directory/server-manager-lib-funcs.pl";

{
	package CompatAdapter;

	# new(class, fields) - Wraps fixture data in an inventory adapter.

	sub new
	{
	return bless($_[1], $_[0]);
	}

	# list_domains(self) - Copies record hashes to protect fixture data.

	sub list_domains
	{
	my ($self) = @_;
	return [ map { +{ %$_ } } @{$self->{'domains'}} ];
	}
	}

# Include both power states and address fields used by the compatibility API.
my $adapter = CompatAdapter->new({
	'domains' => [
		{
			'id' => 'uuid-web',
			'uuid' => 'uuid-web',
			'name' => 'web-01',
			'state' => 'running',
			'active' => 1,
			'addresses' => [ { address => '192.0.2.10' },
					 { address => '2001:db8::10' },
					 { address => '192.0.2.11' } ],
			'macs' => [ '52:54:00:aa:bb:cc' ],
		},
		{
			'id' => 'uuid-db',
			'uuid' => 'uuid-db',
			'name' => 'db-01',
			'state' => 'shutoff',
			'active' => 0,
			'addresses' => [ ],
			'macs' => [ '52:54:00:11:22:33' ],
		},
	],
});

# Preserve lookup by UUID, name, and a scalar inventory field.
my @servers = list_managed_servers(0, $adapter);
is(scalar(@servers), 2, 'list_managed_servers returns libvirt domains');
is(get_managed_server('uuid-web', $adapter)->{'name'}, 'web-01',
   'get_managed_server accepts a UUID');
is(get_managed_server('db-01', $adapter)->{'id'}, 'uuid-db',
   'get_managed_server accepts a name');
is(get_managed_server_by('state', 'running', $adapter)->{'id'}, 'uuid-web',
   'get_managed_server_by matches normalized fields');
# Address helpers must return one address when called in scalar context.
is(get_server_ip($servers[0]), '192.0.2.10',
   'get_server_ip keeps scalar context behavior');
is_deeply([ get_server_ip($servers[0]) ], [ '192.0.2.10', '192.0.2.11' ],
	  'IPv4 helper reads libvirt address records and excludes IPv6');
is(get_server_ip6($servers[0]), '2001:db8::10',
   'IPv6 helper returns the first address in scalar context');
is_deeply([ get_server_ip6($servers[0]) ], [ '2001:db8::10' ],
	  'IPv6 helper excludes IPv4 addresses');
is_deeply([ get_server_ip($servers[1]), get_server_ip6($servers[1]) ], [ ],
	  'a stopped guest returns no current addresses');

# Theme inventory omits addresses; Virtualmin's two helpers share one lookup.
{
	no warnings qw(redefine once);
	my $lookups = 0;
	local *CompatAdapter::get_domain = sub {
		$lookups++;
		is($_[1], 'uuid-web',
		   'on-demand lookup uses the stable guest ID');
		return $servers[0];
		};
	local *main::get_libvirt = sub { $adapter };
	my $inventory = { id => 'uuid-web' };
	is_deeply(
		[ get_server_ip($inventory), get_server_ip6($inventory) ],
		[ '192.0.2.10', '192.0.2.11', '2001:db8::10' ],
		'Virtualmin receives both address families from minimal inventory');
	is($lookups, 1, 'IPv4 and IPv6 share a single libvirt lookup');
	}
is(get_server_mac($servers[1]), '52:54:00:11:22:33',
   'get_server_mac keeps scalar context behavior');

# Original Cloudmin records and libvirt inventory share mac_addresses.
my $legacy = { mac_addresses => '52:54:00:aa:bb:cc 52:54:00:11:22:33' };
is(get_server_mac($legacy), '52:54:00:aa:bb:cc',
   'get_server_mac accepts the original Cloudmin record field');
is_deeply([ get_server_mac($legacy) ],
	  [ '52:54:00:aa:bb:cc', '52:54:00:11:22:33' ],
	  'get_server_mac preserves all interfaces in list context');
is_deeply([ get_server_mac({ mac_addresses => '' }) ], [ ],
	  'get_server_mac returns no addresses for a guest without interfaces');

# Status checks refresh the caller's record rather than only returning a flag.
my $stale = { 'id' => 'uuid-web', 'active' => 0 };
ok(check_server_status($stale, 0, 0, undef, $adapter),
   'check_server_status reports an active domain');
is($stale->{'name'}, 'web-01', 'check_server_status refreshes the record');

# The KVM inventory entry point keeps its array-reference return shape.
my $instances = list_kvm_instances(undef, $adapter);
is(ref($instances), 'ARRAY', 'list_kvm_instances returns an array reference');
is(scalar(@$instances), 2, 'list_kvm_instances uses libvirt discovery');

# Themes and Webmin's LVM module still call these Cloudmin 9 functions.
ok(scalar(can_action(undef, 'global')),
   'can_action treats every user as the master administrator');
is_deeply([ can_action(undef, 'global') ], [ 1, undef ],
	  'the theme master admin check keeps list-context semantics');
is_deeply([ can_action($servers[0], 'delete') ], [ 1, undef ],
	  'can_action returns the allowed flag and no error in list context');
my $parent = get_parent_server($servers[0]);
is($parent->{'id'}, '0',
   'get_parent_server reports the local host by its Cloudmin 9 ID');
is($parent->{'host'}, 'kvm1.example.test',
   'get_parent_server names the local host');
is(get_parent_server(undef), undef,
   'get_parent_server has no host for a missing guest');

# The image compatibility API keeps the legacy catalogue function name while
# filtering assets for the requested KVM host architecture.
my @images = list_available_server_images('aarch64');
ok(@images && !grep({ $_->{'architecture'} ne 'aarch64' } @images),
   'available images are filtered for ARM64 hosts');
is($images[0]->{'architecture'}, 'aarch64',
   'image records expose the selected architecture');
is(get_available_server_image('almalinux-10', 'aarch64')->{'format'},
   'qcow2', 'an available image can be selected by stable ID');
my @search = search_available_server_images('ubuntu 24.04 arm64', 'aarch64');
is(scalar(@search), 1, 'image search recognizes common architecture aliases');
is($search[0]->{'id'}, 'ubuntu-24.04', 'image search returns expected record');

# Catalogue display filtering leaves the architecture-aware picker unchanged.
{
	no warnings qw(redefine once);
	# get_host_image_architecture() fixes the simulated host to ARM64.
	local *main::get_host_image_architecture = sub { 'aarch64' };
	# get_storage_info() avoids contacting real storage services.
	local *main::get_storage_info = sub { { pools => [ ] } };
	# get_image_sizes() supplies a cache without starting size lookups.
	local *main::get_image_sizes = sub { bless({ },
						   'CatalogueSizeFixture') };
	# CatalogueSizeFixture::get(self, entry) reports no cached size.
	local *CatalogueSizeFixture::get = sub { { } };
	# An explicit No lists other architectures for catalogue administration.
	local $config{'catalogue_host_arch'} = 0;
	my $all = get_images_info();
	ok(
		grep(
			{ $_->{'architecture'} eq 'x86_64' } @{
				$all->{'catalogue_entries'}}),
		'disabling the filter includes other architectures');
	# Filtering the table must preserve picker choices and catalogue totals.
	$config{'catalogue_host_arch'} = 1;
	my $host = get_images_info();
	ok(@{$host->{'catalogue_entries'}} &&
	   !grep(
		   { $_->{'architecture'} ne 'aarch64' } @{
				$host->{'catalogue_entries'}}),
	   'configured catalogue includes only the host architecture');
	is_deeply($host->{'images'}, $all->{'images'},
		  'catalogue filtering does not change import choices');
	is($host->{'counts'}->{'catalogue'}, $all->{'counts'}->{'catalogue'},
	   'catalogue total still counts all entries');
	# An absent setting must default to the same host architecture as Yes.
	delete($config{'catalogue_host_arch'});
	is_deeply(get_images_info()->{'catalogue_entries'},
		  $host->{'catalogue_entries'},
		  'an absent setting defaults to the host architecture');
	}

# Catalogue provenance follows the image through request preparation.
{
	no warnings qw(redefine once);
	local *main::get_images_info =
		sub { return { pools => [ { id => 'fixture',
					    name => 'default' } ] }; };
	foreach my $origin (qw(bundled custom)) {
		local *main::get_available_server_image = sub {
			return { id => 'fixture', name => 'Fixture',
				 format => 'qcow2',
				 url => 'https://example.test/image.qcow2',
				 checksum_url => 'https://example.test/SUMS',
				 checksum_algorithm => 'sha512',
				 catalogue_origin => $origin };
			};
		my $request = prepare_image_import({ pool => 'fixture',
						     install_type => 'download',
						     id => 'fixture' });
		is($request->{'checksum_source'},
		   $origin eq 'bundled' ? 'vendor' : 'catalogue',
		   "$origin checksum source is accurate");
		is($request->{'checksum_algorithm'}, 'sha512',
		   'selected checksum algorithm is retained');
		}
	}
done_testing();
