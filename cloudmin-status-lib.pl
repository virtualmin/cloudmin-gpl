# Read-only guest health checks; never log in or run commands in a guest.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
use IO::Socket::IP;
use IO::Select;
use Time::HiRes ();
use Fcntl qw(:flock);
our (%text, %config, %in, $module_root_directory, $module_var_directory,
     $module_config_directory, $module_name);
# Replace collectors that still include licensing in session permissions.
our $cloudmin_status_protocol = 13;
require "$module_root_directory/cloudmin-terminal-lib.pl";

# check_ssh_service(addresses, [port])
# Checks discovered guest addresses for an SSH banner on port (default 22).
# All addresses share a two-second budget.
# Callers supply a validated port, normally from get_terminal_port.
sub check_ssh_service
{
my ($addresses, $port) = @_;
# Callers without a saved port retain the standard SSH default.
$port = 22 if (!defined($port));
my $deadline = Time::HiRes::time() + 2;
foreach my $address (@$addresses) {
	my $remaining = $deadline - Time::HiRes::time();
	# All candidate addresses share the two-second budget.
	last if ($remaining <= 0);
	my $socket = IO::Socket::IP->new(PeerHost => $address, PeerPort => $port,
		Type => Socket::SOCK_STREAM(),
		Timeout => $remaining < 0.5 ? $remaining : 0.5);
	# An unreachable address should not prevent trying another
	# reported IP.
	next if (!$socket);
	my $until = Time::HiRes::time() + 0.5;
	# A final connection attempt cannot extend the shared probe
	# deadline.
	$until = $deadline if ($until > $deadline);
	my $buffer = '';
	# A listening TCP port alone is not evidence of a working SSH service.
	while (length($buffer) < 4096 && $until > Time::HiRes::time()) {
		# Stop waiting when this server has used its allotted
		# banner time.
		last if (!IO::Select->new($socket)->can_read($until - Time::HiRes::time()));
		# A closed socket or failed read cannot confirm SSH readiness.
		last if (!sysread($socket, my $part, 512));
		$buffer .= $part;
		# Accept SSH-2-compatible identification, even after
		# server preamble lines.
		if ($buffer =~ /(?:\A|\n)SSH-(?:2\.0|1\.99)-[^\r\n]+\r?\n/) {
			close($socket);
			return $address;
			}
		}
	close($socket);
	}
return undef;
}

# get_server_health(uuid)
# Returns public health signals; the shared worker drops the localized labels.
sub get_server_health
{
my ($uuid) = @_;
# Status subscriptions refer to stable inventory UUIDs, not arbitrary
# names.
die "Invalid virtual machine ID\n" if (!defined($uuid) || ref($uuid) ||
	$uuid !~ /\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i);
my $vm = get_libvirt(1)->get_guest_status($uuid);
my @addresses = list_terminal_addresses($vm);
# Probe the same shared port that future SSH connection forms will offer.
my $port = get_terminal_port($uuid);
my $running = $vm->{'state'} =~ /\A(?:running|blocked)\z/;
my $local = $config{'libvirt_uri'} eq 'qemu:///system';
my $ssh = !$running ? 'inactive' : !$local ? 'remote' : !@addresses
	? 'no_address' : 'unavailable';
# The local collector probes only running guests with usable known
# addresses.
my $address = check_ssh_service(\@addresses, $port)
	if ($running && $local && @addresses);
# Mark SSH as responding only after receiving its identification line.
$ssh = 'responding' if ($address);
my $agent = $running ? $vm->{'agent'} : 'inactive';
return {
	power => $vm->{'state'}, agent => $agent, ssh => $ssh,
	ssh_address => $address, ssh_port => $port,
	addresses => $vm->{'addresses'},
	labels => {
		power => $text{'index_state_'.$vm->{'state'}} ||
			$text{'index_state_unknown'},
		agent => $text{'vm_agent_'.$agent},
		ssh => $address ? text('vm_ssh_responding', $address, $port)
		: text('vm_ssh_'.$ssh, $port),
		addresses => @addresses ? join(', ', @addresses)
		: $text{'vm_no_address'},
	},
	# A warning page can reopen itself when its prerequisites become
	# available.
	terminal_available => $running && @addresses &&
	foreign_check('xterm') && !is_readonly_mode() ? 1 : 0,
	console_available => $vm->{'active'} && $local &&
		($vm->{'graphics'}->{'type'} || '') eq 'vnc' &&
		foreign_check('xterm') && !is_readonly_mode() ? 1 : 0,
	# This checks device presence, not whether another client holds the port.
	# The shared collector filters both console modes with each viewer's grant.
	serial_available => $vm->{'active'} && $local && $vm->{'serial_console'} &&
		foreign_check('xterm') && !is_readonly_mode() ? 1 : 0,
};
}

# get_status_config(vm, [reopen])
# Returns socket configuration and the current user's labels and permissions.
# reopen is terminal, console or serial for a connection, or edit_machine after
# shutdown. Omit it to update status without navigating to another page.
sub get_status_config
{
my ($vm, $reopen) = @_;
# Map reconnect targets to tabs without changing the status readiness keys.
my %tabs = (terminal => 'ssh', serial => 'serial', console => 'graphical');
my $page = $tabs{$reopen || ''} ? 'remote_access' : $reopen;
my $config = { endpoint => get_webprefix().'/server-manager/machine_status.cgi',
	id => $vm->{'uuid'},
	yes => $text{'index_yes'}, no => $text{'index_no'},
	usage => { map { $_ => $text{'vm_usage_'.$_} }
	qw(format missing unavailable cpu memory disk rate) },
	filesystems => { map { $_ => $text{'vm_filesystems_'.$_} }
	qw(checking stopped unavailable empty) },
	units => [ 'B',
	map { $text{'nice_size_'.$_} } qw(kiB MiB GiB TiB PiB) ],
	# Connection warning pages must not reopen after their grant is removed.
	# Serial has its own readiness field but shares the console permission.
	readonly => is_readonly_mode() || ($reopen && $reopen =~ /\A(?:console|serial|terminal)\z/ &&
		!can_access($reopen eq 'serial' ? 'console' : $reopen, $vm->{'uuid'})) ? 1 : 0,
	labels => { map { $_ => $text{$_} }
	grep { /^(?:index_state_|vm_agent_|vm_ssh_)/ } keys %text },
	unavailable => $text{'vm_status_unavailable'},
	checking => $text{'vm_status_checking'}, reopen => $reopen || '',
	# Reopen the selected console tab, including the theme's navigation mode.
	url => $reopen ? get_webprefix().'/server-manager/'.$page.'.cgi?id='.
	urlize($vm->{'uuid'}).($tabs{$reopen} ? '&tab='.$tabs{$reopen} : '').
	($in{'xnavigation'} ? '&xnavigation=1' : '') : '' };
return convert_to_json($config);
}

# get_overview_status_config([token]) supplies theme-native row templates.
# Omit the token when power controls are unavailable.
# Tokens and translated markup belong to the page, never the shared cache.
sub get_overview_status_config
{
my ($token) = @_;
my $config = convert_from_json(get_status_config({ uuid => 'overview' }));
my $id = '00000000-0000-0000-0000-000000000000';
# Send column IDs so live updates find the right cells when columns are hidden.
# As in the initial table, controls require a token as well as a visible column.
my @columns = grep { $_->[0] ne 'controls' || $token }
	view_selection('machine_columns');
$config->{'columns'} = [map { $_->[0] } @columns];
# Filter every power-state template with the same settings as the initial rows.
$config->{'rows'} = { map {
	my (undef, $rows) = table_columns('machine_columns',
		[get_vm_row({ uuid => $id, name => '', state => $_,
		active => $_ ne 'shutoff', persistent => 1, autostart => 0 },
		$token)], 0, $token);
	$_ => $rows->[0]
	} qw(running blocked paused shutdown shutoff crashed nostate
	     pmsuspended unknown) };
$config->{'no_ips'} = $text{'index_no_ips'};
$config->{'boot_label'} = $text{'vm_start_at_boot'};
return convert_to_json($config);
}

# notify_status_changed(uuid) queues module changes without a libvirt event.
sub notify_status_changed
{
my ($id) = @_;
# With no collector, the next subscriber's full snapshot covers this
# change.
return if (!-e "$module_var_directory/status-server.json");
open(my $fh, '>>', "$module_var_directory/status-changes") || return;
chmod(0600, "$module_var_directory/status-changes");
flock($fh, LOCK_EX) || return;
# Bound the pending notification file; the collector drains it on its
# next tick.
truncate($fh, 0) if (-s $fh > 65536);
print $fh lc($id)."\n";
close($fh);
}

1;
