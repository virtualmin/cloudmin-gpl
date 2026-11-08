#!/usr/bin/perl
# clone-fixture.pl fail|cancel|interrupt|cleanup
# Fault injection for check-clones.py and journal cleanup for clone live tests.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP qw(decode_json encode_json);
use POSIX ();

BEGIN
{
# Load Webmin only on the Linux fixture controller with its normal root paths.
die "Authorized Linux test host as root only\n" unless $^O eq 'linux' &&
	$< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$Bin/../..") or die $!;
$0 = abs_path('./api.pl');
}
require './server-manager-lib.pl';
require './lib/Cloudmin/Clones.pm';
{
	package CloneFixtureFailure;
	our @ISA = ('Cloudmin::Clones');

	# worker_task(self, id, task, request, [options...])
	# faults after a real copy.

	sub worker_task
	{
	my ($self, $id, $task, @rest) = @_;
	if ($task eq 'inspect') {
		# The first inspection occurs after allocating
		# a destination volume.
		if ($self->{'fixture_interrupt'}) {
			# Exit without unwinding the worker, as
			# after a controller crash.
			print JSON::PP::encode_json(
				main::get_public_vm_job($self->{'jobs'}->get(
					$id))),
				"\n";
			STDOUT->flush();
			POSIX::_exit(0);
			}
		$self->{'jobs'}->update($id, sub { $_[0]->{'cancel'} = 1 })
			if ($self->{'fixture_cancel'});
		die "Fixture interruption after disk copy\n";
		}
	return $self->SUPER::worker_task($id, $task, @rest);
	}

	# release_source(self, id, adapter) fails restoration except
	# during cancellation.

	sub release_source
	{
	die "Fixture source restoration failure\n"
		unless $_[0]->{'fixture_cancel'};
	return shift->SUPER::release_source(@_);
	}
	}
my $action = shift(@ARGV);
# Keep fixture inputs bounded before decoding controller-side settings.
my $body = do { local $/; <STDIN> };
die "Fixture input too large\n" if length($body) > 131072;
my $input = decode_json($body);
my $jobs = get_vm_jobs();
if ($action eq 'cleanup') {
	# Delete only finished fixture journals after their
	# guests and disks are gone.
	foreach my $id (@{$input->{'jobs'}}) {
		my $job = $jobs->get($id) || next;
		# Accept finished standard or TPM clone fixtures
		# with no worker left.
		die "Unrelated or active fixture job\n" unless $job->{'request'}->{'name'} =~ /\Acloudmin-(?:clone-test-[a-f0-9]{8}-(?:cold|live|shutdown|cancel|failed|interrupt|unchanged)|tpm-test-[a-f0-9]{8}-(?:prepared|unchanged))\z/ &&
			($job->{'request'}->{'operation'} || '') eq 'clone' &&
			$job->{'state'} =~ /\A(?:complete|failed|cancelled)\z/ &&
			!$job->{'cleanup_pending'} && !$jobs->busy($id);
		die "Fixture guest still exists\n"
			if get_libvirt(1)->find_domain(
				$job->{'request'}->{'uuid'});
		foreach my $volume ( @{$job->{'resources'}->{'volumes'} || [ ]},
				     map { $job->{'resources'}->{$_} || () } qw(seed nvram) ) {
			die "Fixture storage still exists\n"
				if $volume->{'path'} && -e $volume->{'path'};
			}
		# Keep the journal if TPM cleanup still needs
		# its recorded ownership.
		die "Fixture TPM still exists\n"
			if $job->{'resources'}->{'tpm'} &&
			-d Cloudmin::TPM::path($job->{'request'}->{'uuid'});
		$jobs->write_data(
			sub { $_[0]->do('DELETE FROM jobs WHERE id = ?', undef,
					$id); });
		}
	print "{}\n";
	exit;
	}
die "Unknown fixture action\n"
	unless $action =~ /\A(?:fail|cancel|interrupt)\z/;
# Validate a fixture-owned source and reserve it through normal job submission.
my $service = get_clone_service();
my $choices = $service->choices($input->{'id'});
die "Unrelated source\n"
	unless $choices->{'name'} =~ /\Acloudmin-clone-test-[a-f0-9]{8}\z/;
$input->{'name'} = $choices->{'name'}.'-'.($action eq 'fail'
	? 'failed'
	: $action);
$input->{'revision'} = $choices->{'revision'};
my $id = substr(Cloudmin::Images::generate_id(), 0, 32);
my $request = $service->prepare($input, $id);
$jobs->lock('create-host', sub {
	$jobs->assert_guest_available($input->{'id'});
	$jobs->submit($id, 'root', 'vm:'.$request->{'name'}, $request);
	});
bless($service, 'CloneFixtureFailure');
# Inject the selected fault without changing production worker implementation.
$service->{'fixture_cancel'} = $action eq 'cancel';
$service->{'fixture_interrupt'} = $action eq 'interrupt';
$service->run($id);
print encode_json(get_public_vm_job($jobs->get($id))), "\n";
