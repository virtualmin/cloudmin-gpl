#!/usr/bin/perl
# Temporary accounts for live UI and ACL checks on a disposable Linux VM. Usage:
# create|create-readonly|create-other|create-editor|acl|files|
# readonly|servers|delete
#        [theme] [username] [logging]
# Read the password from standard input for creation. The username defaults to
# cloudmin-ui-check; logging grants access only to this fixture's action log.
# create-other grants only the Running Processes module, for access-denial
# checks. create-editor allows editing only cloudmin-ui-check's Cloudmin ACL.
# acl reads Cloudmin grants as JSON from standard input. readonly reads 0 or 1
# to change an existing fixture's global read-only mode. The optional theme
# applies only to this account and is ignored for deletion. root-session returns
# a temporary root session and its configured theme as JSON; capture it
# privately. delete-root-session reads that session from stdin.

use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);

# Require a root-run Linux test host before loading Webmin's administration API.
my $root;

BEGIN
{
die "Run only on a disposable Linux VM as root\n"
	unless $^O eq 'linux' && $< == 0;
# Keep this session helper inaccessible through HTTP.
die "Run from a root shell, not HTTP\n"
	if ($ENV{'GATEWAY_INTERFACE'} || $ENV{'REQUEST_METHOD'});
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
$root = abs_path("$Bin/../../..");
chdir($root) or die "Cannot enter Webmin directory: $!";
unshift(@INC, $root);
$0 = "$root/cloudmin-ui-check.pl";
}
use WebminCore;
our $current_theme;
init_config();
foreign_require('acl', 'acl-lib.pl');

my ($action, $theme, $username, $logging) = @ARGV;
# Root-only proxy tests use a short-lived session without reading or changing
# root's password, theme or permissions. Callers capture this output privately.
if (($action || '') eq 'root-session') {
	my %miniserv;
	get_miniserv_config(\%miniserv);
	my $sid = acl::create_session_user(\%miniserv, 'root', 3600);
	# Do not print a credential response if session creation failed.
	die "Cannot create test session\n" if (!$sid);
	# Miniserv keeps its session database open; refresh
	# its view of this write.
	reload_miniserv();
	print convert_to_json({ sid => $sid, theme => $current_theme });
	exit;
	}
# Remove only the session supplied by the caller, never other root sessions.
elsif (($action || '') eq 'delete-root-session') {
	my $sid = <STDIN>;
	chomp($sid);
	# Require the exact session to remove.
	die "Invalid test session\n" if (!$sid || $sid !~ /\A[a-f0-9]+\z/);
	my %miniserv;
	get_miniserv_config(\%miniserv);
	acl::delete_session_id(\%miniserv, acl::hash_session_id($sid));
	reload_miniserv();
	exit;
	}
$username ||= 'cloudmin-ui-check';
# Separate fixtures must not replace another live check's account.
die "Invalid fixture username\n"
	if (
		$username !~ /\Acloudmin-(?:ui|frame|spa|terminal)-check(?:-[a-f0-9]{8})?\z/);
my @existing = acl::list_users([ $username ]);
# Keep the fixture local-only and refuse to overwrite an existing account.
if (($action || '') =~ /\Acreate(?:-readonly|-other|-editor)?\z/) {
	die "Test user already exists\n" if (@existing);
	# Only an installed theme directory can be assigned to the account.
	die "Unknown theme\n"
		if (defined($theme) &&
		    ($theme !~ /\A[a-z0-9-]+\z/ || !-d "$root/$theme"));
	my $password = <STDIN>;
	die "No fixture password supplied\n" unless defined($password);
	chomp($password);
	die "Fixture password too short\n" unless length($password) >= 32;
	# A user outside Cloudmin proves that shared routes check module access.
	my @modules = $action eq 'create-other'
		? ('proc')
		: ( 'server-manager', ($action eq 'create-editor' ? 'acl' : ()),
		    ($logging ? 'webminlog' : ()) );
	# Webmin stores a per-user theme in both its config
	# and miniserv's preroot.
	acl::create_user({
		'name' => $username,
		'pass' => acl::encrypt_password($password),
		'modules' => \@modules,
		'allow' => '127.0.0.1',
		(defined($theme) ? ( 'theme' => $theme ) : ()),
	});
	# Log fixtures can read only their own Cloudmin
	# actions, without rollback.
	if ($logging) {
		save_module_acl({ users => $username, mods => 'server-manager',
				  notify => 0, rollback => 0 }, $username,
				'webminlog');
		}
	# The editor fixture cannot create users or alter other
	# accounts or modules.
	if ($action eq 'create-editor') {
		my %editor = get_module_acl($username, 'acl');
		# Clear inherited grants, then allow editing only the
		# target Cloudmin ACL.
		$_ = 0 for values %editor;
		@editor{qw(acl mode mods users noconfig)} =
			( 1, 2, 'server-manager', 'cloudmin-ui-check', 1 );
		save_module_acl(\%editor, $username, 'acl');
		}
	# Read-only mode is a global ACL, separate from an
	# externally managed user.
	if ($action eq 'create-readonly') {
		my $aclfile = "/etc/webmin/$username.acl";
		lock_file($aclfile);
		save_module_acl({ readonly => 1 }, $username, '', 1);
		unlock_file($aclfile);
		}
	}
# acl can update only an existing test account.
elsif (($action || '') eq 'acl') {
	die "Test user does not exist\n" if (!@existing);
	# Accept only the Cloudmin permission fields used by these tests.
	my $input = do { local $/; <STDIN> };
	my $acl = convert_from_json($input);
	die "Invalid fixture ACL\n" if (ref($acl) ne 'HASH' ||
					grep {
			!/\A(?:admin|vms|power|force|console|terminal|password)\z/ } keys %$acl);
	# Match the production editor's rule for access to Webmin
	# module configuration.
	$acl->{'noconfig'} = ($acl->{'admin'} || '') eq '1' ? 0 : 1;
	save_module_acl($acl, $username, 'server-manager');
	}
# servers explicitly grants the fixture access to the host's native proxy.
elsif (($action || '') eq 'servers') {
	# Add the module only to an existing fixture account.
	die "Test user does not exist\n" if (!@existing);
	my $user = $existing[0];
	# Repeated setup must not duplicate module entries.
	push(@{$user->{'modules'}}, 'servers')
		if (!grep { $_ eq 'servers' } @{$user->{'modules'}});
	acl::modify_user($username, $user);
	save_module_acl({ edit => 1, add => 1, links => 1, servers => '*' },
			$username, 'servers');
	}
# files grants the fixture read access to its temporary scripts as nobody.
elsif (($action || '') eq 'files') {
	die "Test user does not exist\n" if (!@existing);
	my $path = <STDIN>;
	chomp($path);
	die "Invalid fixture script directory\n"
		if ($path !~ m{\A/tmp/cloudmin-create-key-[a-zA-Z0-9_-]+\z} ||
		    !-d $path);
	my %global = get_module_acl($username, '');
	@global{qw(root fileunix)} = ( $path, 'nobody' );
	save_module_acl(\%global, $username, '', 1);
	}
# Change only the fixture's global flag, preserving its
# session and module grants.
elsif (($action || '') eq 'readonly') {
	die "Test user does not exist\n" if (!@existing);
	my $value = <STDIN>;
	die "Expected read-only flag 0 or 1\n"
		if (!defined($value) || $value !~ /\A[01]\n?\z/);
	chomp($value);
	my $aclfile = "/etc/webmin/$username.acl";
	lock_file($aclfile);
	my %global = get_module_acl($username, '');
	$global{'readonly'} = 0 + $value;
	save_module_acl(\%global, $username, '', 1);
	unlock_file($aclfile);
	}
# Webmin also removes the deleted user's module ACLs and active sessions.
elsif (($action || '') eq 'delete') {
	# Repeated cleanup also removes preferences left after account deletion.
	acl::delete_user($username);
	}
# Reject unexpected actions without changing the Webmin account list.
else {
	die "Expected create, create-readonly, create-other, create-editor, acl, readonly or delete, followed by optional theme and username\n";
	}
# Module ACL saves take effect directly, as in Webmin's permission editor.
reload_miniserv() if (($action || '') !~ /\A(?:acl|readonly)\z/);
