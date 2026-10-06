use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
require "$Bin/../lib/Cloudmin/BackupSSH.pm";

# Override every trust path so these tests never read real host approvals.
my $dir = tempdir('cloudmin-backup-ssh-XXXXXX', DIR => '/tmp', CLEANUP => 1);
local $Cloudmin::BackupSSH::directory = "$dir/trust";
local @Cloudmin::BackupSSH::known_files = ("$dir/known");
my $target = {host => 'Backup.Example.test', port => 2222};
my $host = Cloudmin::BackupSSH::host($target);
is($host, '[backup.example.test]:2222', 'non-default port has its own trust identity');
is(Cloudmin::BackupSSH::host({%$target, port => 22}), 'backup.example.test', 'hostnames are normalized');
for my $bad ('-option', "host\nother", 'host/path') {
 ok(!eval {Cloudmin::BackupSSH::host({host=>$bad});1}, 'invalid scan target rejected');
}

# Public fixture keys are generated only inside the task's temporary directory.
for my $key (qw(first second)) {
 system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', "$dir/$key") == 0 or die 'keygen failed';
}
# public_key(name) reads one temporary fixture key without its comment.
sub public_key {
 my ($name) = @_;
 open(my $fh, '<', "$dir/$name.pub") or die $!;
 return Cloudmin::BackupSSH::key(<$fh>);
}
# A stubbed scan lets approval races be tested without a network connection.
my @keys = map { $host.' '.public_key($_) } qw(first second);
my $observed = [$keys[0]];
no warnings qw(redefine once);
local *Cloudmin::Worker::run = sub {return {keys => $observed}};
my $state = Cloudmin::BackupSSH::check($target);
is($state->{status}, 'unknown', 'unknown hosts need confirmation');
like($state->{current}->[0], qr/^ssh-ed25519 SHA256:\S+$/, 'confirmation uses SHA256 fingerprints');
ok(!-e $Cloudmin::BackupSSH::directory, 'checking never creates trust');
eval {Cloudmin::BackupSSH::require_trusted($target)};
like($@, qr/is unknown/, 'unattended operations refuse unknown hosts');
eval {Cloudmin::BackupSSH::approve($target, $state->{previous}, 'wrong')};
like($@, qr/changed again/, 'unreviewed keys cannot be approved');
Cloudmin::BackupSSH::approve($target, @$state{qw(previous proposed)});
is(Cloudmin::BackupSSH::check($target)->{status}, 'trusted', 'approved keys are reused');
is((stat(Cloudmin::BackupSSH::path($target)))[2] & 0777, 0600, 'trust file is private');
# Replacing a key must invalidate earlier approvals until explicitly reviewed.
$observed = [$keys[1]];
my $changed = Cloudmin::BackupSSH::check($target);
is($changed->{status}, 'changed', 'rotation needs explicit approval');
is_deeply($changed->{old}, $state->{current}, 'old fingerprint accompanies the replacement');
eval {Cloudmin::BackupSSH::require_trusted($target)};
like($@, qr/has changed/, 'scheduled operations reject changed keys');
eval {Cloudmin::BackupSSH::approve($target, @$state{qw(previous proposed)})};
like($@, qr/changed again/, 'an old confirmation cannot approve a replacement');
Cloudmin::BackupSSH::approve($target, @$changed{qw(previous proposed)});
is(Cloudmin::BackupSSH::check($target)->{status}, 'trusted', 'explicit replacement permits subsequent operations');

# Existing SSH files are read by OpenSSH, including hashed host entries.
unlink(Cloudmin::BackupSSH::path($target)) or die $!;
open(my $fh, '>', "$dir/known") or die $!; print($fh "$keys[1]\n"); close($fh);
# Hashing reports its disposable plaintext backup; retain output only on failure.
my $pid = open3(my $input, my $output, undef, 'ssh-keygen', '-H', '-f', "$dir/known");
close($input);
my $hash_log = do { local $/; <$output> };
close($output);
waitpid($pid, 0);
die "hashing failed: $hash_log" if ($? != 0);
unlink("$dir/known.old") or die "Cannot remove plaintext fixture backup: $!";
is(Cloudmin::BackupSSH::check($target)->{status}, 'trusted', 'hashed known_hosts entries need no new approval');
my $lookup = Cloudmin::BackupSSH::known($target);
like($lookup->[0], qr/^\|1\|/, 'worker receives the native hashed entry');
# External revocation must override any ordinary match or saved approval.
open($fh, '>', "$dir/known") or die $!; print($fh "\@revoked $keys[1]\n"); close($fh);
eval {Cloudmin::BackupSSH::check($target)};
like($@, qr/is revoked/, 'revoked keys cannot be approved');
done_testing();
