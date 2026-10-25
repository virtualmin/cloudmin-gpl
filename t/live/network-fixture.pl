#!/usr/bin/perl
# network-fixture.pl action [bridge] [interface-or-creation-journal]
# Actions: inventory, review, begin, status, assert-restored, confirm, rollback,
# or restore-fixture (cleanup of the named cmtestbr fixture only).
# The last input is an Ethernet interface except for restore-fixture, which
# accepts an optional original creation journal instead of the current journal.
# Exercises the production controller on a disposable Linux host. No fixture
# credentials or private network backup contents are printed.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
BEGIN {
	die "Disposable Linux host as root only\n" unless ($^O eq 'linux' && $< == 0);
	$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
	$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$FindBin::Bin/../..") || die $!;
	$0 = abs_path("$FindBin::Bin/../../network-worker.pl");
	}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
our ($remote_user, $error_must_die);
$remote_user = 'root';
$error_must_die = 1;
my ($action, $name, $source) = @ARGV;
my $host = get_host_network();
# Read combined network and bridge inventory without making changes.
if ($action eq 'inventory') {
	print convert_to_json(get_network_service()->inventory(), 0, 1);
	}
# Return the proposed bridge change without private backup contents.
elsif ($action eq 'review') {
	my $p = get_network_service()->prepare_bridge($name, $source);
	print convert_to_json({ map { $_ => $p->{$_} } qw(name source mode management addresses revision confirm_timeout) }, 0, 1);
	}
# Submit the reviewed bridge conversion through the signed controller.
elsif ($action eq 'begin') {
	my $p = $host->prepare($name, $source);
	change_network('bridge', { name => $name, source => $source, revision => $p->{'revision'},
		token => get_image_jobs()->form_token('root') });
	print convert_to_json($host->public_state(), 0, 1);
	}
# Expose only the public recovery state to the test driver.
elsif ($action eq 'status') {
	print convert_to_json($host->public_state(), 0, 1);
	}
# Compare restored files with the journal after automatic recovery.
elsif ($action eq 'assert-restored') {
	my $p = $host->read_state() || die "No transaction\n";
	die "Recovery did not complete\n" unless ($p->{'state'} eq 'rolled_back');
	foreach my $path (keys %{$p->{'files'}}) {
		my $file = $p->{'files'}->{$path};
		# Pre-existing files must regain their exact saved contents.
		if ($file) {
			die "Contents differ: $path\n" unless (read_file_contents($path) eq $file->{'content'});
			}
		# Files created by the conversion must be removed during rollback.
		else { die "New configuration remains: $path\n" if (-e $path); }
		}
	print "Exact saved configuration restored\n";
	}
# Keep the pending settings through the normal confirmation action.
elsif ($action eq 'confirm') {
	my $p = $host->public_state();
	change_network('confirm', { id => $p->{'id'}, token => get_image_jobs()->form_token('root') });
	print convert_to_json($host->public_state(), 0, 1);
	}
elsif ($action eq 'rollback') {
	# Only the pending transaction can be restored through this helper.
	$host->rollback();
	print convert_to_json($host->public_state(), 0, 1);
	}
elsif ($action eq 'restore-fixture') {
	# Cleanup can undo confirmed creation or use its backup after removal tests.
	my $p = $source ? convert_from_json(read_file_contents($source), 1) : $host->read_state();
	# Refuse cleanup when neither journal source supplies a transaction.
	die "No fixture transaction\n" if (!$p);
	# This helper may recover only the explicitly named disposable fixture.
	die "Not the requested test bridge\n" unless ($name eq 'cmtestbr' && $p->{'name'} eq $name);
	# A removal backup would recreate the bridge instead of cleaning it up.
	die "Cleanup requires the original creation journal\n" if (($p->{'operation'} || '') eq 'remove');
	$p->{'state'} = 'confirm';
	$host->write_state($p);
	$host->rollback();
	print convert_to_json($host->public_state(), 0, 1);
	}
# Reject actions outside this fixture interface.
else { die "Unknown fixture action\n"; }
