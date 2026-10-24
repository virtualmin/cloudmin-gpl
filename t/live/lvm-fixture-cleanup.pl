#!/usr/bin/perl
# Remove only completed journals supplied by the LVM lifecycle fixture.
use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
BEGIN {
    die "Run on the disposable Linux host as root\n" if ($^O ne 'linux' || $<);
    $ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
    $ENV{'WEBMIN_VAR'} = '/var/webmin';
    $ENV{'REMOTE_USER'} = 'root';
    chdir("$Bin/../..") or die $!;
    $0 = abs_path('./api.pl');
}
require './server-manager-lib.pl';
my $body = do { local $/; <STDIN> };
die "Fixture input too large\n" if (length($body) > 65536);
my $input = convert_from_json($body);
my $jobs = get_vm_jobs();
my $adapter = get_libvirt(1);
foreach my $id (@{$input->{'jobs'}}) {
    my $job = $jobs->get($id) || next;
    my $r = $job->{'request'};
    # Inspection requests name the archive; its verified manifest names the guest.
    my $name = $r->{'operation'} eq 'backup_inspect'
        ? $job->{'resources'}->{'manifest'}->{'name'} || '' : $r->{'name'} || '';
    die "Unrelated or unfinished fixture job\n" if (
        $name !~ /\Acloudmin-create-check-[a-f0-9]{8}(?:-copy-[a-f0-9]{6})?\z/ ||
        ($r->{'operation'} || '') !~ /\A(?:snapshot_create|snapshot_restore|snapshot_delete|clone|delete|backup|backup_inspect|restore|capture_image|add_disk|grow_disk|detach_disk|attach_disk|delete_disk)\z/ ||
        $job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/ ||
        $job->{'cleanup_pending'} || $jobs->busy($id));
    my $domain = $r->{'uuid'} ? $adapter->find_domain($r->{'uuid'}) : undef;
    die "Fixture copy still exists\n" if ($domain && $r->{'operation'} =~ /\A(?:clone|backup|restore)\z/);
    die "Fixture snapshot still exists\n" if ($domain && $r->{'snapshot'} &&
        Cloudmin::Snapshots::find_snapshot($domain, $r->{'snapshot'}));
    if ($r->{'operation'} =~ /\A(?:backup|backup_inspect|restore)\z/) {
        # Remove completed backup staging and its index before the job journal.
        my $service = get_backup_service();
        $service->clean_work($id);
        my $record = $service->directory()."/$id.json";
        unlink($record) or die $! if (-f $record);
    }
    if ($r->{'operation'} eq 'capture_image') {
        # Reusable images have a separate store that also owns the image volume.
        get_image_jobs()->remove($id) or die "Cannot remove fixture image\n";
    }
    $jobs->write_data(sub { $_[0]->do('DELETE FROM jobs WHERE id = ?', undef, $id); });
}
