#!/usr/bin/perl
# backup-transfer.pl request-file
# Exercises isolated transfers using a private, VM-local fixture request.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);

BEGIN
{
die "Run on a Linux test host as root\n" if ($^O ne 'linux' || $<);
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin'; $ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
$0 = abs_path("$Bin/../../api.pl");
chdir("$Bin/../..") or die $!;
}
require './server-manager-lib.pl';
use Digest::SHA;
my $input = WebminCore::convert_from_json(read_file_contents($ARGV[0]));
my ($target, $file, $dir) = @$input{qw(target file directory)};
# Browser fixtures need the real trust path without creating an approval.
if (($input->{'operation'} || '') eq 'trust_path') {
	print Cloudmin::BackupSSH::path($target); exit;
	}
# Keep fixture approvals separate from real backup destinations.
$Cloudmin::BackupSSH::directory = "$dir/trust";
@Cloudmin::BackupSSH::known_files = ("$dir/known");
# Probe the fixture without saving its candidate keys.
if (($input->{'operation'} || '') eq 'check') {
	print convert_to_json(Cloudmin::BackupSSH::check($target)); exit;
	}
# Approve exactly the fingerprints returned by the preceding fixture probe.
if (($input->{'operation'} || '') eq 'approve') {
	print convert_to_json(Cloudmin::BackupSSH::approve($target,
							   @$input{qw(previous proposed)})); exit;
	}
# Test unattended refusal before starting an actual transfer.
if (($input->{'operation'} || '') eq 'preflight') {
	Cloudmin::BackupTransport::preflight($target, 0); exit;
	}
# Exercise real isolated upload, download and deletion with byte comparison.
my $name = 'cloudmin-transfer-fixture.tar';
Cloudmin::BackupTransport::transfer('put', $target, $name, $file);
Cloudmin::BackupTransport::transfer('get', $target, $name, "$dir/download");

# checksum(path) streams a fixture file into a SHA-256 digest.
sub checksum
{
open(my $f, '<', $_[0]) or
	die $!; return Digest::SHA->new(256)->addfile($f)->hexdigest();
}
die "Remote round trip changed archive bytes\n"
	if (checksum($file) ne checksum("$dir/download"));
Cloudmin::BackupTransport::transfer('delete', $target, $name, "$dir/download");
unlink("$dir/download");
my $missing =
	eval { Cloudmin::BackupTransport::transfer('get', $target, $name,
						   "$dir/missing"); 1 };
die "Deleted remote archive still exists\n" if ($missing);
print "$target->{mode}: upload, download, checksum, delete and missing-file checks passed\n";
