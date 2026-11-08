#!/usr/bin/perl
# job-cleanup-fixture.pl create|status|forget reads JSON parameters on stdin.
# Manages only this test's journal and private temporary provisioning file.
use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);

BEGIN
{
# Resolve installed Webmin only after confirming this is a Linux test host.
die "Run on a Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
my $root = abs_path("$FindBin::Bin/../../..");
chdir("$root/server-manager") || die $!;
$0 = "$root/server-manager/api.pl";
}
require './server-manager-lib.pl';
my $input = convert_from_json(do { local $/; <STDIN> });
my $id = $input->{'id'};
Cloudmin::Jobs::validate_id($id);
my $jobs = get_vm_jobs();
my $action = shift(@ARGV) || '';
# Simulate committed creation without starting a real setup monitor.
if ($action eq 'create') {
	# Restrict journal allocation to this fixture's unique naming scheme.
	die "Not a fixture name\n"
		if $input->{'name'} !~ /\Acloudmin-cleanup-check-[a-f0-9]+\z/;
	my $job = $jobs->submit($id, 'root', 'vm:'.$input->{'name'}, {
		name => $input->{'name'}, uuid => $input->{'uuid'},
		pool => $input->{'pool'}, software => 'none' });
	$jobs->update($id, sub {
		$_[0]->{'state'} = 'running'; $_[0]->{'phase'} =
			'software_boot';
		$_[0]->{'resource'} = 'software:'.$id;
		$_[0]->{'resources'} = { domain => 1, software => 1,
					 disk =>
						 { name => $input->{'disk'},
						   key => $input->{'key'} },
					 software_deadline => time() + 8100 };
		$_[0]->{'events'} =
			[ { step => 'software_boot', state => 'running' } ];
		});
	# Give cleanup a private provisioning file to remove with
	# the journalled disk.
	make_dir("$jobs->{directory}/$id", 0700);
	open(my $fh, '>', "$jobs->{directory}/$id/user-data") || die $!;
	print $fh 'fixture'; close($fh);
	print "Created fixture\n";
	}
else {
	# Never let a status or teardown request address an ordinary user's job.
	my $job = $jobs->get($id) || die "Fixture is missing\n";
	die "Not a fixture job\n"
		if $job->{'request'}->{'name'} !~ /\Acloudmin-cleanup-check-[a-f0-9]+\z/;
	if ($action eq 'status') {
		# Return the production public view used by
		# live cleanup assertions.
		print convert_to_json(get_public_vm_job($job));
		}
	elsif ($action eq 'forget') {
		# No fixture teardown may remove storage while
		# its worker still runs.
		die "Fixture worker still active\n" if $jobs->busy($id);
		my $adapter = get_libvirt(1);
		$adapter->remove_created_guest($job->{'request'}->{'uuid'},
					       $id);
		$adapter->remove_created_volume($job->{'request'}->{'pool'},
						@{$job->{'resources'}->{'disk'}}{qw(name key)});
		get_vm_service()->cleanup_work($id);
		# Forget the journal only after
		# ownership-checked resources are gone.
		$jobs->write_data(
			sub { $_[0]->do('DELETE FROM jobs WHERE id = ?', undef,
					$id); 1 });
		}
	# Unknown actions must never fall through to
	# destructive fixture cleanup.
	else { die "Unknown fixture action\n"; }
	}
