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

1;
