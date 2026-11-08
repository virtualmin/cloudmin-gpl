#!/usr/bin/perl
# clone-network-fixture.pl create|cleanup
# Create test networks through Cloudmin and remove only finished fixture jobs.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP qw(decode_json encode_json);

BEGIN
{
# Network mutations run only on the authorized Linux fixture controller.
die "Authorized Linux test host as root only\n" unless $^O eq 'linux' &&
	$< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$Bin/../..") or die $!;
$0 = abs_path('./api.pl');
}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
my $action = shift(@ARGV);
my $in = decode_json(do { local $/; <STDIN> });
die "Invalid fixture prefix\n"
	unless ($in->{'prefix'} || '') =~ /\Acm-clone-net-[a-f0-9]{8}\z/;
if ($action eq 'create') {
	# Exercise the production network validator and libvirt writer.
	my $expected =
		'cn'.substr($in->{'prefix'},
			    -6).'-'.substr($in->{'network'}->{'mode'}, 0, 1);
	die "Unrelated network\n"
		unless $in->{'network'}->{'name'} eq $expected;
	print encode_json({ name =>
				    get_network_service(1)->create($in->{'network'}) }), "\n";
	}
elsif ($action eq 'cleanup') {
	# Do not remove history until workers, guests and
	# their storage are gone.
	my $jobs = get_vm_jobs();
	foreach my $id (@{$in->{'jobs'}}) {
		my $job = $jobs->get($id) || next;
		die "Unrelated or active job\n" unless
			($job->{'request'}->{'name'} ||
			 '') =~ /\A\Q$in->{'prefix'}\E-[a-z0-9-]+\z/ &&
			($job->{'request'}->{'operation'} || '') eq 'clone' &&
			$job->{'state'} =~ /\A(?:complete|failed|cancelled)\z/ &&
			!$job->{'cleanup_pending'} && !$jobs->busy($id);
		die "Fixture guest still exists\n"
			if get_libvirt(1)->find_domain(
				$job->{'request'}->{'uuid'});
		foreach my $volume ( @{$job->{'resources'}->{'volumes'} || [ ]},
				     map { $job->{'resources'}->{$_} || () } qw(seed nvram) ) {
			die "Fixture volume still exists\n"
				if $volume->{'path'} && -e $volume->{'path'};
			}
		$jobs->write_data(
			sub { $_[0]->do('DELETE FROM jobs WHERE id = ?', undef,
					$id); });
		}
	print "{}\n";
	}
else {
	# Reject unknown commands instead of treating them as cleanup requests.
	die "Choose create or cleanup\n";
	}
