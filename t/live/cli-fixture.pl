#!/usr/bin/perl
# cli-fixture.pl name username Remove only finished CLI fixture journals after
# the fixture guest was deleted.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);

BEGIN
{
die "Run on a disposable Linux host as root\n" unless $^O eq 'linux' && $< == 0;
$ENV{WEBMIN_CONFIG} = '/etc/webmin'; $ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root'; chdir("$Bin/../..") || die $!;
$0 = abs_path('./api.pl');
}
require './server-manager-lib.pl';
# A paired random machine/account name confines cleanup to one fixture run.
my ($name, $username) = @ARGV;
die "Invalid fixture identity\n"
	unless ($name || '') =~ /\Acloudmin-cli-check-([a-f0-9]{8})\z/ &&
	($username || '') eq 'cmcli'.$1;
my $jobs = get_vm_jobs();
die "Fixture guest still exists\n" if get_libvirt(1)->find_domain($name);
# Read candidate journals first; no deletion is allowed while the guest exists.
my $db = $jobs->connect(0);
my $rows = $db->selectall_arrayref('SELECT record FROM jobs', undef);
$db->disconnect();
my @ids;
foreach my $row (@$rows) {
	my $record = convert_from_json($row->[0]);
	# Ignore every job whose requested machine name is outside this fixture.
	next unless ($record->{request}->{name} || '') eq $name;
	# Keep live workers and pending cleanup records for explicit recovery.
	die "Unfinished or unrelated fixture job\n"
		unless $record->{owner} eq 'root' &&
		$record->{state} =~ /\A(?:complete|failed|cancelled)\z/ &&
		!$record->{cleanup_pending} && !$jobs->busy($record->{id});
	# Check fixture-created volumes, leaving shared source images alone.
	foreach my $kind (qw(disk seed)) {
		my $volume = $record->{resources}->{$kind} || next;
		die "Fixture volume still exists\n" if $volume->{path} &&
			-e $volume->{path};
		}
	# Remove private working files only after disk
	# absence has been verified.
	get_vm_service()->cleanup_work($record->{id});
	push(@ids, $record->{id});
	}
# cleanup_records(db) removes verified finished jobs and fixture drafts.
$jobs->write_data(sub {
	my ($db) = @_;
	$db->do('DELETE FROM jobs WHERE id = ?', undef, $_) for @ids;
	# Review drafts use this run's unique guest account,
	# not all root drafts.
	$db->do('DELETE FROM credentials WHERE owner = ? AND username = ?',
		undef, 'root', $username);
	});
print "Fixture journals and password drafts removed\n";
