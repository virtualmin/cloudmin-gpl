#!/usr/bin/perl
# Exercise automatic image checks on a disposable Cloudmin host.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
use File::Temp qw(tempdir);
use Digest::SHA ();
use MIME::Base64 ();

BEGIN
{
$webmin_root = abs_path("$FindBin::Bin/../../..");
die "Run only on a disposable Linux VM as root\n"
	unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$webmin_root/server-manager") || die $!;
$0 = "$webmin_root/server-manager/check-image-inspection.pl";
}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
require './lib/Cloudmin/ImageInspector.pm';
require Sys::Guestfs;
$| = 1;

# digest(path) Detects any change to the reusable source disk during inspection.

sub digest
{
open(my $fh, '<', $_[0]) || die $!;
binmode($fh);
return Digest::SHA->new(256)->addfile($fh)->hexdigest();
}

# command(arguments...) - Builds and inspects only this test's disposable copy.

sub command
{
my ($out, $err);
my $status = execute_command_logged(join(' ', map { quote_path($_) } @_),
				    undef, \$out, \$err, 0, 1);
die($err || $out || 'Fixture command failed') if ($status);
return $out;
}

my $service = get_vm_service();
my $options = $service->options();
my ($image) = grep { $_->{'name'} =~ /^Ubuntu/ && $_->{'cloud_init'} }
	      @{$options->{'images'}};
die "Import an Ubuntu cloud image first\n" if (!$image);
my $before = digest($image->{'volume_path'});
my ($pool) = grep { $_->{'name'} eq 'default' } @{$options->{'pools'}};
my ($network) = grep { $_->{'name'} eq 'default' } @{$options->{'networks'}};
my $key = 'ssh-ed25519 '.
	  MIME::Base64::encode_base64(pack('N', 11).'ssh-ed25519'.pack('N',
								       32).
				      ('A' x 32), '');
my $minimum = $image->{'min_disk_bytes'} || $image->{'virtual_size'};
my $input = { name => 'cloudmin-inspection-check', image => $image->{'id'},
	      pool => $pool->{'id'}, network => $network->{'key'}, cpus => 1,
	      memory_mib => 512,
	      disk_gib => int(($minimum + 1024**3 - 1) / 1024**3),
	      username => 'cloudmin',
	      ssh_keys => $key, address_mode => 'dhcp', start => 0,
	      autostart => 0 };

# Remove only the test's metadata view to exercise a real disk
# through full preflight.
my $custom = { %$image, architecture => undef, cloud_init => undef };
my $review = $service->prepare($input, { %$options, images => [ $custom ] });
die "Detected architecture differs from host\n"
	if ($review->{'architecture'}
	    ne $options->{'capabilities'}->{'architecture'});
die "Manual confirmation remains\n" if (exists($review->{'image_compatible'}));
print "Custom image passes full preflight through automatic disk inspection\n";

# Change only an independent fixture copy to prove disabled
# cloud-init is rejected.
my $work = tempdir('cloudmin-inspection-fixture-XXXXXX', DIR => '/var/tmp',
		   CLEANUP => 1);
my $copy = "$work/disabled.qcow2";
command('qemu-img', 'convert', '-f', $image->{'format'}, '-O', 'qcow2',
	$image->{'volume_path'}, $copy);
my $g = Sys::Guestfs->new();
$g->set_backend('direct');
$g->set_network(0);
$g->add_drive_opts($copy, format => 'qcow2', readonly => 0);
$g->launch();
# Mount only the independent copy before disabling its cloud-init installation.
my ($root) = $g->inspect_os();
my %mounts = $g->inspect_get_mountpoints($root);
foreach my $mount (sort { length($a) <=> length($b) } keys %mounts) {
	$g->mount($mounts{$mount}, $mount);
	}
$g->write('/etc/cloud/cloud-init.disabled', '');
$g->shutdown();
$g->close();
# The real inspector must explain the rejection without modifying the source.
my $accepted = eval { command('timeout', '--kill-after=5', '180',
			      $^X, './inspect-image.pl', $copy, 'qcow2'); 1 };
die "Disabled cloud-init was accepted\n" if ($accepted);
die "Unexpected inspection failure: $@" if ($@ !~ /Cloud-init is disabled/);
print "Disabled cloud-init is rejected in a real disk image\n";
die "Inspection modified the reusable source\n"
	if (digest($image->{'volume_path'}) ne $before);
print "Source checksum unchanged; fixture copy removed on exit\n";
