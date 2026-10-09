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

# new(class, [api => callback], [raw => callback], [sleep => callback],
#     [now => callback], [out => handle], [err => handle], [in => handle])
# Builds a dispatcher using standard streams and a real clock by default.
# api(action, input) runs host commands; raw([action]) runs raw API requests.
# Help needs neither. sleep() and now() let tests advance a fake clock.
sub new
{
my ($class,%args) = @_;
return bless {out => \*STDOUT, err => \*STDERR, in => \*STDIN,
    sleep => sub {select(undef,undef,undef,0.25)}, now => sub {time()}, %args}, $class;
}

# read_actions() identifies requests that do not need a form token.
sub read_actions { return qw(options machines settings status list snapshots clone_options image_options backups bridges bridge_status storage license); }

# command(self, name) finds a command definition without contacting the host.
sub command
{
my ($self,$name) = @_;
my ($command) = grep {$_->{name} eq $name} @{commands()};
return $command;
}

# options(command) adds selectors and confirmation to explicit command options.
sub options
{
my ($command) = @_;
my %options = %{$command->{options}};
if ($command->{select}) {
    # Require a name or UUID so conflicting selectors cannot be ignored.
    $options{name} = option('s',help => 'Source virtual machine name',metavar => 'name');
    $options{id} = option('s',help => 'Source virtual machine UUID',metavar => 'uuid');
}
# Destructive actions and cancellation cleanup require explicit confirmation.
$options{yes} = option('flag',help => 'Confirm this operation')
    if ($command->{confirm} || $command->{name} eq 'cancel-job');
return \%options;
}

# usage_error(message) distinguishes parser errors from API validation failures.
sub usage_error { die bless({message => $_[0]}, 'Cloudmin::CLI::Usage'); }

# parse(self, command, argv) consumes argv and returns values and global flags.
# Getopt parses numbers and switches; request() handles files, units and IDs.
sub parse
{
my ($self,$command,$argv) = @_;
my (%values,%global);
my $options = options($command);
my @specs;
# Build strict Getopt specifications from the shared command definition.
foreach my $name (sort keys %$options) {
    my $type = $options->{$name}->{type};
    my $spec = $name.($type eq 'yesno' ? '!' : $type eq 'flag' ? ''
        : $type eq 'i' ? '=i' : $type eq 's@' ? '=s@' : '=s');
    # collect(option, value) stores repeats only for multi-value options.
    push(@specs,$spec,sub {
        my ($opt,$value) = @_;
        # Repeated selectors and public keys keep every supplied value.
        if ($type eq 's@') { push(@{$values{$name}},$value); }
        # Reject a second singular value rather than silently replacing it.
        # Getopt catches callback exceptions and reports them as warnings, so
        # die with plain text here; the parser failure becomes a usage error.
        else {
            die "Specify --$name only once\n" if (exists($values{$name}));
            $values{$name} = $value;
        }
    });
}
# Output, waiting and help flags belong to the CLI, not the API request.
foreach my $name (qw(multiline json name-only id-only no-wait help)) {
    push(@specs,$name,\$global{$name});
}
# Capture parser warnings so failures use the chosen output and exit contract.
my $error = '';
my $ok;
{
    # capture_warning(message) keeps Getopt diagnostics out of direct stderr.
    local $SIG{__WARN__} = sub { $error .= $_[0] };
    my $parser = Getopt::Long::Parser->new(config => [qw(bundling no_ignore_case no_auto_abbrev no_getopt_compat permute)]);
    $ok = $parser->getoptionsfromarray($argv,@specs);
}
$error =~ s/\s+\z//;
usage_error($error || 'Invalid command options') if (!$ok);
usage_error('Unexpected positional argument') if (@$argv);
# Short help needs no host connection or complete command.
return (\%values,\%global) if ($global{help});
# Keep machine-readable output mutually exclusive with scalar identifier lists.
usage_error('Choose only one output format') if
    (grep {$global{$_}} qw(json name-only id-only)) > 1 ||
    $global{multiline} && ($global{'name-only'} || $global{'id-only'});
# A single detail record has no list identity field to extract.
usage_error('--name-only and --id-only require a list command')
    if (!$command->{list} && ($global{'name-only'} || $global{'id-only'}));
# Check required options and allowed values before host or file access.
foreach my $name (sort keys %$options) {
    my $opt = $options->{$name};
    usage_error("Missing required option --$name") if ($opt->{required} && !exists($values{$name}));
    next if (!exists($values{$name}));
    usage_error("Invalid --$name; choose ".join('|',@{$opt->{values}}))
        if ($opt->{values} && !grep {$_ eq $values{$name}} @{$opt->{values}});
}
# A selector is optional only for host-wide lists; name and UUID cannot coexist.
if ($command->{select}) {
    my $count = grep {exists($values{$_})} qw(name id);
    usage_error('Select exactly one of --name or --id')
        if ($count > 1 || $count == 0 && $command->{select} eq 'machine');
}
# Destructive actions need --yes; a storage review alone needs no confirmation.
usage_error('This operation requires --yes')
    if (($command->{confirm} || $command->{name} eq 'cancel-job' && $values{cleanup}) && !$values{yes}
        && !($command->{reviewable} && $values{review}));
# Cancellation needs confirmation only when it also deletes the guest.
usage_error('--yes is only used with --cleanup') if ($command->{name} eq 'cancel-job' && $values{yes} && !$values{cleanup});
# Both key sources map to one API field and must not overwrite each other.
usage_error('Use --ssh-key or --ssh-keys-file, not both') if (exists($values{'ssh-key'}) && exists($values{'ssh-keys-file'}));
# Pool registration needs exactly one backend, before any API call.
usage_error('Specify exactly one of --path or --group')
    if ($command->{name} eq 'create-pool' && (grep {exists($values{$_})} qw(path group)) != 1);
# Apply defaults only to omitted options, preserving explicit --no- switches.
foreach my $name (keys %$options) {
    $values{$name} = $options->{$name}->{default} if (!exists($values{$name}) && exists($options->{$name}->{default}));
}
return (\%values,\%global);
}

# file_value(self, path, option) reads up to 128 KiB of UTF-8 text.
# path is a regular file or "-" for stdin. The option definition controls
# newline retention, secret redaction and the required JSON type.
sub file_value
{
my ($self,$path,$option) = @_;
my $fh;
# Stdin is single-use; never wait interactively for a password or request body.
if ($path eq '-') {
    usage_error('Only one option may read standard input') if ($self->{stdin_used}++);
    die "Supply file contents on standard input\n" if (-t $self->{in});
    $fh = $self->{in};
}
# Check both the path and opened handle so nonregular inputs are refused.
else {
    die "Input must be a regular file\n" if (!-f $path);
    open($fh,'<',$path) || die "Cannot open input file: $!\n";
    die "Input must be a regular file\n" if (!-f $fh);
}
# Read one extra byte to distinguish an oversized value from a complete input.
my $data = '';
while (length($data) <= 131072) {
    my $n = read($fh,my $chunk,131073-length($data));
    die "Cannot read input file: $!\n" if (!defined($n));
    last if (!$n);
    $data .= $chunk;
}
# Close only handles opened here; the caller retains its standard input.
close($fh) if ($path ne '-');
die "Input file is too large\n" if (length($data) > 131072);
$data = decode('UTF-8',$data,FB_CROAK);
# Remove editor-added final newlines from values, but preserve script text.
$data =~ s/\r?\n\z// if (!$option->{keep_newline});
# Remember known secret contents solely for error redaction.
push(@{$self->{secrets}},$data) if ($option->{secret} && length($data));
# Reject JSON that does not match the option's required type.
if ($option->{json}) {
    my $decoded = eval {convert_from_json($data,1)};
    die "Input file must contain a JSON $option->{json}\n" if (ref($decoded) ne $option->{json});
    return $decoded;
}
return $data;
}

# size(value, unit) converts binary sizes to the API's MiB or GiB field units.
sub size
{
my ($value,$unit) = @_;
die "Invalid size; use a number with optional KiB, MiB, GiB or TiB\n"
    if ($value !~ /\A\s*(\d+(?:\.\d+)?)\s*([KMGTPE]i?B?|B)?\s*\z/i);
# Bare sizes use the destination unit; all explicit suffixes use powers of 1024.
my ($number,$suffix) = ($1,uc($2 || ''));
my %powers = (B=>0,K=>1,M=>2,G=>3,T=>4,P=>5,E=>6);
my $power = $suffix eq '' ? ($unit eq 'MiB' ? 2 : 3) : $powers{substr($suffix,0,1)};
return 0 + sprintf('%.17g',$number * 1024**$power / 1024**($unit eq 'MiB' ? 2 : 3));
}

# api(self, action, input) forwards to the supplied controller callback.
# The entry point provides authentication; tests supply an isolated substitute.
sub api { return $_[0]->{api}->($_[1],$_[2]); }

# resolve(self, kind, value) resolves exact IDs or unambiguous display names.
sub resolve
{
my ($self,$kind,$value) = @_;
if ($kind eq 'storage_pool') {
    # Creation choices omit stopped pools; management uses full inventory.
    $self->{storage} ||= $self->api('storage',{});
    my @items = @{$self->{storage}->{pools}};
    my @matches = grep {($_->{uuid} || '') eq $value} @items;
    @matches = grep {$_->{name} eq $value} @items if (!@matches);
    die "Unknown storage pool: $value\n" if (!@matches);
    die "Ambiguous storage pool name; use its ID\n" if (@matches != 1);
    $self->{storage_pool} = $matches[0];
    return $matches[0]->{uuid};
}
# Reuse one options snapshot for all names resolved in this command.
$self->{choices} ||= $self->api('options',{});
my $choices = $self->{choices};
my @items = $kind =~ /\A(?:template|plan)\z/
    ? @{$choices->{presets}->{$kind}->{entries} || []}
    : $kind eq 'image' ? (@{$choices->{images} || []},@{$choices->{catalogue_images} || []})
    : @{$choices->{$kind eq 'pool' ? 'pools' : 'networks'} || []};
# Match IDs before display names; networks also accept a bare UUID.
my $key = $kind eq 'network' ? 'key' : 'id';
my @matches = grep {($_->{$key} || '') eq $value} @items;
@matches = grep {($_->{name} || '') eq $value || $kind eq 'network' && ($_->{id} || '') eq $value} @items if (!@matches);
# A missing or ambiguous match must never select an arbitrary resource.
die "Unknown $kind: $value\n" if (!@matches);
die "Ambiguous $kind name; use its ID\n" if (@matches != 1);
# Known but disabled templates must report policy rather than an unknown ID.
die $matches[0]->{disabled} if ($matches[0]->{disabled});
return $matches[0]->{$key};
}

# request(self, command, values) builds a request and reads current revisions.
# Returns action, input, list filters, selected machine and preflight record.
sub request
{
my ($self,$command,$values) = @_;
my $options = options($command);
my (%input,%filters);
my $action = $command->{action};
# Translate CLI-only switches and typed values before assembling API fields.
foreach my $name (sort keys %$values) {
    my $opt = $options->{$name};
    next if ($name eq 'yes' || $command->{select} && $name =~ /\A(?:name|id)\z/);
    my $value = $values->{$name};
    # List filters are applied to returned inventory, not sent as API fields.
    if ($opt->{filter}) { $filters{$opt->{filter}} = $value; next; }
    # Review and cleanup switches choose an action instead of an input value.
    if ($opt->{action}) { $action = $opt->{action} if ($value); next; }
    # Review chooses the CLI return path; it is not an API input field.
    next if (($command->{bridge} || $command->{reviewable}) && $name eq 'review');
    # Read file contents and normalize sizes, booleans, repeated keys and IDs.
    $value = $self->file_value($value,$opt) if ($opt->{type} eq 'file');
    $value = size($value,$opt->{unit}) if ($opt->{type} eq 'size');
    $value = $value eq 'yes' ? 1 : 0 if ($opt->{boolean});
    $value = join($opt->{join},@$value) if (defined($opt->{join}));
    $value = $self->resolve($opt->{resolve},$value) if ($opt->{resolve});
    my $field = $opt->{field} || $name; $field =~ tr/-/_/;
    # Dotted mappings build nested destination objects; other fields stay flat.
    if ($field =~ /\A(\w+)\.(\w+)\z/) { $input{$1}->{$2} = $value; }
    # Ordinary operation fields belong directly in the request object.
    else { $input{$field} = $value; }
}
# Derive the backend and revision from explicit, validated selectors.
$input{type} = exists($values->{group}) ? 'logical' : 'dir' if ($command->{name} eq 'create-pool');
$input{revision} = $self->{storage_pool}->{revision} if ($command->{pool_revision});
my $machine;
# Resolve a machine from visible inventory, preserving its public summary.
if ($command->{select} && (exists($values->{name}) || exists($values->{id}))) {
    my $key = exists($values->{id}) ? 'id' : 'name';
    my @matches = grep {$_->{$key} eq $values->{$key}} @{$self->api('machines',{})};
    die "Virtual machine not found\n" if (!@matches);
    die "Ambiguous virtual machine name; use its UUID\n" if (@matches != 1);
    $machine = $matches[0];
    $input{id} = $machine->{id};
}
# Pass the CLI confirmation to the API.
$input{confirm} = 1 if ($command->{confirm} || $action eq 'cancel_cleanup');
# An autostart-only edit avoids the hardware job; empty edits are usage errors.
if ($command->{name} eq 'modify-system') {
    my @fields = grep {$_ ne 'id' && $_ ne 'autostart'} keys %input;
    usage_error('Specify at least one setting to change') if (!@fields && !exists($input{autostart}));
    $action = 'autostart' if (!@fields);
}
my $current;
if ($command->{prepare} && $action ne 'autostart') {
    # Read the revision just before submission; the API detects later changes.
    $current = $self->api($command->{prepare}, $command->{prepare_fields}
        ? {map {$_ => $input{$_}} @{$command->{prepare_fields}}}
        : $command->{prepare} eq 'bridge_remove_review' ? {name => $input{name}} : {id => $input{id}});
    $input{revision} = $current->{revision};
}
if ($command->{name} eq 'modify-system' && $action eq 'update') {
    # The update API requires both resource fields even for a description edit.
    foreach my $field (qw(cpus memory_mib)) {
        $input{$field} = $current->{$field} if (!exists($input{$field}));
    }
}
# Confirm deletion against the current name and snapshot/checkpoint history.
if ($action eq 'delete') {
    $input{confirm_name} = $current->{name};
    $input{history_revision} = $current->{history_revision};
}
# The media API ejects the current disc when the volume is empty.
$input{volume} = '' if ($command->{name} eq 'eject-media');
return ($action,\%input,\%filters,$machine,$current);
}

# follow(self, job, global, command) waits for an independent job.
sub follow
{
my ($self,$job,$global,$command) = @_;
# Asynchronous callers receive the submitted record without any polling.
return $job if ($global->{'no-wait'});
my $deadline = $self->{now}->() + 3700;
my ($phase,$failures) = ('',0);
while (1) {
    my $next = $job->{phase} || $job->{state} || '';
    # Report only phase changes, and keep JSON output free of progress text.
    if ($next ne $phase) {
        $phase = $next;
        (my $text = $phase) =~ tr/_/ /;
        print {$self->{err}} ".. $text\n" if (!$global->{json});
    }
    my $state = $job->{state} || '';
    # A completed operation needs no further status reads.
    return $job if ($state eq 'complete');
    # Cancellation or cleanup can succeed while the job stays failed or
    # cancelled.
    return $job if ($command->{action} =~ /\A(?:cancel|recover)\z/ &&
        $state =~ /\A(?:cancelled|failed)\z/ && !$job->{cleanup_pending});
    # Failed or cancelled ordinary operations must not print a success message.
    die(($job->{error} || 'Virtual machine operation failed')."\n") if ($state eq 'failed');
    # Report cancellation as failure for commands that expected completion.
    die "Virtual machine operation was cancelled\n" if ($state eq 'cancelled');
    # Stop waiting at the deadline; leave the worker running.
    die "Job $job->{id} is still running; use cloudmin get-job --job $job->{id}\n" if ($self->{now}->() >= $deadline);
    $self->{sleep}->();
    my $current = eval {$self->api('status',{job => $job->{id}})};
    # A successful status read clears the consecutive-failure counter.
    if ($current) { $job = $current; $failures = 0; }
    # Allow transient read failures, then return the job ID for a later check.
    elsif (++$failures >= 3) { die "Cannot read job $job->{id}; use cloudmin get-job --job $job->{id}\n"; }
}
}

# execute(self, command, values, global) submits and waits as requested.
sub execute
{
my ($self,$command,$values,$global) = @_;
my ($action,$input,$filters,$machine,$current) = $self->request($command,$values);
# Storage and bridge preflights already produced the requested review.
if (($command->{bridge} || $command->{reviewable}) && $values->{review}) {
    $self->{review} = 1;
    return $current;
}
# A blocked review must never proceed to a destructive request.
die $current->{usage}->{reason}."\n" if ($command->{reviewable} && $current->{usage}->{reason});
# Separate autostart from hardware writes so it follows successful completion.
my $autostart = delete($input->{autostart}) if ($command->{name} eq 'modify-system');
# Autostart alone uses the immediate action and its enabled field.
if ($action eq 'autostart') { $input->{enabled} = $autostart; }
# Do not apply autostart before an asynchronous hardware job has succeeded.
elsif (defined($autostart) && $global->{'no-wait'}) {
    usage_error('Change --autostart separately when using --no-wait');
}
# Submit once; wait for jobs unless reviewing or changing autostart alone.
my $result = $self->api($action,$input);
$result = $self->follow($result,$global,$command) if ($command->{job} && $action ne 'review' && $action ne 'autostart');
if (defined($autostart) && $action ne 'autostart') {
    # Apply only after the resource job releases its guest reservation.
    $self->api('autostart',{id => $input->{id},enabled => $autostart});
}
# Simple power requests wait for host state, not guest application readiness.
if ($command->{wait_state} && !$global->{'no-wait'}) {
    my $deadline = $self->{now}->() + 120;
    while (1) {
        my $state = $self->api('machines',{id => $input->{id}});
        last if ($state->{state} eq $command->{wait_state});
        # A delayed guest response remains pending after the CLI timeout.
        die "State change is still pending; use cloudmin get-system --id $input->{id}\n" if ($self->{now}->() >= $deadline);
        $self->{sleep}->();
    }
}
# Wait for network confirmation, but leave confirmation to the caller.
if ($command->{bridge} && !$global->{'no-wait'}) {
    my $deadline = $self->{now}->() + 3700;
    while ($result && ($result->{state} || '') !~ /\A(?:confirm|confirmed|rolled_back|rollback_failed|failed)\z/) {
        # The host recovery timer continues even if this client stops waiting.
        die "Bridge change is still running; use cloudmin get-bridge-status\n" if ($self->{now}->() >= $deadline);
        $self->{sleep}->();
        $result = $self->api('bridge_status',{id => $result->{id}});
    }
    # Report failed recovery even when polling itself succeeded.
    die "Bridge recovery failed; use cloudmin get-bridge-status\n" if ($result && ($result->{state} || '') =~ /\A(?:failed|rollback_failed)\z/);
    # Successful automatic rollback is still a failed removal request.
    die "The bridge removal was rolled back\n" if ($action eq 'bridge_remove' && $result && $result->{state} eq 'rolled_back');
}
# Machine details include the public inventory row already used for selection.
if ($command->{summary_action}) {
    $result = {%$result, summary => $machine};
}
if ($command->{storage_volumes}) {
    # Flatten inventory while retaining the pool ID and complete ownership data.
    my @pools = grep {!$input->{pool} || $_->{uuid} eq $input->{pool}} @{$result->{pools}};
    die join("\n", map {$_->{volume_error}} grep {$_->{volume_error}} @pools)."\n"
        if (grep {$_->{volume_error}} @pools);
    $result = [map {my $pool = $_; map {{%$_, pool => $pool->{name}, pool_id => $pool->{uuid}}}
        @{$pool->{volumes} || []}} @pools];
}
if (($command->{subset} || '') eq 'lvm_groups') {
    # A discovery failure is distinct from a host with no unregistered groups.
    die $result->{lvm_group_error}."\n" if ($result->{lvm_group_error});
    $result = {%$result, lvm_groups => [map {{name => $_}} @{$result->{lvm_groups}}]};
}
if ($command->{subset}) {
    # List commands expose native records; no text parsing or field renaming.
    # Fail if any part of the snapshot inventory could not be read.
    die join("\n",@{$result->{errors}})."\n"
        if ($command->{subset} eq 'snapshots' && @{$result->{errors} || []});
    $result = $command->{subset} eq 'images'
        ? [@{$result->{images} || []},@{$result->{catalogue_images} || []}]
        : $result->{$command->{subset}};
}
# Values within a filter are alternatives; separate filters all have to match.
if ($command->{list} && keys %$filters) {
    foreach my $field (sort keys %$filters) {
        my @wanted = ref($filters->{$field}) eq 'ARRAY' ? @{$filters->{$field}} : ($filters->{$field});
        # Resolve preset IDs to names for matching against inventory.
        if ($field =~ /\A(?:template|plan)\z/) {
            my $id = $self->resolve($field,$wanted[0]);
            my ($preset) = grep {$_->{id} eq $id} @{$self->{choices}->{presets}->{$field}->{entries}};
            @wanted = ($preset->{name});
        }
        $result = [grep { my $row = $_; grep {defined($row->{$field}) && $row->{$field} eq $_} @wanted } @$result];
    }
}
# Save display context without altering the native API record returned to JSON.
$self->{done_name} = ref($result) eq 'HASH' && ($result->{name} || $result->{id}) || $input->{name} || ($machine && $machine->{name}) || $input->{job} || $input->{id} || '';
$self->{review} = $action eq 'review' || $values->{review};
return $result;
}

# label(key) supplies consistent labels for known fields and readable fallbacks.
sub label
{
my ($key) = @_;
my %labels = (id=>'ID',uuid=>'UUID',cpus=>'CPUs',used_by=>'Used by',memory_mib=>'Memory',disk_gib=>'Disk',addresses=>'IP address',created=>'Created on');
# Prefer familiar labels; otherwise expand API field names for display.
return $labels{$key} if ($labels{$key});
$key =~ tr/_/ /;
return join(' ',map {ucfirst($_)} split(/ /,$key));
}

# human_size(bytes) formats binary sizes without changing the underlying data.
sub human_size
{
my ($bytes) = @_;
my @units = qw(B KiB MiB GiB TiB PiB EiB);
my $i = 0;
while ($bytes >= 1024 && $i < $#units) { $bytes /= 1024; $i++; }
return sprintf('%.3g %s',$bytes,$units[$i]);
}

# scalar_text(key, value) formats values and removes terminal controls.
sub scalar_text
{
my ($key,$value) = @_;
# Unknown measurements stay distinct from measured zero values.
return '-' if (!defined($value));
# Accept either JSON-library booleans or Webmin scalar-reference booleans.
return $value ? 'Yes' : 'No' if (blessed($value) && ref($value) =~ /Boolean\z/);
# Webmin also represents JSON booleans as references to zero or one.
return $$value ? 'Yes' : 'No' if (ref($value) eq 'SCALAR');
# Known numeric flag fields use the same human-readable boolean labels.
return $value ? 'Yes' : 'No' if ($key =~ /\A(?:autostart|active|persistent|readonly|bootmenu|start|cancel|cleanup_pending)\z/ && $value =~ /\A[01]\z/);
# API resource fields encode their unit in the key, unlike byte measurements.
return human_size($value*1024**2) if ($key =~ /_mib\z/);
# Disk capacities use GiB before being converted for display.
return human_size($value*1024**3) if ($key =~ /_gib\z/);
# Storage and explicit byte fields already use bytes.
return human_size($value) if ($key =~ /\A(?:size|capacity|allocation|available|physical)\z/ || $key =~ /_bytes\z/);
# Human output uses local creation time; JSON retains the original epoch.
return strftime('%Y-%m-%d %H:%M:%S',localtime($value)) if ($key eq 'created' && $value =~ /\A\d+\z/);
# Capitalize state labels without changing their machine-readable API values.
$value = ucfirst($value) if ($key eq 'state');
# Guest-controlled text must not inject terminal escape or control sequences.
$value =~ s/[\x00-\x1f\x7f-\x9f]/ /g;
return $value;
}

# multiline(data, [indent]) formats nested records as indented text.
sub multiline
{
my ($data,$indent) = @_;
$indent ||= '';
# Scalar leaves use the same formatting as table cells.
return $indent.scalar_text('', $data)."\n" if (ref($data) ne 'HASH' && ref($data) ne 'ARRAY');
# Separate list records while preserving the requested nesting level.
return join("\n",map {multiline($_,$indent)} @$data) if (ref($data) eq 'ARRAY');
my $text = '';
# Only outer records get an identity heading; nested records keep field labels.
if (!$indent) {
    $text = scalar_text('', $data->{name} || $data->{id} || 'Details')."\n";
    $indent = '    ';
}
foreach my $key (sort keys %$data) {
    # Avoid repeating the name that is used as an outer record heading.
    next if ($key eq 'name' && $indent eq '    ');
    my $value = $data->{$key};
    my $label = label($key);
    # Nested objects retain their hierarchy under the field label.
    if (ref($value) eq 'HASH') { $text .= "$indent$label:\n".multiline($value,$indent.'    '); }
    # Arrays of records, addresses and simple values need different layouts.
    elsif (ref($value) eq 'ARRAY') {
        # Complex array entries each retain their own labeled block.
        if (grep {ref($_) eq 'HASH' || ref($_) eq 'ARRAY'} @$value) {
            $text .= "$indent$label:\n".multiline($_,$indent.'    ') for @$value;
        }
        # Address lists use one labeled line per address.
        elsif ($key eq 'addresses') { $text .= "$indent$label: ".scalar_text($key,$_)."\n" for @$value; }
        # Short scalar lists fit on one line after their label.
        else { $text .= "$indent$label: ".join(' ',map {scalar_text($key,$_)} @$value)."\n"; }
    }
    # Scalar fields get one line, with the raw epoch retained beside a date.
    else {
        $text .= "$indent$label: ".scalar_text($key,$value)."\n";
        # Keep a directly reusable creation timestamp in multiline output.
        $text .= "${indent}Created Unix time: $value\n" if ($key eq 'created' && defined($value));
    }
}
return $text;
}

# table(command, rows) aligns list columns using their formatted display widths.
sub table
{
my ($command,$rows) = @_;
my @keys = @{$command->{list}->{columns}};
my @rows = ([map {label($_)} @keys]);
# Summarize volume owners and scalar arrays without changing the records.
foreach my $row (@$rows) {
    push(@rows,[map {my $key = $_; my $v = $key eq 'used_by'
        ? join(', ', map {$_->{name} || $_->{id} || $_->{uuid} || $_->{kind}} @{$row->{usage}->{owners} || []}) || $row->{usage}->{reason} || '-'
        : $row->{$key};
        ref($v) eq 'ARRAY' ? join(' ',map {scalar_text($key,ref($_) eq 'HASH' ? $_->{address} : $_)} @$v)
        : scalar_text($key,$v)} @keys]);
}
# Measure rendered cells before padding, including labels and unit suffixes.
my @width = map {length($_)} @{$rows[0]};
# Grow each column to fit its longest rendered value.
foreach my $row (@rows) { for my $i (0..$#keys) { $width[$i] = length($row->[$i]) if (length($row->[$i]) > $width[$i]); } }
# Add separators and align headers and values with the same widths.
splice(@rows,1,0,[map {'-' x $_} @width]);
return join('',map {my $row=$_; join('  ',map {sprintf('%-*s',$width[$_],$row->[$_])} 0..$#keys)."\n"} @rows);
}

# render(self, command, result, global) prints the chosen output format.
sub render
{
my ($self,$command,$result,$global) = @_;
my $text;
# JSON preserves native records and takes precedence over human formatting.
if ($global->{json}) { $text = convert_to_json({command=>$command->{name},status=>'success',data=>$result},1,1); }
# Identifier-only lists have no headings or progress decorations.
elsif ($global->{'name-only'} || $global->{'id-only'}) {
    my $key = $global->{'id-only'} ? $command->{list}->{id} || 'id' : $command->{list}->{key};
    $text = join('',map {scalar_text($key,$_->{$key})."\n"} @$result);
}
# Explicit multiline output and ordinary detail reads expand nested records.
elsif ($global->{multiline} || !$command->{list} && !$command->{done}) { $text = multiline($result); }
# Inventory commands default to a compact aligned table.
elsif ($command->{list}) { $text = table($command,$result); }
# Reviews show the proposed settings rather than claiming a completed change.
elsif ($self->{review}) { $text = multiline($result); }
# Asynchronous jobs return their durable ID for subsequent status requests.
elsif ($global->{'no-wait'} && $command->{job} && ref($result) eq 'HASH' && $result->{state}) { $text = $result->{id}."\n"; }
# Finished immediate actions and followed jobs use their completion message.
else { $text = sprintf($command->{done},scalar_text('', $self->{done_name}))."\n"; }
print {$self->{out}} $text;
# Human bridge output explains the next step without committing the change.
if (!$global->{json} && ref($result) eq 'HASH' && ($result->{state} || '') eq 'confirm' && $command->{bridge}) {
    print {$self->{out}} "Check the connection, then run: cloudmin confirm-bridge --id $result->{id}\n";
}
}

# command_list(self) groups commands in the same order as their definitions.
sub command_list
{
my ($self) = @_;
my $text = "Usage: cloudmin <command> [options]\n       cloudmin help [command]\n";
my $group = '';
foreach my $command (@{commands()}) {
    # Underline each group heading, matching Virtualmin's command list.
    if ($group ne $command->{group}) {
        $group = $command->{group};
        $text .= "\n$group\n".('-' x length($group))."\n";
    }
    $text .= sprintf('%-20s %s',$command->{name},$command->{summary})."\n";
}
return $text;
}

# option_order(command) keeps documented ordering stable as fields are added.
sub option_order
{
my ($command) = @_;
# Explicit priorities precede alphabetical fallback, without duplicate options.
my %seen;
return grep {!$seen{$_}++} (@{$command->{order} || []},sort keys %{options($command)});
}

# option_usage(name, definition) renders a value, enum, flag or negatable flag.
sub option_usage
{
my ($name,$opt) = @_;
# Negatable switches take no value and advertise both spellings.
return "--$name | --no-$name" if ($opt->{type} eq 'yesno');
# Plain flags take no argument or negative spelling.
return "--$name" if ($opt->{type} eq 'flag');
# Prefer an explicit placeholder, then derive one from the value definition.
my $value = $opt->{metavar} || ($opt->{values} ? join('|',@{$opt->{values}})
    : $opt->{resolve} ? 'ID|name' : $opt->{type} eq 'file' ? 'file|-'
    : $opt->{type} eq 'size' ? 'size' : $opt->{type} eq 'i' ? 'number' : 'value');
return "--$name $value";
}

# synopsis(self, command) generates required and optional syntax from the table.
sub synopsis
{
my ($self,$command) = @_;
# The raw entry point accepts an action and JSON stdin, not named options.
return "cloudmin api [action] < request.json\n" if ($command->{raw});
my $prefix = 'cloudmin '.$command->{name};
my @parts = ('[--multiline | --json]');
# List commands additionally offer one identifier per output line.
push(@parts,'[--name-only | --id-only]') if ($command->{list});
# Advertise asynchronous waiting only for commands that implement it.
push(@parts,'[--no-wait]') if ($command->{job} || $command->{wait_state} || $command->{bridge});
# Machine selectors are alternatives; only host-wide queries may omit them.
if ($command->{select}) {
    my $selector = '--name name | --id uuid';
    push(@parts,$command->{select} eq 'optional-machine' ? "[$selector]" : "($selector)");
}
my $options = options($command);
# A storage review is useful without confirming the destructive action.
push(@parts, '(--review | --yes)') if ($command->{reviewable});
# Omit selectors and review/confirmation switches already shown above.
foreach my $name (option_order($command)) {
    next if ($command->{select} && $name =~ /\A(?:name|id)\z/);
    next if ($command->{reviewable} && $name =~ /\A(?:review|yes)\z/);
    my $opt = $options->{$name};
    my $part = option_usage($name,$opt);
    # Required fields and destructive confirmation remain outside brackets.
    $part = "[$part]" if (!$opt->{required} && !($name eq 'yes' && $command->{confirm}));
    # An asterisk marks options that accept repeated values.
    $part .= '*' if ($opt->{type} eq 's@');
    push(@parts,$part);
}
return $prefix.' '.join("\n".(' ' x (length($prefix)+1)),@parts)."\n";
}

# short_help(self, command) uses the familiar Virtualmin summary and synopsis.
sub short_help
{
my ($self,$command) = @_;
return "See `cloudmin help $command->{name}` for more details and examples\n\n".
    $command->{summary}."\n\n".$self->synopsis($command);
}

# pod_sections(self) reads the single long-help source, keyed by command name.
sub pod_sections
{
my ($self) = @_;
open(my $fh,'<',dirname(__FILE__).'/CLI/commands.pod') || die "Cannot read command help: $!\n";
local $/; my $pod = <$fh>; close($fh);
# Keep each command section intact for both terminal and Markdown renderers.
my %sections;
while ($pod =~ /^=head2 ([a-z-]+)\n(.*?)(?=^=head2 |\z)/msg) { $sections{$1} = "=head2 $1\n$2"; }
return ($pod,\%sections);
}

# help(self, [name]) renders one command with generated option details.
# Without a name, renders the complete POD source as one plain-text manual.
sub help
{
my ($self,$name) = @_;
my ($pod,$sections) = $self->pod_sections();
# A requested section must also have an executable command definition.
usage_error("Unknown command: $name") if (defined($name) && !$self->command($name));
# Promote a command section to the manual title and append its current options.
if (defined($name)) {
    my $command = $self->command($name);
    $pod = $sections->{$name};
    $pod =~ s/^=head2 [^\n]+\n/=head1 $name\n\n$command->{summary}\n/;
    my $options = options($command);
    # Render option details as part of the manual, without repeating syntax.
    $pod .= "\n=head2 Options\n\n=over\n\n" if (keys %$options);
    $pod .= '=item C<'.option_usage($_,$options->{$_}).">\n\n".
        ($options->{$_}->{help} || label($_))."\n\n" for option_order($command);
    $pod .= "=back\n" if (keys %$options);
}
# Render in memory so paging and redirection receive identical manual text.
my $out = '';
open(my $input,'<',\$pod) || die $!;
open(my $output,'>',\$out) || die $!;
Pod::Text->new(sentence=>0,width=>78)->parse_from_filehandle($input,$output);
return $out;
}

# show_help(self, [name]) pages terminal help or prints redirected help.
sub show_help
{
my ($self,$name) = @_;
my $text = $self->help($name);
my ($pager) = grep {-x $_} qw(/usr/bin/less /bin/less /usr/bin/more /bin/more);
if (-t $self->{in} && -t $self->{out} && $pager) {
    # A temporary file lets the reader quit early without breaking a pipe.
    my ($fh,$path) = tempfile('cloudmin-help-XXXXXX',TMPDIR=>1,UNLINK=>1);
    print $fh $text;
    close($fh) || die "Cannot write command help: $!\n";
    # Run a known pager directly, without a shell or custom command.
    system($pager,$path) == 0 || die "Cannot display command help\n";
}
else {
    # Pipes, files and hosts without a pager still receive the complete manual.
    print {$self->{out}} $text;
}
}

# docs_intro() returns the introduction shared by both Markdown layouts.
sub docs_intro
{
return "Run `cloudmin` as root on the Cloudmin host. Lists use tables by default; `--multiline` shows details. `--json` returns an object with `command`, `status` and `data` fields; `data` holds the API result. Success exits 0, operation failures exit 1, and usage errors exit 2.\n\nCommands wait for jobs by default; `--no-wait` returns the job ID immediately. Passwords and license credentials are read from files or standard input.\n\n";
}

# docs_body(self, command, sections) renders one command's reference entry
# below its heading: generated syntax, converted POD text, examples and the
# option list. sections maps command names to their POD sections.
sub docs_body
{
my ($self,$command,$sections) = @_;
my $name = $command->{name};
my $text = "```text\n".$self->synopsis($command)."```\n\n";
my $section = $sections->{$name} || die "Missing help for $name\n";
$section =~ s/^=head2 [^\n]+\n//;
my $code = 0;
# Convert the supported POD subset while keeping examples in shell fences.
foreach my $line (split(/\n/,$section)) {
    # Structural list markers and the POD terminator have no Markdown text.
    next if ($line =~ /^=(?:over|back|cut)/);
    # Contiguous indented lines belong to a verbatim shell example.
    if ($line =~ /^    /) {
        # Open one code fence for each run of example lines.
        $text .= "```sh\n" if (!$code++);
        $line =~ s/^    //; $text .= "$line\n"; next;
    }
    # A prose line ends the preceding shell example.
    if ($code) { $text .= "```\n"; $code = 0; }
    # Lists and inline formatting need explicit Markdown equivalents.
    $line =~ s/^=item /- /;
    $line =~ s/C<([^>]+)>/`$1`/g; $line =~ s/B<([^>]+)>/**$1**/g;
    $text .= "$line\n";
}
# Close a final example even when no prose follows it.
$text .= "```\n" if ($code);
my $opts = options($command);
# Append authoritative option descriptions; raw API has no named options.
if (keys %$opts) {
    $text .= "\nOptions:\n\n";
    $text .= '- `'.option_usage($_,$opts->{$_}).'`: '.($opts->{$_}->{help} || label($_)).".\n" for option_order($command);
}
return $text;
}

# docs(self) renders the whole reference as one Markdown document.
sub docs
{
my ($self) = @_;
my (undef,$sections) = $self->pod_sections();
my $text = "# Cloudmin command-line reference\n\n".docs_intro();
# Pair each manual section with syntax derived from the same command definition.
foreach my $command (@{commands()}) {
    $text .= "## $command->{name}\n\n".$command->{summary}."\n\n".
        $self->docs_body($command,$sections)."\n";
}
return $text;
}

# page_front_matter(path) reads simple key: value pairs from an existing page.
# Returns an empty hash when the page does not exist yet.
sub page_front_matter
{
my ($path) = @_;
open(my $fh,'<',$path) || return {};
local $/; my $text = <$fh>; close($fh);
return {} if ($text !~ /\A---\n(.*?)\n---\n/s);
my %fields;
foreach my $line (split(/\n/,$1)) {
    $fields{$1} = $2 if ($line =~ /\A([A-Za-z]+):\s*(.*?)\s*\z/);
}
return \%fields;
}

1;
