#!/usr/bin/perl
package Cloudmin::GuestSoftware;

# Standalone guest setup; this file does not require a Webmin installation.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:DEFAULT :flock);
use Errno qw(ENOENT);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use IO::Handle;
use MIME::Base64 qw(encode_base64);
use HTTP::Tiny;
use IO::Socket::SSL;
use Net::SSLeay;
use URI;
use POSIX ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

our $DIRECTORY = '/var/lib/cloudmin-install';
our $IDENTITY_DIRECTORY = '/var/log/qemu-ga';
our $HOST_PUBLIC_KEY = '/etc/ssh/ssh_host_rsa_key.pub';
our $CONFIG = '/etc/cloudmin-install.json';
our $UNIT = 'cloudmin-software.service';
my %STEPS = map { $_ => 1 } qw(before packages download install after);
my %STAGES = (%STEPS, map { $_ => 1 } qw(queued complete failed cancelled));

# fail(reason) carries only a fixed prerequisite code to the public protocol.
sub fail
{
die bless({ reason => $_[0] }, 'Cloudmin::GuestSoftware::Error');
}

# read_file(path) reads private configuration or saved state as bytes.
sub read_file
{
open(my $fh, '<', $_[0]) || die "Cannot read setup file: $!\n";
binmode($fh);
local $/;
my $value = <$fh>;
close($fh) || die "Cannot close setup file: $!\n";
return $value;
}

# write_file(path, contents) writes private inputs and scripts without a shell.
sub write_file
{
open(my $fh, '>', $_[0]) || die "Cannot write setup file: $!\n";
binmode($fh);
print $fh $_[1] or die "Cannot write setup file: $!\n";
close($fh) || die "Cannot close setup file: $!\n";
}

# remove_file(path) allows repeated cleanup but retains other filesystem errors.
sub remove_file
{
unlink($_[0]) || $! == ENOENT || die "Cannot remove setup file: $!\n";
}

# save(name, value) commits private state before acknowledging work over SSH.
sub save
{
my ($name, $value) = @_;
my $path = "$DIRECTORY/$name";
open(my $fh, '>', "$path.tmp") || die "Cannot save setup state: $!\n";
print $fh encode_json($value) or die "Cannot save setup state: $!\n";
$fh->flush && $fh->sync || die "Cannot sync setup state: $!\n";
close($fh) || die "Cannot close setup state: $!\n";
rename("$path.tmp", $path) || die "Cannot commit setup state: $!\n";
# Sync the directory too, so reconnection cannot replay acknowledged work.
sysopen(my $directory, $DIRECTORY, O_RDONLY) || die "Cannot open setup directory: $!\n";
$directory->sync || die "Cannot sync setup directory: $!\n";
close($directory);
}

# status() exposes only known stages and a known failed step.
sub status
{
# No journal means the first SSH request has not been accepted yet.
return { stage => 'queued' } if (!-e "$DIRECTORY/status.json");
my $value = decode_json(read_file("$DIRECTORY/status.json"));
my $result = { stage => $STAGES{$value->{'stage'} || ''} ? $value->{'stage'} : 'failed' };
$result->{'failed_step'} = $value->{'failed_step'}
	if ($result->{'stage'} eq 'failed' && $STEPS{$value->{'failed_step'} || ''});
return $result;
}

# report(value) writes one status line, never installer output or credentials.
sub report
{
print encode_json($_[0]), "\n" or die "Setup monitor disconnected\n";
STDOUT->flush;
}

# executable(name) locates guest tools without interpreting their names as shell.
sub executable
{
# Ignore empty PATH entries so tools never resolve from the working directory.
foreach my $dir (split(/:/, $ENV{'PATH'} || '')) {
	return "$dir/$_[0]" if (length($dir) && -f "$dir/$_[0]" && -x _);
}
return undef;
}

# spawn(command, [config]) starts a child with closed stdin and captured output.
# Setup commands receive their guest context; control commands discard stderr.
sub spawn
{
my ($command, $config) = @_;
my $pid = open(my $output, '-|');
die "Cannot start guest command: $!\n" if (!defined($pid));
if (!$pid) {
	# Child failures must never enter the parent's JSON error handler.
	eval {
		open(STDIN, '<', '/dev/null') || die;
		if ($config) {
			# Capture installer diagnostics with the configured guest context.
			open(STDERR, '>&', \*STDOUT) || die;
			chdir($DIRECTORY) || die;
			@ENV{qw(DEBIAN_FRONTEND INTERACTIVE_MODE CLOUDMIN_VM_UUID CLOUDMIN_HOSTNAME CLOUDMIN_GUEST_USER)} =
				('noninteractive', 'off', $config->{'uuid'}, $config->{'hostname'} || '', $config->{'username'} || '');
		}
		else {
			# Control commands return stdout only, without private diagnostics.
			open(STDERR, '>', '/dev/null') || die;
		}
		exec { $command->[0] } @$command;
	};
	POSIX::_exit(127);
}
return ($pid, $output);
}

# command(arguments, [timeout]) bounds control commands and their captured output.
# Returns the exit status and output. timeout defaults to 30 seconds and raises
# a typed, private error when exceeded.
sub command
{
my ($args, $timeout) = @_;
my ($pid, $output) = spawn($args);
my ($code, $text) = (0, '');
# Keep reading stdout after reaching the output limit so children cannot block.
my $ok = eval {
	local $SIG{'ALRM'} = sub { fail('timeout'); };
	alarm($timeout || 30);
	while (1) {
		my $n = read($output, my $buffer, 4096);
		die "Cannot read guest command\n" if (!defined($n));
		last if (!$n);
		$text .= $buffer if (length($text) < 16384);
	}
	close($output);
	$code = $? & 127 ? 128 + ($? & 127) : $? >> 8;
	alarm(0);
	1;
};
my $error = $@;
alarm(0);
if (!$ok) {
	# A timed-out command must not survive its caller or retain the output pipe.
	kill('KILL', $pid);
	close($output);
	waitpid($pid, 0);
	die $error;
}
return ($code, $text);
}

# agent_policy(text) permits public identity reads, preserving other RPC rules.
sub agent_policy
{
my ($text) = @_;
my @needed = qw(guest-file-open guest-file-read guest-file-close);
my %needed = map { $_ => 1 } @needed;
# Handle EL8's blacklist, newer EL command-line filters and qemu-ga.conf.
my @lines = split(/(?<=\n)/, $text);
foreach my $line (@lines) {
	next if ($line =~ /^\s*#/);
	$line =~ s{((?:--(?:allow-rpcs|block-rpcs|blacklist)=|^\s*(?:allow-rpcs|block-rpcs|blacklist|BLACKLIST_RPC)\s*=\s*)["']?)([a-zA-Z0-9_,*-]+)}{
		my ($prefix, $list) = ($1, $2);
		my @names = split(/,/, $list);
		if ($prefix =~ /allow-rpcs/) {
			# Add missing read operations without duplicating existing entries.
			my %seen = map { $_ => 1 } @names;
			push(@names, grep { !$seen{$_} } @needed);
		}
		else {
			# Remove only the required operations from a block list.
			@names = grep { !$needed{$_} } @names;
		}
		$prefix.join(',', @names);
	}eg;
}
return join('', @lines);
}

# service_unit(names...) finds an installed unit or a loaded template instance.
sub service_unit
{
foreach my $name (@_) {
	if ($name =~ /\*/) {
		# SUSE can start a separate agent instance for each virtio channel.
		my ($code, $output) = command(['systemctl', 'list-units', '--all',
			'--type=service', '--no-legend', '--plain', $name]);
		next if ($code);
		return $1 if ($output =~ /^\s*(qemu-ga\@[A-Za-z0-9_.\\-]+\.service)\s/m);
	}
	else {
		# Query LoadState so an installed but inactive service can be started.
		my ($code, $output) = command(['systemctl', 'show', $name,
			'--property=LoadState', '--value']);
		return $name if (!$code && $output =~ /\Aloaded\s*\z/);
	}
}
return undef;
}

# prepare(config) publishes only the public SSH identity after initial SSH setup.
sub prepare
{
my ($config) = @_;
# Keep all distro-default key types, including RSA on FIPS guests.
my $had_rsa = -s $HOST_PUBLIC_KEY;
my ($code) = command(['ssh-keygen', '-A']);
die "Cannot generate guest host keys\n" if ($code);
my $public = read_file($HOST_PUBLIC_KEY);
$public =~ s/\s+\z//;
die "Invalid guest host key\n" if ($public !~ /\Assh-rsa [A-Za-z0-9+\/=]+(?: [^\r\n]*)?\z/);
if (!$had_rsa) {
	# A running SSH server must load a key created after its own startup.
	my $unit = service_unit('sshd.service', 'ssh.service') ||
		die "Cannot find the guest SSH service\n";
	my ($code) = command(['systemctl', 'try-reload-or-restart', $unit]);
	die "Cannot reload the guest SSH host keys\n" if ($code);
}
# Several distributions disable agent file RPCs. Enable only the operations
# needed to read the identity, without allowing guest-exec or file writes.
foreach my $path ('/etc/sysconfig/qemu-ga', '/etc/sysconfig/qemu-guest-agent', '/etc/qemu/qemu-ga.conf') {
	next if (!-f $path);
	my $old = read_file($path);
	my $new = agent_policy($old);
	write_file($path, $new) if ($old ne $new);
}
# Publish this public record in the agent's own log directory, whose standard
# SELinux label permits reads without granting access to other guest files.
local $DIRECTORY = $IDENTITY_DIRECTORY;
make_path($DIRECTORY, { mode => 0700 });
save('cloudmin-identity.json', { uuid => $config->{'uuid'}, key => $public });
if (-e '/sys/fs/selinux/enforce') {
	# Restore the standard agent label only on guests that use SELinux.
	my $restorecon = executable('restorecon') || die "Cannot label the guest public identity\n";
	my ($code) = command([$restorecon, $DIRECTORY, "$DIRECTORY/cloudmin-identity.json"]);
	die "Cannot label the guest public identity\n" if ($code);
}
# Apply policy changes using the distribution's actual agent service name.
my $agent = service_unit('qemu-guest-agent.service', 'qemu-ga.service', 'qemu-ga@*.service') ||
	die "Cannot find the guest agent service\n";
my ($restarted) = command(['systemctl', 'restart', $agent]);
die "Cannot restart the guest agent service\n" if ($restarted);
}

# redirect_url(url, location, authenticated) requires HTTPS redirects.
# Authenticated downloads must also remain on the same host and port.
sub redirect_url
{
my ($url, $location, $authenticated) = @_;
die "Missing installer redirect\n" if (!defined($location) || ref($location) || !length($location));
my $before = URI->new($url);
my $after = URI->new_abs($location, $before)->canonical;
die "Unsafe installer redirect\n" if ($after->scheme ne 'https' || !$after->host || defined($after->userinfo) ||
	($authenticated && (lc($after->host) ne lc($before->host) || $after->port != $before->port)));
return $after->as_string;
}

# download(url, headers, post) fetches a bounded installer over verified HTTPS.
sub download
{
my ($url, $headers, $post) = @_;
# Follow redirects explicitly so authenticated requests cannot cross origins.
my $client = HTTP::Tiny->new(verify_SSL => 1, timeout => 30,
	max_redirect => 0, max_size => 4 * 1024 * 1024 + 1);
my $contents;
my $ok = eval {
	local $SIG{'ALRM'} = sub { die "Installer download timed out\n"; };
	alarm(120);
	for (1..10) {
		my $response = $client->request($post ? 'POST' : 'GET', $url,
			{ headers => $headers, $post ? (content => '') : () });
		if ($response->{'status'} =~ /\A30[12378]\z/) {
			# Handle redirects ourselves even on older HTTP::Tiny releases.
			$url = redirect_url($url, $response->{'headers'}->{'location'}, $headers->{'Authorization'});
			$post = 0 if ($response->{'status'} =~ /\A30[123]\z/);
			next;
		}
		# Keep HTTP::Tiny's 599 transport diagnostic in the private log.
		die "Installer download failed: HTTP $response->{'status'}\n"
			if (!$response->{'success'} && $response->{'status'} != 599);
		die "Installer download failed: ".substr($response->{'content'} || 'HTTPS connection error', 0, 500)."\n"
			if ($response->{'status'} == 599);
		$contents = $response->{'content'};
		last;
	}
	die "Too many installer redirects\n" if (!defined($contents));
	alarm(0);
	1;
};
my $error = $@;
alarm(0);
die $error if (!$ok);
return $contents;
}

# arguments(config) uses the official installer's supported flags.
sub arguments
{
my ($config) = @_;
my @args = ('--bundle', $config->{'virtualmin_bundle'}, '--type', $config->{'virtualmin_type'}, '--yes');
# Keep certificate provisioning under the template's explicit SSL choice.
push(@args, '--no-hostname-ssl') if ($config->{'virtualmin_ssl'} eq '0');
if ($config->{'virtualmin_postgres'} eq '1') {
	# Debian and Ubuntu use a different PostgreSQL client package name.
	my $debian = read_file('/etc/os-release') =~ /^ID=(?:"?(?:debian|ubuntu)"?)$/m;
	push(@args, '--extra', 'postgresql,'.($debian ? 'postgresql-client' : 'postgresql-server'),
		'--include', 'PostgreSQL');
}
return \@args;
}

# redact(input, output, secrets) bounds logs and masks secrets across read chunks.
sub redact
{
my ($input, $output, $secrets) = @_;
my @secrets = grep { defined($_) && length($_) } @$secrets;
# Hold back enough bytes to recognize a secret split across successive reads.
my $keep = 1;
foreach (@secrets) { $keep = length($_) if (length($_) > $keep); }
my ($pending, $written) = ('', tell($output));
while (1) {
	my $n = read($input, my $chunk, 4096);
	die "Cannot read guest output\n" if (!defined($n));
	$pending .= $chunk;
	my $cut = $n ? (length($pending) > $keep ? length($pending) - $keep : 0) : length($pending);
	my $previous = -1;
	while ($cut != $previous) {
		# Keep entire secrets that cross the boundary, including overlapping ones.
		$previous = $cut;
		foreach my $secret (@secrets) {
			my $start = index($pending, $secret, $cut >= length($secret) ? $cut-length($secret)+1 : 0);
			$cut = $start if ($start >= 0 && $start < $cut && $start+length($secret) > $cut);
		}
	}
	my $block = substr($pending, 0, $cut, '');
	foreach my $secret (@secrets) { $block =~ s/\Q$secret\E/[redacted]/g; }
	if ($written < 4 * 1024 * 1024) {
		# Drain the child after reaching the limit, but stop growing its log.
		$block = substr($block, 0, 4 * 1024 * 1024 - $written);
		print $output $block or die "Cannot write guest log\n";
		$output->flush;
		$written += length($block);
	}
	last if (!$n);
}
}

# package_commands(names) rejects options and shell syntax in package names.
sub package_commands
{
my @packages = split(' ', $_[0] || '');
die "Invalid package names\n" if (!@packages || @packages > 200 ||
	grep { !/\A[a-zA-Z0-9][a-zA-Z0-9.+_:-]{0,127}\z/ || /-\z/ } @packages);
# Use the first available manager. APT installation waits for the dpkg lock.
foreach my $entry (
	['apt-get', ['update'], ['-o', 'DPkg::Lock::Timeout=600', 'install', '-y', '--', @packages]],
	['dnf', ['--refresh', '-y', 'install', '--', @packages]],
	['zypper', ['--non-interactive', 'refresh'], ['--non-interactive', 'install', '--', @packages]]) {
	my ($name, @commands) = @$entry;
	my $path = executable($name);
	return [map { [$path, @$_] } @commands] if ($path);
}
die "No supported package manager (apt-get, dnf or zypper)\n";
}

# execute(arguments, log, secrets, config) runs one noninteractive setup command.
sub execute
{
my ($args, $log, $secrets, $config) = @_;
my ($pid, $output) = spawn($args, $config);
my $ok = eval { redact($output, $log, $secrets); 1; };
my $error = $@;
# A broken log pipe must not leave the command running without supervision.
kill('KILL', $pid) if (!$ok);
# Closing the pipe reaps the child; preserve its exit status before reporting.
close($output);
my $code = $?;
die $error if (!$ok);
die "Guest command failed\n" if ($code);
}

# script(config, name, log, secrets) calls the Pro guest script helper.
# name selects a script in config; log is the output handle and secrets lists
# values to redact. The helper runs inside the guest alongside this file.
sub script
{
my $helper = dirname(__FILE__).'/guest-scripts.pl';
# A queued script must fail explicitly if its executor is no longer installed.
die "Custom setup scripts require Cloudmin Pro\n" if (!-r $helper);
require $helper;
# The Pro file defines this routine in our namespace; forward its arguments.
goto &run_custom_script;
}

# cleanup() removes temporary credential and executable copies after setup.
sub cleanup
{
remove_file("$DIRECTORY/$_") foreach qw(request.json installer.sh before_script.sh after_script.sh);
}

# install(config) never replays saved running, completed or failed work.
sub install
{
my ($config) = @_;
open(my $lock, '>', "$DIRECTORY/run.lock") || die "Cannot lock guest setup\n";
flock($lock, LOCK_EX) || die "Cannot lock guest setup\n";
# Only queued work may start; a previous running step could have side effects.
return if (!-e "$DIRECTORY/status.json" || status()->{'stage'} ne 'queued');
provision($config);
}

# provision(config) journals each step and stops the sequence on its first error.
sub provision
{
my ($config) = @_;
my ($serial, $key, $step) = ('', '', 'before');
my @completed;
my $ok = eval {
	# Keep accepted credentials in memory and remove their temporary input file.
	my $request = decode_json(read_file("$DIRECTORY/request.json"));
	($serial, $key) = map { $request->{$_} || '' } qw(serial key);
	remove_file("$DIRECTORY/request.json");
	open(my $log, '>', "$DIRECTORY/install.log") || die "Cannot open guest log\n";
	# begin(name) records intent before a command can have side effects.
	my $begin = sub {
		$step = $_[0];
		save('status.json', { stage => $step, completed => \@completed });
		print $log "\n[$step]\n" or die "Cannot write guest log\n";
		$log->flush;
	};
	if ($config->{'before_script'}) {
		# Prepare repositories and other prerequisites before installation.
		$begin->('before');
		script($config, 'before_script', $log, [$serial, $key]);
		push(@completed, 'before');
	}
	if ($config->{'packages'}) {
		# Install requested packages before the optional Virtualmin installer.
		$begin->('packages');
		execute($_, $log, [$serial, $key], $config) foreach @{package_commands($config->{'packages'})};
		push(@completed, 'packages');
	}
	if (($config->{'software'} || 'none') ne 'none') {
		# Download the optional installer without passing credentials on argv.
		$begin->('download');
		my $pro = $config->{'software'} eq 'virtualmin-pro';
		my $url = $pro ? 'https://www.virtualmin.com/api/install' : 'https://download.virtualmin.com/virtualmin-install';
		my $headers = $pro ? { Authorization => 'Basic '.encode_base64("$serial:$key", '') } : {};
		my $contents = download($url, $headers, $pro);
		die "The download did not return a valid Virtualmin installer\n"
			if (length($contents) > 4 * 1024 * 1024 || substr($contents, 0, 2) ne '#!');
		write_file("$DIRECTORY/installer.sh", $contents);
		push(@completed, 'download');
		# Record download and installation separately for failure reporting.
		$begin->('install');
		execute(['/bin/sh', "$DIRECTORY/installer.sh", @{arguments($config)}], $log, [$serial, $key], $config);
		remove_file("$DIRECTORY/installer.sh");
		push(@completed, 'install');
	}
	if ($config->{'after_script'}) {
		# Apply final configuration only after the preceding steps succeeded.
		$begin->('after');
		script($config, 'after_script', $log, [$serial, $key]);
		push(@completed, 'after');
	}
	close($log);
	save('status.json', { stage => 'complete', completed => \@completed });
	1;
};
if (!$ok) {
	# Private diagnostics are bounded and scrubbed before they reach the log.
	my $message = ref($@) ? "Guest software setup failed at step: $step" : substr("$@", 0, 1500);
	foreach my $secret ($serial, $key, length($key) ? encode_base64("$serial:$key", '') : '') {
		$message =~ s/\Q$secret\E/[redacted]/g if (length($secret));
	}
	open(my $log, '>>', "$DIRECTORY/install.log") || die "Cannot append guest log\n";
	print $log "\n$message\n";
	close($log);
	save('status.json', { stage => 'failed', failed_step => $step, completed => \@completed });
}
cleanup();
}

# cancel() stops the service before marking the journal as cancelled.
sub cancel
{
open(my $lock, '>', "$DIRECTORY/submit.lock") || die "Cannot lock guest request\n";
flock($lock, LOCK_EX) || die "Cannot lock guest request\n";
my ($code) = command(['systemctl', 'stop', $UNIT], 45);
die "Cannot stop guest setup\n" if ($code);
if (status()->{'stage'} !~ /\A(?:complete|failed)\z/) {
	# Retain completed steps and block a delayed watcher from starting work.
	my $journal = -e "$DIRECTORY/status.json" ? decode_json(read_file("$DIRECTORY/status.json")) : {};
	$journal->{'stage'} = 'cancelled';
	save('status.json', $journal);
}
cleanup();
report(status());
}

# watch(config) accepts one private request and follows its persistent journal.
sub watch
{
my ($config) = @_;
# Bound the private SSH payload and verify it belongs to this guest.
my $raw = '';
while (length($raw) <= 4096) {
	my $n = read(STDIN, my $chunk, 4097-length($raw));
	die "Cannot read guest request\n" if (!defined($n));
	last if (!$n);
	$raw .= $chunk;
}
die "Guest request too large\n" if (length($raw) > 4096);
my $request = decode_json($raw);
fail('identity') if (($request->{'uuid'} || '') ne $config->{'uuid'});
if (!executable('systemctl')) {
	# A missing service manager cannot be resolved by reconnecting over SSH.
	write_file("$DIRECTORY/install.log", "Guest software setup requires systemd.\n");
	save('status.json', { stage => 'failed' });
	report(status());
	return;
}
if (($request->{'action'} || '') eq 'cancel') {
	# Stopping work does not need a license or wait for cloud-init.
	cancel();
	return;
}
report({ stage => 'boot' });
# Wait for initial setup; cloud-init exit 2 allows recoverable warnings.
fail('cloud_init_missing') if (!executable('cloud-init'));
my $code;
my $ready = eval { ($code) = command(['cloud-init', 'status', '--wait'], 900); 1; };
fail('cloud_init_timeout') if (!$ready && ref($@) && $@->{'reason'} eq 'timeout');
die $@ if (!$ready);
fail('cloud_init_failed') if ($code != 0 && $code != 2);
{
	# Serialize acceptance with cancellation and competing SSH watchers.
	open(my $lock, '>', "$DIRECTORY/submit.lock") || die "Cannot lock guest request\n";
	flock($lock, LOCK_EX) || die "Cannot lock guest request\n";
	if (!-e "$DIRECTORY/status.json") {
		# Save credentials once, before acknowledging the first request.
		fail('credentials') if (($config->{'software'} || '') eq 'virtualmin-pro' &&
			(!$request->{'serial'} || !$request->{'key'}));
		save('request.json', { map { $_ => $request->{$_} || '' } qw(serial key) });
		save('status.json', { stage => 'queued' });
	}
	if (status()->{'stage'} eq 'queued') {
		# The service prevents repeat execution when a watcher reconnects.
		my ($started) = command(['systemctl', 'start', '--no-block', $UNIT]);
		die "Cannot start guest setup\n" if ($started);
	}
}
report({ stage => 'accepted' });
my $previous = '';
my $deadline = clock_gettime(CLOCK_MONOTONIC) + 7300;
while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
	my $value = status();
	my $encoded = JSON::PP->new->canonical->encode($value);
	if ($encoded ne $previous) {
		# Send state transitions without repeating unchanged progress records.
		report($value);
		$previous = $encoded;
	}
	return if ($value->{'stage'} =~ /\A(?:complete|failed|cancelled)\z/);
	# A queued systemd job is still pending even while the unit is inactive.
	my ($code, $output) = command(['systemctl', 'show', $UNIT, '-p', 'ActiveState', '-p', 'Job']);
	die "Cannot inspect guest setup\n" if ($code);
	my %properties = map { split(/=/, $_, 2) } grep { /=/ } split(/\n/, $output);
	if (($properties{'ActiveState'} || '') !~ /\A(?:active|activating)\z/ && !$properties{'Job'}) {
		# Re-read after querying systemd; completion may have just been saved.
		my $journal = decode_json(read_file("$DIRECTORY/status.json"));
		next if ($journal->{'stage'} =~ /\A(?:complete|failed|cancelled)\z/);
		# Preserve the interrupted step so a later watcher cannot replay it.
		$journal->{'failed_step'} = $journal->{'stage'};
		$journal->{'stage'} = 'failed';
		save('status.json', $journal);
		remove_file("$DIRECTORY/$_") foreach qw(request.json installer.sh);
	}
	sleep(3);
}
die "Installation monitoring timed out\n";
}

# main() permits root cloud-init preparation, the service and verified watcher.
sub main
{
# This helper is invoked only by cloud-init, its root service or sudo over SSH.
return 1 if ($< != 0 || $> != 0 || @ARGV != 1 || $ARGV[0] !~ /\A(?:prepare|watch|run)\z/);
umask(0077);
my $ok = eval {
	make_path($DIRECTORY, { mode => 0700 });
	my $config = decode_json(read_file($CONFIG));
	$ARGV[0] eq 'prepare' ? prepare($config) : $ARGV[0] eq 'run' ? install($config) : watch($config);
	1;
};
if (!$ok) {
	# Report fixed reason codes without exposing private exception text.
	my $reason = ref($@) eq 'Cloudmin::GuestSoftware::Error' ? $@->{'reason'} : 'helper';
	report({ stage => 'failed', reason => $reason });
	return 1;
}
return 0;
}

# Tests can load these routines without starting guest setup.
exit(main()) if (!caller);
1;
