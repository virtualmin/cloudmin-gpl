#!/usr/bin/perl
# check-iso-install.pl module-directory [alpine-iso-path]
# Exercise ISO import, creation, media changes and snapshot restore on a Linux
# test host. All storage and domains belong to this fixture's unique pool.
# By default, use nonbootable test media. Supply a checksum-verified Alpine
# virt ISO for the host architecture to also install and boot a real OS.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use File::Copy qw(copy);
use FindBin qw($Bin);
use Digest::SHA qw(sha256_hex);
my $module;
# Load the installed controller and its configuration only on a test VM.
BEGIN {
    die "Run on an authorized Linux test host as root\n" unless $^O eq 'linux' && $< == 0;
    $module = shift(@ARGV) || die "Supply the installed Cloudmin module directory\n";
    $ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
    $ENV{'WEBMIN_VAR'} = '/var/webmin';
    $ENV{'REMOTE_USER'} = 'root';
    chdir($module) || die $!;
    $0 = "$module/api.pl";
}
require './server-manager-lib.pl';
my $alpine_iso = shift(@ARGV);
die "Supply an absolute path to a readable Alpine virt ISO\n"
    if defined($alpine_iso) && ($alpine_iso !~ m{\A/} || !-f $alpine_iso);
# Keep identifiers available to teardown even when setup or a job fails.
my ($pool, $directory, $work, $creation, $uuid, $import);
my $adapter = get_libvirt(1);
my $images = get_image_jobs();
my $jobs = get_vm_jobs();
my $name = 'cloudmin-iso-check-'.substr(Cloudmin::Images::generate_id(), 0, 12);

# check(condition, message) stops at the first failure and retains its cause.
sub check {
    die "FAILED: $_[1]\n" unless $_[0];
    print "PASS: $_[1]\n";
}

# api(action, [fields]) uses controller validation and a fresh signed token.
# Omitted fields supply an empty request, as used by the options action.
sub api {
    my ($action, $fields) = @_;
    return call_vm_api(1, $action, { %{$fields || {}}, token => $images->form_token('root') });
}

# change(action, [fields]) submits and checks a synchronous fixture job.
sub change {
    my ($action, $fields) = @_;
    my $job = api($action, $fields);
    my $done = $jobs->get($job->{'id'});
    die "$action failed: ".($done->{'error'} || $done->{'state'})."\n"
        unless $done->{'state'} eq 'complete';
    return $done;
}

# edit_media(volume) inserts fixture media; an empty volume name ejects it.
# Fetch the current hardware revision before each change.
sub edit_media {
    my ($volume) = @_;
    my $settings = api('settings', {id => $uuid});
    my ($cd) = grep { $_->{'device'} eq 'cdrom' } @{$settings->{'disks'}};
    return change('change_media', {id => $uuid, revision => $settings->{'revision'},
        target => $cd->{'target'}, pool => $pool->get_uuid_string(), volume => $volume});
}

# Run the real workers synchronously so teardown never races a background job.
my $ok = eval {
    no warnings qw(redefine once);
    # spawn(store, id) executes the requested job before the API call returns.
    local *Cloudmin::Jobs::spawn = sub { run_vm_job($_[1]); };
    my $log_call = \&Cloudmin::Libvirt::log_call;
    my $import_format;
    # log_call(method, details) records the format and forwards normal logging.
    local *Cloudmin::Libvirt::log_call = sub {
        # Record the format requested from libvirt; a pool refresh may later
        # identify the raw bytes as ISO media in its inventory.
        $import_format = $_[1]->{'format'} if $_[0] eq 'Sys::Virt::StoragePool::create_volume';
        return $log_call->(@_);
    };
    # Isolate all imported media, guest disks and snapshot overlays in one pool.
    $directory = tempdir($name.'-XXXXXX', DIR => '/var/lib/libvirt/images');
    chmod(0755, $directory) || die $!;
    $pool = $adapter->connect()->define_storage_pool(
        "<pool type='dir'><name>$name</name><target><path>$directory</path></target></pool>");
    $pool->create();
    # Keep the import source readable by the unprivileged worker.
    $work = tempdir($name.'-XXXXXX', DIR => '/var/tmp');
    chmod(0755, $work) || die $!;
    if ($alpine_iso) {
        # Use vendor media without changing its bootloader or adding seed data.
        copy($alpine_iso, "$work/installer.iso") || die $!;
    }
    else {
        # The fast lifecycle check does not need a bootable operating system.
        mkdir("$work/content", 0755) || die $!;
        open(my $file, '>', "$work/content/README.txt") || die $!;
        print $file "Cloudmin ISO test media. No operating system.\n";
        close($file);
        system('/usr/bin/xorriso', '-as', 'mkisofs', '-quiet', '-V', 'CLOUDMIN_TEST',
            '-o', "$work/installer.iso", "$work/content") == 0 || die "Cannot build ISO fixture\n";
    }
    chmod(0644, "$work/installer.iso") || die $!;
    # Import through the real controller and worker with a known SHA-256 digest.
    open(my $iso, '<', "$work/installer.iso") || die $!;
    binmode($iso);
    my $digest = Digest::SHA->new(256)->addfile($iso)->hexdigest();
    close($iso);
    my $request = prepare_image_import({install_type => 'local', format => 'iso',
        path => "$work/installer.iso", pool => $pool->get_uuid_string(), sha256 => $digest});
    $import = $images->create('root', $images->form_token('root'), $request);
    $images->run($import->{'id'});
    $import = $images->get($import->{'id'});
    # Verify the ISO type survives import while libvirt receives raw capacity.
    check($import->{'state'} eq 'ready', 'ISO import completed: '.($import->{'error'} || 'ready'));
    check($import->{'verified'} eq 'sha256' && $import->{'checksum_digest'} eq $digest,
        'ISO import verified its checksum');
    check($import->{'volume'} =~ /\.iso\z/ && $import->{'format'} eq 'iso', 'ISO identity and suffix retained');
    my (undef, $volume) = $adapter->volume(@$import{qw(pool volume volume_key)});
    my $vxml = Cloudmin::Libvirt::parse_xml_document($volume->get_xml_description(0));
    check($import_format eq 'raw', 'import requests a raw libvirt volume');
    check($vxml->findvalue('/volume/target/format/@type') =~ /\A(?:raw|iso)\z/,
        'storage inventory recognizes raw or ISO media');
    # Create a small installer VM without cloud-init credentials or setup media.
    my $options = api('options');
    my ($network) = grep { $_->{'type'} eq 'network' } @{$options->{'networks'}};
    die "Fixture needs an active virtual network\n" unless $network;
    $creation = api('create', {name => $name, install_source => 'iso', image => $import->{'id'},
        pool => $pool->get_uuid_string(), network => $network->{'key'},
        cpus => 1, memory_mib => 512, disk_gib => $alpine_iso ? 2 : 1,
        start => 1, autostart => 0});
    my $job = $jobs->get($creation->{'id'});
    check($job->{'state'} eq 'complete', 'installer VM created: '.($job->{'error'} || 'complete'));
    $uuid = $job->{'request'}->{'uuid'};
    check(!$job->{'resources'}->{'seed'} && !$job->{'resources'}->{'ssh_key'}, 'no cloud-init media or host key');
    # QEMU startup and XML checks cover attachment, not an OS installation.
    my $domain = $adapter->find_domain($uuid);
    check($domain->is_active(), 'QEMU starts with the ISO attached');
    my $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(2));
    check($doc->findvalue('/domain/os/boot[1]/@dev') eq 'cdrom', 'CD/DVD is the first boot device');
    check($doc->findvalue('/domain/devices/disk[@device="cdrom"]/source/@file') eq $import->{'volume_path'},
        'drive mounts the shared imported ISO');
    check($doc->exists('/domain/devices/disk[@device="cdrom"]/readonly'), 'ISO drive is read-only');
    check(0+$doc->findvalue('count(/domain/devices/disk[@device="disk"])') == 1, 'one independent system disk');
    if ($alpine_iso) {
        # Install through the serial console, then boot with the drive empty.
        system('python3', "$Bin/iso-alpine-console.py", $uuid, $name, 'install') == 0
            || die "Alpine installation failed\n";
        edit_media('');
        api('start', {id => $uuid});
        system('python3', "$Bin/iso-alpine-console.py", $uuid, $name, 'verify') == 0
            || die "Installed Alpine did not boot from disk\n";
        check(1, 'Alpine installed and booted with the ISO ejected');
        # Restore the original attachment for the remaining snapshot checks.
        edit_media($import->{'volume'});
        api('start', {id => $uuid});
    }
    # Editing must offer ISO media only for the removable drive, not cloning.
    my $settings = api('settings', {id => $uuid});
    check(!grep({ $_->{'id'} eq $import->{'id'} } @{$settings->{'images'}}), 'ISO excluded from writable clone choices');

    # A stopped snapshot needs no guest agent; later swaps exercise live QEMU.
    api('force_off', {id => $uuid, confirm => 1});
    my $history = api('snapshots', {id => $uuid});
    my $point = change('snapshot_create', {id => $uuid, revision => $history->{'revision'}, label => 'Before media swap'});
    my $snapshot = $point->{'request'}->{'snapshot'};
    api('start', {id => $uuid});
    edit_media('');
    edit_media($import->{'volume'});
    check(scalar(() = $domain->list_all_snapshots(0)) == 1, 'live media swaps preserve the snapshot');
    # Restoring the stopped snapshot must recover its original media contents.
    api('force_off', {id => $uuid, confirm => 1});
    edit_media('');
    $history = api('snapshots', {id => $uuid});
    change('snapshot_restore', {id => $uuid, revision => $history->{'revision'}, snapshot => $snapshot, confirm => 1});
    $doc = Cloudmin::Libvirt::parse_xml_document($domain->get_xml_description(2));
    my $restored_media = $doc->findvalue('/domain/devices/disk[@device="cdrom"]/source/@file');
    my $restored_format = $doc->findvalue('/domain/devices/disk[@device="cdrom"]/driver/@type');
    # Libvirt may restore read-only media through a fresh QCOW2 overlay.
    # Compare the presented bytes rather than requiring the old filename.
    check($doc->exists('/domain/devices/disk[@device="cdrom"]/readonly'), 'restored media stays read-only');
    check(system('/usr/bin/qemu-img', 'compare', '-f', $restored_format, '-F', 'raw',
        $restored_media, $import->{'volume_path'}) == 0, 'snapshot restore preserves the ISO contents');
    # Delete history through the API, then verify the shared ISO is unchanged.
    $history = api('snapshots', {id => $uuid});
    change('snapshot_delete', {id => $uuid, revision => $history->{'revision'}, snapshot => $snapshot, confirm => 1});
    check(scalar(() = $domain->list_all_snapshots(0)) == 0, 'snapshot deletion succeeds after media swaps and restore');
    open(my $source, '<', $import->{'volume_path'}) || die $!;
    binmode($source);
    check(Digest::SHA->new(256)->addfile($source)->hexdigest() eq $digest,
        'shared installer ISO is unchanged after the full lifecycle');
    close($source);
    1;
};
my $error = $@;

# Cleanup trusts only this run's generated pool and the creation ownership marker.
my $clean = eval {
    if ($creation) {
        # Recover the UUID from the job if setup failed before recording it.
        my $job = $jobs->get($creation->{'id'});
        die "Fixture worker is still active\n" if $jobs->busy($creation->{'id'});
        $uuid ||= $job->{'request'}->{'uuid'};
        my $domain = $adapter->find_domain($uuid);
        if ($domain) {
            # Remove only the fixture guest and its libvirt snapshot metadata.
            die "Fixture guest ownership changed\n" unless $domain->get_name() eq $name;
            $domain->destroy() if $domain->is_active();
            $_->delete(2) for $domain->list_all_snapshots(0);
            $adapter->remove_created_guest($uuid, $creation->{'id'});
        }
    }
    if ($pool) {
        # Verify pool ownership before attempting any volume deletion.
        die "Fixture pool ownership changed\n" unless $pool->get_name() eq $name;
        $pool->refresh();
        # Remove leaves before backing files. Stop if a surviving reference
        # belongs outside this run's pool rather than weakening ownership checks.
        my @volumes = $pool->list_all_volumes();
        while (@volumes) {
            my (@kept, $reason);
            for my $v (@volumes) {
                if (eval { Cloudmin::Images::assert_unused(undef, $adapter->connect(), $pool, $v); 1 }) {
                    # Delete unused leaves before their backing files.
                    $v->delete(0);
                }
                else {
                    # Retry after deleting leaves; retain other errors.
                    $reason = $@;
                    push(@kept, $v);
                }
            }
            # No progress means a reference or error needs manual investigation.
            die $reason if @kept == @volumes;
            @volumes = @kept;
        }
        # Mark the imported fixture deleted after its restored overlays are gone.
        $images->remove($import->{'id'}) if $import;
        $pool->destroy();
        $pool->undefine();
    }
    # Remove fixture directories after clearing domains and volume references.
    remove_tree($directory) if $directory;
    remove_tree($work) if $work;
    1;
};
# Report both the original failure and any cleanup error without losing either.
die $error.($clean ? '' : "Cleanup failed: $@") unless $ok && $clean;
print "ISO import, VM creation and snapshot checks passed; fixtures removed\n";
