use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64);
require "$Bin/../lib/Cloudmin/SSHKeys.pm";
require "$Bin/../lib/Cloudmin/VMs.pm";
require "$Bin/../lib/Cloudmin/Libvirt.pm";

# Keys are private and identified by both the guest UUID and creation job.
my $dir = tempdir(CLEANUP => 1);
my $keys = Cloudmin::SSHKeys->new("$dir/keys");
my $uuid = '11111111-2222-4333-8444-555555555555';
my $id = 'a' x 32;
ok(!$keys->find($uuid, $id), 'guests without keys need no directory');
my $path = $keys->destination($uuid, $id);
is((stat("$dir/keys"))[2] & 0777, 0700, 'key directory is private');
ok(!eval { $keys->destination('../invalid', $id); 1 },
   'UUID cannot escape the key store');
ok(!eval { $keys->destination($uuid, '../invalid'); 1 },
   'job ID cannot escape the key store');
# Existing keys can be selected but never overwritten by another creation.
open(my $fh, '>', $path) || die $!;
print $fh 'fixture-key';
close($fh);
chmod(0600, $path);
is($keys->find($uuid, $id), $path, 'protected key can be selected');
ok(!$keys->find($uuid, 'b' x 32),
   'replacement creation cannot inherit another key');
ok(!eval { $keys->destination($uuid, $id); 1 },
   'generation cannot overwrite a key');
# Reject permissions and links that would expose private key contents.
chmod(0644, $path);
ok(!eval { $keys->find($uuid, $id); 1 },
   'publicly readable private keys are rejected');
chmod(0600, $path);
link($path, "$dir/linked") || die $!;
ok(!eval { $keys->find($uuid, $id); 1 }, 'hard-linked keys are rejected');
unlink("$dir/linked");
# Cleanup is repeatable and unlinks unsafe symlinks without following them.
$keys->remove($uuid, $id);
ok(!-e $path, 'removal deletes the key');
ok(eval { $keys->remove($uuid, $id); 1 }, 'cleanup can be retried');
symlink("$dir/outside", $path) || die $!;
ok(!eval { $keys->find($uuid, $id); 1 }, 'key symlinks are rejected');
$keys->remove($uuid, $id);
ok(!-l $path, 'cleanup unlinks a symlink without following it');
# Directory permissions protect the store even when the selected key is absent.
chmod(0755, "$dir/keys");
ok(!eval { $keys->find($uuid, $id); 1 },
   'unprotected key directory is rejected');
chmod(0700, "$dir/keys");

# A host key adds access without changing the selected guest password policy.
my $public = 'ssh-ed25519 '.
	     encode_base64(pack('N', 11).'ssh-ed25519'.pack('N',
							    32).('A' x 32), '');
for my $auth (qw(password keys both)) {
	my $seed = Cloudmin::VMs::seed_data({ username => 'fixture',
					      auth_type => $auth,
					      host_public_key => $public,
					      ssh_keys => $auth eq 'password'
						      ? ''
						      : $public,
					      password_hash => 'fixture-hash',
					      hostname => 'fixture',
					      mac => '52:54:00:00:00:01',
					      address_mode => 'dhcp' }, $uuid);
	my $data = $seed->{'user-data'};
	$data =~ s/^#cloud-config\n//;
	my $user = WebminCore::convert_from_json($data);
	is(scalar(@{$user->{'users'}->[0]->{'ssh_authorized_keys'}}),
	   $auth eq 'password' ? 1 : 2,
	   "$auth keeps the host key alongside the user's selected authentication");
	is($user->{'ssh_pwauth'} ? 1 : 0, $auth eq 'keys' ? 0 : 1,
	   "$auth keeps its password policy");
	}

# The adapter calls cleanup only for local Cloudmin-owned domains.
my @removed;
# on_remove(uuid, job_id) records the ownership passed to key cleanup.
my $adapter = Cloudmin::Libvirt->new(on_remove => sub { push(@removed, [ @_ ]);
	});
$adapter->removed_guest($uuid, $id);
is_deeply(\@removed, [ [ $uuid, $id ] ],
	  'local removal forwards both ownership identifiers');
$adapter->removed_guest($uuid, undef);
is(scalar(@removed), 1, 'unmanaged guests do not trigger key cleanup');
$adapter->{'uri'} = 'qemu+ssh://remote/system';
$adapter->removed_guest($uuid, $id);
is(scalar(@removed), 1, 'remote domain removal cannot delete a local key');
done_testing();
