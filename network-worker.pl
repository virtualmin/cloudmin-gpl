#!/usr/bin/perl
# network-worker.pl apply|rollback|boot
# Independent systemd entry point for bridge changes and unconfirmed boot recovery.
use strict;
use warnings;
use FindBin qw($Bin);
BEGIN {
	die "Run on the Cloudmin Linux host as root\n" unless ($^O eq 'linux' && $< == 0);
	$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
	$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
	chdir($FindBin::Bin) || die $!;
	}
our ($remote_user, $error_must_die);
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
my $action = shift(@ARGV) || '';
die "Invalid network worker action\n" if ($action !~ /\A(?:apply|rollback|boot)\z/);
$error_must_die = 1;
# Use the journal owner for audit records from this independent process.
my $host = get_host_network();
my $state = $host->read_state() || exit;
$remote_user = $state->{'owner'} || 'root';
my $ok = eval {
	# Apply only the currently armed transaction and log an actual change.
	if ($action eq 'apply') {
		my $name = $host->apply();
		webmin_log('applied', 'network', $state->{'id'}, { name => $name }) if ($name);
		}
	# Both timeout and boot recovery restore the same saved configuration.
	else {
		my $name = $host->rollback($action eq 'boot');
		webmin_log('rollback', 'network', $state->{'id'}, { name => $name }) if ($name);
		}
	1;
	};
# Retain the failed step in the pending journal for recovery and reporting.
if (!$ok) {
	my $error = "$@";
	# Record diagnostics before systemd's independent recovery service runs.
	get_vm_jobs()->lock('host-network', sub {
		my $p = $host->pending() || return;
		$p->{'error'} = $error;
		$host->write_state($p);
		});
	webmin_log('failed', 'network', $state->{'id'}, { name => $state->{'name'}, error => $error });
	die $error;
	}
