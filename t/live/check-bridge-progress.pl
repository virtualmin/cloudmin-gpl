#!/usr/bin/perl
# check-bridge-progress.pl module-root [host-network-library]
# Checks recovery progress with a private journal and a harmless systemd worker.
# host-network-library defaults to the installed module's implementation.
use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;

# This fixture starts a systemd unit; it must run on the Linux test host.
die "Run on the Linux test host as root\n" unless ($^O eq 'linux' && $< == 0);
my ($module, $library) = @ARGV;
# Use an explicit installation so separately uploaded fixtures load its context.
die "Pass the installed Cloudmin module directory\n"
	unless ($module && -d $module);
$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir($module) or die $!;
# Resolve Webmin's module context even when this fixture is uploaded separately.
$0 = "$module/network-worker.pl";
require './server-manager-lib.pl';
require($library || "$module/lib/Cloudmin/HostNetwork.pm");

{
	package ProgressHost;
	our @ISA = ('Cloudmin::HostNetwork');

	# command(self, argv, [quiet], [safe]) redirects recovery queries to the
	# test unit. Other commands run unchanged.
	sub command
	{
	my ($self, $argv, @flags) = @_;
	my @args = map { $_ eq 'cloudmin-network-rollback.service'
		? $self->{'test_unit'}
		: $_ } @$argv;
	return $self->SUPER::command(\@args, @flags);
	}
	}

# Simulate an earlier failure without touching the real transaction journal.
my $dir = tempdir('cloudmin-bridge-progress.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $unit = 'cloudmin-progress-test-'.time().'-'.$$.'.service';
my $host = ProgressHost->new(directory => $dir, test_unit => $unit);
my $record =
	{ id => 'test', name => 'fixture', source => 'unused', owner => 'root',
	  state => 'rollback_failed',
	  error => 'Previous address is missing',
	  files => { } };
$host->write_state($record);
my $ok = eval {
	# A queued or running recovery worker must hide the previous failure.
	$host->command([ 'systemd-run', '--quiet', '--no-block',
			 '--unit='.$unit,
			 '--property=Type=oneshot', '/usr/bin/sleep', '3' ]);
	my $public = $host->public_state();
	is($public->{'state'}, 'rolling_back',
	   'accepted recovery reports progress immediately');
	ok(!exists($public->{'error'}),
	   'running recovery hides the prior error');
	ok(!exists($public->{'files'}),
	   'running recovery reveals no backup data');
	is($host->read_state()->{'state'}, 'rollback_failed',
	   'status does not rewrite the journal');
	# A stopped worker must expose the failure again
	# rather than spin forever.
	for (1 .. 10) {
		sleep(1);
		$public = $host->public_state();
		# Stop polling as soon as the harmless worker exits.
		last if ($public->{'state'} ne 'rolling_back');
		}
	is($public->{'state'}, 'rollback_failed',
	   'stopped recovery allows another attempt');
	is($public->{'error'}, $record->{'error'},
	   'stopped recovery retains its diagnostic');
	# A completed journal must win over any stale worker
	# progress indication.
	$host->write_state({ %$record, state => 'rolled_back',
			     error => undef });
	is($host->public_state()->{'state'}, 'rolled_back',
	   'successful recovery keeps its final result');
	1;
	};
my $error = $@;
# Remove only the harmless fixture unit; the host recovery service is untouched.
eval { $host->command([ 'systemctl', 'stop', $unit ]); };
eval { $host->command([ 'systemctl', 'reset-failed', $unit ]); };
# Report fixture exceptions only after attempting to remove its unit.
die $error if (!$ok);
done_testing();
