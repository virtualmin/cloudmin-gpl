#!/usr/bin/perl
# backup-fixture-cleanup.pl uuid removes private data for a finished
# test fixture.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);

BEGIN
{
die "Run on a Linux test host as root\n" if ($^O ne 'linux' || $<);
$ENV{WEBMIN_CONFIG} = '/etc/webmin'; $ENV{WEBMIN_VAR} =
	'/var/webmin'; $ENV{REMOTE_USER} = 'root';
$0 = abs_path("$Bin/../../api.pl"); chdir("$Bin/../..") or die $!;
}
require './server-manager-lib.pl';
my $uuid = $ARGV[0]; my $service = get_backup_service();
die 'Invalid fixture UUID'
	if $uuid !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/;
# Match this fixture through either its source request or inspected manifest.
my @jobs =
	grep { ($_->{request}->{uuid} || '') eq $uuid ||
		($_->{resources}->{manifest}->{uuid} ||
		 '') eq $uuid } @{get_vm_jobs()->list()};
# Validate every match before deleting anything; unfinished recovery keeps data.
foreach my $job (@jobs) {
	my $name = $job->{resources}->{manifest}->{name} ||
		   $job->{request}->{name};
	die 'Not a backup fixture' if $name !~ /^cloudmin-backup-test-/;
	die 'Fixture still running or needs recovery'
		if $job->{cleanup_pending} ||
		$job->{state} !~ /^(complete|failed|cancelled)$/;
	}
# Remove only private backup records and staging; durable job history remains.
foreach my $job (@jobs) {
	$service->clean_work($job->{id});
	unlink($service->directory()."/$job->{id}.json");
	}
print "Fixture backup records and inspection cache removed\n";
