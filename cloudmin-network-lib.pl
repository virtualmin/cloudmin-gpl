# Network controller integration with Webmin authentication, locks and logging.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Use the same timeout bounds in the controller and Module Configuration.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
our ($module_root_directory, $module_var_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/Networks.pm";
require "$module_root_directory/lib/Cloudmin/HostNetwork.pm";

# get_host_network()
# Keeps rollback journals private and uses the VM controller's resource locks.
sub get_host_network
{
return Cloudmin::HostNetwork->new(directory => "$module_var_directory/networking",
	module => $module_root_directory, jobs => get_vm_jobs(),
	confirm_timeout => config_number('bridge_confirm_timeout'),
	client => $ENV{'REMOTE_ADDR'});
}

# get_network_service([writable])
# Network mutations are local-host operations; inventory shares the same adapter.
# writable defaults to false; true requests a libvirt connection for changes.
sub get_network_service
{
# Network inventory includes host interfaces outside the user's assigned VMs.
require_access('host');
my ($writable) = @_;
my $adapter = get_libvirt($writable);
die "Networking is available only for the local qemu:///system host\n"
	if ($adapter->uri() ne 'qemu:///system');
return Cloudmin::Networks->new(adapter => $adapter,
	host => get_host_network(), jobs => get_vm_jobs());
}

# change_network(action, input)
# Requires host administrator access and a valid token before network changes.
sub change_network
{
my ($action, $in) = @_;
die "Networking changes are disabled in read-only mode\n" if (is_readonly_mode());
# Finish or reverse an accepted network change even when licensing blocks new work.
require_access($action =~ /\A(?:confirm|rollback|restore_rules)\z/ ? 'recover' : 'manage');
get_image_jobs()->check_token($remote_user, $in->{'token'});
local $main::error_must_die = 1;
my $service = get_network_service(1);
my $host = $service->{'host'};
my $name;
# Rebuild libvirt's rules without stopping networks or redefining guests.
if ($action eq 'restore_rules') {
	die "Use POST for network changes\n" if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	require "$module_root_directory/lib/Cloudmin/NetworkPreflight.pm";
	return get_vm_jobs()->lock('create-host', sub {
		$service->assert_idle();
		my $unit = Cloudmin::NetworkPreflight::restore($service->{'adapter'}, sub { get_libvirt(1) });
		webmin_log('restore_rules', 'network', undef, {service => $unit}) if ($unit);
		return $unit;
	});
}
# Create and start a libvirt network under the shared controller lock.
if ($action eq 'create') {
	$name = $service->create($in);
	}
# Reserve bridge creation or removal before launching the independent worker.
elsif ($action eq 'bridge' || $action eq 'bridge_remove') {
	return get_vm_jobs()->lock('create-host', sub {
		$service->assert_idle();
		my $remove = $action eq 'bridge_remove';
		# Read the removal destination from the bridge's current membership.
		my $plan = $remove ? $service->prepare_bridge_removal($in->{'name'})
			: $service->prepare_bridge(@$in{qw(name source)});
		my $id = $host->begin($in->{'name'}, $plan->{'source'}, $in->{'revision'},
			$remote_user, $remove ? 'remove' : undef);
		webmin_log($action, 'network', $id, { name => $in->{'name'}, source => $plan->{'source'} });
		return $id;
		});
	}
# Only the originating user can confirm the reviewed bridge transaction.
elsif ($action eq 'confirm') {
	$name = $host->confirm($in->{'id'}, $remote_user);
	}
# Explicit recovery may outlive the account that began the change.
elsif ($action eq 'rollback') {
	my $p = $host->pending() || die "No pending bridge change\n";
	die "This bridge change has been replaced\n" if ($p->{'id'} ne ($in->{'id'} || ''));
	# Any writer can recover an expired or failed transaction, including one
	# whose original Webmin account no longer exists. Confirmation stays private.
	die "This bridge change belongs to another user\n" if ($p->{'owner'} ne $remote_user &&
		$p->{'state'} ne 'rollback_failed' && time() < $p->{'deadline'});
	# Recovery runs outside the HTTP process because it may move its connection.
	$host->command(['systemctl', 'start', '--no-block', 'cloudmin-network-rollback.service']);
	return $p->{'name'};
	}
# Apply ordinary network lifecycle actions through the libvirt service.
else {
	$name = $service->change($action, @$in{qw(id revision enabled)});
	}
webmin_log($action, 'network', $in->{'id'} || $name, { name => $name });
return $name;
}

# call_bridge_api(action, input)
# Uses the UI's bridge validation and recovery, keeping file backups private.
# input is the decoded request hash; write actions require a signed token.
sub call_bridge_api
{
my ($action, $in) = @_;
require_access('host');
my $service = get_network_service();
my $host = $service->{'host'};
# Inventory is readable without starting or reserving a network change.
if ($action eq 'bridges') {
	return $service->inventory()->{'bridges'};
	}
# Poll the current transaction; an optional ID protects against a newer change.
if ($action eq 'bridge_status') {
	my $state = $host->public_state();
	# A stale poll must not report another transaction as its own completion.
	die "This bridge change has been replaced\n" if ($in->{'id'} &&
		(!$state || $state->{'id'} ne $in->{'id'}));
	return $state;
	}
# Reviewing a removal requires the same permissions and token as submitting it.
if ($action eq 'bridge_remove_review') {
	# Review grants a revision for submission, so it requires write access.
	die "Networking changes are disabled in read-only mode\n" if (is_readonly_mode());
	require_access('manage');
	get_image_jobs()->check_token($remote_user, $in->{'token'});
	$service->assert_idle();
	my $plan = $service->prepare_bridge_removal($in->{'name'});
	# The plan also contains private snapshots that must stay on the host.
	return { map { $_ => $plan->{$_} }
		qw(name source operation addresses management confirm_timeout revision) };
	}
# Reuse the UI's token, ownership and locking checks for all mutations.
my %actions = (bridge_remove => 'bridge_remove', bridge_confirm => 'confirm', bridge_rollback => 'rollback');
# Unknown requests must never fall through to an unrelated network action.
die "Unknown bridge action\n" if (!$actions{$action});
change_network($actions{$action}, $in);
return $host->public_state();
}

1;
