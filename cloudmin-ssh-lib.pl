# Key APIs require Pro and host access. Changes and private downloads also
# require a form token.
use strict;
use warnings;
our ($module_root_directory, $module_var_directory, $remote_user, $guest_login_accounts_cache);

# has_ssh_key_manager() checks whether the Pro key module is installed.
sub has_ssh_key_manager
{
return -r "$module_root_directory/pro/SSHKeys.pm";
}

# get_ssh_key_manager() opens the Pro library for host administrators.
# The store checks manage access for writes and private-key downloads.
sub get_ssh_key_manager
{
# Both the host grant and installed extension are required, including for reads.
require_access('host');
die "SSH key management requires Cloudmin Pro\n" if (!has_ssh_key_manager());
require "$module_root_directory/pro/SSHKeys.pm";
# Recheck permissions per operation and serialize library changes.
return Cloudmin::Pro::SSHKeys->new(directory => "$module_var_directory/ssh-keys",
    # access(write) requires manage permission when write is true.
    access => sub { require_access($_[0] ? 'manage' : 'host'); },
    # lock(callback) runs the store's update under its shared lock.
    lock => sub { get_vm_jobs()->lock('ssh-key-library', $_[0]) });
}

# resolve_saved_ssh_keys(input) resolves library keys before VM validation.
# Pro merges selected and automatic public keys when the request allows it.
sub resolve_saved_ssh_keys
{
my ($input) = @_;
# GPL preserves plain public-key input but rejects library selections.
if (!has_ssh_key_manager()) {
    die "Saved SSH keys require Cloudmin Pro\n" if ($input->{'saved_ssh_keys'});
    return $input;
}
# Pro also checks whether the installation or clone mode accepts keys.
return get_ssh_key_manager()->resolve($input);
}

# guest_ssh_service(id) returns (service, guest) for one UUID.
# Callers check Pro and host access first; id is a guest UUID. Agent commands
# use a writable adapter and bounded virsh calls. Listings are reads and also
# run for read-only sessions; Webmin vetoes the other commands for them.
sub guest_ssh_service
{
my ($id) = @_;
# Reject malformed IDs before asking libvirt to resolve a domain.
die "Invalid virtual machine ID\n" if (!defined($id) || ref($id) ||
    $id !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
# Read fresh guest state before opening the write-capable agent channel.
require "$module_root_directory/pro/GuestSSH.pm";
my $adapter = get_libvirt(1);
my $vm = $adapter->get_domain($id, 1) || die "Virtual machine not found\n";
die "The virtual machine must be running\n" if ($vm->{'state'} !~ /\A(?:running|blocked)\z/);
my $protected;
if (($vm->{'cloudmin'} || {})->{'job'}) {
    # Protect Cloudmin's own login independently of the library's contents.
    # Use the stored UUID; callers may supply uppercase letters.
    my $path = get_ssh_keys()->find($vm->{'uuid'}, $vm->{'cloudmin'}->{'job'});
    # Keep ssh-keygen diagnostics, which name the private key file, off pages.
    $protected = eval { Cloudmin::WorkerTasks::command('/usr/bin/ssh-keygen', '-y', '-P', '', '-f', $path) } if ($path);
    die "Cannot read the managed login key of this virtual machine\n" if ($path && !$protected);
}
# agent(command, arguments) sends only the three permitted key operations.
my $agent = sub {
    my ($command, $arguments) = @_;
    # Restrict this transport to key RPCs with a host-side execution deadline.
    die "Unsupported guest SSH key operation\n" if ($command !~ /\Aguest-ssh-(?:get|add|remove)-authorized-keys\z/);
    die "Managing guest SSH keys requires virsh and timeout on the host\n"
        if (!-x '/usr/bin/virsh' || !-x '/usr/bin/timeout');
    # Quote every argument and bound both the agent and its virsh process.
    my $json = convert_to_json({execute => $command, arguments => $arguments}, 0, 1);
    my $cmd = join(' ', map { quote_path($_) } '/usr/bin/timeout', '-k', '1', '15',
        '/usr/bin/virsh', '--connect', $adapter->uri(), 'qemu-agent-command',
        '--domain', $vm->{'uuid'}, '--timeout', '10', '--cmd', $json);
    my ($output, $error);
    # LC_ALL stabilizes libvirt diagnostics; file errors come from the guest.
    # Mark only key listing safe for Webmin's read-only command gate.
    local $ENV{'LC_ALL'} = 'C';
    my $status = execute_command($cmd, undef, \$output, \$error, undef,
        $command eq 'guest-ssh-get-authorized-keys' ? 1 : 0);
    return guest_ssh_reply($command, $status, $output, $error);
};
return (Cloudmin::Pro::GuestSSH->new(agent => $agent, protected => $protected), $vm);
}

# guest_ssh_reply(command, status, output, error) decodes one virsh reply.
# An account without an authorized_keys file has no keys yet; other failures
# must remain errors so additions never rely on an unreadable key list.
sub guest_ssh_reply
{
my ($command, $status, $output, $error) = @_;
return { keys => [] } if ($status && $command eq 'guest-ssh-get-authorized-keys' &&
    ($error || '') =~ /unable to execute QEMU agent command 'guest-ssh-get-authorized-keys': failed to read '[^'\r\n]+\/\.ssh\/authorized_keys': [^\r\n]*No such file or directory/);
# The agent can start before first-boot setup enables SSH key access.
# Keep denials as errors and suggest a retry before manual repair.
die "The guest agent was denied access to this account's SSH keys. If the virtual machine was just created, wait for initial setup to finish and try again. If access is still denied, check file permissions. On SELinux guests, run `setsebool -P virt_qemu_ga_manage_ssh on` as root inside the virtual machine.\n"
    if ($status && ($error || '') =~ /unable to execute QEMU agent command 'guest-ssh-(?:get|add|remove)-authorized-keys': [^\r\n]*Permission denied/);
# Other command failures must not be mistaken for an empty key list.
die "Cannot access guest SSH keys. Check that the account exists and the guest agent is running and allows SSH key commands.\n" if ($status);
# Bound JSON parsing and require a successful agent response envelope.
die "Guest SSH key response is too large\n" if (length($output || '') > 1024*1024);
my $reply = eval { convert_from_json($output) };
die "The guest agent could not complete the SSH key operation\n"
    if (ref($reply) ne 'HASH' || !exists($reply->{'return'}) || $reply->{'error'});
return $reply->{'return'};
}

# login_accounts(passwd, [preferred...]) suggests guest login account names.
# Include UID 0 and UIDs 1000-65533, excluding known non-login shells. This
# does not check account locks or SSH policy. Preferred names come first
# when present.
sub login_accounts
{
my ($passwd, @preferred) = @_;
my (%seen, @accounts);
foreach my $line (split(/\r?\n/, $passwd // '')) {
    my ($name, undef, $uid, undef, undef, undef, $shell) = split(/:/, $line);
    # Use the ordinary Linux user-ID range for suggestions, plus UID 0.
    next if (!defined($uid) || $uid !~ /\A\d+\z/ || ($uid != 0 && ($uid < 1000 || $uid >= 65534)));
    # Offer only names accepted by the guest-key API.
    next if (!defined($name) || $name !~ /\A[a-z_][a-z0-9_.-]{0,31}\$?\z/i);
    # Empty shells are allowed; known commands that prevent login are omitted.
    next if (($shell // '') =~ m{(?:\A|/)(?:nologin|false|sync|halt|shutdown)\s*\z});
    # Duplicate passwd records must not produce duplicate choices.
    push(@accounts, $name) if (!$seen{$name}++);
}
# Keep preferred accounts first without repeating them in the sorted tail.
my %first = map { $_ => 1 } grep { $seen{$_} } @preferred;
return [(grep { $first{$_} } @preferred), (sort grep { !$first{$_} } @accounts)];
}

# guest_login_accounts(vm) reads the running guest's account list through the
# agent. Returns undef when the guest, session or agent cannot provide it.
# Callers choose their fallback. show_vm_access scopes a cache to one rendering.
sub guest_login_accounts
{
my ($vm) = @_;
# Agent file reads are a write-capable channel, kept from read-only sessions.
return undef if (!can_access('manage'));
# Stopped guests cannot answer; avoid opening an agent channel for them.
return undef if (defined($vm->{'state'}) && $vm->{'state'} !~ /\A(?:running|blocked)\z/);
my $id = $vm->{'uuid'};
return $guest_login_accounts_cache->{$id}
    if ($guest_login_accounts_cache && exists($guest_login_accounts_cache->{$id}));
my $passwd = eval { get_libvirt(1)->read_guest_file($id, '/etc/passwd', 262144) };
# Preserve failures as undef and prefer the creation account when it exists.
my $accounts = defined($passwd)
    ? login_accounts($passwd, ($vm->{'cloudmin'} || {})->{'username'} || ()) : undef;
# Cache only inside the page's local scope, never across CGI requests.
$guest_login_accounts_cache->{$id} = $accounts if ($guest_login_accounts_cache);
return $accounts;
}

# call_ssh_key_api(action, input) dispatches synchronous key requests.
# input holds the action fields and a token for writes or private downloads.
sub call_ssh_key_api
{
my ($action, $input) = @_;
my $manager = get_ssh_key_manager();
# Ordinary inventory never returns private key material.
return $input->{'key'} ? $manager->get($input->{'key'}) : $manager->list() if ($action eq 'ssh_keys');
# Only public inventories bypass the write permission and token checks.
if ($action ne 'guest_ssh_keys') {
    require_access('manage');
    get_image_jobs()->check_token($remote_user, $input->{'token'});
}
my $result;
# Translate the API library selector into the store's record identifier.
if ($action eq 'save_ssh_key') {
    my %fields = %$input;
    $fields{'id'} = delete($fields{'key'});
    $result = $manager->save(\%fields);
}
# Library deletion needs confirmation and the last reviewed revision.
elsif ($action eq 'delete_ssh_key') {
    die "Confirm SSH key deletion\n" if (($input->{'confirm'} || '') ne '1');
    $result = $manager->remove($input->{'key'}, $input->{'revision'});
}
elsif ($action eq 'download_ssh_key') {
    # Private material requires write access and a token; log only its name.
    my $private = $manager->download($input->{'key'});
    webmin_log($action, 'sshkey', $input->{'key'}, {name => $manager->get($input->{'key'})->{'name'}});
    return {private => $private};
}
elsif ($action eq 'guest_ssh_keys') {
    # Listing changes nothing, so a slow agent must not hold the host lock
    # that creation, cloning and password resets share.
    get_vm_jobs()->assert_guest_available($input->{'id'} || '');
    my ($service) = guest_ssh_service($input->{'id'});
    return $service->inventory($input->{'username'});
}
elsif ($action =~ /\A(?:add_guest_ssh_key|remove_guest_ssh_key)\z/) {
    # Share the guest reservation lock with backups, clones and password resets.
    # The lock callback takes no arguments and rechecks availability inside it.
    return get_vm_jobs()->lock('create-host', sub {
        get_vm_jobs()->assert_guest_available($input->{'id'} || '');
        my ($service, $vm) = guest_ssh_service($input->{'id'});
        my $result;
        # Resolve one input source to public text before contacting the guest.
        if ($action eq 'add_guest_ssh_key') {
            die "Select a saved key or paste public keys, not both\n"
                if ($input->{'key'} && length($input->{'public'} || ''));
            die "Select a saved key or paste public keys\n"
                if (!$input->{'key'} && !length($input->{'public'} || ''));
            my $public = $input->{'key'} ? $manager->get($input->{'key'})->{'public'} : $input->{'public'};
            $result = $service->add($input->{'username'}, $public);
        }
        else {
            # Removal targets a reviewed guest line, not a library entry.
            die "Confirm removal of the guest SSH key\n" if (($input->{'confirm'} || '') ne '1');
            $result = $service->remove(@$input{qw(username key revision)});
        }
        # Audit the account and guest identity without recording key material.
        webmin_log($action, 'vm', $vm->{'uuid'}, {name => $vm->{'name'}, username => $input->{'username'}});
        return { %$result, id => $vm->{'uuid'}, name => $vm->{'name'} };
    });
}
else {
    # Unknown actions must not fall through to a success response.
    die "Unknown SSH key action\n";
}
# Library changes log only the entry ID and its display name.
webmin_log($action, 'sshkey', $result->{'id'}, {name => $result->{'name'}});
return $result;
}

1;
