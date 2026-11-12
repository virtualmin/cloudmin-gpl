# Versioned controller entry points for the VM UI and API.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(
	Cwd::abs_path(File::Basename::dirname(__FILE__).
		      '/cloudmin-access-lib.pl'));
no warnings 'once';
use Digest::SHA qw(sha256_hex);
use WebminCore qw(convert_to_json);
use MIME::Base64 ();
our (%config, %text, $module_root_directory, $module_var_directory,
     $remote_user);
require "$module_root_directory/lib/Cloudmin/Jobs.pm";
require "$module_root_directory/lib/Cloudmin/VMs.pm";
require "$module_root_directory/lib/Cloudmin/VMManage.pm";
require "$module_root_directory/cloudmin-presets-lib.pl";
require "$module_root_directory/cloudmin-webmin-lib.pl";
require "$module_root_directory/cloudmin-ssh-lib.pl";

# get_snapshot_manager() Snapshot jobs share the VM journal and honor the
# module's read-only ACL.
sub get_snapshot_manager
{
require "$module_root_directory/lib/Cloudmin/Snapshots.pm";
return Cloudmin::Snapshots->new(jobs => get_vm_jobs(),
				images => get_image_jobs(),
				readonly => is_readonly_mode(),
				adapter => sub { get_libvirt(!is_readonly_mode()) });
}

# get_vm_manager() Shares the creation journal and inventory with VM management.
sub get_vm_manager
{
return Cloudmin::VMManage->new(jobs => get_vm_jobs(),
			       images => get_image_jobs(),
			       adapter => sub { get_libvirt(1) });
}

# get_clone_service() shares creation's workers, inventory and private journal.
sub get_clone_service
{
require "$module_root_directory/lib/Cloudmin/Clones.pm";
return Cloudmin::Clones->new(%{get_vm_service()});
}

# get_vm_image_service() loads the Pro capture service only when installed.
sub get_vm_image_service
{
die "Creating images from virtual machines requires Cloudmin Pro\n"
	if (!-r "$module_root_directory/pro/VMImages.pm");
require "$module_root_directory/pro/VMImages.pm";
return Cloudmin::VMImages->new(%{get_vm_service()});
}

# run_vm_job(id) Dispatches stored requests without trusting a
# caller's operation type.
sub run_vm_job
{
my ($id) = @_;
my $job = get_vm_jobs()->get($id) || die "Job not found\n";
# Backup and restore jobs share the VM journal and reservations.
if (($job->{'request'}->{'operation'} ||
     '') =~ /\A(?:backup|backup_inspect|restore)\z/) {
	require "$module_root_directory/cloudmin-backups-lib.pl";
	return get_backup_service()->run($id);
	}
# Captures share clone cleanup but publish through the Pro image service.
return get_vm_image_service()->run($id)
	if (($job->{'request'}->{'operation'} || '') eq 'capture_image');
# Clone recovery must restore the source before cleaning up its destination.
return get_clone_service()->run($id)
	if (($job->{'request'}->{'operation'} || '') eq 'clone');
return get_snapshot_manager()->run($id)
	if (($job->{'request'}->{'operation'} || '') =~ /\Asnapshot_/);
return $job->{'request'}->{'operation'}
	? get_vm_manager()->run($id)
	: get_vm_service()->run($id);
}

# get_vm_jobs() Returns the private SQLite job store with Webmin locks
# and audit callbacks.
sub get_vm_jobs
{
# log(action, type, id, details) uses Webmin's existing audit log.
return Cloudmin::Jobs->new(directory => "$module_var_directory/vm-jobs",
			   # Recheck at durable submission too; workers resume
			   # existing jobs unchanged.
			   admit =>
				   sub { require_cloudmin_license()
			if (defined(&require_cloudmin_license)); },
			   lock_file => \&lock_data_file,
			   unlock_file => \&unlock_data_file,
			   test_lock => \&test_lock,
	# host_guard() blocks resource changes while bridge recovery is pending.
			   host_guard => sub {
		return if (!-f "$module_var_directory/networking/bridge.json");
		require "$module_root_directory/cloudmin-network-lib.pl";
		die "Wait for the pending bridge change to finish\n"
			if (get_host_network()->pending());
		},
			   log => sub { webmin_log(@_); });
}

# get_vm_service() Creates a VM service with connections opened when needed.
sub get_vm_service
{
# adapter() creates a writable adapter; host_memory() returns available bytes.
return Cloudmin::VMs->new(jobs => get_vm_jobs(),
			  images => get_image_jobs(),
			  catalogue => get_image_catalogue(),
			  adapter => sub { get_libvirt(1) },
			  ssh_keys => get_ssh_keys(),
			  # Enforce installer policy in shared preparation,
			  # including CLI/API calls.
			  virtualmin_enabled => virtualmin_enabled(),
	# register_webmin(job, address) runs after pinned SSH confirms
	# installation. It completes accepted creation even if the
			  # license has since expired.
			  register_webmin => sub { register_vm_webmin($_[0],
								      $_[1],
								      1) },
			  host_memory => sub {
		foreign_require('proc', 'proc-lib.pl');
		my (undef, $available) = proc::get_memory_info();
		return $available * 1024;
		});
}

# call_vm_api(version, action, input) Runs v1 VM operations under module ACLs;
# changes also require signed tokens.
sub call_vm_api
{
my ($version, $action, $input) = @_;
# Remove plaintext from the caller's form hash before any logging or rendering.
my $password = delete($input->{'password'});
# Do not retain a password confirmation supplied by an API client either.
delete($input->{'password_again'});
# License credentials are per submission and never echoed by review or forms.
my $serial = delete($input->{'virtualmin_serial'});
my $license = delete($input->{'virtualmin_key'});
# Reject unsupported API semantics before opening any job store.
die "Unsupported API version\n" if ($version ne '1');
# Keep license status and repair reachable while ordinary changes are blocked.
return call_license_api($action, $input)
	if (
		$action =~ /\A(?:license|check_license|change_license|deregister_license)\z/);
# Machine summaries are also available to delegated viewers. Filter before
# reading details; the remaining host APIs retain their administrator check.
return get_api_machines($input) if ($action eq 'machines');
# Historical reads apply host or assigned-VM scope before opening the database.
if ($action eq 'statistics' || $action eq 'statistics_export') {
	require "$module_root_directory/cloudmin-statistics-lib.pl";
	return call_statistics_api($action, $input);
	}
# Notification dispatch checks read scope and mutation grants before storage.
if ($action =~ /\A(?:notifications|notification_config|mute_notifications|unmute_notifications|set_notification_target_enabled|set_notification_rule_enabled|retry_notification|save_notification_target|save_notification_rule|delete_notification_target|delete_notification_rule|test_notification_target)\z/) {
	require "$module_root_directory/cloudmin-notifications-lib.pl";
	return call_notification_api($action, $input);
	}
# Delegate only the listed power actions; a token never substitutes for a grant.
my $power =
	$action =~ /\A(?:start|shutdown|reboot|suspend|resume|reset|force_off|autostart)\z/;
# Power and password changes each need their own grant and exact VM assignment.
# Check these before opening stores, even when the caller has a valid token.
if ($power || $action eq 'reset_password') {
	die "Virtual machine changes are disabled in read-only mode\n"
		if (is_readonly_mode());
	require_access($action eq 'reset_password'
		? 'password'
		: power_permission($action), $input->{'id'});
	}
# Return delegated grants without reading host resources or opening job stores.
elsif ($action eq 'options' && !can_access('host')) {
	return { permissions => access_policy()->{'grants'} };
	}
# Settings, jobs and all other actions remain host-administrator operations.
else {
	require_access('host');
	}
# Host networking uses its own journal and must remain
# recoverable while pending.
if (
	$action =~ /\A(?:bridges|bridge_status|bridge_remove_review|bridge_remove|bridge_confirm|bridge_rollback)\z/) {
	require "$module_root_directory/cloudmin-network-lib.pl";
	return call_bridge_api($action, $input);
	}
# Host storage uses the page's service, locks and audit trail.
if (
	$action =~ /\A(?:storage|register_pool|pool_start|pool_stop|pool_autostart|volume_review|delete_volume|pool_review|unregister_pool)\z/) {
	require "$module_root_directory/cloudmin-storage-lib.pl";
	return call_storage_api($action, $input);
	}
# SSH key management has its own Pro gate and token checks.
if (
	$action =~ /\A(?:ssh_keys|save_ssh_key|delete_ssh_key|download_ssh_key|guest_ssh_keys|add_guest_ssh_key|remove_guest_ssh_key)\z/) {
	return call_ssh_key_api($action, $input);
	}
my $service = get_vm_service();
my $jobs = $service->{'jobs'};
# Public inventory excludes the saved credentials used by backup transports.
if ($action eq 'backups') {
	require "$module_root_directory/cloudmin-backups-lib.pl";
	return get_backup_service()->inventory();
	}
if ($action eq 'image_options') {
	# Resolve capture choices through the same Pro gate as submission.
	return get_vm_image_service()->choices($input->{'id'});
	}
if ($action eq 'clone_options') {
	# Source choices expose no secure domain XML or
	# provisioning credentials.
	my $choices = get_clone_service()->choices($input->{'id'});
	$choices->{'presets'} =
		{ map { $_ => get_presets()->list($_) } qw(template plan) };
	return $choices;
	}
if ($action eq 'snapshots') {
	# Inventory contains labels and relationships, never secure guest XML.
	return get_snapshot_manager()->inventory($input->{'id'});
	}
if ($action eq 'settings') {
	# The editor receives saved settings, never the private libvirt XML.
	return get_vm_manager()->settings($input->{'id'});
	}
if ($action eq 'options') {
	# Reading form choices does not require a signed token.
	return { %{$service->options()}, presets => {
		map { $_ => get_presets()->list($_) } qw(template plan) } };
	}
if ($action eq 'status') {
	# Host administrators can inspect jobs started by other administrators.
	my $job = $jobs->get($input->{'job'}) ||
		  die "Job not found\n";
	return get_public_vm_job($job);
	}
if ($action eq 'list') {
	# Include every owner's jobs, exposing only public progress fields.
	my %seen;
	return [ map { get_public_vm_job($_) } grep { !$seen{$_->{'id'}}++ }
		 @{$jobs->list_pending()}, @{$jobs->list()} ];
	}
# Every remaining action may change guest state or retain credentials.
die "Virtual machine changes are disabled in read-only mode\n"
	if (is_readonly_mode());
# These actions complete or clean up accepted work. All other new host writes
# use the same permission gate as the browser, including direct raw API calls.
require_access('manage') if (!$power && $action ne 'reset_password' &&
			     $action !~ /\A(?:cancel|cancel_cleanup|recover|discard)\z/);
$service->{'images'}->check_token($remote_user, $input->{'token'});
# Keep a reviewed bridge conversion isolated from newly submitted VM changes.
if (-f "$module_var_directory/networking/bridge.json") {
	require "$module_root_directory/cloudmin-network-lib.pl";
	die "Wait for the pending bridge change to finish\n"
		if (get_host_network()->pending());
	}
# Backup operations validate and reserve their inputs before starting workers.
if ($action =~ /\A(?:backup|backup_inspect|restore)\z/) {
	require "$module_root_directory/cloudmin-backups-lib.pl";
	return submit_backup_operation($action, $input);
	}
# Password changes finish in this request, without a recoverable job.
if ($action eq 'reset_password') {
	# callback() holds the host lock to exclude concurrent VM reservations.
	return $jobs->lock('create-host', sub {
		# Reject malformed IDs and guests reserved by a
		# pending management job.
		my $id = $input->{'id'};
		die "Invalid virtual machine ID\n"
			if (!defined($id) || ref($id) ||
			    $id !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
		$jobs->assert_guest_available($id);
		# Call libvirt directly, keeping secrets out of
		# jobs and command lines.
		my $adapter = get_libvirt(1);
		my $vm = $adapter->get_domain($id, 1) ||
			 die "Virtual machine not found\n";
		$adapter->set_user_password($id, $input->{'username'},
					    $password);
		# Audit the account and VM only; libvirt errors
		# also omit the password.
		webmin_log($action, 'vm', $vm->{'uuid'}, {
			name => $vm->{'name'},
			username => $input->{'username'} });
		return { id => $vm->{'uuid'}, name => $vm->{'name'}, action =>
									     $action };
		});
	}
if ($action =~ /\A(?:snapshot_create|snapshot_restore|snapshot_delete|power_cycle|update|delete|delete_disk|grow_disk|add_disk|attach_disk|detach_disk|
		add_interface|update_interface|remove_interface|change_media)\z/x) {
	# A repeated form returns its existing job, including after VM deletion.
	my $id =
		substr(
			sha256_hex('vm-manage:'.$action.':'.
				   Cloudmin::Attempts::key(
					   @$input{qw(token attempt)})),
			0, 32);
	my %fields = %$input;
	delete(@fields{qw(token attempt action version)});
	my $fingerprint = sha256_hex(convert_to_json(\%fields,
						     0, 1, 1));
	my $job = $jobs->lock('create-host', sub {
		my $existing = $jobs->get($id, $remote_user);
		# Reconnecting to an attempt requires identical settings.
		if ($existing) {
			die "This form has already submitted different settings; reload the page\n"
				if (
					$existing->{'request'}->{'fingerprint'} ne $fingerprint);
			return $existing;
			}
		my $manager = $action =~ /\Asnapshot_/
			? get_snapshot_manager()
			: get_vm_manager();
		$jobs->assert_guest_available($input->{'id'} ||
					      '');
		# Validate the requested change before reserving the guest.
		my $request = $manager->prepare($action, $input,
						$id);
		$jobs->assert_guest_available(
			$request->{'uuid'});
		$request->{'fingerprint'} = $fingerprint;
		return $jobs->submit($id, $remote_user,
				     'guest:'.$request->{'uuid'}, $request);
		});
	$jobs->spawn($id, sub { run_vm_job($_[0]); })
		if (
			$job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
	return get_public_vm_job($job);
	}
if (
	$action =~ /\A(?:start|shutdown|reboot|suspend|resume|reset|force_off|autostart)\z/) {
	# Serialize power changes with edits that require a stable guest state.
	return $jobs->lock('create-host', sub {
		# Address guests by UUID so a stale form cannot
		# control a reused name.
		my $id = $input->{'id'};
		die "Invalid virtual machine ID\n"
			if (!defined($id) || ref($id) ||
			    $id !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
		my $adapter = get_libvirt(1);
		$jobs->assert_guest_available($id, $action);
		my $vm = $adapter->get_domain($id, 1) ||
			 die "Virtual machine not found\n";
		if ($action eq 'autostart') {
			# Send the desired value, rather than toggling on a
			# repeated submission.
			my $enabled = $input->{'enabled'};
			# Explicit booleans make retries safe and reject
			# ambiguous form values.
			die "Select whether to start at boot\n"
				if (!defined($enabled) || ref($enabled) ||
				    $enabled !~ /\A[01]\z/);
			# A transient domain has no saved definition to
			# autostart at host boot.
			die "Only persistent virtual machines can start at boot\n"
				if (!$vm->{'persistent'});
			$adapter->set_domain_autostart($id, $enabled);
			}
		elsif ($action eq 'force_off' || $action eq 'reset') {
			# Both abrupt power operations require confirmation
			# and an active guest.
			die($action eq 'reset'
				? "Confirm hard reset\n"
				: "Confirm force power off\n")
				if (!defined($input->{'confirm'}) ||
				    ref($input->{'confirm'}) ||
				    $input->{'confirm'} ne '1');
			die "The virtual machine is already stopped\n"
				if (!$vm->{'active'});
			$action eq 'reset'
				? $adapter->reset_domain($id)
				: $adapter->destroy_domain($id);
			}
		elsif ($action eq 'resume') {
			# Resume applies only to a paused guest, not a
			# stopped or sleeping OS.
			die "The virtual machine must be paused\n"
				if ($vm->{'state'} ne 'paused');
			$adapter->resume_domain($id);
			}
		else {
			# Check fresh state; libvirt still handles
			# changes made concurrently.
			die "The virtual machine is already active\n"
				if ($action eq 'start' && $vm->{'active'});
			# Shutdown and reboot require a guest that can
			# receive the request.
			die "The virtual machine must be running\n"
				if ($action ne 'start' &&
				    $vm->{'state'} !~ /\A(?:running|blocked)\z/);
			my %methods = ( start => 'start_domain',
					shutdown => 'shutdown_domain',
					reboot => 'reboot_domain',
					suspend => 'suspend_domain' );
			my $method = $methods{$action};
			$adapter->$method($id);
			}
		# Failure to save suppression must not hide a
		# successful power action.
		require "$module_root_directory/cloudmin-notifications-lib.pl";
		eval { notification_planned_power($id, $action) };
		warn "Cannot suppress planned guest downtime: $@" if $@;
		webmin_log($action, 'vm', $vm->{'uuid'}, {
			name => $vm->{'name'},
			($action eq 'autostart'
				? ( enabled => $input->{'enabled'} )
				: ()) });
		require "$module_root_directory/cloudmin-status-lib.pl";
		notify_status_changed($id);
		return { id => $vm->{'uuid'}, name => $vm->{'name'},
			 action => $action };
		});
	}
if ($action eq 'review') {
	# API clients may validate settings without submitting a creation job.
	# API requests use presets only when explicitly selected.
	$input = get_presets()->resolve($input)
		if ($input->{'template'} || $input->{'plan'});
	# Add selected and automatic library keys before validating the request.
	$input = resolve_saved_ssh_keys($input);
	my $hash = get_vm_password_hash($jobs, $input, $password);
	my $review = $service->prepare($input, undef, $hash);
	# The browser receives only a status flag, never the retained hash.
	$review->{'password_set'} = delete($review->{'password_hash'}) ? 1 : 0;
	return $review;
	}
if ($action eq 'capture_image') {
	# Retrying the same form returns its job; different
	# values need a new form.
	my $capture = get_vm_image_service();
	my $id =
		substr(
			sha256_hex('vm-image:'.
				   Cloudmin::Attempts::key(
					   @$input{qw(token attempt)})), 0, 32);
	my %fields = %$input;
	delete(@fields{qw(token attempt action version)});
	my $fingerprint = sha256_hex(convert_to_json(\%fields, 0, 1, 1));
	my $job = $jobs->lock('create-host', sub {
		my $existing = $jobs->get($id, $remote_user);
		if ($existing) {
			# Reusing an attempt is safe only when its
			# submitted settings match.
			die "This form has already submitted different image settings; reload the page\n"
				if (
					$existing->{'request'}->{'fingerprint'} ne $fingerprint);
			return $existing;
			}
		# Reserve the source before a competing clone,
		# backup or edit can start.
		$jobs->assert_guest_available($input->{'id'} || '');
		my $request = $capture->prepare($input, $id);
		$request->{'fingerprint'} = $fingerprint;
		return $jobs->submit($id, $remote_user,
				     'guest:'.$request->{'source_uuid'},
				     $request);
		});
	# Repeated submissions may relaunch unfinished work,
	# never finished jobs.
	$jobs->spawn($id, sub { run_vm_job($_[0]); })
		if ($job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
	return get_public_vm_job($job);
	}
if ($action eq 'clone') {
	# Retried submissions retain the original immutable
	# request and destination.
	my $id =
		substr(
			sha256_hex('vm-clone:'.
				   Cloudmin::Attempts::key(
					   @$input{qw(token attempt)})), 0, 32);
	my %fields = %$input;
	delete(@fields{qw(token attempt action version)});
	my $fingerprint = sha256_hex(convert_to_json(\%fields, 0, 1, 1));
	my $job = $jobs->lock('create-host', sub {
		my $existing = $jobs->get($id, $remote_user);
		# Return the accepted clone job without
		# admitting duplicate work.
		if ($existing) {
			die "This form has already submitted different clone settings; reload the page\n"
				if (
					$existing->{'request'}->{'fingerprint'} ne $fingerprint);
			return $existing;
			}
		$jobs->assert_guest_available($input->{'id'} || '');
		my $resolved = get_presets()->resolve($input, 'clone');
		$resolved->{'auth_type'} ||= 'password';
		# Prepared clones merge selected and automatic keys. Unchanged
		# clones keep their existing access and reject
		# explicit library selections.
		$resolved = resolve_saved_ssh_keys($resolved);
		$resolved->{'host_ssh_key'} =
			($config{'machine_host_ssh_key'} // '1') eq '1'
				? 1
				: 0
			if (!exists($resolved->{'host_ssh_key'}));
		my $hash =
			($resolved->{'clone_mode'} || 'prepared') eq 'prepared'
				? get_vm_password_hash($jobs, $resolved,
						       $password)
				: undef;
		my $request =
			get_clone_service()->prepare($resolved, $id, $hash);
		# Reserve both machines before discarding a
		# retained form credential.
		$request->{'fingerprint'} = $fingerprint;
		my $created =
			$jobs->submit($id, $remote_user, 'vm:'.
				      $request->{'name'},
				      $request);
		my $draft =
			substr(
				sha256_hex('vm-create:'.
					   Cloudmin::Attempts::key(@$input{qw(token attempt)})),
				0, 32);
		$jobs->delete_credential($draft, $remote_user);
		return $created;
		});
	$jobs->spawn($id, sub { run_vm_job($_[0]); })
		if ($job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
	return get_public_vm_job($job);
	}
if ($action eq 'create') {
	# Repeated submissions of one attempt must return the same creation job.
	my $id =
		substr(
			sha256_hex('vm-create:'.
				   Cloudmin::Attempts::key(
					   @$input{qw(token attempt)})), 0, 32);
	my $job = $jobs->get($id, $remote_user);
	if ($job) {
		# Reattach a preset request using its saved values, even after
		# an edit or deletion of the preset. Explicitly changed
		# selections still fail.
		foreach my $kind (qw(template plan)) {
			die "This form has already created a virtual machine. Reload the page\n"
				if (($input->{$kind} ||
				     '') ne ($job->{'request'}->{$kind} || ''));
			}
		# Reconnecting keeps the original name, image and installation
		# source. A clean failure can be retried with a new attempt.
		my %identity;
		foreach my $field (qw(name image install_source)) {
			# Match the text normalization used when the
			# request was prepared.
			my $value = defined($input->{$field}) &&
				    !ref($input->{$field})
					    ? $input->{$field}
					    : !exists($input->{$field}) &&
				    $input->{'template'} && $field ne 'name'
					    ? $job->{'request'}->{$field}
					    : '';
			$value =~ s/^\s+|\s+$//g;
			$identity{$field} = $value;
			}
		# Older clients and jobs predate the source selector
		# and use cloud images.
		$identity{'install_source'} ||= 'cloud';
		die "This form has already created ".
			$job->{'request'}->{'name'}.
			". Reload the page to create another virtual machine\n"
			if ($identity{'name'} ne $job->{'request'}->{'name'} ||
			    $identity{'image'} ne
			    $job->{'request'}->{'image'} ||
			    $identity{'install_source'} ne (
				    $job->{'request'}->{'install_source'} ||
				    'cloud'));
		}
	else {
		# Check current inventory before reserving a name or
		# allocating resources.
		$job = $jobs->lock('create-host', sub {
			# Save resolved defaults and
			# credentials with this attempt.
			$input = get_presets()->resolve($input)
				if ($input->{'template'} || $input->{'plan'});
			# Add selected and automatic library keys before
			# validating the request.
			$input = resolve_saved_ssh_keys($input);
			my $hash =
				get_vm_password_hash($jobs, $input, $password);
			my $request = $service->prepare($input, undef, $hash);
			# Shared template defaults must not grant delegated
			# creators host logins.
			$request->{'webmin_register'} = 0
				if (($remote_user || '') ne 'root');
			# Registering a guest must not bypass the host's
			# Servers Index grants.
			require_webmin_registration()
				if ($request->{'webmin_register'});
			# Retain the submitted login privately until Servers
			# Index registration. Key-only accounts have no usable
			# Unix password to reuse.
			$request->{'webmin_password'} = $password
				if ($request->{'webmin_register'} &&
				    ($request->{'auth_type'} || 'keys') ne 'keys' &&
				    defined($password) && length($password));
			my $credentials =
				Cloudmin::Software::credentials(
					$request->{'software'}, $serial,
					$license);
			@{$request}{keys %$credentials} = values %$credentials;
			die "Enable managed virtual machine SSH keys in Module Configuration for guest software setup\n"
				if (Cloudmin::Software::enabled($request) &&
				    (
					    $config{'machine_host_ssh_key'} // '1') ne '1');
			# Keep IDs for retry matching; workers use the
			# resolved request only.
			$request->{$_} =
				$input->{$_} for grep {
					$input->{$_} } qw(template plan);
			my $hex = Cloudmin::Images::generate_id();
			$request->{'uuid'} = join('-', substr($hex, 0, 8),
						  substr($hex, 8, 4),
						  '4'.substr($hex, 13, 3),
						  '8'.substr($hex, 17,
							     3),
						  substr($hex, 20, 12));
			# Module configuration controls managed SSH access for
			# cloud images. ISO installers configure access
			# inside the guest instead.
			$request->{'host_ssh_key'} =
				($request->{'install_source'} || '') ne 'iso' &&
				($config{'machine_host_ssh_key'} // '1') eq '1'
					? 1
					: 0;
			$request->{'console_password'} =
				substr(Cloudmin::Images::generate_id(), 0, 8);
			my $created = $jobs->submit($id, $remote_user,
						    'vm:'.$request->{'name'},
						    $request);
			$jobs->delete_credential($id, $remote_user);
			return $created;
			});
		}
	# Reattach unfinished work without rerunning a finished job.
	$jobs->spawn($id, sub { get_vm_service()->run($_[0]); })
		if ($job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
	return get_public_vm_job($job);
	}
if ($action eq 'discard') {
	# Host administrators may release a proven partial edit by any owner.
	my $job = $jobs->get($input->{'job'}) || die "Job not found\n";
	get_vm_manager()->discard_change($job->{'id'});
	return get_public_vm_job($jobs->get($job->{'id'}));
	}
if ($action eq 'cancel_cleanup') {
	# Destructive cleanup is explicit and reserves a committed guest again.
	die "Confirm cancellation and cleanup\n"
		if (($input->{'confirm'} || '') ne '1');
	my $job = $jobs->lock('create-host', sub {
		my $current = $jobs->get($input->{'job'}) ||
			      die "Job not found\n";
		# Completed creations and unrelated operations are
		# not rollback targets.
		die "Only unfinished creation jobs can remove their virtual machine\n"
			if ($current->{'request'}->{'operation'} ||
			    (!$current->{'cleanup_pending'} &&
			     $current->{'state'} =~ /\A(?:complete|failed|cancelled)\z/));
		# Software setup normally leaves the guest editable. Reclaim it
		# before cleanup so a simultaneous edit, snapshot or
		# backup cannot start.
		$jobs->assert_guest_available($current->{'request'}->{'uuid'})
			if ($current->{'resources'}->{'software'} &&
			    !$current->{'cleanup_created'});
		foreach my $other (@{$jobs->list_pending()}) {
			# Captures reserve their source; include it even
			# without a destination.
			next if ($other->{'id'} eq $current->{'id'});
			my $uuid = $current->{'request'}->{'uuid'};
			die "Another operation uses this virtual machine; finish it before cleanup\n"
				if (($other->{'resource'} || '') eq 'guest:'.
				    $uuid ||
				    ($other->{'request'}->{'source_uuid'} ||
				     '') eq $uuid ||
				    ($other->{'request'}->{'uuid'} || '') eq $uuid);
			}
		return $jobs->update($current->{'id'}, sub {
			# The worker may have completed while the host
			# lock was being acquired.
			die "This job has already finished\n"
				if (!$_[0]->{'cleanup_pending'} &&
				    $_[0]->{'state'} =~ /\A(?:complete|failed|cancelled)\z/);
			$_[0]->{'cancel'} = 1;
			$_[0]->{'cleanup_created'} = 1;
			# Resume pending rollback through recovery.
			$_[0]->{'state'} = 'recovering'
				if ($_[0]->{'cleanup_pending'});
			# Setup normally reserves only its installer;
			# deletion needs the guest.
			$_[0]->{'resource'} =
				'guest:'.$_[0]->{'request'}->{'uuid'}
				if ($_[0]->{'resources'}->{'software'});
			});
		});
	# Persist and audit the request before a detached worker acts on it.
	$jobs->audit('cancel_cleanup', $job);
	$jobs->spawn($job->{'id'}, sub { run_vm_job($_[0]); });
	return get_public_vm_job($job);
	}
if ($action eq 'cancel' || $action eq 'recover') {
	# Host administrators can finish other owners' jobs that block changes.
	my $job = $jobs->get($input->{'job'}) ||
		  die "Job not found\n";
	if ($action eq 'cancel') {
		# Started hardware changes need recovery; copy jobs can
		# cancel and roll back.
		die "This change has started; use recovery if it fails\n"
			if ($job->{'request'}->{'operation'} &&
			    $job->{'request'}->{'operation'} !~ /\A(?:clone|capture_image|backup|backup_inspect|restore)\z/ && $job->{'resources'}->{'started'});
		# A finished job cannot be cancelled, including
		# across concurrent updates.
		die "This job has already finished\n"
			if (
				$job->{'state'} =~ /\A(?:complete|failed|cancelled)\z/);
		$job = $jobs->update($job->{'id'}, sub {
			# Recheck inside the transaction if a
			# worker started meanwhile.
			die "This change has started; use recovery if it fails\n"
				if ($_[0]->{'request'}->{'operation'} &&
				    $_[0]->{'request'}->{'operation'} !~ /\A(?:clone|capture_image|backup|backup_inspect|restore)\z/ &&
				    $_[0]->{'resources'}->{'started'});
			# Completion and cancellation compete in the
			# same SQLite transaction.
			die "This job has already finished\n"
				if (
					$_[0]->{'state'} =~ /\A(?:complete|failed|cancelled)\z/);
			$_[0]->{'cancel'} = 1;
			});
		$jobs->audit('cancel', $job)
			if ($job->{'request'}->{'operation'});
		}
	else {
		# Recovery is explicit for failed cleanup; running jobs
		# are simply reattached.
		if ($job->{'cleanup_pending'}) {
			# Reopen failed cleanup so the recovery
			# worker can retry it.
			$job = $jobs->update($job->{'id'},
					     sub { $_[0]->{'state'} = 'recovering'; });
			}
		}
	# A running worker observes cancellation; recovery
	# may need a new worker.
	$jobs->spawn($job->{'id'}, sub { run_vm_job($_[0]); })
		if ($job->{'state'} !~ /\A(?:complete|failed|cancelled)\z/);
	return get_public_vm_job($job);
	}
die "Unknown virtual machine API action\n";
}

# get_api_machines(input) summarizes guests the caller may view. input is a
# request hash; its optional id is an exact UUID or guest name.
sub get_api_machines
{
my ($input) = @_;
my $id = $input->{'id'};
# Validate the selector's type and length before loading inventory.
die "Invalid virtual machine selector\n" if (defined($id) &&
					     (ref($id) || !length($id) || length($id) > 255));
# Report inventory errors and check permissions before reading guest details.
my @servers = list_managed_servers_sorted();
die "$main::cloudmin_last_error\n" if ($main::cloudmin_last_error);
@servers = grep { can_access('view', $_->{'uuid'}) } @servers;
if (defined($id)) {
	# Never reveal whether an inaccessible guest exists.
	@servers = grep { $_->{'uuid'} eq $id || $_->{'name'} eq $id } @servers;
	die "Virtual machine not found\n" if (!@servers);
	die "Ambiguous virtual machine name; use its UUID\n" if (@servers != 1);
	}
# Skip resource and address lookups when no guests are visible.
return [ ] if (!@servers);
# Reuse the collector's current readings instead of sampling again per API call.
require "$module_root_directory/cloudmin-statistics-lib.pl";
my $latest = statistics_latest();
my $jobs = get_vm_jobs();
my @result;
# Build an explicit public record instead of exposing libvirt or job internals.
foreach my $server (@servers) {
	my $uuid = $server->{'uuid'};
	my $sample = $latest->{'vms'}->{$uuid}->{'resources'} || { };
	# Load creation metadata only from a valid job ID.
	my $meta = $server->{'cloudmin'} || { };
	my $job = ($meta->{'job'} || '') =~ /\A[a-f0-9]{32}\z/
		? $jobs->get($meta->{'job'})
		: undef;
	# Imported metadata must not disclose another guest's creation record.
	$job = undef if ($job && ($job->{'request'}->{'uuid'} || '') ne $uuid);
	# Normalize power states and units; unknown disk capacity stays null.
	my %row = ( id => $uuid, name => $server->{'name'},
		    state => $server->{'state'} =~ /\A(?:running|blocked)\z/
			    ? 'running'
			    : $server->{'state'} eq 'paused'
				    ? 'paused'
				    : 'stopped',
		    cpus => 0 + $server->{'vcpus'}, memory_mib =>
							    $server->{'memory_kib'} / 1024,
		    disk_gib => defined($sample->{'disk_capacity_bytes'})
			    ? $sample->{'disk_capacity_bytes'} / 1024**3
			    : undef,
		    addresses => [ get_server_addresses($server) ],
		    autostart => $server->{'autostart'} ? \1 : \0 );
	# Read the creation time only from a matching job.
	$row{'created'} = 0 + $job->{'created'} if ($job && $job->{'created'});
	# Expose attached preset names without disclosing their settings.
	my $presets =
		Cloudmin::Presets->new(
			directory => $main::module_config_directory,
			# access(writing) checks this guest's view
			# grant for preset reads.
			access => sub { require_access('view', $uuid) });
	# Omit preset names that can no longer be resolved.
	foreach my $kind (qw(template plan)) {
		my $key = $meta->{$kind} || ($job
			? $job->{'request'}->{$kind}
			: '');
		next if (!$key);
		my $preset = eval { $presets->get($kind, $key) };
		$row{$kind} = $preset->{'name'} if ($preset);
		}
	push(@result, \%row);
	}
# Exact selectors return one object; the unfiltered endpoint returns an array.
return defined($id) ? $result[0] : \@result;
}

# generate_random_password() Uses 144 bits from the OS random source without
# storing the plaintext password.
sub generate_random_password
{
return substr(MIME::Base64::encode_base64(pack('H*',
					       Cloudmin::Images::generate_id()),
					  ''), 0, 24);
}

# get_vm_password_hash(jobs, input, [password]) Hashes a new password with
# Webmin, or loads the hash retained for this form. Returns undef for ISO
# installs and key-only cloud accounts.
sub get_vm_password_hash
{
my ($jobs, $input, $password) = @_;
# Installer credentials are entered inside the guest, never retained here.
return undef if (($input->{'install_source'} || '') =~ /\A\s*iso\s*\z/);
# Key-only accounts have no password to hash or recover from this form.
return undef if (($input->{'auth_type'} || 'keys') eq 'keys');
# Do not interpret an unknown authentication mode as password access.
die "Select an authentication method\n"
	if (($input->{'auth_type'} || '') !~ /\A(?:password|both)\z/);
my $id =
	substr(
		sha256_hex('vm-create:'.
			   Cloudmin::Attempts::key(@$input{qw(token attempt)})),
		0,
		32);
my $username = $input->{'username'} || '';
$username =~ s/^\s+|\s+$//g;
if (defined($password) && length($password)) {
	# Do not trim passwords or impose a complexity rule on
	# the initial account.
	die "Enter a password of up to 1024 characters without line breaks\n"
		if (ref($password) || length($password) > 1024 ||
		    $password =~ /[\x00\r\n]/);
	foreign_require('useradmin', 'user-lib.pl');
	my $salt = '$6$rounds=500000$'.
		   substr(Cloudmin::Images::generate_id(), 0, 16).'$';
	# JSON decodes Unicode; crypt expects the same UTF-8 bytes as SSH login.
	utf8::encode($password) if (utf8::is_utf8($password));
	my $hash = useradmin::encrypt_sha512($password, $salt);
	# Reject crypt failures instead of storing a disabled or malformed hash.
	die "Password hashing is unavailable on this host\n"
		if (
			$hash !~ /\A\$6\$rounds=500000\$[a-f0-9]{16}\$[.\/A-Za-z0-9]{86}\z/);
	$jobs->save_credential($id, $remote_user, $username, $hash);
	return $hash;
	}
my $hash = $jobs->credential($id, $remote_user, $username);
# A reused form can omit plaintext only after retaining a matching hash.
die "Enter an initial password\n" if (!$hash);
return $hash;
}

# get_public_vm_job(job) Exposes progress and identity without
# provisioning credentials.
sub get_public_vm_job
{
my ($job) = @_;
my $request = $job->{'request'};
my %deployment;
# Use the saved creation settings, including when reopening an older job.
if (($request->{'operation'} || 'create') eq 'create' &&
    $request->{'image_name'}) {
	my $installer = ($request->{'install_source'} || '') eq 'iso';
	$deployment{'image_name'} = $request->{'image_name'};
	# Match the form's Virtualmin, script or package summary without
	# exposing script contents or license credentials. Installer ISOs
	# have no guest setup.
	$deployment{'software_name'} = !$installer &&
				       ($request->{'software'} || '') =~ /\Avirtualmin-(?:gpl|pro)\z/
					       ? Cloudmin::Presets::template_name($request, { })
					       : $text{!$installer && Cloudmin::Software::enabled($request)
						       ? (Cloudmin::Software::uses_scripts($request)
							       ? 'vm_summary_setup'
							       : 'vm_summary_packages')
						       : 'vm_summary_none'};
	}
# Include the attachment-change flag for feedback after the editor redirects. It
# reports a hardware edit, not a change to the guest's IP configuration.
return {
	(map { $_ => $job->{$_} }
	 qw(id state phase events error cleanup_pending cleanup_warning
	   audit_warning created updated cancel cleanup_created image_progress network_changed)),
	%deployment,
	name => $job->{'request'}->{'name'},
	uuid => $job->{'request'}->{'uuid'},
	operation => $job->{'request'}->{'operation'} || 'create',
	# Workers may revise the planned scope and deferred
	# groups after queueing.
	scope => $job->{'scope'} || $job->{'request'}->{'scope'},
	deferred_fields => $job->{'deferred_fields'} ||
			   $job->{'request'}->{'deferred_fields'} || [ ],
	# Copy jobs can roll back after starting; hardware edits cannot.
	can_cancel => (
		!$job->{'request'}->{'operation'} ||
		$job->{'request'}->{'operation'} =~ /\A(?:clone|capture_image|backup|backup_inspect|restore)\z/ ||
		!$job->{'resources'}->{'started'}) ? 1 : 0,
	# Committed guests remain accessible even if later software setup fails.
	vm_created => $job->{'resources'}->{'software'} &&
		      $job->{'resources'}->{'domain'} ? 1 : 0,
	# Registered guests open Remote Access; others link to
	# their own HTTPS page.
	software_url => ($job->{'request'}->{'software'} ||
			 '') =~ /\Avirtualmin-(?:gpl|pro)\z/ &&
			$job->{'state'} eq 'complete'
				? $job->{'request'}->{'webmin_register'}
					? 'remote_access.cgi?id='.
			urlize($job->{'request'}->{'uuid'}).
			'&tab=webmin'
					: 'https://'.$job->{'request'}->{'hostname'}.
			':10000/'
				: undef,
	# Registration failure leaves the guest usable and offers a retry.
	webmin_warning => $job->{'webmin_warning'},
	start => $job->{'request'}->{'start'} };
}

# wait_vm_job(job, [timeout]) Waits for a submitted job without tying its worker
# to the browser connection. timeout defaults to 3700 seconds; timeout leaves
# the background job running.
sub wait_vm_job
{
my ($job, $timeout) = @_;
my $deadline = time() + ($timeout // 3700);
my $failures = 0;
while (1) {
	# Only completed work may return the user to a freshly editable form.
	return $job if ($job->{'state'} eq 'complete');
	die(($job->{'error'} || 'Virtual machine operation failed')."\n")
		if ($job->{'state'} eq 'failed');
	die "Virtual machine operation was cancelled\n"
		if ($job->{'state'} eq 'cancelled');
	# A disconnected or timed-out request leaves the durable worker running.
	die "The operation is still running. Check Active Jobs for its status.\n"
		if (time() >= $deadline);
	select(undef, undef, undef, 0.25);
	my $current = eval { call_vm_api(1, 'status',
					 { job => $job->{'id'} }); };
	if ($current) {
		# A successful status read resets the transient failure count.
		$job = $current;
		$failures = 0;
		}
	elsif (++$failures >= 3) {
		# Report persistent read failures without claiming
		# the job itself failed.
		die "Could not read the operation status: ".error_message($@).
			". Check Active Jobs for its status.\n";
		}
	}
}

# recover_vm_jobs() Resumes unfinished jobs when a host administrator with
# write access visits.
sub recover_vm_jobs
{
# Read-only and delegated page visits must not resume jobs that change the host.
return if (is_readonly_mode() || !can_access('host'));
my $jobs = get_vm_jobs();
# Host recovery must also reconcile jobs whose original Webmin user was removed.
foreach my $job (@{$jobs->list(undef, 1)}) {
	$jobs->spawn($job->{'id'}, sub { run_vm_job($_[0]); });
	}
}

1;
