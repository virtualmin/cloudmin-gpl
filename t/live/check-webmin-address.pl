#!/usr/bin/perl
# Check a running guest's host-side address evidence without
# changing its records.
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/../../lib", "$Bin/../../../webmin", "$Bin/../../..";
use WebminCore;
use Cloudmin::Libvirt;
use Test::More;
require "$Bin/../../cloudmin-webmin-lib.pl";

# Accept only an explicitly selected guest on a Linux test host.
die "Run on a Linux test host as root\n" if ($^O ne 'linux' || $< != 0);
my ($uuid) = @ARGV;
die "Supply a guest UUID\n"
	if (($uuid || '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/);
my $adapter = Cloudmin::Libvirt->new(uri => 'qemu:///system', readonly => 1);
my $vm = $adapter->get_domain($uuid, 1) || die "Guest not found\n";
die "Choose a running guest\n" if (!$vm->{'active'});

# get_libvirt([writable]) ignores write requests and supplies
# a read-only adapter.
no warnings 'redefine';
local *main::get_libvirt = sub { $adapter };
# Require a host lease so this test exercises MAC matching, not agent reports.
my $domain = $adapter->find_domain($uuid);
my @leases = grep { ($_->{'source'} || '') eq 'lease' }
	     @{$adapter->get_domain_addresses($domain, $vm, 1)};
die "Choose a guest with a current host DHCP lease\n" if (!@leases);
for my $lease (@leases) {
	is(vm_webmin_address_source($vm, $lease->{'address'}), 'lease',
	   'actual libvirt lease matches the guest MAC from its domain definition');
	}

# Synthetic changes affect this in-memory record only, never libvirt or Webmin.
my $ip = $leases[0]->{'address'};
{
	local $vm->{'interfaces'} = [ ];
	is(vm_webmin_address_source($vm, $ip), 'unverified',
	   'a lease alone is insufficient without the guest MAC');
	}
{
	local $vm->{'cloudmin'} = { ipv4 => '192.0.2.244/24' };
	is(vm_webmin_address_source($vm, '192.0.2.244'), 'static',
	   'saved static metadata supports guests without leases');
	}
done_testing();
