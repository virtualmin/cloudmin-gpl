package Cloudmin::CLI;

# Command definitions, API requests and output share one dispatcher.
use strict;
use warnings;
use Getopt::Long ();
use WebminCore qw(convert_to_json convert_from_json);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use Pod::Text ();
use POSIX qw(strftime);
use Scalar::Util qw(blessed);
use Encode qw(decode FB_CROAK);

# option(type, [attributes...]) describes one command-line value.
# Attributes are key/value pairs for validation, API mapping and help.
sub option { return { type => shift, @_ }; }

# creation_options() defines fields shared by creation and prepared clones.
sub creation_options
{
return {
    # Resolve creation choices through the same options used by the web form.
    image => option('s', resolve => 'image', help => 'Imported or catalogue image ID or name'),
    pool => option('s', resolve => 'pool', help => 'Destination storage pool ID or name'),
    template => option('s', resolve => 'template', help => 'Template ID or name'),
    plan => option('s', resolve => 'plan', help => 'Plan ID or name'),
    cpus => option('i', help => 'Number of CPUs'),
    memory => option('size', field => 'memory_mib', unit => 'MiB', help => 'Memory allocation; bare values use MiB'),
    disk => option('size', field => 'disk_gib', unit => 'GiB', help => 'Total disk capacity; bare values use GiB'),
    # Read secrets from files; repeated public keys become one API text field.
    username => option('s', help => 'Initial guest administrator account'),
    'auth-type' => option('s', values => [qw(keys password both)], help => 'Initial login authentication'),
    'password-file' => option('file', field => 'password', secret => 1, help => 'Password file, or - for stdin'),
    'ssh-key' => option('s@', field => 'ssh_keys', join => "\n", help => 'SSH public key; repeat for more keys'),
    'ssh-keys-file' => option('file', field => 'ssh_keys', help => 'File containing SSH public keys'),
    # Power, firmware and identity fields share creation and clone validation.
    network => option('s', resolve => 'network', help => 'Network key, UUID or name, or bridge:name'),
    start => option('yesno', help => 'Start after creation'),
    autostart => option('yesno', help => 'Start when the host boots'),
    firmware => option('s', values => [qw(auto efi bios)], help => 'Guest firmware'),
    hostname => option('s', help => 'Guest hostname; defaults to its name'),
    desc => option('s', field => 'description', help => 'Description'),
    mac => option('s', help => 'Guest MAC address; omitted generates one'),
    # Static addressing is configured in the new guest, not on the host.
    'address-mode' => option('s', values => [qw(dhcp static)], help => 'Guest address configuration'),
    ipv4 => option('s', help => 'Static IPv4 address with prefix'),
    ipv6 => option('s', help => 'Static IPv6 address with prefix'),
    gateway4 => option('s', help => 'IPv4 gateway'),
    gateway6 => option('s', help => 'IPv6 gateway'),
    dns => option('s', help => 'Space- or comma-separated DNS servers'),
    'host-ssh-key' => option('yesno', help => 'Create a managed host SSH key for the guest'),
    'require-fqdn' => option('yesno', help => 'Require a fully qualified hostname'),
};
}

# destination_options() maps CLI destination fields to the API target object.
sub destination_options
{
# Keep ordinary destination fields separate from file-backed credentials.
my %options;
foreach my $field (qw(mode path host user port key_file bucket endpoint region ca_file account project subscription)) {
    my $name = $field; $name =~ tr/_/-/;
    $options{'dest-'.$name} = option($field eq 'port' ? 'i' : 's',
        field => 'target.'.$field, help => 'Backup destination '.$name);
}
$options{'dest-mode'}->{'values'} = [qw(local ssh s3 gcs azure bb dropbox drive)];
# Mark secret file contents for redaction if the controller returns an error.
foreach my $field (qw(password access secret session_token refresh_token)) {
    my $name = $field; $name =~ tr/_/-/;
    $options{'dest-'.$name.'-file'} = option('file', field => 'target.'.$field,
        secret => 1, help => 'Destination '.$name.' file, or - for stdin');
}
return \%options;
}

# commands() returns the ordered command table used by parsing, help and docs.
sub commands
{
my @commands;
# add(name, action, summary, [attributes...]) appends a command definition.
# Its attribute pairs describe selectors, output and follow-up requests.
my $add = sub {
    my ($name, $action, $summary, %attributes) = @_;
    push(@commands, { name => $name, action => $action, summary => $summary,
        options => {}, %attributes });
};
my $creation = creation_options();
# Filter public inventory records; select one exact guest for machine details.
$add->('list-systems', 'machines', 'Lists the virtual machines on this host.',
    group => 'Virtual machines', order => [qw(name id state template plan)],
    options => {
        name => option('s@', filter => 'name', metavar => 'name', help => 'Exact virtual machine name'),
        id => option('s@', filter => 'id', metavar => 'uuid', help => 'Exact virtual machine UUID'),
        state => option('s', filter => 'state', values => [qw(running stopped paused)], help => 'Power state'),
        template => option('s', filter => 'template', metavar => 'ID|name', help => 'Template ID or name'),
        plan => option('s', filter => 'plan', metavar => 'ID|name', help => 'Plan ID or name'),
    }, list => {key => 'name', columns => [qw(name state cpus memory_mib addresses)]});
$add->('get-system', 'settings', 'Shows a virtual machine and its saved settings.',
    group => 'Virtual machines', select => 'machine', summary_action => 'machines');
# Power actions differ in confirmation and waiting: full restart is a job,
# simple state changes are polled, and reboot/reset return on acceptance.
foreach my $item (
    ['start', 'start', 'Starts a stopped virtual machine.', 'Started %s', 'running'],
    ['shutdown', 'shutdown', 'Shuts down a virtual machine cleanly.', 'Shut down %s', 'stopped'],
    ['reboot', 'reboot', 'Requests a guest operating system reboot.', 'Requested reboot for %s'],
    ['pause', 'suspend', 'Pauses a running virtual machine.', 'Paused %s', 'paused'],
    ['unpause', 'resume', 'Resumes a paused virtual machine.', 'Resumed %s', 'running'],
    ['restart', 'power_cycle', 'Shuts down and starts with the saved settings.', 'Restarted %s'],
    ['reset', 'reset', 'Resets virtual hardware immediately.', 'Reset %s'],
    ['poweroff', 'force_off', 'Powers off immediately without a clean shutdown.', 'Powered off %s', 'stopped']) {
    $add->($item->[0].'-system', $item->[1], $item->[2], group => 'Virtual machines',
        select => 'machine', done => $item->[3], wait_state => $item->[4],
        job => $item->[1] eq 'power_cycle' ? 1 : 0,
        confirm => $item->[1] =~ /\A(?:reset|force_off)\z/ ? 1 : 0);
}
# Resource edits share a revision-checked job; autostart is a separate API call.
$add->('modify-system', 'update', 'Changes saved resources, boot settings or automatic startup.',
    group => 'Virtual machines', select => 'machine', prepare => 'settings', job => 1,
    additional_actions => ['autostart'], done => 'Updated %s', options => {
        map({ $_ => $creation->{$_} } qw(cpus memory desc)),
        'cpu-limit' => option('i', help => 'Maximum CPUs'),
        'memory-limit' => option('size', field => 'memory_limit_mib', unit => 'MiB', help => 'Maximum memory; bare values use MiB'),
        boot => option('s', help => 'First boot device: disk:TARGET or nic:MAC'),
        bootmenu => option('s', boolean => 1, values => [qw(yes no)], help => 'Enable the firmware boot menu'),
        autostart => option('s', boolean => 1, values => [qw(yes no)], help => 'Start when the host boots'),
        'enable-live' => option('flag', help => 'Add CPU slots, spare device ports and a CD drive while stopped'),
        'changes-file' => option('file', field => 'changes', json => 'ARRAY', help => 'JSON array of hardware edits'),
    });
# Send password changes to the agent without storing them in a job.
$add->('passwd-system', 'reset_password', 'Changes an existing guest account password through its agent.',
    group => 'Virtual machines', select => 'machine', done => 'Changed password on %s', options => {
        user => option('s', required => 1, field => 'username', help => 'Existing guest account'),
        'password-file' => { %{$creation->{'password-file'}}, required => 1 },
    });
# Only new machines can schedule package, Virtualmin and script installation.
my %software = (
    'install-source' => option('s', values => [qw(cloud iso)], help => 'Cloud image or installer ISO'),
    software => option('s', values => [qw(none virtualmin-gpl virtualmin-pro)], help => 'Software to install'),
    packages => option('s', help => 'Space-separated guest packages'),
    'virtualmin-bundle' => option('s', values => [qw(LAMP LEMP)], help => 'Apache or Nginx stack'),
    'virtualmin-type' => option('s', values => [qw(full mini)], help => 'Virtualmin installation size'),
    'virtualmin-postgres' => option('yesno', help => 'Install PostgreSQL'),
    'virtualmin-ssl' => option('yesno', help => 'Request a hostname certificate'),
    'webmin-register' => option('yesno', help => 'Register the guest in the host Servers Index'),
    'license-file' => option('file', field => 'virtualmin_key', secret => 1, help => 'Virtualmin Pro license key file, or - for stdin'),
    'license-serial-file' => option('file', field => 'virtualmin_serial', secret => 1, help => 'Virtualmin Pro serial file, or - for stdin'),
);
# Script contents are read here; host paths are read by API validation. Both
# forms execute in the guest, with the Pro boundary enforced by the API.
foreach my $when (qw(before after)) {
    $software{$when.'-script-mode'} = option('s', values => [qw(none file inline)], help => 'Guest script source (Cloudmin Pro)');
    $software{$when.'-script-file'} = option('file', field => $when.'_script', keep_newline => 1, help => 'Read guest script contents from a file');
    $software{$when.'-script-path'} = option('s', help => 'Guest script file on the Cloudmin host');
}
# Creation defaults to starting, while review selects validation without a job.
$add->('create-system', 'create', 'Creates a virtual machine from a cloud image or installer ISO.',
    group => 'Virtual machines', job => 1, done => 'Created virtual machine %s', options => {
        %$creation, %software,
        start => {%{$creation->{start}}, default => 1},
        name => option('s', required => 1, help => 'New virtual machine name'),
        review => option('flag', action => 'review', help => 'Validate without creating'),
    });
# Clones copy source disks and firmware; select the source separately.
my %clone = %$creation; delete @clone{qw(image firmware)};
$add->('clone-system', 'clone', 'Copies a virtual machine to independent disks.',
    group => 'Virtual machines', select => 'machine', prepare => 'clone_options', job => 1,
    done => 'Cloned virtual machine %s', options => { %clone,
        'new-name' => option('s', field => 'name', required => 1, help => 'Destination virtual machine name'),
        mode => option('s', field => 'clone_mode', values => [qw(prepared unchanged)], help => 'Prepare a new identity or keep guest settings'),
        shutdown => option('flag', help => 'Cleanly stop the source while copying and restart it afterward'),
        'nvram-mode' => option('s', values => [qw(fresh copy)], help => 'Create fresh firmware variables or copy them'),
        'confirm-unchanged' => option('flag', help => 'Acknowledge that guest settings and credentials are retained'),
        'confirm-license' => option('flag', help => 'Acknowledge copied Virtualmin Pro credentials will be removed'),
    });
# Deleting a machine keeps disks unless their attachment targets are selected.
$add->('delete-system', 'delete', 'Deletes a virtual machine and only the selected disk targets.',
    group => 'Virtual machines', select => 'machine', prepare => 'settings', confirm => 1,
    job => 1, done => 'Deleted virtual machine %s', options => {
        disk => option('s@', field => 'disks', help => 'Attached disk target to delete; repeat for more disks'),
        shutdown => option('flag', help => 'Permit stopping a running guest'),
    });
# Disk targets identify attachments; all disk edits use the current revision.
$add->('list-disks', 'settings', 'Lists a virtual machine\'s disks and removable drives.',
    group => 'Disks and interfaces', select => 'machine', subset => 'disks',
    list => {key => 'target', id => 'target', columns => [qw(target device role format path)]});
foreach my $item (
    ['create-disk','add_disk','Creates and attaches a disk.',{pool => {%{$creation->{pool}}, required => 1}, disk => $creation->{disk}, image => $creation->{image}}],
    ['attach-disk','attach_disk','Attaches an unused storage volume.',{pool => {%{$creation->{pool}}, required => 1}, volume => option('s', required => 1, help => 'Volume name in the pool')}],
    ['detach-disk','detach_disk','Detaches a disk while keeping its data.',{target => option('s', required => 1, help => 'Attached disk target')}],
    ['delete-disk','delete_disk','Detaches and permanently deletes one disk.',{target => option('s', required => 1, help => 'Attached disk target')}],
    ['resize-disk','grow_disk','Grows a disk to the specified total capacity.',{target => option('s', required => 1, help => 'Attached disk target'), disk => {%{$creation->{disk}}, required => 1}}],
    ['insert-media','change_media','Inserts an ISO in an existing CD/DVD drive.',{target => option('s', required => 1, help => 'CD/DVD target'), pool => {%{$creation->{pool}}, required => 1}, volume => option('s', required => 1, help => 'ISO volume name')}],
    ['eject-media','change_media','Ejects media without removing the drive.',{target => option('s', required => 1, help => 'CD/DVD target')}]) {
    $add->($item->[0],$item->[1],$item->[2], group => 'Disks and interfaces', select => 'machine',
        prepare => 'settings', job => 1, options => $item->[3],
        confirm => $item->[1] eq 'delete_disk' ? 1 : 0, done => 'Updated disks on %s');
}
# Interface edits select existing devices by MAC, not guest interface names.
$add->('list-interfaces','settings','Lists a virtual machine\'s network interfaces.',
    group => 'Disks and interfaces', select => 'machine', subset => 'interfaces',
    list => {key => 'mac', id => 'mac', columns => [qw(mac type source model link)]});
$add->('add-interface','add_interface','Adds a virtio network interface.',
    group => 'Disks and interfaces', select => 'machine', prepare => 'settings', job => 1,
    done => 'Added interface to %s', options => {network => {%{$creation->{network}}, required => 1}, mac => $creation->{mac}});
# Link and bandwidth edits preserve fields the caller leaves unspecified.
$add->('modify-interface','update_interface','Changes an interface\'s network, link or bandwidth.',
    group => 'Disks and interfaces', select => 'machine', prepare => 'settings', job => 1,
    done => 'Updated interface on %s', options => {
        mac => {%{$creation->{mac}}, required => 1}, network => $creation->{network},
        link => option('s', values => [qw(up down)], help => 'Interface link state'),
        'inbound-kib' => option('i', help => 'Inbound average KiB/s; zero removes the limit'),
        'outbound-kib' => option('i', help => 'Outbound average KiB/s; zero removes the limit'),
    });
$add->('delete-interface','remove_interface','Removes a network interface.',
    group => 'Disks and interfaces', select => 'machine', prepare => 'settings', job => 1,
    done => 'Removed interface from %s', options => {mac => {%{$creation->{mac}}, required => 1}});
# Snapshot lists may span the host; writes need a guest and history revision.
$add->('list-snapshots','snapshots','Lists snapshots for the host or one virtual machine.',
    group => 'Snapshots', select => 'optional-machine', subset => 'snapshots',
    list => {key => 'id', columns => [qw(id vm label state created)]});
foreach my $item (
    ['create-snapshot','snapshot_create','Creates a disk snapshot.',{
        label => option('s', required => 1, help => 'Snapshot label'), desc => $creation->{desc},
        mode => option('s', values => [qw(prepared unprepared)], help => 'Snapshot preparation mode'),
        shutdown => option('flag', help => 'Permit clean shutdown if the guest agent is unavailable'),
        restart => option('flag', help => 'Start after success')}],
    ['restore-snapshot','snapshot_restore','Restores a saved snapshot.',{
        snapshot => option('s', required => 1, help => 'Snapshot ID'),
        shutdown => option('flag', help => 'Permit clean shutdown before restoring'),
        restart => option('flag', help => 'Start after restoring')}],
    ['delete-snapshot','snapshot_delete','Deletes a snapshot while keeping current disk data.',{
        snapshot => option('s', required => 1, help => 'Snapshot ID')}]) {
    $add->($item->[0],$item->[1],$item->[2], group => 'Snapshots', select => 'machine',
        prepare => 'snapshots', job => 1, options => $item->[3],
        confirm => $item->[1] ne 'snapshot_create' ? 1 : 0, done => 'Finished snapshot operation on %s');
}
# Backup and inspection share destination fields; restore needs an inspection.
my $destination = destination_options();
$add->('list-backups','backups','Lists completed backup archives.', group => 'Backups',
    list => {key => 'name', columns => [qw(id name created size destination)]});
$add->('backup-systems','backup','Creates a full backup of one virtual machine.',
    group => 'Backups', select => 'machine', job => 1, done => 'Backed up %s', options => { %$destination,
        'dest-mode' => {%{$destination->{'dest-mode'}}, required => 1},
        'dest-path' => {%{$destination->{'dest-path'}}, required => 1},
        shutdown => option('flag', help => 'Stop cleanly while copying and restart afterward'),
        compression => option('yesno', help => 'Compress the archive with gzip'),
    });
# Inspect a recorded backup or retrieve an archive by name.
$add->('inspect-backup','backup_inspect','Verifies a backup archive before restoring it.',
    group => 'Backups', job => 1, done => 'Inspected backup %s', options => { %$destination,
        backup => option('s', help => 'Backup job ID from the local inventory'),
        filename => option('s', help => 'Archive filename in the destination'),
    });
$add->('restore-systems','restore','Restores an inspected backup with its original identity.',
    group => 'Backups', confirm => 1, job => 1, done => 'Restored %s', options => {
        inspection => option('s', required => 1, help => 'Completed inspection job ID'),
        pool => {%{$creation->{pool}}, required => 1},
    });
# Expose selectable host resources without changing their API record shapes.
foreach my $item (
    ['list-images','images','Lists imported and catalogue images.',[qw(id name format)]],
    ['list-networks','networks','Lists usable virtual networks and host bridges.',[qw(key name type forward)]]) {
    $add->($item->[0],'options',$item->[2],group => 'Host and images',subset => $item->[1],
        list => {key => 'name', id => $item->[1] eq 'networks' ? 'key' : 'id', columns => $item->[3]});
}
$add->('get-host','options','Shows host capabilities.',group => 'Host and images',subset => 'capabilities');
# Capture checks the source revision, image requirements and Pro support.
$add->('create-image','capture_image','Creates a reusable image from a virtual machine (Cloudmin Pro).',
    group => 'Host and images', select => 'machine', prepare => 'image_options',job => 1,done => 'Created image %s',options => {
        'image-name' => option('s', required => 1, field => 'name', help => 'New image name'),
        pool => {%{$creation->{pool}}, required => 1},
        'clean-credentials' => option('s', boolean => 1, values => [qw(yes no)], help => 'Remove all local accounts\' login credentials; defaults to yes'),
        shutdown => option('flag', help => 'Stop cleanly while copying and restart afterward'),
    });
# Job control uses durable job IDs, independent of machine selectors.
$add->('list-jobs','list','Lists recent and unfinished jobs.',group => 'Jobs',
    list => {key => 'name',columns => [qw(id name operation state phase)]});
foreach my $item (
    ['get-job','status','Shows a job\'s current progress.'],
    ['cancel-job','cancel','Requests cancellation at the next safe point.'],
    ['recover-job','recover','Resumes interrupted work or retries cleanup.'],
    ['discard-job','discard','Keeps completed disk growth and discards the remaining failed edits.']) {
    my %opts = (job => option('s',required => 1,help => 'Job ID'));
    # Only cancellation may explicitly delete an unfinished creation.
    $opts{cleanup} = option('flag',action => 'cancel_cleanup',help => 'Also remove an unfinished creation; requires --yes') if ($item->[1] eq 'cancel');
    $add->($item->[0],$item->[1],$item->[2],group => 'Jobs',options => \%opts,
        job => $item->[1] =~ /\A(?:cancel|recover)\z/ ? 1 : 0,
        ($item->[1] ne 'status' ? (done => 'Finished job request %s') : ()));
}
# Storage management resolves names from active and inactive pools alike.
$add->('list-pools','storage','Lists active and inactive storage pools.', group => 'Host storage',
    subset => 'pools', list => {key => 'name', id => 'uuid', columns => [qw(name uuid type active available)]});
$add->('list-volumes','storage','Lists storage volumes and their owners.', group => 'Host storage',
    storage_volumes => 1, options => {pool => option('s', resolve => 'storage_pool', help => 'Pool ID or unambiguous name')},
    list => {key => 'name', id => 'key', columns => [qw(name pool capacity allocation used_by)]});
$add->('list-volume-groups','storage','Lists LVM volume groups available for registration.', group => 'Host storage',
    subset => 'lvm_groups', list => {key => 'name', id => 'name', columns => ['name']});
$add->('create-pool','register_pool','Registers a directory or an existing LVM volume group.',
    group => 'Host storage', done => 'Registered storage pool %s', options => {
        name => option('s', required => 1, help => 'New pool name'),
        path => option('s', help => 'Absolute directory path; cannot be used with --group'),
        group => option('s', help => 'Existing LVM volume group; cannot be used with --path'),
        autostart => option('yesno', default => 1, help => 'Start the pool at host boot; defaults to enabled'),
    });
foreach my $item (['start-pool','pool_start'], ['stop-pool','pool_stop'], ['set-pool-autostart','pool_autostart']) {
    # Directory lifecycle changes echo the current inventory revision.
    $add->($item->[0],$item->[1],$item->[0] eq 'start-pool' ? 'Starts a directory pool.'
        : $item->[0] eq 'stop-pool' ? 'Stops a directory pool without deleting its files.'
        : 'Changes whether a directory pool starts at boot.', group => 'Host storage', pool_revision => 1,
        done => 'Updated storage pool %s', options => {
            pool => option('s', required => 1, resolve => 'storage_pool', field => 'id', help => 'Pool ID or unambiguous name'),
            ($item->[1] eq 'pool_autostart' ? (enabled => option('s', required => 1, boolean => 1,
                values => [qw(yes no)], help => 'Whether to start at host boot')) : ()),
        });
}
# Removal commands obtain a revision from a separate review. --review returns
# that record without submitting the removal, even when --yes is also given.
$add->('delete-volume','delete_volume','Deletes an unused storage volume after a review.',
    group => 'Host storage', prepare => 'volume_review', prepare_fields => [qw(pool volume)],
    confirm => 1, reviewable => 1, done => 'Deleted storage volume %s', options => {
        pool => option('s', required => 1, resolve => 'storage_pool', help => 'Pool ID or unambiguous name'),
        volume => option('s', required => 1, help => 'Exact volume name'),
        review => option('flag', help => 'Show owners and any reason deletion is blocked'),
    });
$add->('unregister-pool','unregister_pool','Removes a pool registration and keeps its data.',
    group => 'Host storage', prepare => 'pool_review', prepare_fields => [qw(id stop)], confirm => 1,
    reviewable => 1, done => 'Unregistered storage pool %s', options => {
        pool => option('s', required => 1, resolve => 'storage_pool', field => 'id', help => 'Directory or parent LVM pool ID or name'),
        review => option('flag', help => 'Show references and any reason unregistration is blocked'),
        stop => option('flag', help => 'Stop the unused pool first; LVM deactivates the whole volume group'),
    });
# Host networking uses confirmation transactions rather than machine jobs.
$add->('list-bridges','bridges','Lists host bridges outside libvirt-managed networks.',group => 'Host bridges',
    list => {key => 'name',id => 'name',columns => [qw(name active addresses ports)]});
$add->('get-bridge-status','bridge_status','Shows the current bridge transaction.',group => 'Host bridges',
    options => {id => option('s',help => 'Transaction ID; omitted selects the current transaction')});
# Review is read-only; applying removal waits for explicit network confirmation.
$add->('remove-bridge','bridge_remove','Moves the bridge\'s network settings back to its Ethernet port.',
    group => 'Host bridges',prepare => 'bridge_remove_review',bridge => 1,options => {
        name => option('s',required => 1,help => 'Host bridge name'),
        review => option('flag',help => 'Show the removal plan without applying it'),
    });
foreach my $item (
    ['confirm-bridge','bridge_confirm','Keeps the new network settings after checking connectivity.'],
    ['rollback-bridge','bridge_rollback','Requests recovery of the previous network settings.']) {
    $add->($item->[0],$item->[1],$item->[2],group => 'Host bridges',bridge => $item->[1] eq 'bridge_rollback' ? 1 : 0,
        options => {id => option('s',required => 1,help => 'Bridge transaction ID')});
}
# License repair stays available after expiry; keys use private files or stdin.
$add->('get-license','license','Shows the Cloudmin license status.',group => 'License Manager');
$add->('check-license','check_license','Rechecks the Cloudmin license with the license server.',group => 'License Manager');
$add->('change-license','change_license','Validates and saves a Cloudmin Pro license.',group => 'License Manager',options => {
    serial => option('s',required => 1,help => 'Cloudmin license serial number'),
    'key-file' => option('file',required => 1,field => 'license_key',secret => 1,help => 'License key file, or - for stdin'),
});
# Removing the license uses the CLI's standard explicit confirmation.
$add->('deregister-license','deregister_license','Removes this host\'s Cloudmin license.',
    group => 'License Manager', confirm => 1);
$add->('api',undef,'Runs the raw JSON API with a request on standard input.',group => 'Raw API',raw => 1);
return \@commands;
}

1;
