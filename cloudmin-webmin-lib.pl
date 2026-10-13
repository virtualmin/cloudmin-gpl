# Guest Webmin offers direct links and an optional same-origin host proxy.
use strict;
use warnings;
no warnings 'once';
our ($module_root_directory, $module_config_directory, $remote_user, %text);

# can_vm_webmin(uuid) checks access to the Webmin tab for the host's root login.
# Registered entries also need the per-server check when resolving their URLs.
sub can_vm_webmin
{
my ($uuid) = @_;
# Check the host login and guest visibility before loading native permissions.
return 0 if (($remote_user || '') ne 'root' || is_readonly_mode() || !can_access('view', $uuid) ||
	!foreign_available('servers'));
foreign_require('servers', 'servers-lib.pl');
# Cloudmin's root-only gate does not replace Servers Index's link permission.
return $servers::access{'links'} ? 1 : 0;
}

# require_webmin_registration([finishing]) checks server-list permissions.
# finishing is reserved for a worker completing an already accepted creation.
sub require_webmin_registration
{
# Registration stores host-side logins and requires Cloudmin management access.
die "Only root can register guest Webmin access through this host\n"
	if (($remote_user || '') ne 'root');
require_access($_[0] ? 'recover' : 'manage');
# Check module access before reading its separate add, edit and link grants.
die "Webmin Servers Index access is required to register a virtual machine\n"
	if (!foreign_available('servers'));
foreign_require('servers', 'servers-lib.pl');
die "Permission to add, edit and connect to Webmin servers is required\n"
	if (!$servers::access{'edit'} || !$servers::access{'add'} || !$servers::access{'links'});
}

# vm_webmin_server(uuid, [creation_job]) finds only Cloudmin's own registration.
# Supplying creation_job prevents a reused UUID from adopting an older login.
sub vm_webmin_server
{
my ($uuid, $job) = @_;
# An uninstalled module has no registration to find or remove.
return if (!foreign_check('servers'));
foreign_require('servers', 'servers-lib.pl');
my ($server) = grep { ($_->{'cloudmin_uuid'} || '') eq ($uuid || '') &&
	(!defined($job) || ($_->{'cloudmin_job'} || '') eq $job) } servers::list_servers();
return $server;
}

# vm_webmin_lock(uuid, callback) serializes changes to a guest's registration.
# Invoke callback with no arguments and return its result after unlocking.
sub vm_webmin_lock
{
my ($uuid, $code) = @_;
# The UUID becomes part of a lock filename, so accept no path characters.
die "Invalid virtual machine ID\n"
	if (($uuid || '') !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/);
my $path = "$module_config_directory/webmin-$uuid";
lock_data_file($path);
# Catch native errors so failed callbacks still release the lock.
local $main::error_must_die = 1;
my $result = eval { $code->() };
my $error = $@;
unlock_data_file($path);
# Rethrow the callback error after releasing the lock.
die $error if ($error);
return $result;
}

# vm_webmin_server_change(server, callback) excludes login files from audit copies.
# The callback saves or deletes this entry through the native Servers Index API.
sub vm_webmin_server_change
{
my ($server, $code) = @_;
my $file = "$servers::module_config_directory/$server->{'id'}.serv";
# Acquire the native file lock without capturing credentials for diffs or undo.
lock_data_file($file, 0, 0, 1);
local $main::error_must_die = 1;
my $ok = eval { $code->(); 1 };
my $error = $@;
# Native saves release the lock themselves; deletes and failures may not.
unlock_data_file($file);
# Preserve the native failure after releasing the credential file's lock.
die $error if (!$ok);
}

# register_vm_webmin(job, [address], [finishing]) adds the guest to Servers Index.
# Use the initial password if available, or the native login prompt.
# If address is omitted, use the first configured or discovered guest IP.
# finishing defaults to false; workers set it when completing accepted creation.
sub register_vm_webmin
{
my ($job, $address, $finishing) = @_;
require_webmin_registration($finishing);
my $r = $job->{'request'};
my ($uuid, $id) = ($r->{'uuid'}, $job->{'id'});
# Only the Virtualmin installation path promises a guest Webmin service.
die "This virtual machine was not installed with Virtualmin\n"
	if (($r->{'software'} || '') !~ /\Avirtualmin-(?:gpl|pro)\z/);
return vm_webmin_lock($uuid, sub {
	# Recheck creation ownership before using a saved login.
	my $adapter = get_libvirt(1);
	my $vm = Cloudmin::Software::guest($adapter, $job);
	my $server = vm_webmin_server($uuid, $id);
	# Existing records retain their administrator's credentials and settings.
	if ($server) {
		# Reusing a record still requires its native per-server grant.
		die "Access to this Webmin server is not allowed\n" if (!servers::can_use_server($server));
		return $server;
		}
	# Use a configured or discovered guest IP instead of a DNS lookup.
	my @addresses = Cloudmin::Software::addresses($r, $vm);
	die "The virtual machine has no reported IP address\n" if (!@addresses);
	# A supplied installer address must remain in the guest's address list.
	die "The virtual machine address changed; try again\n"
		if ($address && !grep { $_ eq $address } @addresses);
	my ($user, $password) = @{$r}{qw(username webmin_password)};
	my $saved_login = defined($password) && length($password);
	# Saved credentials must fit the native line-based server configuration.
	die "Invalid guest Webmin username or password\n" if ($saved_login && (
		!defined($user) || ref($user) || $user !~ /\A[a-z_][a-z0-9_-]{0,31}\z/ ||
		ref($password) || length($password) > 1024 || $password =~ /[\x00\r\n]/));
	# Servers Index owns both automatic login and its browser-session prompt.
	$server = { host => $r->{'hostname'}, ip => $address || $addresses[0], port => 10000,
		ssl => 1, fast => 0, type => 'linux', desc => $r->{'name'}, group => 'Cloudmin',
		($saved_login ? (user => $user, pass => $password) : (autouser => 1)),
		cloudmin_uuid => $uuid, cloudmin_job => $id };
	# Reserve an unused native ID without replacing a manually added server.
	$server->{'id'} = time().$$;
	$server->{'id'}++ while (servers::get_server($server->{'id'}));
	vm_webmin_server_change($server, sub { servers::save_server($server); });
	return $server;
	});
}

# remove_vm_webmin(uuid, job) removes only the deleted creation's server entry.
sub remove_vm_webmin
{
my ($uuid, $job) = @_;
# Guest deletion also works on hosts without Servers Index installed.
return if (!foreign_check('servers'));
return vm_webmin_lock($uuid, sub {
	my $server = vm_webmin_server($uuid, $job);
	# A missing matching entry makes repeated cleanup harmless.
	if ($server) {
		# Deletion must not retain the former password in audit or undo files.
		vm_webmin_server_change($server, sub { servers::delete_server($server->{'id'}); });
		}
	return 1;
	});
}

# vm_webmin_address_source(vm, address) checks host records for a reported IP.
# A match describes host configuration, not the identity of the answering server.
sub vm_webmin_address_source
{
my ($vm, $address) = @_;
my @static = map { (split(m{/}, $_ || ''))[0] || '' }
	@{$vm->{'cloudmin'} || {}}{qw(ipv4 ipv6)};
# Static addresses are recorded in the guest's host-side creation metadata.
return 'static' if (grep { $_ eq $address } @static);
my %macs = map { lc($_->{'mac'} || '') => 1 } @{$vm->{'interfaces'} || []};
delete($macs{''});
# Query leases separately: normal discovery may have returned only agent data.
my $addresses = eval {
	my $adapter = get_libvirt(1);
	my $domain = $adapter->find_domain($vm->{'uuid'});
	$domain ? $adapter->get_domain_addresses($domain, $vm, 1) : [];
	} || [];
return 'lease' if (grep { ($_->{'source'} || '') eq 'lease' &&
	$macs{lc($_->{'mac'} || '')} && ($_->{'address'} || '') eq $address } @$addresses);
# ARP and guest-agent reports alone cannot confirm the host's assigned address.
return 'unverified';
}

# vm_webmin_direct_url(vm) returns the guest HTTPS URL without login credentials.
# Use a current guest address and the registered port, or port 10000 by default.
sub vm_webmin_direct_url
{
my ($vm) = @_;
# Direct links retain the tab's permission and running-guest requirements.
die "Access to guest Webmin is not allowed\n" if (!can_vm_webmin($vm->{'uuid'}));
die "Start the virtual machine before opening Webmin\n" if (!$vm->{'active'});
# Use configured or reported addresses without relying on guest DNS.
my @addresses = Cloudmin::Software::addresses($vm->{'cloudmin'} || {}, $vm);
die "The virtual machine has no reported IP address\n" if (!@addresses);
# Only the current creation may supply saved connection settings.
my $job = $vm->{'cloudmin'}->{'job'} || '';
my $server = vm_webmin_server($vm->{'uuid'}, $job)
	if ($job =~ /\A[a-f0-9]{32}\z/);
die "Access to this Webmin server is not allowed\n"
	if ($server && !servers::can_use_server($server));
my $port = $server && $server->{'port'} ? $server->{'port'} : 10000;
# Reject malformed saved ports before including them in a browser URL.
die "Invalid Webmin port\n" if ($port !~ /\A[0-9]+\z/ || $port < 1 || $port > 65535);
# Prefer the saved destination while it remains in the current address list.
my $address = $server && (grep { $_ eq ($server->{'ip'} || '') } @addresses)
	? $server->{'ip'} : $addresses[0];
# IPv6 literals need brackets in URLs. No username or password enters the URL.
$address = "[$address]" if ($address =~ /:/);
return "https://$address:$port/";
}

# show_vm_webmin_options(vm, direct_url, [register], [change]) shows both actions.
# register offers entry creation when true; it is off when omitted.
# change binds address acceptance to the old and new IPs shown in the alert.
sub show_vm_webmin_options
{
my ($vm, $url, $register, $change) = @_;
my $html = $register ? ui_note($text{'webmin_unregistered'}) : '';
my $navigation = $main::in{'xnavigation'} ? '&xnavigation=1' : '';
# Keep ID and tab in the action URL only; duplicate hidden fields break parsing.
$html .= ui_form_start('remote_access.cgi?id='.urlize($vm->{'uuid'}).
	'&tab=webmin'.$navigation, 'post').
	ui_hidden('token', get_image_jobs()->form_token($remote_user));
# A missing entry is registered only when the embedded button is submitted.
$html .= ui_hidden('register_webmin', 1) if ($register);
my $changed = $change && %$change;
if ($changed) {
	# The same embedded action also confirms the displayed address change.
	$html .= ui_hidden('webmin_old_ip', $change->{'old'}).
		ui_hidden('webmin_new_ip', $change->{'new'});
	}
# Direct access is a link; only the warning button submits proxy consent.
return $html.ui_cluster([
	ui_action_button($text{'webmin_direct_open'}, 'primary', {href => $url,
		icon => 'external',
		title => $text{'webmin_direct_note'},
		attrs => {target => '_blank', rel => 'noopener noreferrer',
			'data-webmin-direct' => 1}}),
	ui_action_button($text{$changed ? 'webmin_address_accept' : 'webmin_proxy_connect'},
		'warning', {type => 'submit', value => 1, icon => 'warning',
		name => $changed ? 'accept_webmin_address' : 'connect_webmin'}),
	]).ui_form_end();
}

# vm_webmin_url(vm, [change], [approval]) checks access before opening the proxy.
# On an IP change, fill the optional change hash and return no URL until approved.
# approval contains the old and new IPs from a token-checked POST by the caller.
sub vm_webmin_url
{
my ($vm, $change, $approval) = @_;
# A reused output hash must not retain a warning from an earlier lookup.
%$change = () if ($change);
# Recheck Cloudmin permissions even for callers outside the tab renderer.
die "Access to guest Webmin is not allowed\n" if (!can_vm_webmin($vm->{'uuid'}));
# Unmanaged guests cannot adopt a registration from an earlier creation.
return if (($vm->{'cloudmin'}->{'job'} || '') !~ /\A[a-f0-9]{32}\z/);
return vm_webmin_lock($vm->{'uuid'}, sub {
	my $server = vm_webmin_server($vm->{'uuid'}, $vm->{'cloudmin'}->{'job'});
	# No matching entry means the page should offer registration.
	return if (!$server);
	# Also check the native per-server permission.
	die "Access to this Webmin server is not allowed\n" if (!servers::can_use_server($server));
	# Require a running guest with a configured or discovered IP.
	die "Start the virtual machine before opening Webmin\n" if (!$vm->{'active'});
	my @addresses = Cloudmin::Software::addresses($vm->{'cloudmin'}, $vm);
	die "The virtual machine has no reported IP address\n" if (!@addresses);
	# Keep a usable saved address; otherwise warn before sending the saved login.
	if (!grep { $_ eq ($server->{'ip'} || '') } @addresses) {
		my $old = $server->{'ip'} || '';
		my $new = $addresses[0];
		if (!$approval || ($approval->{'old'} || '') ne $old ||
		    ($approval->{'new'} || '') ne $new) {
			# A changed destination or stale confirmation needs a fresh warning.
			%$change = (old => $old, new => $new,
				source => vm_webmin_address_source($vm, $new)) if ($change);
			return;
			}
		# Confirmation cannot override either module's permission to edit entries.
		require_access('manage');
		die "Permission to edit Webmin servers is required\n" if (!$servers::access{'edit'});
		$server->{'ip'} = $new;
		vm_webmin_server_change($server, sub { servers::save_server($server); });
		}
	return get_webprefix().'/servers/link.cgi/'.$server->{'id'}.'/';
	});
}

# show_vm_webmin_frame(url) embeds the native proxy with the host's palette.
sub show_vm_webmin_frame
{
my ($url) = @_;
# This sandbox retains same-origin script access; it does not isolate guests.
# Hide the initial document until the guest page and its palette have loaded.
return ui_tag('div',
	ui_tag('iframe', '', { src => $url, title => $text{'console_webmin'},
		'data-webmin-loading' => 1,
		allow => 'fullscreen; clipboard-read; clipboard-write', allowfullscreen => undef,
		sandbox => 'allow-scripts allow-same-origin allow-forms allow-downloads allow-popups allow-modals' }),
	{ class => 'cloudmin-webmin-view' }).
	ui_tag('script', read_file_contents("$module_root_directory/webmin-view.js"));
}

1;
