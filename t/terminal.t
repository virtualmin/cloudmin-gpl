use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use WebminCore;
our (%text, %config, %access);
our $remote_user = 'fixture';
our $root_directory = $CloudminTest::webmin_root;
our $module_root_directory = "$Bin/..";
our $module_var_directory = tempdir(CLEANUP => 1);
# Test terminal policy and navigation without a systemd or libvirt connection.
require "$Bin/../cloudmin-pages.pl";
require "$Bin/../cloudmin-terminal-lib.pl";
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if (/^([^=]+)=(.*)$/); }
my $readonly = 0;
# is_readonly_mode() supplies mutable fixture permissions without host ACLs.
{ no warnings 'redefine'; *is_readonly_mode = sub { $readonly }; }
my $uuid = '00000000-1111-2222-3333-444444444444';
my $vm = { uuid => $uuid, name => '<guest>', state => 'running', addresses => [
	map { { address => $_ } }
	qw(192.0.2.10 2001:db8::1 127.0.0.1 ::1 :: fe80::1 169.254.1.1) ] };
is_deeply([ list_terminal_addresses($vm) ], [ '192.0.2.10', '2001:db8::1' ],
	  'only routable guest addresses are offered');
my $request = parse_terminal_request($vm,
				     { username => 'root', port => 22,
				       address => '192.0.2.10' });
is($request->{'uuid'}, $uuid, 'request is bound to the current guest');
# Saved ports follow the guest UUID across users and hypervisor changes.
is(get_terminal_port($uuid), 22, 'new guest defaults to port 22');
save_terminal_port($uuid, 2222);
is(get_terminal_port($uuid), 2222, 'successful login port persists');
my %ports;
read_file("$module_var_directory/ssh-ports", \%ports);
is_deeply(\%ports, { $uuid => 2222 }, 'saved port uses only the guest UUID');
is((stat("$module_var_directory/ssh-ports"))[2] & 0777, 0600,
   'saved ports are private');
{
	local $config{'libvirt_uri'} = 'qemu+ssh://other/system';
	is(get_terminal_port($uuid), 2222,
	   'guest keeps its port after a hypervisor change');
	}
is(get_terminal_port('00000000-1111-2222-3333-555555555555'), 22,
   'another guest does not inherit the saved port');
# A failed or abandoned attempt pauses automatic login for only this account.
is_deeply(get_terminal_login($uuid), { },
	  'new account has no previous attempt');
save_terminal_login($uuid, 'a' x 32, 'pending',
		    { %$request, password => 'never-save',
		      key => '/private/key' });
my $login = get_terminal_login($uuid);
is($login->{'state'}, 'pending', 'attempt starts pending');
ok(!exists($login->{'password'}) && !exists($login->{'key'}),
   'login state excludes credentials');
is((stat(terminal_login_file($uuid)))[2] & 0777, 0600,
   'login state is private');
save_terminal_login($uuid, 'a' x 32, 'failed');
is(get_terminal_login($uuid)->{'state'}, 'failed', 'failure remains saved');
# Only the current attempt can clear the pause for this Webmin account.
save_terminal_login($uuid, 'b' x 32, 'pending', $request);
save_terminal_login($uuid, 'a' x 32, 'connected');
is(get_terminal_login($uuid)->{'state'}, 'pending',
   'older success cannot clear a newer pending attempt');
save_terminal_login($uuid, 'b' x 32, 'connected');
is(get_terminal_login($uuid)->{'state'}, 'connected',
   'successful authentication enables automatic connection');
# Native lock and write errors must preserve state and release only owned locks.
# Each save() callback attempts to replace its file with a new fixture value.
for my $case (
	[ 'ports', "$module_var_directory/ssh-ports",
	  sub { save_terminal_port($uuid, 2200) } ],
	[ 'login', terminal_login_file($uuid),
	  sub { save_terminal_login($uuid, 'c' x 32, 'pending',
				    $request) } ] ) {
	my ($name, $file, $save) = @$case;
	my $before = read_file_contents($file);
	# A directory prevents Webmin from creating its lock
	# without changing the data.
	mkdir("$file.lock") or die $!;
	ok(!eval { $save->(); 1 },
	   "$name rejects a failed lock acquisition");
	like($@, qr/Cannot lock/,
	     "$name reports the lock failure");
	is(read_file_contents($file), $before,
	   "$name lock failure preserves saved values");
	rmdir("$file.lock") or die $!;
	# A nested caller must not write or release a lock it did not acquire.
	lock_file($file) or die "Cannot lock fixture\n";
	ok(!eval { $save->(); 1 },
	   "$name rejects an already held lock");
	ok(-f "$file.lock",
	   "$name keeps the caller's lock");
	is(read_file_contents($file), $before,
	   "$name nested call leaves saved values alone");
	unlock_file($file);
	# A real write error must throw through eval, even in a page request.
	rename($file, "$file.saved") or die $!;
	mkdir($file) or die $!;
	{
		local $main::error_must_die = 0;
		ok(!eval { $save->(); 1 }, "$name catches native write errors");
		ok($@, "$name returns a write error to its caller");
		ok(!-e "$file.lock",
		   "$name releases its lock after a write error");
		is($main::error_must_die, 0,
		   "$name restores the caller's error handling");
		}
	rmdir($file) or die $!;
	rename("$file.saved", $file) or die $!;
	}
{
	# User names remain one filename component and cannot share login state.
	local $remote_user = 'other/account';
	is_deeply(get_terminal_login($uuid), { },
		  'accounts have separate connection state');
	unlike(terminal_login_file($uuid), qr/other\/account/,
	       'account names cannot add path components');
	}
# Invalid writes must leave the last authenticated port unchanged.
for my $port ( 0, 65536, '22 -oProxyCommand=sh' ) {
	ok(!eval { save_terminal_port($uuid, $port); 1 },
	   'invalid saved port rejected');
	is(get_terminal_port($uuid), 2222,
	   'invalid port leaves previous success intact');
	}
foreach my $bad ( { username => '-oProxyCommand=sh' },
		  { address => '192.0.2.20' },
		  { address => '127.0.0.1' },
		  { port => '22 -oProxyCommand=sh' },
		  { port => 0 },
		  { port => 65536 } ) {
	my $ok = eval { parse_terminal_request($vm,
					       { %$request, %$bad }); 1 };
	ok(!$ok, 'reject untrusted destination or SSH option');
	}
$readonly = 1;
ok(!eval { save_terminal_port($uuid, 2200); 1 },
   'read-only access cannot save ports');
ok(!eval { parse_terminal_request($vm, $request); 1 },
   'read-only users cannot start SSH');
$readonly = 0;
ok(!eval { parse_terminal_request({ %$vm, state => 'shutoff' }, $request); 1 },
   'stopped guest cannot start SSH');
my @command =
	build_terminal_command($request, 'a' x 32, 'admin', '/private/session');
my $command = join(' ', @command);
like($command, qr/DynamicUser=yes/,
     'SSH runs with an unprivileged dynamic UID');
like($command, qr/EscapeChar=none/, 'SSH local shell escapes disabled');
like($command, qr/StrictHostKeyChecking=ask/, 'host key requires confirmation');
like($command, qr/IdentityAgent=none/, 'host agent unavailable');
like($command, qr/InaccessiblePaths=-\/etc\/webmin/,
     'Webmin credentials inaccessible');
is_deeply([ @command[-5 .. -1] ], [ '-p', 22, '-l', 'root', '192.0.2.10' ],
	  'destination is separate argv');
ok(!eval { build_terminal_command($request, '../bad', 'admin',
				  '/private/session'); 1 },
   'unit name cannot contain a path');
# Remote inventory cannot select a local credential with matching metadata.
{
	local $config{'libvirt_uri'} = 'qemu+ssh://remote/system';
	ok(!get_terminal_key({ %$vm, cloudmin => { job => 'a' x 32 } }),
	   'remote guests cannot borrow local VM keys');
	}
# The server resolves key paths from VM ownership, ignoring submitted paths.
{
	no warnings 'redefine';
	# get_terminal_key(vm) resolves the fixture key
	# independently of form input.
	local *get_terminal_key = sub { '/private/vm-key' };
	my $key_request = parse_terminal_request($vm,
						 { %$request, auth => 'key',
						   key => '/etc/shadow' });
	is($key_request->{'key'}, '/private/vm-key',
	   'submitted key paths cannot select host files');
	my $key_command = join(' ',
			       build_terminal_command($key_request, 'c' x 32,
						      'admin',
						      '/private/session'));
	like($key_command, qr/LoadCredential=ssh-key:\/private\/vm-key/,
	     'only the selected key is passed as a credential');
	like($key_command, qr/--setenv=CLOUDMIN_TERMINAL_KEY=1/,
	     'key login explicitly enables the SSH credential');
	like($key_command, qr/PreferredAuthentications=publickey/,
	     'key login does not fall back to passwords');
	like($key_command, qr/IdentitiesOnly=yes/,
	     'other SSH identities are not tried');
	# get_terminal_key(vm) simulates a guest with no saved login key.
	local *get_terminal_key = sub { undef };
	ok(!eval { parse_terminal_request($vm, { %$request,
						 auth => 'key' }); 1 },
	   'missing key fails before starting SSH');
	}
ok(!eval { parse_terminal_request($vm, { %$request, auth => 'agent' }); 1 },
   'unknown authentication is rejected');
unlike($command, qr/LoadCredential=ssh-key:/,
       'password login receives no private key');
unlike($command, qr/CLOUDMIN_TERMINAL_KEY=/,
       'password login does not try to load a key from session credentials');
my @second =
	build_terminal_command($request, 'b' x 32, 'different',
			       '/private/session');
my ($home) = grep { /^--setenv=HOME=/ } @command;
my ($other) = grep { /^--setenv=HOME=/ } @second;
isnt($home, $other, 'Webmin users retain separate guest host keys');

# Check both editions independently of the installed Pro extension.
local $module_root_directory = tempdir(CLEANUP => 1);
# Match Virtualmin's create/selection/actions/divider/global-link ordering.
my $stopped = { uuid => '11111111-2222-3333-4444-555555555555',
		name => 'stopped', state => 'shutoff' };
my @menu = get_menu_items([ $vm, $stopped ], $uuid, 0, 1);
is_deeply(
	[ @{$menu[0]}{qw(type id)} ], [ 'title', 'title' ],
	'menu starts with the title item frame themes use for the Cloudmin tab');
my @links = map { un_urlize($_->{'link'}) }
	    grep { $_->{'type'} && $_->{'type'} eq 'item' } @menu;
is_deeply(
	\@links,
	[ map { '/server-manager/'.$_ } ( 'machine_form.cgi',
					  'machine.cgi?id='.$uuid,
					  'edit_machine.cgi?id='.$uuid,
					  'snapshots.cgi?id='.$uuid,
					  'remote_access.cgi?id='.$uuid,
					  'notifications.cgi?id='.$uuid,
					  'statistics.cgi?id='.$uuid,
					  'index.cgi',
					  'images.cgi', 'storage.cgi',
					  'networks.cgi',
					  'snapshots.cgi', 'backups.cgi',
					  'jobs.cgi', 'notifications.cgi',
					  'statistics.cgi' ) ],
	'guest links precede global tools, with notifications before statistics');
# Module configuration and presets share Virtualmin's settings category.
my ($settings) = grep { ($_->{'type'} || '') eq 'cat' } @menu;
is($settings->{'id'}, 'global_setting', 'settings use Virtualmin category ID');
is($settings->{'desc'}, 'System Settings', 'settings category label');
is_deeply(
	[ map { $_->{'link'} } @{$settings->{'members'}} ],
	[ '/config.cgi?server-manager', '/server-manager/edit_newtmpl.cgi',
	  '/server-manager/edit_newplan.cgi',
	  '/server-manager/ssh_keys.cgi' ],
	'configuration, presets and the SSH key preview are under System Settings');
my ($key_preview) =
	grep { ($_->{'link'} ||
		'') eq
		'/server-manager/ssh_keys.cgi' } @{$settings->{'members'}};
like($key_preview->{'desc'}, qr/data-pro-disabled="ssh-keys-link"/,
     'GPL menu has the shared Pro badge');
unlike($key_preview->{'desc'}, qr/<a\b/,
       'the badge does not nest links inside the menu link');
# The GPL library preview follows the shared Pro-tip preference.
{
	local $config{'hide_pro_tips'} = 1;
	my ($hidden_settings) =
		grep { ($_->{'type'} || '') eq 'cat' } get_menu_items([ $vm ],
								      $uuid, 0,
								      1);
	ok(!grep({ ($_->{'link'} ||
		    '') =~ /ssh_keys\.cgi/ } @{$hidden_settings->{'members'}}),
	   'hidden Pro tips omit the GPL key library preview');
	}
my ($selector) = grep { ($_->{'type'} || '') eq 'menu' } @menu;
is($selector->{'name'}, 'sid', 'use the Cloudmin guest selector');
is($selector->{'menu'}->[0]->[1], '&lt;guest&gt;', 'guest labels escaped');
@menu = get_menu_items([ $vm, $stopped ], $stopped->{'uuid'}, 0, 1);
ok(grep({ ($_->{'link'} || '') =~ /remote_access\.cgi/ } @menu),
   'stopped guest keeps its terminal action');
@menu = get_menu_items([ $vm ], $uuid, 0, 0);
ok(grep({ ($_->{'link'} || '') =~ /remote_access\.cgi/ } @menu),
   'missing terminal dependency keeps the explanatory page accessible');
@menu = get_menu_items([ $vm ], $uuid, 1, 1);
ok(!grep({ ($_->{'link'} ||
	    '') =~ /(?:remote_access|terminal|machine_form|edit_machine)\.cgi/ }
	 @menu), 'read-only menu has no mutation actions');
# Either grant shows one Remote access entry, with no separate SSH link.
for my $grant ( 'terminal', 'console' ) {
	no warnings qw(redefine once);
	# can_access(action, [uuid]) enables only the grant under test.
	local *main::can_access = sub { $_[0] eq $grant };
	@menu = get_menu_items([ $vm ], $uuid, 0, 1);
	my @console =
		grep { ($_->{'link'} || '') =~ /remote_access\.cgi/ } @menu;
	is(scalar(@console), 1, "$grant permission exposes one Console entry");
	is($console[0]->{'desc'}, $text{'console_title'},
	   'sidebar uses the Remote access label');
	}
@menu = get_menu_items([ ], undef, 0, 1);
ok(!grep({ ($_->{'type'} || '') eq 'menu' } @menu),
   'empty inventory has no selector');
is(scalar(grep { ($_->{'type'} || '') eq 'item' } @menu), 10,
   'empty menu keeps creation and global links');
@menu = get_menu_items([ $vm, $stopped ], 'removed', 0, 1);
($selector) = grep { ($_->{'type'} || '') eq 'menu' } @menu;
is($selector->{'value'}, $uuid,
   'stale selection falls back to first visible guest');
# Guest keys live in the editor; the saved-key library stays in System Settings.
make_path("$module_root_directory/pro");
open(my $pro, '>', "$module_root_directory/pro/SSHKeys.pm") || die $!;
close($pro);
@menu = get_menu_items([ $vm ], $uuid, 0, 1);
ok(!grep({ ($_->{'link'} || '') =~ /pro\/guest_keys\.cgi/ } @menu),
   'guest SSH Keys has no separate sidebar entry');
# Read-only Pro navigation goes directly to the SSH inventory tab.
my @readonly_menu = get_menu_items([ $vm ], $uuid, 1, 1);
ok(grep({ un_urlize($_->{'link'} || '') eq
	"/server-manager/edit_machine.cgi?id=$uuid&vm_edit_tabs=access&vm_access_tabs=ssh_keys" } @readonly_menu),
   'read-only Pro sessions can inspect keys through Access');
($settings) = grep { ($_->{'type'} || '') eq 'cat' } @menu;
ok(
	grep(
		{ $_->{'link'} eq '/server-manager/pro/list_keys.cgi' } @{
			$settings->{'members'}}),
	'Pro library appears under System Settings');
{
	# A power-only delegate must not inherit the host's key-library links.
	local %access = ( admin => 0, power => 1, vms => $uuid );
	@menu = get_menu_items([ $vm ], $uuid, 0, 1);
	ok(!grep({ ($_->{'link'} ||
		    '') =~ /pro\/(?:guest_keys|list_keys)/ } @menu),
	   'delegated accounts have no SSH key management link');
	ok(!grep({ ($_->{'type'} || '') eq 'cat' } @menu),
	   'delegated accounts have no host key library category');
	}
done_testing();
