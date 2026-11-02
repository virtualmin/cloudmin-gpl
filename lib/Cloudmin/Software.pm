package Cloudmin::Software;

# Guest provisioning uses pinned SSH. Scripts run only inside the guest;
# license inputs stay out of templates and the seed disk.
use strict;
use warnings;
use WebminCore qw(convert_to_json read_file_contents check_ipaddress check_ip6address);
use File::Basename qw(dirname);
use Time::HiRes ();

# script_fields() names reusable script settings, including inactive sources.
sub script_fields { return qw(before_script before_script_mode before_script_path
	after_script after_script_mode after_script_path); }

# has_scripts() checks both Pro helpers on disk, without caching availability.
sub has_scripts
{
my $pro = dirname(__FILE__).'/../../pro';
return -r "$pro/SetupScripts.pm" && -r "$pro/guest-scripts.pl";
}

# require_scripts() refuses script work when its Pro implementation is absent.
sub require_scripts
{
die "Custom setup scripts require Cloudmin Pro. Set both scripts to None or install Cloudmin Pro.\n"
	if (!has_scripts());
require(dirname(__FILE__).'/../../pro/SetupScripts.pm');
}

# uses_scripts(settings) detects selected sources, even when their text is empty.
# Explicit None overrides stale text or paths; older records infer the source.
sub uses_scripts
{
my ($settings) = @_;
return scalar grep {
	my $mode = $settings->{$_.'_mode'};
	defined($mode) && length($mode) ? $mode ne 'none'
		: length($settings->{$_} // '') || length($settings->{$_.'_path'} // '')
} qw(before_script after_script);
}

# script_settings(input) returns normalized script fields for supplied options.
# GPL can clear fields; active sources require Pro validation. Omitted fields
# remain absent so callers can preserve template inheritance.
sub script_settings
{
my ($input) = @_;
if (uses_scripts($input)) {
	# This gate also protects direct API requests and recovered creation data.
	require_scripts();
	return Cloudmin::Pro::SetupScripts::settings($input);
}
my %values;
foreach my $field (qw(before_script after_script)) {
	# Omitted fields still inherit; explicit None discards either old source.
	next if (!grep { exists($input->{$_}) } ($field, $field.'_mode', $field.'_path'));
	@values{$field.'_mode', $field, $field.'_path'} = ('none', '', '');
}
return \%values;
}

# fields() lists reusable software options, excluding license and login secrets.
sub fields { return qw(packages before_script before_script_mode before_script_path
	after_script after_script_mode after_script_path software virtualmin_bundle
	virtualmin_type virtualmin_postgres virtualmin_ssl webmin_register); }

# enabled(settings) checks for packages, scripts or a Virtualmin installation.
sub enabled
{
my ($settings) = @_;
return (($settings->{'software'} || 'none') ne 'none' ||
	length($settings->{'packages'} || '') || grep {
		($settings->{$_.'_mode'} || '') ne 'none' &&
		(length($settings->{$_} || '') || length($settings->{$_.'_path'} || ''))
	} qw(before_script after_script)) ? 1 : 0;
}

# settings(input) validates supplied options without adding template defaults.
sub settings
{
my ($input) = @_;
my %patterns = (software => qr/(?:none|virtualmin-gpl|virtualmin-pro)/,
	virtualmin_bundle => qr/(?:LAMP|LEMP)/, virtualmin_type => qr/(?:full|mini)/,
	virtualmin_postgres => qr/[01]/, virtualmin_ssl => qr/[01]/,
	webmin_register => qr/[01]/);
my %values;
# Validate only supplied installer choices; defaults are applied at creation.
foreach my $field (keys %patterns) {
	next if (!exists($input->{$field}) || defined($input->{$field}) && $input->{$field} eq '');
	die "Invalid software installation option\n" if (!defined($input->{$field}) ||
		ref($input->{$field}) || $input->{$field} !~ /\A$patterns{$field}\z/);
	$values{$field} = $input->{$field};
}
# Packages are names, not command options, paths, URLs or shell expressions.
if (exists($input->{'packages'})) {
	my $value = $input->{'packages'};
	die "Enter package names separated by spaces or newlines\n"
		if (!defined($value) || ref($value) || length($value) > 8192);
	my @packages = grep { length } split(/\s+/, $value);
	die "Enter at most 200 package names, without versions or wildcards\n"
		if (@packages > 200 || grep { !/\A[a-zA-Z0-9][a-zA-Z0-9.+_:-]{0,127}\z/ || /-\z/ } @packages);
	my %seen;
	$values{'packages'} = join(' ', grep { !$seen{$_}++ } @packages);
}
# The Pro package owns script validation and file access. GPL accepts explicit
# clearing, but rejects active scripts from forms, presets and API requests.
my $scripts = script_settings($input);
@values{keys %$scripts} = values %$scripts;
return \%values;
}

# prepare(input, request) validates guest setup before allocation.
sub prepare
{
my ($input, $request) = @_;
my $values = settings($input);
# Generic scripts and packages must not inherit a Virtualmin login request.
delete($values->{'webmin_register'}) if (($values->{'software'} || 'none') eq 'none');
# Template hostname rules also apply when no software installation is requested.
die "The selected template requires a fully qualified hostname, such as host.example.com. ".
	"Use it as the virtual machine name, or set the guest hostname separately.\n"
	if ($request->{'install_source'} eq 'cloud' &&
		($request->{'require_fqdn'} || ($values->{'software'} || '') =~ /\Avirtualmin-/) &&
		$request->{'hostname'} !~ /\./);
# Ordinary creation requests need no software prerequisites.
return if (!enabled($values));
die "Guest software setup requires a cloud image and Start after creation\n"
	if ($request->{'install_source'} ne 'cloud' || !$request->{'start'});
# Copy file contents before submission; workers never reopen the host paths.
foreach my $field (qw(before_script after_script)) {
	next if (($values->{$field.'_mode'} || '') ne 'file');
	$values->{$field} = Cloudmin::Pro::SetupScripts::script_file($values->{$field.'_path'});
	$values->{$field.'_mode'} = 'inline';
	$values->{$field.'_path'} = '';
}
@{$request}{keys %$values} = values %$values;
# Package-only and script-only setups need no Virtualmin-specific resources.
return if (($values->{'software'} || 'none') eq 'none');
my %options = (virtualmin_bundle => 'LAMP', virtualmin_type => 'full',
	virtualmin_postgres => '0', virtualmin_ssl => '1', webmin_register => '1', %$values);
my $minimum = $options{'virtualmin_type'} eq 'mini' ? 1024 : 2048;
die "Virtualmin needs at least $minimum MiB of memory and 20 GiB of disk space\n"
	if ($request->{'memory_mib'} < $minimum || $request->{'disk_gib'} < 20);
@{$request}{keys %options} = values %options;
}

# credentials(software, serial, key) validates one creation's license inputs.
sub credentials
{
my ($software, $serial, $key) = @_;
# GPL and package-only setup must not retain supplied Pro credentials.
return {} if (($software || '') ne 'virtualmin-pro');
die "Enter the Virtualmin Pro license serial and key for this virtual machine\n"
	if (!defined($serial) || ref($serial) || $serial !~ /\A[0-9]{1,20}\z/ ||
		!defined($key) || ref($key) || $key !~ /\A[A-Za-z0-9_-]{1,256}\z/);
return { virtualmin_serial => $serial, virtualmin_key => $key };
}

# seed(data, request, uuid) adds guest helpers and configuration to cloud-init.
# Virtualmin license credentials are delivered later over authenticated SSH.
sub seed
{
my ($data, $request, $uuid) = @_;
# Do not install the helper or its dependencies when setup is disabled.
return if (!enabled($request));
# Recheck the installed executor before turning a saved request into a seed.
require_scripts() if (uses_scripts($request));
my $root = dirname(__FILE__).'/../..';
my %config = (uuid => $uuid, map { $_ => $request->{$_} }
	grep { defined($request->{$_}) } fields(), qw(username hostname));
# The seed installs a dormant service; authenticated SSH starts it after setup.
push(@{$data->{'write_files'}},
	{ path => '/usr/local/lib/cloudmin/guest-software.pl', owner => 'root:root',
	  permissions => '0700', content => read_file_contents("$root/guest-software.pl") },
	{ path => '/usr/local/lib/cloudmin/guest-software-bootstrap.sh', owner => 'root:root',
	  permissions => '0700', content => read_file_contents("$root/guest-software-bootstrap.sh") },
	{ path => '/etc/cloudmin-install.json', owner => 'root:root', permissions => '0600',
	  content => convert_to_json(\%config, 0, 1) },
	{ path => '/etc/systemd/system/cloudmin-software.service', owner => 'root:root',
	  permissions => '0644', content => "[Unit]\nDescription=Set up guest software\n".
	  "After=network-online.target cloud-final.service\nWants=network-online.target\n".
	  "[Service]\nType=oneshot\nUMask=0077\n".
	  "ExecStart=/usr/bin/perl /usr/local/lib/cloudmin/guest-software.pl run\n".
	  "ExecStopPost=/bin/rm -f /var/lib/cloudmin-install/request.json /var/lib/cloudmin-install/installer.sh /var/lib/cloudmin-install/before_script.sh /var/lib/cloudmin-install/after_script.sh\n".
	  "TimeoutStartSec=7200\nTimeoutStopSec=30\nKillMode=control-group\nStandardOutput=null\nStandardError=null\n" });
# Include the Pro executor only when this request selects custom scripts.
if (uses_scripts($request)) {
	push(@{$data->{'write_files'}}, {
		path => '/usr/local/lib/cloudmin/guest-scripts.pl', owner => 'root:root',
		permissions => '0700', content => read_file_contents("$root/pro/guest-scripts.pl") });
}
# Install distro-specific Perl modules before software starts.
push(@{$data->{'runcmd'}},
	['/bin/sh', '/usr/local/lib/cloudmin/guest-software-bootstrap.sh'],
	['systemctl', 'daemon-reload'],
	['/usr/bin/perl', '/usr/local/lib/cloudmin/guest-software.pl', 'prepare']);
# Cloud-init generates the normal guest host keys. Only the public identity
# is read through libvirt; no host private key is ever written to this seed.
}

# addresses(request, vm) combines configured static IPs with discovered addresses.
# Software setup checks the guest's pinned SSH host key before using an address.
sub addresses
{
my ($request, $vm) = @_;
my @addresses = map { $_->{'address'} || '' } @{$vm->{'addresses'} || []};
if (($request->{'address_mode'} || '') eq 'static') {
	# Static form values include a prefix length, which SSH does not accept.
	unshift(@addresses, map { (split(m{/}, $_ || ''))[0] || '' }
		@{$request}{qw(ipv4 ipv6)});
}
my %seen;
# Exclude loopback, unspecified and link-local targets, then deduplicate.
return grep { !$seen{$_}++ &&
	((check_ipaddress($_) && $_ !~ /\A(?:0\.|127\.|169\.254\.)/) ||
	 (check_ip6address($_) && $_ !~ /\A(?:::1|::|fe[89ab][0-9a-f]:.*)\z/i))
} @addresses;
}

# failure(result) maps the small guest protocol to safe, useful error messages.
sub failure
{
my ($result) = @_;
my %reasons = (
	identity => 'The guest identity does not match this creation request',
	perl => 'Guest software setup requires Perl and its modules; check the cloud-init log inside the virtual machine',
	privilege => 'Guest software setup requires passwordless sudo for the initial user',
	cloud_init_missing => 'Guest software setup requires cloud-init inside the virtual machine',
	cloud_init_timeout => 'Initial guest setup did not finish within 15 minutes; check cloud-init status inside the virtual machine',
	cloud_init_failed => 'Initial guest setup failed; check cloud-init status inside the virtual machine',
	credentials => 'Virtualmin Pro license credentials are missing from the guest setup request',
	helper => 'The guest setup helper failed; check its configuration and Perl installation inside the virtual machine');
# Known prerequisite failures have diagnostics that are safe to publish.
return $reasons{$result->{'reason'} || ''}."\n" if ($reasons{$result->{'reason'} || ''});
# Step failures keep detailed command output in the guest's private log.
my %steps = (before => 'Preparation script', packages => 'Package installation',
	download => 'Virtualmin download', install => 'Virtualmin installation', after => 'Final setup script');
my $step = $steps{$result->{'failed_step'} || ''} || 'Guest software setup';
return "$step failed. See /var/lib/cloudmin-install/install.log inside the virtual machine\n";
}

# guest(adapter, job, [skip_addresses]) checks the original guest still runs.
# skip_addresses defaults to false; progress checks omit address discovery.
sub guest
{
my ($adapter, $job, $skip_addresses) = @_;
my $vm = $adapter->get_domain($job->{'request'}->{'uuid'}, $skip_addresses);
# An absent domain ends setup normally; discovery errors still propagate.
die bless({}, 'Cloudmin::Software::GuestDeleted') if (!$vm);
die "The virtual machine's creation identity changed before software setup finished\n"
	if (($vm->{'cloudmin'}->{'job'} || '') ne $job->{'id'});
die "The virtual machine was stopped before software setup finished\n" if (!$vm->{'active'});
return $vm;
}

# run(service, id) monitors guest installation outside the host disk-work lock.
# service supplies the job store, libvirt adapter and managed SSH keys.
sub run
{
my ($service, $id) = @_;
my $jobs = $service->{'jobs'};
# Only one host monitor may own this job, including after CGI disconnection.
return if ($jobs->busy($id));
return $jobs->lock('worker-'.$id, sub {
	my $job = $jobs->get($id);
	# A stale launcher must not reopen completed or non-software work.
	return if (!$job->{'resources'}->{'software'} ||
		$job->{'state'} !~ /\A(?:running|recovering)\z/);
	# Explicit cleanup owns the worker lock before stopping its sandbox or guest.
	return $service->cleanup_creation($id) if ($job->{'cleanup_created'});
	my $adapter = $service->{'adapter'}->();
	my $worker = $service->{'worker'} || Cloudmin::Worker->new();
	my $ok = eval {
		# Recovery must not start saved scripts after the Pro package is removed.
		require_scripts() if (uses_scripts($job->{'request'}));
		# Remove the old sandbox before resuming the guest's saved work.
		$worker->cleanup($job->{'worker'}) if ($job->{'worker'});
		# A saved deadline bounds recovery after reconnects or controller restarts.
		while (time() < $job->{'resources'}->{'software_deadline'}) {
			die "Guest software cancellation requested\n" if ($job->{'cancel'});
			my $r = $job->{'request'};
			my $vm = guest($adapter, $job);
			if (!$job->{'resources'}->{'ssh_host_public'}) {
				# Learn the public key through the domain's trusted agent channel,
				# before sending any credentials to a network address.
				my $final_attempt = time() >= $job->{'resources'}->{'software_deadline'} - 7200;
				my $public = $adapter->get_setup_host_key($r->{'uuid'}, $final_attempt);
				if ($public) {
					# Save the verified key before SSH sends any credentials.
					$job = $jobs->update($id, sub { $_[0]->{'resources'}->{'ssh_host_public'} = $public; });
				}
				else {
					# The agent and identity file appear during cloud-init. Bound
					# this wait separately from the software installation deadline.
					die "Could not verify the guest SSH host key within 15 minutes. Check cloud-init and qemu-guest-agent inside the virtual machine\n"
						if ($final_attempt);
					Time::HiRes::sleep(5);
					$job = $jobs->get($id);
					next;
				}
			}
			# Recheck before launching a worker if the package changed while waiting.
			require_scripts() if (uses_scripts($r));
			# Each address is tried with the same managed key and pinned host key.
			my @addresses = addresses($r, $vm);
			my $last_check = time();
			my $key = $service->{'ssh_keys'}->find($r->{'uuid'}, $id) ||
				die "The virtual machine's managed SSH key is missing\n";
			foreach my $address (@addresses) {
				# Give the worker credentials and this guest's verified keys.
				my $result = $worker->run('software', {
					address => $address, username => $r->{'username'}, uuid => $r->{'uuid'},
					host_public_key => $job->{'resources'}->{'ssh_host_public'},
					serial => $r->{'virtualmin_serial'}, key => $r->{'virtualmin_key'} },
					files => { identity => $key },
					started => sub { my $unit = $_[0];
						# started(unit) saves the sandbox unit for cleanup.
						$jobs->update($id, sub { $_[0]->{'worker'} = $unit; }); },
					progress => sub {
						# progress(event) checks cancellation and saves stages.
						# Cancellation stops the SSH monitor before sending a guest stop.
						die "Guest software cancellation requested\n" if ($jobs->get($id)->{'cancel'});
						# Periodically notice power or deletion changes during SSH monitoring.
						if (time() - $last_check >= 5) {
							guest($adapter, $job, 1);
							$last_check = time();
						}
						# Record known stages without exposing guest output.
						my $event = $_[0];
						die "Guest software setup monitoring timed out\n"
							if (time() >= $job->{'resources'}->{'software_deadline'});
						return if (($event->{'type'} || '') ne 'progress');
						my $stage = $event->{'stage'} || '';
						return if ($stage !~ /\A(?:accepted|before|packages|download|install|after)\z/);
						$jobs->update($id, sub {
							my ($current) = @_;
							# Guest acceptance lets us erase host secrets.
							delete(@{$current->{'request'}}{qw(virtualmin_serial virtualmin_key)})
								if ($stage eq 'accepted');
							# Avoid duplicate stages after reconnection.
							return if ($stage eq 'accepted' || $current->{'phase'} eq 'software_'.$stage);
							$current->{'events'}->[-1]->{'state'} = 'done';
							$current->{'phase'} = 'software_'.$stage;
							push(@{$current->{'events'}}, {step => $current->{'phase'}, state => 'running'});
						});
					});
				$jobs->update($id, sub { delete($_[0]->{'worker'}); });
				# Terminal results end monitoring; transport loss tries another
				# address.
				if ($result->{'stage'} eq 'complete') {
					# Register only a verified guest whose installer has finished.
					# Registration can be retried from Remote Access without reinstalling.
					if ($r->{'webmin_register'} && $service->{'register_webmin'}) {
						# Give registration its own progress step.
						$jobs->update($id, sub {
							$_[0]->{'events'}->[-1]->{'state'} = 'done';
							$_[0]->{'phase'} = 'software_webmin';
							push(@{$_[0]->{'events'}}, {step => 'software_webmin', state => 'running'});
							});
						# Registration failure does not fail the install.
						# Show retry advice without private error details.
						my $registered = eval { $service->{'register_webmin'}->($jobs->get($id), $address); 1 };
						$jobs->update($id, sub { $_[0]->{'webmin_warning'} =
							$registered ? '' : 'Virtualmin is installed, but Webmin registration failed. Open Remote Access, select Webmin, then choose Open embedded Webmin to retry.'; });
						}
					return finish($service, $id, '');
					}
				return finish($service, $id, '', 1) if ($result->{'stage'} eq 'cancelled');
				die failure($result) if ($result->{'stage'} eq 'failed');
			}
			# Retry guest discovery and monitoring until the saved deadline.
			Time::HiRes::sleep(5);
			$job = $jobs->get($id);
		}
		die "Could not confirm guest software setup before the deadline. Check the installation log inside the virtual machine\n";
	};
	if (!$ok) {
		# Deletion and cancellation end setup without rolling back the guest.
		my $error = $@;
		return finish($service, $id, '', 1, 1)
			if (ref($error) eq 'Cloudmin::Software::GuestDeleted');
		return cancel($service, $id, $adapter, $worker) if ($jobs->get($id)->{'cancel'});
		return finish($service, $id, $error);
	}
});
}

# cancel(service, id, adapter, worker) stops setup over pinned SSH, or runs
# explicitly requested creation cleanup while holding the worker lock.
sub cancel
{
my ($service, $id, $adapter, $worker) = @_;
my $job = $service->{'jobs'}->get($id);
# Explicit guest removal uses the creation rollback, not SSH setup cancellation.
return $service->cleanup_creation($id) if ($job->{'cleanup_created'});
my $r = $job->{'request'};
my $ok = eval {
	# Confirm that the old monitor and its private inputs are gone first.
	$worker->cleanup($job->{'worker'}) if ($job->{'worker'});
	my $vm = $adapter->get_domain($r->{'uuid'});
	# A deleted or powered-off guest has no running setup process to stop.
	return finish($service, $id, '', 1, !$vm) if (!$vm || !$vm->{'active'});
	die "The guest identity changed before software setup could be stopped\n"
		if (($vm->{'cloudmin'}->{'job'} || '') ne $id);
	# No SSH launch is possible until the verified public key has been saved.
	return finish($service, $id, '', 1) if (!$job->{'resources'}->{'ssh_host_public'});
	my $key = $service->{'ssh_keys'}->find($r->{'uuid'}, $id) ||
		die "The virtual machine's managed SSH key is missing\n";
	my $deadline = time()+75;
	foreach my $address (addresses($r, $vm)) {
		# Reuse the pinned key; cancellation needs no license credentials.
		my $result = $worker->run('software', {address => $address,
			username => $r->{'username'}, uuid => $r->{'uuid'}, action => 'cancel',
			host_public_key => $job->{'resources'}->{'ssh_host_public'}},
			files => {identity => $key},
			started => sub { my $unit = $_[0];
				# started(unit) saves the stop worker's unit for cleanup.
				$service->{'jobs'}->update($id, sub { $_[0]->{'worker'} = $unit; }); },
			# progress(event) enforces the stop deadline while SSH is connected.
			progress => sub { die "Stopping guest software setup timed out\n" if (time() >= $deadline); });
		# Setup may have finished before the stop request reached the guest.
		return finish($service, $id, '', 1) if ($result->{'stage'} eq 'cancelled');
		return finish($service, $id, '') if ($result->{'stage'} eq 'complete');
		die failure($result) if ($result->{'stage'} eq 'failed');
	}
	die "Cannot confirm that guest software setup stopped. Use the virtual machine's power controls to stop it\n";
};
# Failed stop confirmation is recorded without deleting the created guest.
return finish($service, $id, "$@") if (!$ok);
return $ok;
}

# finish(service, id, error, [cancelled], [guest_deleted]) records setup's outcome.
# Ordinary cancellation keeps the guest; explicit creation cleanup removes it.
# An empty error denotes success unless cancelled; both flags default to false.
sub finish
{
my ($service, $id, $error, $cancelled, $guest_deleted) = @_;
my $jobs = $service->{'jobs'};
# Honor an explicit cleanup request even if setup finishes at the same time.
return $service->cleanup_creation($id) if ($jobs->get($id)->{'cleanup_created'});
# Software failure ends monitoring without rolling back the created guest.
my $job = $jobs->update($id, sub {
	# Cancellation and completion decide the outcome in the same transaction.
	return if ($_[0]->{'cleanup_created'});
	$_[0]->{'state'} = $error ? 'failed' : $cancelled ? 'cancelled' : 'complete';
	$_[0]->{'error'} = $error ? "The virtual machine was created. $error"
		: $cancelled ? 'Software setup cancelled'.($guest_deleted
			? ' because the virtual machine was deleted' : '') : '';
	$_[0]->{'events'}->[-1]->{'state'} = $error ? 'failed' : $cancelled ? 'cancelled' : 'done';
	# Only confirmed deletion clears the record that creation produced a guest.
	$_[0]->{'resources'}->{'domain'} = 0 if ($guest_deleted);
	# Discard login and license credentials when setup ends.
	delete(@{$_[0]->{'request'}}{qw(webmin_password virtualmin_serial virtualmin_key)});
	# Retain the worker reference if its cleanup may have failed.
	delete($_[0]->{'worker'}) if (!$error);
});
# Cleanup may have been requested after the first check but before the update.
return $service->cleanup_creation($id) if ($job->{'cleanup_created'});
# An audit failure must not change the provisioning result or retain secrets.
my $logged = eval { $jobs->audit($error ? 'software_failed' : $cancelled ? 'software_cancelled' : 'software_complete', $job); 1 };
$jobs->update($id, sub { $_[0]->{'audit_warning'} = 'Could not write the installation audit log'; })
	if (!$logged);
return $error ? 0 : 1;
}

1;
