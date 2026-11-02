use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use WebminCore qw(convert_from_json convert_to_json);
require "$Bin/../lib/Cloudmin/VMs.pm";
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/SSHKeys.pm";
require "$Bin/../lib/Cloudmin/Libvirt.pm";

# Validate reusable settings before any guest allocation.
my $pro_scripts = Cloudmin::Software::has_scripts();
my $base = {install_source => 'cloud', start => 1, hostname => 'vm.example.test',
	memory_mib => 2048, disk_gib => 20};
my $r = {%$base};
Cloudmin::Software::prepare({software => 'virtualmin-gpl'}, $r);
is($r->{'virtualmin_bundle'}, 'LAMP', 'Apache is the default');
is($r->{'virtualmin_type'}, 'full', 'full installation is the default');
is($r->{'webmin_register'}, '1', 'Virtualmin enables Servers Index registration by default');
my $direct = {%$base};
Cloudmin::Software::prepare({software => 'virtualmin-gpl', webmin_register => '0'}, $direct);
is($direct->{'webmin_register'}, '0', 'template can disable Servers Index registration');
# Packages and scripts do not inherit Virtualmin's resource requirements.
my $generic = {%$base, hostname => 'short', memory_mib => 512, disk_gib => 12};
Cloudmin::Software::prepare({software => 'none', packages => "jq\n curl jq",
	( $pro_scripts ? (before_script => "  echo before\r\n", after_script => 'echo after') : () ), webmin_register => '1'}, $generic);
ok(!exists($generic->{'webmin_register'}), 'generic setup discards unused Webmin registration');
is($generic->{'packages'}, 'jq curl', 'package names normalized and deduplicated');
is($generic->{'before_script'}, "  echo before\n", 'shell indentation preserved and browser line endings normalized') if ($pro_scripts);
ok(Cloudmin::Software::enabled($generic), 'packages and scripts work without Virtualmin requirements');
ok(Cloudmin::Software::enabled({after_script => 'true'}), 'script-only setup is enabled');
is_deeply([Cloudmin::Software::enabled($generic)], [1], 'enabled returns one boolean in UI argument lists');
ok(!Cloudmin::Software::enabled({software => 'none'}), 'ordinary creation skips guest provisioning');
# Package names cannot inject options, URLs or shell syntax into installation.
for my $packages ('--remove curl', 'curl-','curl;id', 'https://example/a.rpm', 'curl*') {
	ok(!eval { Cloudmin::Software::settings({packages => $packages}); 1 }, 'package input is a name, not an option');
}
for my $changes ({install_source => 'iso'}, {start => 0}) {
	ok(!eval { Cloudmin::Software::prepare({after_script => 'true'}, {%$base, %$changes}); 1 },
		'generic scripts also require a booted cloud image');
}
# Copy script files only at creation, under Webmin's file permissions.
if ($pro_scripts) {
	no warnings qw(redefine once);
	my $allowed = 1;
	# can_read_file_under_global_acl(path) supplies a controllable Webmin grant.
	local *Cloudmin::Pro::SetupScripts::can_read_file_under_global_acl = sub { $allowed };
	# global_acl_file_unix_user() leaves Unix reads under the test process user.
	local *Cloudmin::Pro::SetupScripts::global_acl_file_unix_user = sub { (undef, 0) };
	my $dir = tempdir(CLEANUP => 1);
	my $path = "$dir/setup.sh";
	open(my $file, '>', $path) or die $!;
	print $file "  echo from-file\r\n";
	close($file);
	# Saved paths remain references until creation snapshots their contents.
	my $input = {before_script_mode => 'file', before_script_path => $path,
		before_script => 'ignored inline script'};
	my $values = Cloudmin::Software::settings($input);
	is($values->{'before_script_path'}, $path, 'template retains the selected file path');
	is($values->{'before_script'}, '', 'file mode discards the pasted script');
	my $request = {%$base};
	Cloudmin::Software::prepare($input, $request);
	is($request->{'before_script'}, "  echo from-file\n", 'file contents reach the creation request');
	is($request->{'before_script_mode'}, 'inline', 'worker uses saved contents rather than reopening the file');
	is($request->{'before_script_path'}, '', 'host path is removed from the prepared request');
	# Removing a file affects new submissions, not saved requests.
	unlink($path) or die $!;
	is($request->{'before_script'}, "  echo from-file\n", 'submitted script survives deletion of its source');
	ok(!eval { Cloudmin::Software::prepare($input, {%$base}); 1 }, 'missing file fails before allocation');
	$allowed = 0;
	ok(!eval { Cloudmin::Software::prepare($input, {%$base}); 1 }, 'Webmin file ACL refuses the read');
	like($@, qr/allowed host directories/, 'ACL rejection precedes opening the file');
	# Switching modes drops data from the now-inactive source controls.
	my $none = Cloudmin::Software::settings({%$input, before_script_mode => 'none'});
	ok(!Cloudmin::Software::enabled($none), 'None ignores both unused sources');
	my $inline = Cloudmin::Software::settings({%$input, before_script_mode => 'inline'});
	is($inline->{'before_script_path'}, '', 'inline mode discards the host path');
	is($inline->{'before_script'}, 'ignored inline script', 'inline mode uses pasted contents');
	# File mode accepts only bounded text from valid absolute file paths.
	$allowed = 1;
	for my $bad ('relative.sh', "/tmp/script\n.sh") {
		ok(!eval { Cloudmin::Software::settings({%$input, before_script_path => $bad}); 1 },
			'invalid host path rejected');
	}
	ok(!eval { Cloudmin::Pro::SetupScripts::script_file($dir); 1 }, 'directories cannot be script sources');
	for my $content ("x" x 16385, "echo bad\0", "echo \xff") {
		open($file, '>', $path) or die $!;
		print $file $content;
		close($file);
		ok(!eval { Cloudmin::Pro::SetupScripts::script_file($path); 1 }, 'oversized or binary script rejected');
	}
	open($file, '>', $path) or die $!;
	print $file Encode::encode('UTF-8', "echo caf\x{e9}\n");
	close($file);
	is(Cloudmin::Pro::SetupScripts::script_file($path), "echo caf\x{e9}\n", 'UTF-8 contents retain their characters in JSON requests');
}
else {
	# Every active source is refused before files, seeds or workers are used.
	for my $field (qw(before_script after_script)) {
		for my $input ({$field => 'true'}, {$field.'_mode' => 'inline'},
			{$field.'_mode' => 'file', $field.'_path' => '/missing/setup.sh'}) {
			ok(!eval { Cloudmin::Software::prepare($input, {%$base}); 1 }, 'GPL rejects script request');
			like($@, qr/require Cloudmin Pro/, 'GPL refusal identifies the needed edition');
		}
		my $clear = Cloudmin::Software::settings({$field.'_mode' => 'none', $field => 'old script'});
		is($clear->{$field}, '', 'GPL permits explicitly clearing a saved script');
	}
	ok(!eval { Cloudmin::Software::seed({}, {%$base, before_script => 'true'}, 'fixture'); 1 },
		'GPL rejects previously prepared script seeds');
}
# Virtualmin adds installation prerequisites beyond generic guest setup.
for my $change ({install_source => 'iso'}, {start => 0}, {hostname => 'short'},
	{memory_mib => 512}, {disk_gib => 10}) {
	ok(!eval { Cloudmin::Software::prepare({software => 'virtualmin-gpl'}, {%$base, %$change}); 1 },
		'unsupported creation settings fail before allocation');
}
for my $input ({software => 'curl bad'}, {software => []}, {virtualmin_bundle => 'LAMP;id'},
	{virtualmin_postgres => 'yes'}) {
	ok(!eval { Cloudmin::Software::settings($input); 1 }, 'software settings cannot inject shell options');
}
# Only Pro requests may carry per-creation credentials.
is_deeply(Cloudmin::Software::credentials('virtualmin-gpl', '123', 'unused'), {}, 'GPL discards license inputs');
ok(!eval { Cloudmin::Software::credentials('virtualmin-pro', '', ''); 1 }, 'Pro requires credentials');
is_deeply(Cloudmin::Software::credentials('virtualmin-pro', '123', 'fixture-key'),
	{virtualmin_serial => '123', virtualmin_key => 'fixture-key'}, 'license validation is per creation');

# Seeds contain the helper, but neither a private host key nor a Pro license.
my $uuid = '11111111-2222-4333-8444-555555555555';
my $data = {};
Cloudmin::Software::seed($data, {%$r, software => 'virtualmin-pro',
	virtualmin_serial => '123', virtualmin_key => 'fixture-secret',
	webmin_password => 'private-initial-password',
	ssh_host_private => 'private-host-identity', ssh_host_public => 'public-host-identity'}, $uuid);
my $json = convert_to_json($data);
unlike($json, qr/fixture-secret|virtualmin_serial|virtualmin_key/, 'license never enters the seed');
unlike($json, qr/private-initial-password|webmin_password/, 'Servers Index login never enters the seed');
ok(!exists($data->{'ssh_keys'}), 'cloud-init generates all normal host key types inside the guest');
unlike($json, qr/private-host-identity/, 'private SSH host key never enters the seed');
my ($config) = grep { $_->{'path'} eq '/etc/cloudmin-install.json' } @{$data->{'write_files'}};
is(convert_from_json($config->{'content'})->{'uuid'}, $uuid, 'helper is bound to one guest');
like($json, qr/TimeoutStartSec=7200/, 'installer execution has a guest-side deadline');
my $generic_data = {};
Cloudmin::Software::seed($generic_data, {%$generic, ssh_host_private => 'private', ssh_host_public => 'public'}, $uuid);
my ($generic_config) = grep { $_->{'path'} eq '/etc/cloudmin-install.json' } @{$generic_data->{'write_files'}};
my $setup = convert_from_json($generic_config->{'content'});
is($setup->{'packages'}, 'jq curl', 'generic package setup reaches the guest');
is($setup->{'before_script'}, $generic->{'before_script'}, 'generic script reaches the guest unchanged');
ok(!exists($generic_data->{'packages'}),
	'optional software leaves common guest packages to VM creation');
my ($bootstrap) = grep { $_->{'path'} eq '/usr/local/lib/cloudmin/guest-software-bootstrap.sh' }
	@{$generic_data->{'write_files'}};
like($bootstrap->{'content'}, qr/perl-JSON-PP/, 'seed installs packaged Perl dependencies on Enterprise Linux');
is_deeply($generic_data->{'runcmd'}->[0], ['/bin/sh', '/usr/local/lib/cloudmin/guest-software-bootstrap.sh'],
	'Perl bootstrap runs before the setup service can start');
like($json, qr{ExecStart=/usr/bin/perl /usr/local/lib/cloudmin/guest-software.pl run},
	'guest service runs Perl');
is_deeply($generic_data->{'runcmd'}->[-1], ['/usr/bin/perl', '/usr/local/lib/cloudmin/guest-software.pl', 'prepare'],
	'initial setup publishes the public identity after installing Perl');
is_deeply($generic_data->{'runcmd'}->[1], ['systemctl', 'daemon-reload'],
	'unit definitions are loaded before guest preparation chooses distro services');
is_deeply([Cloudmin::Software::addresses({address_mode => 'static', ipv4 => '192.0.2.9/24',
	ipv6 => '2001:db8::9/64'}, {addresses => [{address => '192.0.2.9'}, {address => '192.0.2.10'},
	{address => '127.0.0.1'}, {address => 'fe80::1'}]})],
	['192.0.2.9', '2001:db8::9', '192.0.2.10'], 'static addresses precede deduplicated routable discoveries');
is_deeply([Cloudmin::Software::addresses({address_mode => 'dhcp', ipv4 => '192.0.2.9/24'},
	{addresses => []})], [], 'DHCP requests never use stale static form values');

# Real journal writes exercise phase transitions and preserve committed guests.
SKIP: {
skip 'SQLite modules unavailable', 133 if (!eval { Cloudmin::Jobs::dependencies(); 1 });
my $dir = tempdir(CLEANUP => 1);
my %locks;
my @audit;
my @audit_states;
my $jobs = Cloudmin::Jobs->new(directory => "$dir/jobs",
	lock_file => sub { $locks{$_[0]} = 1; 1 }, unlock_file => sub { delete($locks{$_[0]}); },
	test_lock => sub { $locks{$_[0]} }, log => sub { push(@audit, $_[0]); push(@audit_states, $_[3]->{'state'}); });
{
	package SoftwareAdapter;
	# get_domain(self, uuid, [skip_addresses]) supplies a fixture-owned guest.
	sub get_domain {
		# Distinguish lookup errors, confirmed deletion and a stopped guest.
		die "Libvirt connection failed\n" if ($_[0]->{'lookup_error'});
		return undef if ($_[0]->{'deleted'});
		return {active => !$_[0]->{'stopped'}, cloudmin => {job => $_[0]->{'id'}}, addresses => []};
	}
	# get_setup_host_key(self, uuid, [final_attempt]) emulates agent identity
	# reads.
	sub get_setup_host_key {
		if ($_[0]->{'agent_denied'}) {
			# At the boot deadline, policy failures must stop rather than retry.
			Test::More::ok($_[2], 'expired boot window requests the final agent diagnostic');
			die "Guest identity lookup failed: guest-file-open has been disabled\n";
		}
		return 'ssh-rsa Zml4dHVyZQ==';
	}
	package SoftwareWorker;
	# cleanup(self, id) records removal of a disconnected monitor's sandbox.
	sub cleanup { $_[0]->{'cleaned'} = $_[1]; }
	# run(self, task, request, %options) reports guest acceptance and progress.
	sub run {
		my ($self, $task, $request, %options) = @_;
		Test::More::ok(!$_[0]->{'locks'}->{$_[0]->{'jobs'}->{'directory'}.'/vm-work'}, 'installation holds no global disk lock');
		Test::More::ok(eval { $self->{'jobs'}->assert_guest_available($request->{'uuid'}); 1 },
			'guest setup does not reserve virtual machine controls');
		Test::More::is($request->{'address'}, '192.0.2.5', 'worker tries static address without agent or lease');
		Test::More::is($request->{'host_public_key'}, 'ssh-rsa Zml4dHVyZQ==', 'SSH uses the saved agent-verified host key');
		$self->{'calls'}++;
		$options{'started'}->('f'x32);
		# A cancel request stops the fixture instead of reporting setup progress.
		return {stage => 'cancelled'} if ($request->{'action'} || '') eq 'cancel';
		if ($self->{'stage'} eq 'cancelled') {
			# Simulate a user cancelling during an active SSH session.
			$self->{'jobs'}->update($self->{'id'}, sub { $_[0]->{'cancel'} = 1; });
			$options{'progress'}->({type => 'tick'});
			die 'Cancellation was not observed';
		}
		# Prerequisite failure precedes acceptance and any installation event.
		return {stage => 'failed', reason => 'cloud_init_failed'} if ($self->{'stage'} eq 'prerequisite');
		$options{'progress'}->({type => 'progress', stage => 'accepted'});
		Test::More::ok(!exists($self->{'jobs'}->get($self->{'id'})->{'request'}->{'virtualmin_key'}),
			'acceptance erases controller license immediately');
		$options{'progress'}->({type => 'progress', stage => 'install'});
		return {stage => $self->{'stage'}};
	}
}
my $case = 0;
for my $outcome (qw(complete webmin_failed failed prerequisite cancelled deleted lookup_error agent_denied pro_removed)) {
	# Resume setup monitoring without rolling back the created guest.
	my $id = sprintf('%032x', ++$case);
	$jobs->submit($id, 'owner', 'vm:'.$id, {%$r, name => 'fixture', uuid => $uuid,
		$outcome eq 'pro_removed' ? (before_script => 'true') : (),
		address_mode => 'static', ipv4 => '192.0.2.5/24',
		virtualmin_key => 'fixture-secret', virtualmin_serial => '123',
		webmin_password => 'private-initial-password'});
	$jobs->update($id, sub {
		$_[0]->{'state'} = 'running'; $_[0]->{'phase'} = 'software_boot';
		$_[0]->{'events'} = [{step => 'software_boot', state => 'running'}];
		$_[0]->{'resources'} = {domain => 1, disk => {name => 'keep'},
			software_deadline => time()+8100};
	});
	# Use a fixture login key to reach the simulated worker.
	my $keys = Cloudmin::SSHKeys->new("$dir/keys");
	open(my $fh, '>', $keys->destination($uuid, $id)) or die $!;
	print $fh 'fixture-private'; close($fh); chmod(0600, $keys->path($uuid, $id));
	my $worker = bless({stage => $outcome eq 'webmin_failed' ? 'complete' : $outcome,
		id => $id, jobs => $jobs, locks => \%locks}, 'SoftwareWorker');
	my $registered = 0;
	my $service = Cloudmin::VMs->new(jobs => $jobs, ssh_keys => $keys,
		adapter => sub { bless({id => $id, $outcome => 1}, 'SoftwareAdapter') }, worker => $worker,
		# register_webmin(job, address) checks the registration inputs.
		# Simulate registration failure after a successful installation.
		register_webmin => sub {
			$registered++;
			is($_[0]->{'phase'}, 'software_webmin', 'registration has its own progress step');
			is($_[1], '192.0.2.5', 'registration receives the verified installer address');
			is($_[0]->{'request'}->{'webmin_password'}, 'private-initial-password', 'original login survives until registration');
			die "Private provisioning failure\n" if ($outcome eq 'webmin_failed');
			});
	# Simulate the creation commit and verify SQLite releases its reservation.
	ok(!eval { $jobs->assert_guest_available($uuid); 1 }, 'creation still blocks conflicting operations');
	@audit = ();
	@audit_states = ();
	$service->finish($id, undef);
	is_deeply(\@audit, ['complete'], 'creation is logged before software setup');
	is_deeply(\@audit_states, ['complete'], 'creation audit records success while software is still running');
	is($jobs->get($id)->{'resource'}, 'software:'.$id, 'creation commits a separate software resource');
	my $db = $jobs->connect(0);
	is(($db->selectrow_array('SELECT resource FROM jobs WHERE id = ?', undef, $id))[0],
		'software:'.$id, 'SQLite reservation matches the durable record');
	$db->disconnect();
	# Expire only the boot window so denied agent reads get a final diagnostic.
	$jobs->update($id, sub { $_[0]->{'resources'}->{'software_deadline'} = time()+7199; })
		if ($outcome eq 'agent_denied');
	{
		# A removed package must stop saved script work before SSH is launched.
		no warnings 'redefine';
		local *Cloudmin::Software::has_scripts = sub { 0 } if ($outcome eq 'pro_removed');
		$service->run($id);
	}
	like($jobs->get($id)->{'error'}, qr/require Cloudmin Pro/, 'recovery reports removed Pro scripts')
		if ($outcome eq 'pro_removed');
	my $state = $outcome =~ /\A(?:prerequisite|lookup_error|agent_denied|pro_removed)\z/ ? 'failed'
		: $outcome eq 'deleted' ? 'cancelled' : $outcome eq 'webmin_failed' ? 'complete' : $outcome;
	is_deeply(\@audit, ['complete', 'software_'.$state],
		'software outcome has its own action without a second creation result');
	# All outcomes keep the disk and discard login and license secrets.
	my $job = $jobs->get($id);
	is($registered, $state eq 'complete' ? 1 : 0, 'only a completed installation registers Webmin');
	# Registration errors show retry advice without private details.
	if ($outcome eq 'webmin_failed') {
		like($job->{'webmin_warning'}, qr/Remote Access/, 'registration failure provides a retry route');
		unlike($job->{'webmin_warning'}, qr/Private provisioning/, 'private failure output stays out of status');
	}
	is($job->{'state'}, $state, 'guest result becomes the durable job state');
	is($worker->{'calls'} || 0, $outcome eq 'cancelled' ? 2
		: $outcome =~ /\A(?:deleted|lookup_error|agent_denied|pro_removed)\z/ ? 0 : 1,
		'permanent errors stop without retries; cancellation sends one stop');
	like($job->{'error'}, qr/Initial guest setup failed/, 'permanent cloud-init failure is explained') if ($outcome eq 'prerequisite');
	like($job->{'error'}, qr/Libvirt connection failed/, 'inventory failure is not reported as deletion') if ($outcome eq 'lookup_error');
	like($job->{'error'}, qr/guest-file-open has been disabled/, 'boot deadline preserves the specific policy failure') if ($outcome eq 'agent_denied');
	is($job->{'resources'}->{'disk'}->{'name'}, 'keep', 'software outcome preserves the system disk');
	is(!!$job->{'resources'}->{'domain'}, $outcome eq 'deleted' ? '' : 1,
		'only confirmed deletion removes the guest link');
	if ($state eq 'cancelled') {
		# Cancellation and deletion need visible outcomes distinct from success.
		is($job->{'events'}->[-1]->{'state'}, 'cancelled', 'cancelled setup is not marked done');
		like($job->{'error'}, qr/Software setup cancelled/, 'cancellation has a visible outcome');
		like($job->{'error'}, qr/virtual machine was deleted/, 'deletion explains why setup ended')
			if ($outcome eq 'deleted');
	}
	ok(!$job->{'cleanup_pending'}, 'software failure never schedules creation rollback');
	unlike(convert_to_json($job), qr/fixture-secret/, 'terminal history has no license key');
	unlike(convert_to_json($job), qr/private-initial-password/, 'all terminal outcomes erase the original login password');
	ok($keys->find($uuid, $id), 'VM keeps its managed login key');
}
# Stopping or deleting a guest ends monitoring promptly without a rollback.
for my $change (qw(stopped deleted)) {
	my $adapter = bless({id => 'fixture', $change => 1}, 'SoftwareAdapter');
	ok(!eval { Cloudmin::Software::guest($adapter, {id => 'fixture', request => {uuid => $uuid}}); 1 },
		"$change guest ends setup monitoring");
	if ($change eq 'deleted') {
		# Confirmed deletion must not be confused with a failed inventory
		# lookup.
		is(ref($@), 'Cloudmin::Software::GuestDeleted', 'deletion is distinct from an inventory failure');
	}
	else {
		# A stopped guest still exists and retains an actionable error.
		like($@, qr/was stopped/, 'power-off has a specific diagnostic');
	}
}
}
done_testing();
