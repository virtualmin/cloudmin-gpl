use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore;
our ($module_root_directory, $module_var_directory, $module_config_directory,
     $remote_user, %access, %text);
# Load real integration helpers with temporary state and mocked host services.
$module_root_directory = "$Bin/..";
$module_var_directory = tempdir(CLEANUP => 1);
$remote_user = 'fixture';
require "$Bin/../cloudmin-lib.pl";
require "$Bin/../cloudmin-license-lib.pl";
require "$Bin/../cloudmin-storage-lib.pl";
require "$Bin/../cloudmin-network-lib.pl";
require "$Bin/../cloudmin-pro-lib.pl";
require "$Bin/../server-manager-lib-funcs.pl";

# Licensing uses the same fixed file as installers and repository tools.
{
	local $module_config_directory = tempdir(CLEANUP => 1);
	local $main::config_directory = $module_config_directory;
	no warnings qw(redefine once);
	local *main::cloudmin_license_host = sub { 'fixture-host' };
	my $service = get_cloudmin_license();
	is($service->{'file'}, '/etc/cloudmin-license',
	   'uses the shared license file');
	is_deeply([ grep { $_->[1] } cloudmin_license_files() ],
		  [ [ '/etc/cloudmin-license', 1 ] ],
		  'credential changes write only the shared license file');
	}

# Repository updates cover current and existing Cloudmin
# hosts, including APT auth.
my $repos =
	"baseurl=https://old:secret\@cloudmin.virtualmin.com/rpm/\n".
	"URIs: https://vm2.virtualmin.com/apt\n".
	"deb https://download.cloudmin.dev/download/repository stable main\n".
	"machine https://rc.cloudmin.dev/download login old password secret\n".
	"deb https://other:key\@software.virtualmin.com/vm apt main\n".
	"machine cloudmin.virtualmin.com login old password secret\n".
	"machine unrelated.example login keep password unchanged\n";
my $updated = cloudmin_license_repo_text($repos, '12345', 'new-fixture-key');
like($updated,
     qr{https://12345:new-fixture-key\@cloudmin\.virtualmin\.com/rpm/},
     'RPM credentials change');
like($updated, qr{https://12345:new-fixture-key\@vm2\.virtualmin\.com/apt},
     'Deb822 credentials change');
like($updated,
     qr/machine cloudmin\.virtualmin\.com login 12345 password new-fixture-key/,
     'APT auth changes');
like($updated,
     qr{https://12345:new-fixture-key\@download\.cloudmin\.dev/download/repository}, 'current repository credentials change');
like($updated,
     qr{machine https://rc\.cloudmin\.dev/download login 12345 password new-fixture-key}, 'current APT auth changes');
like($updated, qr{https://other:key\@software\.virtualmin\.com/vm},
     'Virtualmin repository credentials remain unchanged');
like($updated, qr/machine unrelated.example login keep password unchanged/,
     'other auth stanzas remain unchanged');
is(cloudmin_license_repo_text('https://cloudmin.virtualmin.com.evil.test/',
			      '12345', 'new-fixture-key'),
   'https://cloudmin.virtualmin.com.evil.test/',
   'similar hostname is not trusted');
for my $host (
	qw(rc.download.cloudmin.dev download.cloudmin.com rc.download.cloudmin.com)) {
	is(
		cloudmin_license_repo_text(
			"baseurl=https://old:secret\@$host/pro/\n",
			'12345',
			'new-fixture-key'),
		"baseurl=https://12345:new-fixture-key\@$host/pro/\n",
		"$host repository credentials change");
	is(
		cloudmin_license_repo_text(
			"machine https://$host/pro login old password secret\n",
			'12345',
			'new-fixture-key'),
		"machine https://$host/pro login 12345 password new-fixture-key\n", "$host APT credentials change");
	is(cloudmin_license_repo_text("https://$host.example.org/pro/",
				      '12345',
				      'new-fixture-key'),
	   "https://$host.example.org/pro/",
	   "$host lookalike is unchanged");
	}

# License Manager advice omits navigation back to the page already open.
for my $state (
	qw(missing invalid expired overused unavailable unverified clock storage)) {
	my $status = { state => $state, allowed => 0 };
	my $message = cloudmin_license_message($status, 1);
	unlike($message,
	       qr/License Manager|System Settings|legacy|software\.virtualmin/,
	       "$state page warning has no redundant navigation");
	like($message, $state eq 'missing'
		? qr/to make changes/
		: qr/Changes through Cloudmin are blocked/,
	     "$state warning explains the restriction");
	like(cloudmin_license_message($status),
	     qr/System -> Settings -> License Manager/,
	     "$state API error explains where to fix it");
	}
# Error formatting escapes backend text before adding commands and navigation.
{
	no warnings 'redefine';
	local *main::get_webprefix = sub { '/webmin' };
	my $html = error_html(cloudmin_license_message({ state => 'missing' }));
	like($html, qr{href=["']/webmin/server-manager/pro/license.cgi["']},
	     'license error links to the prefixed manager URL');
	like($html, qr{>System &rarr; Settings &rarr; License Manager</a>},
	     'license link uses arrows');
	is(error_html('<script>alert("test")</script> & details'),
	   html_escape('<script>alert("test")</script> & details'),
	   'other backend text remains escaped');
	like(
		error_html(
			'Run `setsebool -P virt_qemu_ga_manage_ssh on` as root.'),
		qr{\ARun <tt\b[^>]*>setsebool -P virt_qemu_ga_manage_ssh on</tt>\s+as root\.\z},
		'commands receive monospace markup');
	my $escaped_command = html_escape('echo "<script>" & value');
	my $escaped_tail = html_escape('<img src=x>');
	like(
		error_html(
			'Run `echo "<script>" & value` then `true`. <img src=x>'),
		qr{\ARun <tt\b[^>]*>\Q$escaped_command\E</tt>\s+then <tt\b[^>]*>true</tt>\s*\. \Q$escaped_tail\E\z},
		'command contents and surrounding text stay escaped');
	}
# Advice distinguishes editable and read-only views and
# explains storage failures.
like(cloudmin_license_message({ state => 'missing' }, 1),
     qr/using the fields above/, 'missing license points to the form');
like(cloudmin_license_message({ state => 'missing' }, 'readonly'),
     qr/Ask an administrator/,
     'read-only users are not told to use a form they cannot edit');
like(cloudmin_license_message({ state => 'expired', allowed => 1, days_left =>
									  1 },
			      1),
     qr/1 more day\./, 'one day of grace uses singular wording');
like(cloudmin_license_message({ state => 'storage' }, 1),
     qr{hardware UUID or /etc/machine-id},
     'license information failures also explain a missing host identity');

# Exercise Webmin's transport with fake connections on hosts with a CA bundle.
# macOS source tests skip this Linux integration; installed
# tests run it in full.
SKIP: {
	skip 'Linux CA bundle required', 26 if (!grep { -r $_ } (
		'/etc/pki/tls/certs/ca-bundle.crt',
		'/etc/ssl/certs/ca-certificates.crt',
		'/etc/ssl/ca-bundle.pem' ));
	no warnings qw(redefine once);
	my (@connection, $sent, $closed);
	my $body = "OK 2037-05-16 50 1 0 1 H product=cloudmin\n";
	my $wire =
		"HTTP/1.0 200 OK\r\nContent-Length: ".length($body)."\r\n\r\n".
		$body;
	my $failure;
	local *main::make_http_connection =
		sub { @connection = @_; return { } };
	local *main::write_http_connection =
		sub { $sent = $_[1]; return !$failure };
	local *main::read_http_connection = sub { return length($wire)
		? substr($wire, 0, $_[1], '')
		: undef };
	local *main::close_http_connection = sub { $closed++ };
	# The live transport must send product-scoped POST
	# data over verified TLS.
	is(cloudmin_license_request('host-one', 'fixture-key'), $body,
	   'valid API response is returned');
	is_deeply([ @connection[0 .. 4] ],
		  [ 'www.virtualmin.com', 443, 1, 'POST',
		    '/api/license/client' ],
		  'only the current HTTPS POST endpoint is called');
	my $decoded = $sent;
	$decoded =~ s/%([0-9a-f]{2})/chr(hex($1))/gei;
	is($decoded, 'id=host-one&serial=fixture-key&product=cloudmin',
	   'host and key are form encoded without suppressing host tracking');
	is($connection[7]->{'host'}, 'www.virtualmin.com',
	   'TLS hostname is verified');
	ok($connection[7]->{'capath'}, 'TLS CA verification is enabled');
	my %headers = map { @$_ } @{$connection[5]};
	is($headers{'Content-Type'}, 'application/x-www-form-urlencoded',
	   'POST content type is supplied');
	is($headers{'Content-Length'}, length($sent),
	   'POST body length is supplied');
	is($closed, 1, 'successful connection closes');
	# Refuse redirects, failed status, truncated bodies and
	# unsupported framing.
	for my $bad (
		"HTTP/1.0 302 Found\r\nLocation: https://example.test/\r\n\r\n",
		"HTTP/1.0 503 Unavailable\r\n\r\nerror",
		"HTTP/1.0 200 OK\r\nContent-Length: 100\r\n\r\nshort",
		"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
		"HTTP/1.0 200 OK\r\n\r\n".('x' x 4097), 'x' x 16385 ) {
		$wire = $bad;
		my $before = $closed;
		is(cloudmin_license_request('host-one', 'fixture-key'),
		   undef,
		   'unsafe or incomplete response is refused');
		is($closed, $before + 1,
		   'failed response closes the connection');
		}
	# Write and TLS failures return no reply and close only valid handles.
	$failure = 1;
	is(cloudmin_license_request('host-one', 'fixture-key'), undef,
	   'failed POST write is refused');
	is($closed, 8, 'failed POST connection closes');
	local *main::make_http_connection =
		sub { die "fixture-key TLS error\n" };
	is(cloudmin_license_request('host-one', 'fixture-key'), undef,
	   'TLS errors cannot expose the key');
	is($closed, 8, 'failed connect has no connection to close');
	local *main::make_http_connection = sub { return 'Connection failed' };
	is(cloudmin_license_request('host-one', 'fixture-key'), undef,
	   'Webmin connection error is refused');
	is($closed, 8, 'connection error is not treated as a handle');
	}

{
	package LicenseFixture;

	# status(self, [refresh], [force]) keeps all requests
	# in the expired state.

	sub status
	{
	return { state => 'expired', allowed => 0 }
	}

	# check_token(self, user, token) models the signed
	# form-token requirement.

	sub check_token
	{
	die "Bad token\n"
		if (($_[2] || '') ne 'fixture-token')
	}
	}
# Exercise the real dispatch with an expired service and an
# administrator session.
no warnings qw(redefine once);
local *main::cloudmin_pro = sub { 1 };
local *main::get_cloudmin_license = sub { bless { }, 'LicenseFixture' };
local *main::is_readonly_mode = sub { 0 };
local *main::get_image_jobs = sub { bless { }, 'LicenseFixture' };
local *main::get_vm_service =
	sub { { jobs => bless({ }, 'LicenseFixture'),
		images => get_image_jobs() } };
local *main::setup_cloudmin_license_check = sub { };
local *main::webmin_log = sub { };
%access = ();

# Controls remain visible; direct API and controller changes must still fail.
for my $action (
	qw(create review update delete backup restore clone capture_image
    snapshot_create snapshot_restore snapshot_delete add_disk attach_disk detach_disk
    grow_disk delete_disk add_interface update_interface remove_interface change_media
    power_cycle start shutdown reboot suspend resume reset force_off autostart reset_password
    register_pool pool_start pool_stop pool_autostart delete_volume unregister_pool)) {
	ok(!eval { call_vm_api(1, $action,
			       { id => 'fixture',
				 token => 'fixture-token' }); 1 },
	   "$action is blocked");
	like($@, qr/license has expired.*License Manager/,
	     "$action explains renewal");
	}
for my $grant (qw(manage power force password)) {
	ok(can_access($grant, 'fixture'), "$grant controls remain visible");
	ok(!eval { require_access($grant, 'fixture'); 1 },
	   "$grant changes remain blocked");
	like($@, qr/license has expired/,
	     "$grant submission explains the license failure");
	}
for my $grant (qw(host view console terminal recover)) {
	ok(can_access($grant, 'fixture'), "$grant remains available");
	}
ok(eval { require_access('recover'); 1 },
   'recovery keeps administrator permissions');
# Webmin's configuration-save hook must apply the same admission rule.
{
	local $ENV{'SCRIPT_NAME'} = '/config_save.cgi';
	local *main::error = sub { die $_[0] };
	local *main::error_message = sub { $_[0] };
	ok(!eval { config_pre_load({ }); 1 },
	   'Module Configuration saves honor expiry');
	like($@, qr/license has expired/,
	     'configuration refusal explains renewal');
	}
# License repair stays reachable, but still requires a valid form token.
is(call_vm_api(1, 'license', { })->{'state'}, 'expired',
   'license status remains readable');
is(call_vm_api(1, 'check_license', { token => 'fixture-token' })->{'state'},
   'expired', 'recheck remains available');
ok(!eval { call_vm_api(1, 'check_license', { token => 'bad' }); 1 },
   'recheck still requires a token');
like($@, qr/Bad token/, 'blocked license does not bypass CSRF');

# License repair neither bypasses global read-only mode nor grants host access.
{
	local *main::is_readonly_mode = sub { 1 };
	ok(!eval { call_vm_api(1, 'check_license',
			       { token => 'fixture-token' }); 1 },
	   'read-only sessions cannot recheck');
	like($@, qr/read-only/, 'read-only refusal explains the restriction');
	ok(eval { call_vm_api(1, 'license', { }); 1 },
	   'read-only status is available');
	}
# A delegated user never gains host access from the repair exception.
{
	local %access = ( admin => 0 );
	ok(!eval { call_vm_api(1, 'license', { }); 1 },
	   'delegated users cannot read license details');
	like($@, qr/Cloudmin permissions/, 'ACL denial comes first');
	}
# GPL bypasses license enforcement while retaining ordinary permissions.
{
	local *main::cloudmin_pro = sub { 0 };
	ok(can_access('manage'), 'GPL does not depend on license state');
	ok(eval { require_access('manage'); 1 },
	   'GPL mutations keep their normal permissions');
	is(call_vm_api(1, 'license', { })->{'edition'}, 'GPL',
	   'GPL status is explicit');
	}

# Credential replacement preserves unrelated files and rolls
# back partial writes.
{
	my $dir = tempdir(CLEANUP => 1);
	my $license = "$dir/a-license";
	my $repo = "$dir/b-repo";
	my $original =
		"baseurl=https://old:oldkey\@cloudmin.virtualmin.com/rpm/\n";
	Cloudmin::License::write_private($repo, $original);
	my %locks;
	local *main::cloudmin_license_files = sub { ( [ $license, 1 ], [ $repo,
									 0 ] ) };
	local *main::lock_file =
		sub { is($_[3], 1,
			 'credential edits suppress audit diffs');
			$locks{$_[0]} =
				1 };
	local *main::unlock_file = sub { delete $locks{$_[0]} };
	my $write = \&Cloudmin::License::write_private;
	# Fail once after creating the license so rollback
	# must remove that file.
	{
		my $failed = 0;
		local *Cloudmin::License::write_private = sub {
			die "Fixture disk failure\n"
				if ($_[0] eq $repo && !$failed++);
			$write->(@_);
			};
		ok(!eval { save_cloudmin_license('12345',
						 'new-fixture-key'); 1 },
		   'failed repository write rejects the change');
		like($@, qr/previous credentials restored/,
		     'failure explains rollback');
		ok(!-e $license,
		   'failed change restores an originally absent license');
		is(Cloudmin::License::read_private($repo), $original,
		   'failed change preserves repository credentials');
		is_deeply(\%locks, { }, 'failed change releases every lock');
		}
	# A later successful attempt updates both files and
	# leaves no locks behind.
	save_cloudmin_license('12345', 'new-fixture-key');
	like(Cloudmin::License::read_private($license), qr/SerialNumber=12345/,
	     'validated replacement saves the license file');
	like(Cloudmin::License::read_private($repo), qr/12345:new-fixture-key/,
	     'validated replacement updates the repository');
	is_deeply(\%locks, { }, 'successful change releases every lock');
	}

# Repository formats keep their modes, including after a later write fails.
{
	my $dir = tempdir(CLEANUP => 1);
	my $license = "$dir/a-license";
	my @repos = map { [ "$dir/b-$_",
			    0 ] } qw(apt.list yum.repo webmin.config);
	my $auth = "$dir/c-auth.conf";
	my @modes = ( 0644, 0640, 0600 );
	# Linux root tests also catch replacement files losing
	# a non-default group.
	my $group = $< == 0 ? 65534 : (split(/\s+/, $)))[0];
	my $original =
		"deb https://old:oldkey\@download.cloudmin.dev/repository stable main\n";
	for my $i (0 .. $#repos) {
		Cloudmin::License::write_private($repos[$i]->[0], $original);
		chmod($modes[$i], $repos[$i]->[0]) or die $!;
		chown(-1, $group, $repos[$i]->[0]) or die $!;
		}
	Cloudmin::License::write_private($auth,
					 "machine download.cloudmin.dev login old password oldkey\n");
	local *main::cloudmin_license_files =
		sub { ( [ $license, 1 ], @repos, [ $auth, 0 ] ) };
	local *main::lock_file = sub { };
	local *main::unlock_file = sub { };
	my $write = \&Cloudmin::License::write_private;
	# Fail on the last file after the repositories have
	# already been replaced.
	{
		local *Cloudmin::License::write_private = sub {
			die "Fixture disk failure\n" if ($_[0] eq $auth);
			$write->(@_);
			};
		ok(!eval { save_cloudmin_license('12345',
						 'new-fixture-key'); 1 },
		   'late write failure rolls back repository replacements');
		for my $i (0 .. $#repos) {
			my $path = $repos[$i]->[0];
			open(my $fh, '<', $path) or die $!;
			is(do { local $/; <$fh> }, $original,
			   'rollback restores repository contents');
			close($fh);
			is((stat($path))[2] & 0777, $modes[$i],
			   'rollback restores repository mode');
			is((stat($path))[5], $group,
			   'rollback restores repository group');
			}
		ok(!-e $license,
		   'late write failure removes the newly created license file');
		}
	# Success must preserve access modes and groups just as rollback does.
	save_cloudmin_license('12345', 'new-fixture-key');
	for my $i (0 .. $#repos) {
		my $path = $repos[$i]->[0];
		open(my $fh, '<', $path) or die $!;
		like(do { local $/; <$fh> }, qr/12345:new-fixture-key/,
		     'repository credentials are updated');
		close($fh);
		is((stat($path))[2] & 0777, $modes[$i],
		   'successful replacement preserves repository mode');
		is((stat($path))[5], $group,
		   'successful replacement preserves repository group');
		}
	is((stat($license))[2] & 0777, 0600, 'new license file stays private');
	is((stat($auth))[2] & 0777, 0600,
	   'APT authentication file stays private');
	}

# Existing schedules bypass only license admission, retaining their owner's ACL.
{
	require "$Bin/../cloudmin-backups-lib.pl";
	package LicenseScheduleJobs;

	# lock(self, name, callback) runs the fixture callback
	# without a real lock.

	sub lock
	{
	$_[2]->()
	}

	# assert_guest_available(self, uuid) models an unreserved fixture guest.

	sub assert_guest_available
	{
	}

	# submit(self, id, [owner], [resource], [request]) models
	# admission and storage.

	sub submit
	{
	$_[0]->{'admit'}->()
		if ($_[0]->{'admit'}); $_[0]->{'records'}->{$_[1]} =
			{ state => 'queued' }
	}

	# get(self, id) returns the job shared with the fake backup worker.

	sub get
	{
	$_[0]->{'records'}->{$_[1]}
	}
	package LicenseScheduleBackup;

	# prepare(self, input, id) avoids accessing guest disks in the fixture.

	sub prepare
	{
	{ }
	}

	# run(self, id) marks the submitted backup complete
	# without host changes.

	sub run
	{
	$_[0]->{'records'}->{$_[1]}->{'state'} = 'complete'
	}
	package main;
	# The schedule and ordinary callers share records, but get
	# separate job stores.
	my %records;
	my $grant = 1;
	local $main::module_name = 'server-manager';
	local *main::get_vm_jobs = sub { bless { records => \%records,
						 admit => \&require_cloudmin_license },
		'LicenseScheduleJobs' };
	local *main::get_backup_service =
		sub { bless { records => \%records }, 'LicenseScheduleBackup' };
	local *main::backup_schedules = sub { [ { id => 'a' x 32, enabled => 1,
						  owner => 'fixture',
						  guests => [ '11111111-2222-4333-8444-555555555555' ] } ] };
	local *main::read_acl =
		sub { $_[0]->{'fixture', 'server-manager'} = $grant };
	local *main::get_module_acl = sub { () };
	# Only the accepted schedule skips licensing; revoked
	# owner access still fails.
	ok(eval { run_backup_schedule('a' x 32); 1 },
	   'existing scheduled backup runs after expiry');
	is(scalar(keys %records), 1, 'schedule actually submits its backup');
	is((values %records)[0]->{'state'}, 'complete',
	   'scheduled worker finishes');
	ok(!eval { get_vm_jobs()->submit('b' x 32); 1 },
	   'schedule does not open admission to other callers');
	$grant = 0;
	ok(!eval { run_backup_schedule('a' x 32); 1 },
	   'schedule still checks its owner permissions');
	like($@, qr/no longer has permission/,
	     'revoked schedule permission is distinct from expiry');
	}

# Clearing a license uses the same multi-file transaction as replacement.
{
	my $folder = tempdir(CLEANUP => 1);
	my @paths = map { "$folder/$_" } qw(a-license b-repo c-auth);
	my @contents = ( "SerialNumber=12345\nLicenseKey=fixture-key\n",
			 "baseurl=https://12345:fixture-key\@download.cloudmin.com/pro/\n".
			 "deb https://other:keep\@example.test/ stable main\n",
			 "machine download.cloudmin.com login 12345 password fixture-key\n".
			 "machine example.test login other password keep\n" );
	Cloudmin::License::write_private($paths[$_],
					 $contents[$_]) for 0 .. $#paths;
	local *main::cloudmin_license_files = sub { map { [ $paths[$_], $_ == 0
		? 1
		: 0 ] } 0 .. $#paths };
	my %locks;
	local *main::lock_file = sub { $locks{$_[0]} = 1 };
	local *main::unlock_file = sub { delete $locks{$_[0]} };
	my $writer = \&Cloudmin::License::write_private;
	# A final auth-file failure must restore every
	# earlier credential removal.
	{
		my $failed = 0;
		local *Cloudmin::License::write_private = sub {
			die "Fixture auth write failure\n"
				if ($_[0] eq $paths[2] && !$failed++);
			$writer->(@_);
			};
		ok(!eval { save_cloudmin_license('', ''); 1 },
		   'late deregistration failure is reported');
		is_deeply([ map { Cloudmin::License::read_private(
			$_) } @paths ],
			  \@contents,
			  'failed deregistration restores the license and all repositories');
		is_deeply(\%locks, { },
			  'failed deregistration releases file locks');
		}
	# Successful removal touches Cloudmin stanzas only and
	# clears the license file.
	save_cloudmin_license('', '');
	is(Cloudmin::License::read_private($paths[0]),
	   "SerialNumber=\nLicenseKey=\n", 'saved credentials cleared');
	is(Cloudmin::License::read_private($paths[1]),
	   "baseurl=https://download.cloudmin.com/pro/\ndeb https://other:keep\@example.test/ stable main\n",
	   'Cloudmin URL credentials removed without altering unrelated repositories');
	is(Cloudmin::License::read_private($paths[2]),
	   "machine example.test login other password keep\n",
	   'Cloudmin APT authentication removed without altering other hosts');
	is_deeply(\%locks, { },
		  'successful deregistration releases file locks');
	# Repository URLs remain usable for adding
	# replacement credentials later.
	save_cloudmin_license('54321', 'replacement-key');
	like(Cloudmin::License::read_private($paths[1]),
	     qr{https://54321:replacement-key\@download.cloudmin.com/},
	     'a new license restores repository authentication');
	}

# Removal cannot bypass confirmation, permissions, read-only mode or edition.
{
	local *LicenseFixture::deregister =
		sub { return { state => 'missing', allowed => 0 } };
	for my $confirm ( undef, '', 0, 2, [ ] ) {
		ok(!eval { call_vm_api(1, 'deregister_license',
				       { token => 'fixture-token',
					 confirm => $confirm }); 1 },
		   'API deregistration requires explicit scalar confirmation');
		like($@, qr/Confirm license deregistration/,
		     'API explains missing confirmation');
		}
	is(call_vm_api(1, 'deregister_license',
		       { token => 'fixture-token', confirm => 1 })->{'state'},
	   'missing',
	   'confirmed removal is available while the license is blocked');
	ok(!eval { call_vm_api(1, 'deregister_license',
			       { token => 'bad', confirm => 1 }); 1 },
	   'removal requires a valid token');
	{
		local *main::is_readonly_mode = sub { 1 };
		ok(!eval { call_vm_api(1, 'deregister_license',
				       { token => 'fixture-token',
					 confirm => 1 }); 1 },
		   'read-only administrators cannot deregister');
		}
	{
		local %access = ( admin => 0 );
		ok(!eval { call_vm_api(1, 'deregister_license',
				       { token => 'fixture-token',
					 confirm => 1 }); 1 },
		   'delegated users cannot deregister');
		}
	{
		local *main::cloudmin_pro = sub { 0 };
		ok(!eval { call_vm_api(1, 'deregister_license',
				       { token => 'fixture-token',
					 confirm => 1 }); 1 },
		   'GPL cannot deregister');
		}
	}
done_testing();
