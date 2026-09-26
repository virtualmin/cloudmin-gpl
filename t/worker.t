use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
require "$Bin/../lib/Cloudmin/Worker.pm";

my $runner = Cloudmin::Worker->new();
# Large import budgets must reach systemd, while malformed budgets fail early.
my @large = $runner->command('image', 'a'x32, 32 * 1024**3);
ok(grep($_ eq 'LimitFSIZE=34359738368', @large),
	'image workers honor a configured budget above 8 GiB');
for my $bad (0, -1, '1.5', 'infinity', "10\n", {}, 9007199254740992) {
	ok(!eval { Cloudmin::Worker::byte_limit($bad); 1 },
		'invalid or inexact byte budgets are rejected');
	}
for my $task (qw(image local_image inspect clone_prepare seed keys size)) {
	my @command = $runner->command($task, 'a'x32);
	my %properties;
	for my $i (0..$#command-1) {
		$properties{$1} = $2
			if ($command[$i] eq '--property' &&
			$command[$i+1] =~ /^([^=]+)=(.*)$/);
		}
	is($properties{'DynamicUser'}, 'yes',
		"$task requests a temporary non-root user ID");
	is($properties{'NoNewPrivileges'}, 'yes',
		"$task cannot regain privilege through executables");
	is($properties{'CapabilityBoundingSet'}, '',
		"$task has no Linux capabilities");
	is($properties{'KillMode'}, 'control-group',
		"$task cleanup includes external tool children");
	is($properties{'ProtectSystem'}, 'strict',
		"$task cannot change the host filesystem");
	like($properties{'InaccessiblePaths'},
		qr{/etc/webmin.*?/var/webmin.*?/var/lib/libvirt},
		"$task cannot open credentials, jobs or host VM files");
	is($properties{'TemporaryFileSystem'}, '/run:ro',
		"$task cannot reach host control sockets");
	is($properties{'PrivateNetwork'},
		$task eq 'image' || $task eq 'size' ? 'no' : 'yes',
		"$task gets network access only when required");
	ok(!exists($properties{'SupplementaryGroups'}) ||
		$properties{'SupplementaryGroups'} eq 'kvm',
		"$task is never granted a libvirt management group");
	my @kernel = grep { /^--setenv=SUPERMIN_/ } @command;
    is(scalar(@kernel), $task eq 'inspect' || $task eq 'clone_prepare' ? 3 : 0,
		"$task receives appliance kernel settings only for disk inspection");
	# Both appliance tasks need the private kernel and bsdtar view.
	if ($task eq 'inspect' || $task eq 'clone_prepare') {
		ok(grep($_ eq 'BindReadOnlyPaths=/usr/bin/bsdtar:/usr/bin/tar',
			@command),
			'appliance uses stock bsdtar without disabling DynamicUser restrictions');
		like($kernel[0],
			qr{=/var/lib/cloudmin-workers/a{32}/appliance-kernel\z},
			'inspection uses a private kernel copy instead of changing /boot permissions');
		my $release = Cloudmin::Worker::kernel_release();
		is($kernel[1],
			"--setenv=SUPERMIN_MODULES=/lib/modules/$release",
			'appliance modules match the copied running kernel');
		}
	}
for my $id ('../escape', 'a'x31, 'a'x33, "a\n".('a'x31), 'bad;id') {
	ok(!eval { $runner->command('keys', $id); 1 },
		'unsafe service identifiers are rejected');
	}
ok(!eval { $runner->command('shell', 'a'x32); 1 },
	'arbitrary operations cannot be requested');
ok(!eval { $runner->command('page', 'a'x32); 1 },
	'CGI requests are not worker tasks');

# Output from a compromised worker must not turn the root process into a link
# copier.
my $tmp = tempdir(CLEANUP => 1);
open(my $fh, '>', "$tmp/input") || die $!;
print($fh 'private fixture'); close($fh);
ok(!eval { $runner->claim("$tmp/input", "$tmp/claimed", 4); 1 },
	'output claiming enforces the task budget before changing ownership');
ok(!-e "$tmp/claimed", 'oversized output is not claimed');
symlink("$tmp/input", "$tmp/output") || die $!;
ok(!eval { $runner->claim("$tmp/output", "$tmp/claimed"); 1 },
	'output symlinks are rejected');
ok(!-e "$tmp/claimed", 'a rejected symlink creates no output');
unlink("$tmp/output");
link("$tmp/input", "$tmp/output") || die $!;
ok(!eval { $runner->claim("$tmp/output", "$tmp/claimed"); 1 },
	'multiply linked output is rejected');
unlink("$tmp/output");
mkdir("$tmp/output") || die $!;
ok(!eval { $runner->claim("$tmp/output", "$tmp/claimed"); 1 },
	'directory output is rejected');
{
	no warnings qw(redefine once);
	local *Cloudmin::Worker::free_space = sub { return 0; };
	ok(!eval { Cloudmin::Worker::copy_file("$tmp/input", "$tmp/claimed", 4);
		1 },
		'copying cannot consume the host filesystem reserve');
	like($@, qr/Not enough free space/,
		'free-space failure takes precedence over its reduced byte budget');
	ok(!-e "$tmp/claimed", 'insufficient space leaves no partial copy');
	}
done_testing();
