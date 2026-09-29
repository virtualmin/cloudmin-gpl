package Cloudmin::HostNetwork;

# Persistent host bridge changes use Webmin's network backends. A durable journal,
# boot recovery service and independent timer protect access to the host.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Socket qw(AF_INET6 inet_pton);
use IO::Socket::INET;
use File::Basename qw(dirname);
use WebminCore qw(foreign_require read_file_contents write_file_contents
	make_dir rename_logged unlink_file unflush_file_lines execute_command
	execute_command_logged get_perl_path convert_from_json convert_to_json);
require(dirname(__FILE__).'/HostBridgeRemoval.pm');

# new(class, directory => path, module => path, jobs => object,
#     [client => IP], [confirm_timeout => seconds])
# Creates a bridge manager using directory for its journal and jobs for locking.
# module contains the recovery worker; client identifies the management route.
# Tests can override command() and the backend methods without touching the host.
sub new
{
my ($class, %opts) = @_;
# Invalid hand-edited timeouts retain the three-minute recovery guard.
$opts{'confirm_timeout'} = 180 unless (defined($opts{'confirm_timeout'}) &&
	!ref($opts{'confirm_timeout'}) && $opts{'confirm_timeout'} =~ /\A\d{3}\z/ &&
	$opts{'confirm_timeout'} >= 120 && $opts{'confirm_timeout'} <= 900);
return bless(\%opts, $class);
}

# backend(self)
# Loads the same detected network backend used by Webmin's Network Configuration.
sub backend
{
my ($self) = @_;
foreign_require('net', 'net-lib.pl');
no warnings 'once';
return $net::net_mode;
}

# command(self, argv, [quiet], [safe])
# Runs argv with a 60-second timeout and shell-quotes each argument.
# quiet skips command logging; safe allows a read-only command in demo mode.
sub command
{
my ($self, $argv, $quiet, $safe) = @_;
my $out = '';
my $cmd = join(' ', map { quotemeta($_) } ('timeout', '60', @$argv));
my $rv = $quiet ? execute_command($cmd, undef, \$out, \$out, 0, $safe)
	: execute_command_logged($cmd, undef, \$out, \$out);
die "Network command failed: $out\n" if ($rv);
return $out;
}

1;
