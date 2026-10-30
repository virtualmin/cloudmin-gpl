#!/usr/bin/perl
# Check template deletion against libvirt without booting a guest or making disks.
use strict;
use warnings;
no warnings 'once';
use FindBin;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use Test::More;
BEGIN {
	# Load installed Webmin only on the selected Linux test host.
	die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
	my $root = $ARGV[0] || abs_path("$FindBin::Bin/../../..");
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$root/server-manager") || die $!;
	$0 = "$root/server-manager/api.pl";
}
require './server-manager-lib.pl';
$main::error_must_die = 1;
$| = 1;

# Keep template settings and jobs separate from the host's saved configuration.
my $work = tempdir('cloudmin-template-delete-XXXXXX', TMPDIR => 1, CLEANUP => 1);
local $main::module_config_directory = $work;
local $main::module_var_directory = $work;
my $store = get_presets();
my $jobs = get_vm_jobs();
my $adapter = get_libvirt(1);
my $connection = $adapter->connect();
my ($gpl, $pro) = map { '0'x31 . $_ } (2, 3);
my $initial = scalar(@{$store->list('template')->{'entries'}});
my $id = substr(Cloudmin::Images::generate_id(), 0, 32);
my $name = 'cloudmin-template-check-'.substr($id, 0, 8);
# Other guests may use the same bundled IDs in the host's real settings.
my $list_domains = \&Cloudmin::Libvirt::list_domains;
no warnings 'redefine';
local *Cloudmin::Libvirt::list_domains = sub {
	# list_domains(self, [strict]) filters inventory to this fixture's name.
	return [grep { $_->{'name'} eq $name } @{$list_domains->(@_)}];
};
my $domain;
my $ok = eval {
	# Pending creation protects its template before any domain exists.
	$jobs->submit($id, 'root', 'vm:'.$name, {name => $name, template => $gpl});
	ok(!eval { $jobs->lock('create-host', sub { $store->update('template', 'delete', [$gpl]); }); 1 },
		'pending creation blocks template deletion');
	like($@, qr/\Q$name\E/, 'refusal names the pending virtual machine');
	$jobs->update($id, sub { $_[0]->{'state'} = 'complete'; });

	# A stopped definition needs no disk, network or running QEMU process.
	my $xml = "<domain type='kvm'><name>$name</name><memory unit='MiB'>32</memory>".
		"<vcpu>1</vcpu><os><type>hvm</type></os><metadata>".
		"<cloudmin:vm xmlns:cloudmin='urn:cloudmin:vm:1'>".
		"<cloudmin:job>$id</cloudmin:job><cloudmin:template>$gpl</cloudmin:template>".
		"</cloudmin:vm></metadata></domain>";
	$domain = $connection->define_domain($xml);
	my $uuid = $domain->get_uuid_string();
	$jobs->update($id, sub { $_[0]->{'request'}->{'uuid'} = $uuid; });
	ok(!$domain->is_active(), 'fixture remains stopped');
	ok(!eval { $jobs->lock('create-host', sub { $store->update('template', 'delete', [$gpl]); }); 1 },
		'stopped domain metadata blocks deletion');
	like($@, qr/\Q$name\E/, 'refusal names the stopped virtual machine');

	# A used template prevents deleting the entire selected batch.
	ok(!eval { $jobs->lock('create-host', sub { $store->update('template', 'delete', [$gpl, $pro]); }); 1 },
		'used template prevents every deletion in the batch');
	is(scalar(@{$store->list('template')->{'entries'}}), $initial, 'refused batch preserves both optional templates');

	# Once the guest is gone, its completed job no longer prevents deletion.
	$domain->undefine();
	undef($domain);
	$store->update('template', 'default', [$gpl]);
	$jobs->lock('create-host', sub { $store->update('template', 'delete', [$gpl, $pro]); });
	my $remaining = get_presets()->list('template');
	is(scalar(@{$remaining->{'entries'}}), $initial - 2, 'both optional templates stay deleted on a fresh read');
	is($remaining->{'default'}, Cloudmin::Presets::default_id(), 'Default Template becomes selected again');
	1;
};
my $error = $@;
# Always remove only this fixture's unstarted domain.
$domain->undefine() if ($domain);
die $error if (!$ok);
done_testing();
