use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;

# Catch CGI exits so each request can be checked in the same test process.
BEGIN { *CORE::GLOBAL::exit = sub { die bless({}, 'EditorExit'); }; }
our ($module_root_directory, $remote_user, %in, %text, %access, $whatfailed);
$module_root_directory = "$Bin/..";
$remote_user = 'fixture';
require "$module_root_directory/cloudmin-lib.pl";
require "$module_root_directory/cloudmin-pages.pl";
$INC{'./server-manager-lib.pl'} = 1;
$INC{"$module_root_directory/cloudmin-status-lib.pl"} = 1;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) {
	chomp;
	$text{$1} = $2 if (/^([^=]+)=(.*)$/);
	}
close($lang);

# ReadParse() keeps this request's supplied form fields.
sub ReadParse { }
# is_readonly_mode() grants this fixture permission to save.
sub is_readonly_mode { return 0; }
# error_setup(message) records Webmin's operation-specific error context.
sub error_setup { $whatfailed = $_[0]; }
# error(message) exposes the normal Webmin error path to assertions.
sub error { die "$whatfailed: $_[0]"; }
# error_message(error) supplies a readable cause without trailing whitespace.
sub error_message { my $error = $_[0]; $error =~ s/\s+$//; return $error; }
# error_html(message) keeps non-license errors escaped in this CGI fixture.
sub error_html { return html_escape($_[0]); }
# html_escape(value) keeps job failures and warnings as text.
sub html_escape { return WebminCore::html_escape($_[0]); }
# urlize(value) uses Webmin's normal query escaping.
sub urlize { return WebminCore::urlize($_[0]); }

my $uuid = '11111111-2222-3333-4444-555555555555';
my $queued = { id => 'a'x32, uuid => $uuid, state => 'queued', operation => 'update' };
my $complete = { %$queued, state => 'complete' };

# submit(action, tab, initial_job, statuses...) executes the real editor CGI.
sub submit
{
my ($action, $tab, $initial, @statuses) = @_;
my ($url, $output, @calls) = ('', '');
local %in = (action => $action, id => $uuid, vm_edit_tabs => $tab);
local $ENV{'REQUEST_METHOD'} = 'POST';
local $ENV{'CONTENT_LENGTH'} = 0;
local $whatfailed;
no warnings qw(redefine once);
local *main::call_vm_api = sub {
	push(@calls, $_[1]);
	my $value = $_[1] eq 'status' ? shift(@statuses) : $initial;
	die "Unexpected status read\n" if (!defined($value));
	die $value if (!ref($value));
	return $value;
	};
local *main::parse_vm_edit_form = sub { return $_[0]; };
local *main::redirect = sub { $url = WebminCore::un_urlize($_[0]); };
open(my $fh, '>', \$output) or die $!;
local *STDOUT = $fh;
do "$Bin/../edit_machine.cgi";
my $error = $@;
$error = '' if (ref($error) eq 'EditorExit');
return { url => $url, error => $error, output => $output, calls => \@calls };
}

# Fast and delayed saves both reopen the selected tab without progress output.
foreach my $tab (qw(resources disks interfaces)) {
	my $result = submit('update', $tab, $queued, $complete);
	is($result->{'url'}, "edit_machine.cgi?id=$uuid&vm_edit_tabs=$tab&vm_saved=".('a'x32),
		"save redirects to the $tab tab");
	is($result->{'error'}, '', 'successful job has no error page');
	is($result->{'output'}, '', 'redirect is sent before page or theme output');
	is_deeply($result->{'calls'}, ['update', 'status'], 'success waits for the worker result');
	}
my $result = submit('update', 'unknown&delete=1', $complete);
like($result->{'url'}, qr/&vm_edit_tabs=resources&/, 'unknown tabs fall back to resources');
is_deeply($result->{'calls'}, ['update'], 'a completed retry needs no polling');
$result = submit('delete', 'disks', { %$complete, operation => 'delete' });
is($result->{'url'}, 'index.cgi?vm_saved='.('a'x32), 'deletion returns to the surviving overview');
is($result->{'output'}, '', 'deletion also sends a clean redirect');
$result = submit('delete_disk', 'resources', { %$queued, operation => 'delete_disk' },
	{ %$complete, operation => 'delete_disk' });
is($result->{'url'}, "edit_machine.cgi?id=$uuid&vm_edit_tabs=disks&vm_disk_deleted=".('a'x32),
	'disk deletion returns to the editor disk tab');
is($result->{'output'}, '', 'disk deletion sends a clean redirect');
is_deeply($result->{'calls'}, ['delete_disk', 'status'], 'editor waits for disk deletion to finish');

# Both validation errors and later worker failures use error_setup and error.
for my $case (
	['update', "Invalid CPU count\n", [], qr{Cannot edit virtual machine: Invalid CPU count}],
	['update', $queued, [{ %$queued, state => 'failed', error => 'Could not attach <disk>' }],
		qr{Cannot edit virtual machine: Could not attach &lt;disk&gt;}],
	['delete', { %$queued, operation => 'delete' }, [{ %$queued, state => 'failed', error => 'Disk is busy' }],
		qr{Cannot delete virtual machine: Disk is busy}],
	['delete_disk', "Disk is no longer attached\n", [],
		qr{Cannot delete disk: Disk is no longer attached}],
	['delete_disk', { %$queued, operation => 'delete_disk' }, [{ %$queued, state => 'failed', error => 'Disk is busy' }],
		qr{Cannot delete disk: Disk is busy}],
	['update', { %$queued, state => 'cancelled' }, [], qr/operation was cancelled/],
) {
	$result = submit($case->[0], 'disks', $case->[1], @{$case->[2]});
	like($result->{'error'}, $case->[3], 'failed request uses the normal error page');
	is($result->{'url'}, '', 'failed request never redirects as successful');
	}

# A temporary job-store error may recover; persistent errors preserve context.
$result = submit('update', 'resources', $queued, "Store unavailable\n", $complete);
is($result->{'error'}, '', 'a transient status read error recovers');
$result = submit('update', 'resources', $queued, ("Store <unavailable>\n") x 3);
like($result->{'error'}, qr/Could not read the operation status: Store &lt;unavailable&gt;/,
	'failed status reads report their cause safely');
is($result->{'url'}, '', 'unknown completion never causes a success redirect');
ok(!eval { wait_vm_job($queued, 0); 1 }, 'a bounded wait can end while the worker continues');
like($@, qr/still running.*Active Jobs/, 'timeout points to the durable operation');

# Existing power actions keep their immediate destinations.
$result = submit('start', 'resources', { id => $uuid });
is($result->{'url'}, "machine.cgi?id=$uuid", 'Start opens guest details');
$result = submit('shutdown', 'resources', { id => $uuid });
is($result->{'url'}, "edit_machine.cgi?id=$uuid&shutdown_requested=1", 'shutdown returns to its pending view');

# Reset saves synchronously and stays in the editor, without polling a job.
$result = submit('reset_password', '', { id => $uuid });
is($result->{'url'}, "edit_machine.cgi?id=$uuid&vm_edit_tabs=access&vm_access_tabs=password&password_saved=1",
	'password reset returns to its editor form');
is_deeply($result->{'calls'}, ['reset_password'], 'password reset does not wait for a job');
# A stopped guest or unavailable agent must produce an error, not a success URL.
foreach my $failure ('Guest agent is not responding', 'Virtual machine must be running') {
	$result = submit('reset_password', '', "$failure\n");
	like($result->{'error'}, qr{Cannot reset guest password: \Q$failure\E},
		'reset reports a stopped guest or unavailable agent');
	is($result->{'url'}, '', 'failed reset never redirects as successful');
	}
# Opening the form never probes the guest or requires it to be running.
{
no warnings qw(redefine once);
my $readonly = 0;
my $vm = {uuid => $uuid, name => 'fixture', active => 0, state => 'shutoff'};
local %access = (admin => 0, vms => $uuid, password => 1);
# get_libvirt([write]) supplies inventory without connecting to a hypervisor.
local *main::get_libvirt = sub { return bless({}, 'EditorInventory'); };
# get_domain(self, uuid, [skip_addresses]) returns the guest fixture.
local *EditorInventory::get_domain = sub { return $vm; };
# get_guest_status(self, uuid) catches agent probes made while opening the form.
local *EditorInventory::get_guest_status = sub { die "Unexpected agent probe"; };
# is_readonly_mode() lets each request test Webmin's write veto.
local *main::is_readonly_mode = sub { $readonly; };
# get_image_jobs() supplies form tokens without opening a job store.
local *main::get_image_jobs = sub { return bless({}, 'EditorTokens'); };
# form_token(self, user) supplies the token expected by the form renderer.
local *EditorTokens::form_token = sub { return 'signed-token'; };
# ui_print_header(...) suppresses Webmin chrome so only form output is captured.
local *main::ui_print_header = sub { };
# ui_print_footer(...) suppresses navigation around the form under test.
local *main::ui_print_footer = sub { };
# select_theme_server(vm) avoids theme state changes in the fixture.
local *main::select_theme_server = sub { };
# Tab layout is exercised in pages.t; keep this fixture focused on permissions.
# ui_page_assets() omits assets from this controller-only fixture.
local *main::ui_page_assets = sub { '' };
# vm_edit_tabs_start(tab, [access_only]) omits the outer tab markup.
local *main::vm_edit_tabs_start = sub { '' };
# ui_tabs_start_tab(name, tab) omits a pane opener.
local *main::ui_tabs_start_tab = sub { '' };
# ui_tabs_end_tab(name, tab) omits a pane closer.
local *main::ui_tabs_end_tab = sub { '' };
# ui_tabs_end([footer]) omits the tab container closer.
local *main::ui_tabs_end = sub { '' };
# show_vm_access_tabs(password, keys, [tab]) exposes the reset-form marker.
local *main::show_vm_access_tabs = sub { $_[0] };
# show_vm_password_reset_form(vm, token) marks that rendering was reached.
local *main::show_vm_password_reset_form = sub { return 'Password form'; };
# open_reset([fields]) runs a GET; fields defaults to {} and overrides the input.
# No API settings or agent calls are permitted while opening the form.
my $open_reset = sub {
	my ($fields) = @_;
	local %in = (id => $uuid, password_reset => 1, %{$fields || {}});
	local $ENV{'REQUEST_METHOD'} = 'GET';
	local $ENV{'CONTENT_LENGTH'} = 0;
	# call_vm_api(version, action, input) forbids controller calls on GET.
	local *main::call_vm_api = sub { die "Unexpected API call"; };
	# Capture the page without hiding errors from the real CGI.
	my $output = '';
	open(my $fh, '>', \$output) or die $!;
	local *STDOUT = $fh;
	do "$Bin/../edit_machine.cgi";
	my $error = $@;
	# Ignore trapped CGI exits; preserve other exceptions for assertions.
	$error = '' if (ref($error) eq 'EditorExit');
	return {error => $error, output => $output};
	};
# Agent readiness and power state affect submission, not access to the form.
foreach my $state (qw(shutoff running paused)) {
	$vm->{'state'} = $state; $vm->{'active'} = $state ne 'shutoff';
	my $page = $open_reset->();
	is($page->{'error'}, '', "$state guest opens reset form without an agent query");
	is($page->{'output'}, 'Password form', 'form is rendered');
	}
# A reset grant permits POSTs for the assigned VM only, never mutations via GET.
like($open_reset->({action => 'reset_password'})->{'error'}, qr/Use POST/,
	'GET cannot submit a password change');
like($open_reset->({id => 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'})->{'error'}, qr/permissions/,
	'password delegate cannot open another guest');
is_deeply(submit('reset_password', '', {id => $uuid})->{'calls'}, ['reset_password'],
	'password delegate can submit the reset');
# Delegation must not expose other editor actions through a forged submission.
foreach my $action (qw(settings update delete delete_disk start shutdown)) {
	my $denied = submit($action, '', $complete);
	like($denied->{'error'}, qr/permissions/, "$action still requires host access");
	is_deeply($denied->{'calls'}, [], 'refusal happens before the controller');
	}
# Webmin read-only mode blocks both the form and its POST, despite the grant.
$readonly = 1;
like($open_reset->()->{'error'}, qr/read-only/, 'read-only users cannot open reset');
like(submit('reset_password', '', {id => $uuid})->{'error'}, qr/read-only/,
	'read-only users cannot submit reset');
# Ordinary power access must not imply permission to reset guest passwords.
$readonly = 0; $access{'password'} = 0; $access{'power'} = 1;
like($open_reset->()->{'error'}, qr/permissions/, 'power permission does not open reset');
}

# Feedback after the redirect belongs only to the matching completed operation.
{
no warnings qw(redefine once);
my $job = { %$complete, audit_warning => 'Audit <unavailable>' };
local *main::call_vm_api = sub { return $job; };
local *main::notify_theme_save = sub { print "Theme: $_[1]\n"; };
local *main::ui_alert_box = sub { return "Warning: $_[0]\n"; };
my $html = '';
open(my $fh, '>', \$html) or die $!;
{
	local *STDOUT = $fh;
	print_vm_change_result($job->{'id'}, 'update', $uuid);
	}
unlike($html, qr/Theme:/, 'saving settings keeps the current navigation');
like($html, qr{Warning: Audit &lt;unavailable&gt;}, 'completion warnings survive the redirect');
# Post-save guidance appears for live moves; stopped edits apply at boot.
foreach my $scope ('live', 'config') {
	$job = {%$complete, network_changed => 1, scope => $scope};
	$html = '';
	open($fh, '>', \$html) or die $!;
	{
		local *STDOUT = $fh;
		print_vm_change_result($job->{'id'}, 'update', $uuid);
	}
	is(scalar(() = $html =~ /Shut down and start the virtual machine to refresh its network settings/g),
		$scope eq 'live' ? 1 : 0, 'network warning follows live edits, not stopped guests');
}
foreach my $case (['delete', $uuid], ['update', 'another-guest']) {
	$html = '';
	open($fh, '>', \$html) or die $!;
	local *STDOUT = $fh;
	print_vm_change_result($job->{'id'}, @$case);
	is($html, '', 'an unrelated result cannot add warnings or refresh navigation');
	}
# Deletion still refreshes the guest list after redirecting to the overview.
$job = { %$complete, operation => 'delete' };
$html = '';
open($fh, '>', \$html) or die $!;
{
	local *STDOUT = $fh;
	print_vm_change_result($job->{'id'}, 'delete');
	}
like($html, qr/Theme: delete/, 'deletion refreshes navigation on the destination page');
}

# Missing API/form fields preserve saved settings;
# presence marks an unchecked box.
my $live_form = parse_vm_edit_form({ cpus => 2, memory_mib => 768 });
ok(!exists($live_form->{'bootmenu'}), 'live save preserves the omitted boot menu');
ok(!exists($live_form->{'cpu_limit'}), 'live save preserves the omitted CPU maximum');
ok(!exists($live_form->{'memory_limit_mib'}), 'live save preserves the omitted memory maximum');
my $offline_form = parse_vm_edit_form({ cpus => 2, memory_mib => 768, bootmenu_present => 1 });
is($offline_form->{'bootmenu'}, 0, 'unchecked offline boot menu is explicitly disabled');

# Media and network changes retain their selected identities in the shared Save.
my $hardware = parse_vm_edit_form({ disk_0_target => 'sda', disk_0_media => 'eject',
	nic_0_mac => '52:54:00:ab:cd:ef', nic_0_link => 'down',
	nic_0_inbound_kib => 512, nic_0_outbound_kib => 0 });
is_deeply($hardware->{'changes'}, [
	{action => 'change_media', target => 'sda', pool => '', volume => ''},
	{action => 'update_interface', mac => '52:54:00:ab:cd:ef', network => '',
		link => 'down', inbound_kib => 512, outbound_kib => 0}],
	'form submits eject and link/bandwidth edits without changing network source');
done_testing();
