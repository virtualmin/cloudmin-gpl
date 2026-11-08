use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
use File::Temp qw(tempdir);

# Let standalone CGI responses end without exiting the test process.

BEGIN
{
*CORE::GLOBAL::exit = sub { die "CGI finished\n" };
}

# Render the real CGI with Webmin widgets, replacing host and relay operations.
our (%in, %text, %config, $remote_user, $module_root_directory,
     $root_directory);
our $module_var_directory = tempdir(CLEANUP => 1);
$module_root_directory = "$Bin/..";
$root_directory = $CloudminTest::webmin_root;
$remote_user = 'fixture';
$config{'libvirt_uri'} = 'qemu:///system';
$INC{'./server-manager-lib.pl'} = 1;
require './cloudmin-status-lib.pl';
require './cloudmin-console-lib.pl';
require './cloudmin-pages.pl';
require './cloudmin-webmin-lib.pl';
# Keep real render and file helpers behind the scoped failure stubs below.
my $show_status_summary = \&show_status_summary;
my $lock_file = \&lock_file;
my $write_file = \&write_file;
# Use real UI labels so tab assertions catch label changes.
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { chomp; $text{$1} = $2 if (/^([^=]+)=(.*)$/); }
my $uuid = '11111111-2222-3333-4444-555555555555';
my $guest = { uuid => $uuid, name => '<guest>', active => 1, state => 'running',
	      addresses => [ { address => '192.0.2.1' } ],
	      graphics => { type => 'vnc' },
	      serial_console => { alias => 'serial0' } };

{
	package ConsolePageAdapter;

	# get_domain(self, id, skip_addresses) records the
	# lookup and returns a VM.

	sub get_domain
	{
	push(@{$_[0]->{'calls'}}, [ 'lookup', $_[1], $_[2] ]);
	return $_[0]->{'vm'};
	}
	package ConsolePageJobs;

	# form_token(self, user) supplies a token without a writable job store.

	sub form_token
	{
	'signed-token'
	}

	# check_token(self, user, token) refuses invalid Connect submissions.

	sub check_token
	{
	die "Invalid token\n"
		if (($_[2] || '') ne 'signed-token');
	}

	# get(self, id) returns the creation record used by
	# registration retries.

	sub get
	{
	$_[0]->{'job'}
	}

	# assert_guest_available(self, uuid) leaves the fixture
	# available for retry.

	sub assert_guest_available
	{
	1
	}

	# update(self, id, callback) applies a retry result to
	# the same saved record.

	sub update
	{
	$_[2]->($_[0]->{'job'}); return $_[0]->{'job'};
	}
	}

# render(fields, [grants], [options]) runs one request and records side effects.
# Defaults allow terminal and console access to a running guest. Options select
# the user, guest, request method, navigation mode, settings or status endpoint,
# and can inject launch or tab-preference failures.

sub render
{
my ($fields, $grants, $options) = @_;
$grants ||= { terminal => 1, console => 1 };
$options ||= { };
my ($output, @calls, @footer, $help);
my $vm = $options->{'vm'} || $guest;
local %in = ( id => $uuid, %$fields );
local %config = ( %config, %{$options->{'config'} || { }} );
local $remote_user = $options->{'user'} || $remote_user;
local $ENV{'REQUEST_METHOD'} = $options->{'method'} || 'GET';
local $ENV{'CONTENT_LENGTH'} = 0;
no warnings qw(redefine once);
# ReadParse() leaves the supplied fixture fields in %in.
local *main::ReadParse = sub { };
# error_setup(message) suppresses Webmin's page-wide error setup.
local *main::error_setup = sub { };
# PrintHeader() captures a standalone response without Webmin's normal shell.
local *main::PrintHeader = sub { print "Content-Type: text/html\n\n"; };
# error(message) exposes a CGI refusal as the captured exception.
local *main::error = sub { die "$_[0]\n"; };

# error_html(message) escapes non-license errors in this CGI fixture.

sub error_html
{
return html_escape($_[0]);
}
# error_message(error) retains the original exception for assertions.
local *main::error_message = sub { $_[0] };
# lock_file(file, [readonly], [forcefile], [nodiff]) injects tab lock failures.
local *main::lock_file = sub {
	if ($_[0] eq "$module_var_directory/remote-access-tab-".
	    urlize($remote_user)) {
		# Exercise both native lock failure forms without
		# waiting for a timeout.
		die "<fixture> lock failed\n"
			if (($options->{'tab_error'} || '') eq 'lock');
		return 0
			if (($options->{'tab_error'} || '') eq 'lock_return');
		}
	# Other preference and session files still use Webmin's real locks.
	return $lock_file->(@_);
	};
# write_file(file, data, [join], [sort]) injects tab-preference write errors.
local *main::write_file = sub {
	if ($_[0] eq "$module_var_directory/remote-access-tab-".
	    urlize($remote_user)) {
		# Count tab writes and fail only the requested
		# preference operation.
		push(@calls, [ 'save_tab' ]) if ($options->{'tab_error'});
		die "<fixture> write failed\n"
			if (($options->{'tab_error'} || '') eq 'write');
		}
	# Other writes still use Webmin's file helper.
	return $write_file->(@_);
	};
# is_readonly_mode() uses the test's read-only setting.
local *main::is_readonly_mode = sub { $options->{'readonly'} };
# can_access(action, uuid) grants only the selected guest and actions.
local *main::can_access = sub { ($_[1] || '') eq $uuid && $grants->{$_[0]} };
# foreign_check(module) simulates an installed or missing terminal dependency.
local *main::foreign_check = sub { !$options->{'missing_xterm'} };
# can_vm_webmin(uuid) models an independent grant for the proxy tab.
local *main::can_vm_webmin =
	sub { !$options->{'readonly'} && $grants->{'webmin'} };
# vm_webmin_direct_url(vm) supplies a guest URL without contacting the proxy.
local *main::vm_webmin_direct_url = sub { 'https://192.0.2.1:10000/' };
# vm_webmin_url(vm, [change], [approval]) models pending and
# accepted IP changes.
local *main::vm_webmin_url = sub {
	push(@calls, [ 'proxy' ]);
	# Keep the submitted address pair available for acceptance assertions.
	push(@calls, [ 'accept_address', $_[2] ]) if ($_[2]);
	if ($options->{'address_change'} && !$_[2]) {
		# An unaccepted change exposes warning data
		# without a usable proxy URL.
		%{$_[1]} = %{$options->{'address_change'}};
		return;
		}
	return $options->{'unregistered'}
		? undef
		: '/prefix/servers/link.cgi/123/';
	};
# require_webmin_registration() keeps the registration grant separate from view.
local *main::require_webmin_registration =
	sub { die "Denied\n" if (!$grants->{'register'}); };
# register_vm_webmin(job) records success or simulates a retry failure.
local *main::register_vm_webmin = sub {
	# Failed retries must leave the saved progress warning in place.
	die "$options->{'registration_error'}\n"
		if ($options->{'registration_error'});
	push(@calls, [ 'register', $_[0]->{'id'} ]);
	};
# get_vm_jobs() shares the same in-memory creation record across retry calls.
local *main::get_vm_jobs =
	sub { bless { job => $options->{'job'} }, 'ConsolePageJobs' };
# get_libvirt([writable]) records the requested mode without contacting libvirt.
local *main::get_libvirt = sub {
	push(@calls, [ 'adapter', $_[0] ]);
	return bless { calls => \@calls, vm => $vm }, 'ConsolePageAdapter';
	};
# get_image_jobs() supplies the token stub without opening a job store.
local *main::get_image_jobs = sub { bless { }, 'ConsolePageJobs' };
# get_terminal_key(vm) supplies no key, so the form offers password login.
local *main::get_terminal_key = sub { undef };
# start_terminal(request) records a validated request without launching SSH.
local *main::start_terminal = sub {
	push(@calls, [ 'connect', $_[0] ]);
	save_terminal_login($uuid, 'a' x 32, 'pending', $_[0]);
	if ($options->{'terminal_error'}) {
		# Match the launcher's saved state after a startup failure.
		save_terminal_login($uuid, 'a' x 32, 'failed');
		die "$options->{'terminal_error'}\n";
		}
	return ( 'wss://fixture/terminal', 12345, 'a' x 32 );
	};
# get_current_theme_info_cached() selects SPA or full-page client startup.
local *main::get_current_theme_info_cached =
	sub { { spa => $options->{'spa'} // 1 } };
# get_vm_form_defaults(config) supplies the fixture's default guest account.
local *main::get_vm_form_defaults = sub { { username => 'cloudmin' } };
# get_webprefix() exercises URLs behind a reverse-proxy path prefix.
local *main::get_webprefix = sub { '/prefix' };
# get_webmin_version() supplies a stable version for renderer asset URLs.
local *main::get_webmin_version = sub { '2.700' };
# ui_print_header(subtitle, title, ...) captures the Help
# target and badge markup.
local *main::ui_print_header = sub {
	$help = $_[3];
	print "<header>$_[1]<span>$_[0]</span>".($_[7] || '')."</header>\n";
	};
# ui_print_footer([links...]) records any return links requested by the page.
local *main::ui_print_footer = sub { @footer = @_; };
# vm_header_status(vm, [pending_only]) omits unrelated power and change badges.
local *main::vm_header_status = sub { '' };
# select_theme_server(vm) avoids changing the fixture user's saved selection.
local *main::select_theme_server = sub { };
# show_vm_pending_styles() omits unrelated pending-change styling.
local *main::show_vm_pending_styles = sub { '' };
# show_status_summary(vm, [reopen], [message]) renders the real status card.
local *main::show_status_summary = sub {
	push(@calls, [ 'status', $_[1] ]);
	return $show_status_summary->(@_);
	};
# show_status_script() omits the browser's live status subscription code.
local *main::show_status_script = sub { '' };
# foreign_config(module) supplies a fixed palette without reading host settings.
local *main::foreign_config = sub { ( theme => 'dark' ) };
# load_module_preferences(module, config) retains the fixture's chosen palette.
local *main::load_module_preferences = sub { };
# foreign_require(module) uses the terminal stubs below
# instead of loading xterm.
local *main::foreign_require = sub { };
# get_terminal_options(theme) provides the colors required by the real CGI.
local *xterm::get_terminal_options =
	sub { { theme => { background => '#000', foreground => '#fff' } } };
# get_terminal_theme_script(theme) needs no observer for this fixed palette.
local *xterm::get_terminal_theme_script = sub { '' };
# Capture the CGI response and any error for assertions.
open(my $fh, '>', \$output) or die $!;
local *STDOUT = $fh;
do "$Bin/../".($options->{'status'}
	? 'terminal-status.cgi'
	: 'remote_access.cgi');
return { html => $output || '', error => $@, calls => \@calls, footer =>
								       \@footer,
	 help => $help };
}

# submit_fields(html, button) parses a rendered form as Webmin receives it.
# Include the action query as well as hidden fields to catch duplicate values.

sub submit_fields
{
my ($html, $button) = @_;
my ($action, $form) =
	$html =~ /<form\b[^>]*action=['"]([^'"]*)['"][^>]*>(.*?)<\/form>/s;
# Missing markup is a fixture failure, not an empty valid submission.
die "No form in response\n" if (!defined($form));
my @values;
foreach my $input ($form =~ /<(?:input|button)\b([^>]+)>/g) {
	my %attrs;
	while ($input =~ /\b(name|value|type)=(?:"([^"]*)"|'([^']*)')/g) {
		$attrs{$1} = html_unescape(defined($2) ? $2 : $3);
		}
	# Submit hidden state and only the button clicked by the user.
	push(@values,
	     urlize($attrs{'name'}).'='.urlize($attrs{'value'} || ''))
		if ($attrs{'name'} &&
		    (($attrs{'type'} || '') eq 'hidden' ||
		     $attrs{'name'} eq $button));
	}
# Feed the rendered request through native parsing to reproduce duplicate keys.
my $body = join('&', @values);
open(my $post, '<', \$body) or die $!;
local *STDIN = $post;
local $ENV{'REQUEST_METHOD'} = 'POST';
local $ENV{'CONTENT_LENGTH'} = length($body);
local $ENV{'QUERY_STRING'} = (split(/\?/, html_unescape($action), 2))[1] || '';
my %fields;
ReadParse(\%fields);
return \%fields;
}

# Default navigation shows the original SSH form with no connection badge.
my $result = render({ xnavigation => 1 });
is($result->{'error'}, '', 'default Remote access page renders');
is($result->{'help'}, 'remote_access', 'header opens the renamed Help page');
ok(-f "$Bin/../help/$result->{'help'}.html", 'Remote access Help page exists');
like($result->{'html'},
     qr/>SSH terminal<.*>Serial console<.*>Graphical console</s,
     'tabs follow SSH, Serial, Graphical order');
like($result->{'html'}, qr/class='ui_tabs'/,
     'page uses the standard Webmin tab widget');
# Widget labels also appear in its script, so count only rendered label spans.
my $tabs =
	join(
		'',
		$result->{'html'} =~ m{(<span\b[^>]*class="[^"]*\bvm-console-tab-label".*?</svg>)}sg);
is(scalar(() = $tabs =~ /<svg\b/g), 3, 'each access tab has an SVG icon');
is(scalar(() = $tabs =~ /aria-hidden="true"/g), 3,
   'tab icons leave accessible names to their labels');
# The SSH tab keeps its form and hides the badge until Connect.
like($result->{'html'}, qr/SSH service/, 'SSH keeps its status card');
for my $field (qw(address port username auth)) {
	like($result->{'html'}, qr/name=["']$field["']/,
	     "$field field remains on SSH");
	}
unlike($result->{'html'}, qr/<[^>]+data-console-status|var xterm_argv/,
       'no badge or terminal before Connect');
is_deeply($result->{'footer'}, [ ], 'no return button in the footer');
# Form submissions and tab links must preserve both the VM and theme navigation.
like(html_unescape($result->{'html'}),
     qr/action=['"]remote_access\.cgi\?id=[^'"]+&tab=ssh&xnavigation=1['"]/,
     'Connect preserves VM, tab and xnavigation');
for my $tab (qw(ssh serial graphical)) {
	like($tabs,
	     qr/data-console-tab-url="remote_access\.cgi\?id=[^"]+&amp;tab=$tab&amp;xnavigation=1"/, "$tab URL preserves xnavigation");
	}
like($result->{'html'}, qr/id='div_ssh' class='opener_shown ui_tabs_start'/,
     'SSH is the selected native panel');

# Fresh visits offer direct HTTPS without loading any guest content.
my $embedded_fields =
	{ tab => 'webmin', connect_webmin => 1, token => 'signed-token' };
for my $spa ( 0, 1 ) {
	$result =
		render({ tab => 'webmin' },
		       { terminal => 1, console => 1, webmin => 1 },
		       { spa => $spa });
	is($result->{'error'}, '',
	   'Webmin options render in both navigation layouts');
	like($result->{'html'}, qr/>Graphical console<.*>Webmin</s,
	     'Webmin is the fourth tab');
	unlike($result->{'html'}, qr/name=['"]webmin_view['"]|data-ui-switch/,
	       'no connection mode selector remains');
	like($result->{'html'},
	     qr/<a\b(?=[^>]*data-webmin-direct="1")(?=[^>]*href="https:\/\/192\.0\.2\.1:10000\/")/, 'default action opens the guest HTTPS address');
	like($result->{'html'},
	     qr/<a\b(?=[^>]*rel="noopener noreferrer")(?=[^>]*target="_blank")/,
	     'direct link opens without an opener or referer');
	is(scalar(() = $result->{'html'} =~ /<section[^>]*ui_card_warning/g), 1,
	   'one warning card appears initially');
	like($result->{'html'},
	     qr/compromise the host and all other virtual machines/,
	     'embedded mode explains the trust decision');
	unlike($result->{'html'}, qr/<iframe|data-webmin-action=/,
	       'options create no iframe or connection controls');
	ok(!grep($_->[0] =~ /^(?:register|accept_address)$/,
		 @{$result->{'calls'}}),
	   'fresh visit does not register or accept an address');
	like($result->{'html'}, qr/name="connect_webmin"/,
	     'embedded button is available without switching modes');
	unlike($result->{'html'}, qr/ui_card_foot|ui_form_grouped_buttons/,
	       'connection actions use a plain row in the card body');

	# The real emitted form must carry one guest ID and one
	# tab through ReadParse.
	my $connect = submit_fields($result->{'html'}, 'connect_webmin');
	is($connect->{'tab'}, 'webmin',
	   'trust form submits the tab exactly once');
	is($connect->{'id'}, $uuid,
	   'trust form submits the guest ID exactly once');
	$result =
		render($connect, { webmin => 1 }, { method => 'POST',
						    spa => $spa });
	is($result->{'error'}, '',
	   'signed trust confirmation renders the proxy');
	like($result->{'html'},
	     qr/<iframe[^>]*src="\/prefix\/servers\/link.cgi\/123\/"/,
	     'confirmed iframe opens the host proxy');
	like($result->{'html'},
	     qr/<header>.*data-webmin-action="fullscreen".*data-webmin-action="new-tab".*<\/header>/s,
	     'fullscreen stays ahead of the new-tab control');
	like($result->{'html'},
	     qr/<a\b(?=[^>]*data-webmin-action="new-tab")(?=[^>]*href="https:\/\/192\.0\.2\.1:10000\/")/, 'embedded new-tab action also uses direct HTTPS');
	unlike($result->{'html'},
	       qr/compromise the host|data-webmin-direct|cloudmin-webmin-notice/,
	       'embedded view replaces the warning and choices');
	unlike($result->{'html'},
	       qr/var xterm_argv|<div[^>]*data-console-mode=/,
	       'Webmin starts no console relay');
	}
# Only an explicit saved preference permits opening on navigation.
for my $value ( undef, '', 1, 'invalid', 0 ) {
	$result =
		render({ tab => 'webmin' }, { webmin => 1 },
		       { config => { webmin_confirm => $value } });
	is($result->{'error'}, '', 'saved warning preference renders');
	is(!!($result->{'html'} =~ /<iframe/),
	   defined($value) && "$value" eq '0' ? 1 : '',
	   'only the explicit No setting opens the iframe automatically');
	ok(!grep($_->[0] =~ /^(?:register|accept_address)$/,
		 @{$result->{'calls'}}),
	   'automatic opening cannot register or accept an address');
	}
# A missing entry, changed IP or rejected action cannot use automatic opening.
for my $case (
	[ { tab => 'webmin' }, { unregistered => 1 } ],
	[ { tab => 'webmin' },
	  { address_change =>
		    { old => '192.0.2.1', new => '192.0.2.2',
		      source => 'lease' } } ],
	[ { %$embedded_fields, token => 'wrong' }, { method => 'POST' } ],
	[ $embedded_fields, { } ] ) {
	$result = render($case->[0], { webmin => 1, register => 1 },
			 { %{$case->[1]}, config => { webmin_confirm => 0 } });
	unlike($result->{'html'}, qr/<iframe/,
	       'automatic opening preserves registration, address and request checks');
	}
for my $options ( { readonly => 1 }, { } ) {
	$result = render({ tab => 'webmin' }, { console => 1 },
			 { %$options, config => { webmin_confirm => 0 } });
	ok($result->{'error'}, 'automatic opening cannot bypass access checks');
	is_deeply($result->{'calls'}, [ ],
		  'denial precedes guest or proxy access');
	}
# Old separate-window URLs cannot bypass the new confirmation page.
$result = render({ tab => 'webmin', standalone => 1 }, { webmin => 1 });
is($result->{'error'}, '', 'old standalone URL renders normal options');
unlike($result->{'html'}, qr/<iframe/,
       'old standalone URL does not open the proxy');
for my $options ( { }, { method => 'POST' } ) {
	$result =
		render({ %$embedded_fields, token => 'wrong' }, { webmin => 1 },
		       $options);
	unlike($result->{'html'}, qr/<iframe/,
	       'GET and invalid token cannot open the proxy');
	ok(!grep($_->[0] eq 'proxy', @{$result->{'calls'}}),
	   'rejected confirmation never resolves the proxy');
	}
# Address changes appear above the connection card as soon as the page opens.
for my $standalone ( 0, 1 ) {
	$result =
		render({ tab => 'webmin', standalone => $standalone },
		       { webmin => 1 },
		       { address_change =>
				 { old => '192.0.2.1', new => '192.0.2.2',
				   source =>
					   'unverified' } });
	like($result->{'html'}, qr/192\.0\.2\.1.*192\.0\.2\.2.*do not confirm/s,
	     'warning shows both addresses and the missing host confirmation');
	like($result->{'html'},
	     qr/<div[^>]*alert-warning.*<section[^>]*ui_card_warning/s,
	     'address alert appears before the connection card');
	like($result->{'html'}, qr/data-webmin-direct/,
	     'IP warning retains the direct new-tab action');
	like($result->{'html'}, qr/name=['"]accept_webmin_address['"]/,
	     'warning offers explicit acceptance');
	unlike($result->{'html'}, qr/<iframe|data-webmin-action=/,
	       'warning exposes no frame or connection controls');
	}
my $address_fields = { tab => 'webmin', accept_webmin_address => 1,
		       webmin_old_ip => '192.0.2.1',
		       webmin_new_ip => '192.0.2.2', token =>
							     'signed-token' };
# Exercise the emitted form, not just a hand-built equivalent request.
$result = render({ %$embedded_fields, xnavigation => 1 }, { webmin => 1 },
		 { method => 'POST', address_change =>
					     { old => '192.0.2.1',
					       new => '192.0.2.2',
					       source => 'lease' } });
my $submitted = submit_fields($result->{'html'}, 'accept_webmin_address');
is($submitted->{'id'}, $uuid, 'confirmation submits the guest ID exactly once');
is($submitted->{'tab'}, 'webmin',
   'confirmation submits the Webmin tab exactly once');
is($submitted->{'xnavigation'}, 1, 'confirmation retains navigation state');
$result = render($submitted, { webmin => 1 }, { method => 'POST' });
is($result->{'error'}, '',
   'rendered address form passes native parsing and tab validation');
ok(grep($_->[0] eq 'accept_address', @{$result->{'calls'}}),
   'rendered address form reaches address acceptance');
$result = render($address_fields, { webmin => 1 });
like($result->{'html'}, qr/Use the confirmation button/,
     'GET cannot accept an address');
unlike($result->{'html'}, qr/<iframe/, 'GET refusal cannot load credentials');
$result =
	render({ %$address_fields, token => 'wrong' }, { webmin => 1 },
	       { method => 'POST' });
like($result->{'html'}, qr/Invalid token/, 'address acceptance checks CSRF');
unlike($result->{'html'}, qr/<iframe/, 'invalid token cannot open the proxy');
$result = render($address_fields, { webmin => 1 }, { method => 'POST' });
ok(grep($_->[0] eq 'accept_address' && $_->[1]->{'old'} eq '192.0.2.1' &&
	$_->[1]->{'new'} eq '192.0.2.2', @{$result->{'calls'}}),
   'signed POST passes the displayed address pair');
like($result->{'html'}, qr/<iframe/, 'accepted change may load the proxy');
# Unregistered guests can still use direct access without native registration.
$result = render({ tab => 'webmin' }, { webmin => 1 }, { unregistered => 1 });
like($result->{'html'}, qr/data-webmin-direct="1"/,
     'direct access does not need registration');
ok(!grep($_->[0] eq 'register', @{$result->{'calls'}}),
   'fresh visit creates no registration');
$result =
	render({ tab => 'webmin' }, { webmin => 1, register => 1 },
	       { unregistered => 1 });
like($result->{'html'}, qr/name=['"]register_webmin['"]/,
     'permitted registration is offered with the embedded action');
# Choosing the proxy offers setup only to users with the registration grant.
$result =
	render($embedded_fields, { webmin => 1 },
	       { unregistered => 1, method => 'POST' });
like($result->{'html'}, qr/Denied/, 'missing registration grant is reported');
unlike($result->{'html'}, qr/<iframe|name=['"]register_webmin['"]/,
       'denied registration cannot connect');
$result =
	render($embedded_fields, { webmin => 1, register => 1 },
	       { unregistered => 1, method => 'POST' });
like($result->{'html'}, qr/name=['"]register_webmin['"]/,
     'unregistered guest offers Connect');
like($result->{'html'}, qr/name=['"]token['"]/,
     'registration retains its CSRF token');
unlike($result->{'html'}, qr/name=['"](?:username|password)['"]/,
       'Cloudmin has no duplicate Webmin login fields');
# Console grants, GET requests and forged tokens cannot create registrations.
$result = render({ tab => 'webmin' }, { console => 1 });
like($result->{'error'}, qr/Cloudmin permissions/,
     'console grant does not grant guest Webmin');
$result =
	render({ tab => 'webmin', register_webmin => 1 },
	       { webmin => 1, register => 1 });
like($result->{'error'}, qr/Use the Open embedded Webmin button/,
     'GET cannot configure guest Webmin');
$result = render({ tab => 'webmin', register_webmin => 1, token => 'wrong' },
		 { webmin => 1, register => 1 }, { method => 'POST' });
like($result->{'error'}, qr/Invalid token/,
     'registration requires a valid CSRF token');

# A successful retry clears the old progress warning; failed retries retain it.
for my $failure ( 'Registration failed', '' ) {
	my $job =
		{ id => 'a' x 32, state => 'complete',
		  request => { uuid => $uuid },
		  webmin_warning => 'Earlier registration failed' };
	$result =
		render({ tab => 'webmin', register_webmin => 1, token =>
									'signed-token' },
		       { webmin => 1, register => 1 },
		       { method => 'POST', job => $job,
			 registration_error => $failure,
			 vm => { %$guest,
				 cloudmin => { job => $job->{'id'} } } });
	is($result->{'error'} =~ s/\s+\z//r, $failure,
	   'retry reports its result');
	is(!!$job->{'webmin_warning'}, !!$failure,
	   'warning reflects the latest registration result');
	}

# Both hypervisor tabs retain the existing console config and avoid SSH probes.
for my $tab (qw(serial graphical)) {
	$result = render({ tab => $tab });
	is($result->{'error'}, '', "$tab page renders");
	like($result->{'html'}, qr/data-console-mode="$tab"/,
	     "$tab keeps its original client");
	like($result->{'html'},
	     qr/id='div_$tab' class='opener_shown ui_tabs_start'/,
	     "$tab remains selected on direct navigation");
	unlike($result->{'html'}, qr/name="auth"|xterm_argv/,
	       "$tab has no SSH form or session");
	is_deeply($result->{'calls'}, [ [ 'adapter', 0 ], [ 'lookup', $uuid,
							    1 ] ],
		  "$tab skips address discovery");
	if ($tab eq 'serial') {
		# Only a connected tab can release the port;
		# attribute order can vary.
		like($result->{'html'},
		     qr/<button(?=[^>]*data-console-action="disconnect")(?=[^>]*\bdisabled\b)[^>]*>Disconnect serial console<\/button>/,
		     'serial disconnect stays disabled until the client connects');
		}
	else {
		# The graphical console keeps its existing controls.
		unlike($result->{'html'}, qr/data-console-action="disconnect"/,
		       'graphical has no serial disconnect control');
		}
	}
# The legacy mode parameter still selects the serial tab.
$result = render({ mode => 'serial' });
like($result->{'html'}, qr/data-console-mode="serial"/,
     'existing serial URLs keep working');

# An explicit tab must never borrow the other tab's permission.
for my $case ( [ { tab => 'ssh' }, { console => 1 } ],
	       [ { tab => 'serial' }, { terminal => 1 } ],
	       [ { tab => 'graphical' }, { terminal => 1 } ],
	       [ { id => 'foreign' }, { terminal => 1, console => 1 } ] ) {
	$result = render(@$case);
	like($result->{'error'}, qr/Cloudmin permissions/,
	     'unauthorized tab is refused');
	is_deeply($result->{'calls'}, [ ],
		  'denial happens before guest or relay access');
	}
# Without an explicit tab, default to one the user can access.
$result = render({ }, { terminal => 1 });
like($result->{'html'}, qr/>SSH terminal</, 'SSH-only user can open Console');
unlike($result->{'html'}, qr/>Serial console<|>Graphical console</,
       'SSH-only user sees no hypervisor tabs');
$result = render({ }, { console => 1 });
like($result->{'html'}, qr/data-console-mode="serial"/,
     'console-only user defaults to an allowed tab');
unlike($result->{'html'}, qr/>SSH terminal<|name="auth"/,
       'console-only user sees no SSH tab');
# Webmin read-only mode and invalid tab names must stop before host lookups.
$result = render({ }, undef, { readonly => 1 });
like($result->{'error'}, qr/read-only/,
     'read-only users cannot open interactive tabs');
is_deeply($result->{'calls'}, [ ], 'read-only denial precedes lookups');
$result = render({ tab => 'serial;id' });
like($result->{'error'}, qr/Invalid console tab/, 'unknown tabs are rejected');

# Only a signed POST starts SSH, regardless of the navigation mode.
save_terminal_port($uuid, 2222);
$result = render({ tab => 'ssh' });
like($result->{'html'}, qr/name="port"[^>]*value="2222"/,
     'SSH form reuses the authenticated port');
my $clicked = submit_fields($result->{'html'}, 'connect');
is($clicked->{'connect'}, 1, 'action button submits Connect');
my $fields = { tab => 'ssh', connect => 1, token => 'signed-token',
	       username => 'cloudmin', address => '192.0.2.1', port => 2222,
	       auth =>
		       'password' };
for my $spa ( 0, 1 ) {
	$result = render($fields, undef, { method => 'POST', spa => $spa });
	is($result->{'error'}, '', 'Connect renders the existing terminal');
	like($result->{'html'}, qr/data-cloudmin-console="ssh"/,
	     'terminal identifies the SSH tab to themes');
	like($result->{'html'}, qr/<header>.*data-terminal-status/s,
	     'badge is in the VM header after Connect');
	like($result->{'html'}, qr/var xterm_argv = /,
	     'theme terminal configuration is unchanged');
	is(scalar(grep { $_->[0] eq 'connect' } @{$result->{'calls'}}), 1,
	   'one SSH relay starts');
	my ($connection) = grep { $_->[0] eq 'connect' } @{$result->{'calls'}};
	is($connection->[1]->{'port'}, 2222,
	   'saved port reaches the SSH relay');
	}
# Connect requires both POST and a valid token.
for my $case ( [ $fields, { method => 'GET' } ],
	       [ { %$fields, token => 'wrong' }, { method => 'POST' } ] ) {
	$result = render($case->[0], undef, $case->[1]);
	like($result->{'error'},
	     qr/Use the Connect button|Invalid token/,
	     'unsigned or GET connection refused');
	ok(!grep({ $_->[0] eq 'connect' } @{$result->{'calls'}}),
	   'invalid request starts no relay');
	}
# A stopped guest retains the status subscription that can reopen the SSH form.
$result =
	render({ }, undef,
	       { vm => { %$guest, active => 0, state => 'shutoff',
			 addresses => [ ] } });
ok(grep({ $_->[0] eq 'status' &&
	($_->[1] || '') eq 'terminal' } @{$result->{'calls'}}),
   'stopped SSH page keeps its reconnect status');

# Automatic connections still submit the signed form and stop after a failure.
unlink(terminal_login_file($uuid));
$result = render({ tab => 'ssh' });
unlike($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
       'automatic SSH is off by default');
my $auto = { config => { terminal_auto => 1 } };
for my $spa ( 0, 1 ) {
	$result = render({ tab => 'ssh' }, undef, { %$auto, spa => $spa });
	like($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
	     'enabled setting submits the form automatically');
	ok(!grep({ $_->[0] eq 'connect' } @{$result->{'calls'}}),
	   'automatic GET starts no relay');
	like($result->{'html'},
	     qr/<button\b(?=[^>]*name="connect")[^>]*\bhidden[\s>]/,
	     'automatic button is hidden before scripts load');
	unlike($result->{'html'},
	       qr/>SSH service<|<select|<input[^>]*type="text"/,
	       'automatic entry renders no settings or status card');
	like($result->{'html'},
	     qr/<div\b(?=[^>]*id="terminal")[^>]*data-cloudmin-console="ssh-loading"/, 'automatic entry reserves the terminal screen');
	unlike($result->{'html'},
	       qr/<div\b[^>]*data-cloudmin-console="ssh"|var xterm_argv =/,
	       'loading screen cannot start a terminal renderer');
	like($result->{'html'},
	     qr/<header>.*data-terminal-status.*>Connection settings</s,
	     'startup shows progress and keeps manual settings reachable');
	$clicked = submit_fields($result->{'html'}, 'connect');
	is_deeply($clicked, { id => $uuid, %$fields },
		  'hidden form submits the complete signed connection request');
	}
# Open terminals include the attempt token and a link to settings.
for my $spa ( 0, 1 ) {
	$result =
		render({ %$clicked, username => 'alternate' }, undef,
		       { %$auto, method => 'POST', spa => $spa });
	like($result->{'html'}, qr/terminal-connect\.js/,
	     'both renderers watch login completion');
	like($result->{'html'}, qr/terminal-status\.cgi\?id=.*attempt=aaaaaaaa/,
	     'status is bound to the current attempt');
	like($result->{'html'}, qr/>Connection settings</,
	     'open terminal retains settings link');
	}
# An abandoned pending attempt must not start another automatic connection.
$result = render({ tab => 'ssh' }, undef, $auto);
unlike($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
       'unfinished login prevents automatic retries');
like($result->{'html'}, qr/name="username"[^>]*value="alternate"/,
     'form remembers the account used');
like($result->{'html'}, qr/data-vm-field="ssh"[^>]*>Checking \.\.<\/span>/,
     'unfinished login shows only Checking before the first status update');
save_terminal_login($uuid, 'a' x 32, 'failed');
for my $spa ( 0, 1 ) {
	$result = render({ tab => 'ssh' }, undef, { %$auto, spa => $spa });
	unlike($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
	       'failed login keeps the form');
	like($result->{'html'},
	     qr/class="[^"]*\bui_list_desc"[^>]*><span\b[^>]*data-vm-field="ssh"[^>]*>Checking \.\.<\/span>\s*<\/div>/,
	     'failed login shows only Checking before the first status update');
	like($result->{'html'},
	     qr/data-vm-message="The previous SSH connection did not complete\.[^"]*"/,
	     'live updates receive the guidance to preserve');
	unlike($result->{'html'},
	       qr/<[^>]*class=["'][^"']*\b(?:ui_alert|alert-warning)\b/,
	       'failed login has no separate alert box');
	}
save_terminal_login($uuid, 'a' x 32, 'connected');
# Login success resumes automatic entry; settings links still open the form.
$result = render({ tab => 'ssh' }, undef, $auto);
like($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
     'successful login resumes automatic connection');
$result = render({ tab => 'ssh', ssh_settings => 1 }, undef, $auto);
unlike($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
       'settings link always opens the form');
unlike($result->{'html'},
       qr/<button\b(?=[^>]*name="connect")[^>]*\bhidden[\s>]/,
       'manual settings remain visible');
# A previous failure link still opens settings, but cannot
# revive a cleared error.
for my $spa ( 0, 1 ) {
	$result =
		render({ tab => 'ssh', ssh_failed => 1 }, undef,
		       { %$auto, spa => $spa });
	like($result->{'html'}, qr/name="username"/,
	     'old failure link leaves the form available');
	unlike($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
	       'old failure link does not start another connection');
	unlike($result->{'html'}, qr/data-vm-message=/,
	       'successful login clears guidance even on an old failure URL');
	}
# Launch errors stay escaped in status metadata until the readiness check ends.
$result =
	render($fields, undef,
	       { %$auto, method => 'POST',
		 terminal_error => '<fixture> launch failed' });
is($result->{'error'}, '', 'launch error renders the editable page');
like($result->{'html'}, qr/data-vm-message="&lt;fixture&gt; launch failed/,
     'launch error remains escaped for the completed status update');
unlike($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
       'launch failure cannot loop');
unlike($result->{'html'},
       qr/<button\b(?=[^>]*name="connect")[^>]*\bhidden[\s>]/,
       'failed startup leaves the retry form visible');
$result = render({ tab => 'ssh' }, undef, $auto);
unlike($result->{'html'}, qr/id="cloudmin-ssh-auto"/,
       'launch failure remains blocked on next visit');
# Outcome requests enforce the same grant and expose no login fields.
$result = render({ attempt => 'a' x 32 }, undef, { status => 1 });
like($result->{'html'}, qr/"state"\s*:\s*"failed"/,
     'status endpoint returns failure for the current attempt');
unlike($result->{'html'}, qr/username|password|192\.0\.2/,
       'status contains no connection fields');
$result = render({ attempt => 'b' x 32 }, undef, { status => 1 });
like($result->{'html'}, qr/"state"\s*:\s*"gone"/,
     'status for an older attempt cannot affect the current page');
$result = render({ attempt => 'a' x 32 }, { console => 1 }, { status => 1 });
like($result->{'html'}, qr/Cloudmin permissions/,
     'status denies users without terminal permission');
unlike($result->{'html'}, qr/"state"/, 'denied status exposes no outcome');
$result = render({ attempt => 'a' x 32 }, undef, { status => 1,
						   readonly => 1 });
like($result->{'html'}, qr/read-only/, 'status respects read-only mode');

# Tab memory follows the Webmin user and never grants access to a saved tab.
my $tab_file =
	"$module_var_directory/remote-access-tab-".urlize($remote_user);
for my $spa ( 0, 1 ) {
	unlink($tab_file);
	# First visits use SSH; later visits reuse this user's allowed tab.
	$result = render({ }, undef, { spa => $spa });
	like($result->{'html'}, qr/SSH service/,
	     'first visit still defaults to SSH');
	render({ tab => 'serial' }, undef, { spa => $spa });
	$result =
		render({ }, undef, { spa => $spa,
				     config => { terminal_auto => 1 } });
	like($result->{'html'}, qr/data-console-mode="serial"/,
	     'last tab reopens with no explicit setting');
	is_deeply($result->{'calls'}, [ [ 'adapter', 0 ], [ 'lookup', $uuid,
							    1 ] ],
		  'remembered Serial avoids SSH discovery and startup');
	is((stat($tab_file))[2] & 0777, 0600, 'saved tab remains private');
	# Explicit tab and legacy mode links both take precedence over memory.
	$result = render({ tab => 'graphical' }, undef, { spa => $spa });
	like($result->{'html'}, qr/data-console-mode="graphical"/,
	     'explicit tab overrides the remembered choice');
	$result = render({ mode => 'serial' }, undef, { spa => $spa });
	like($result->{'html'}, qr/data-console-mode="serial"/,
	     'legacy mode also overrides the remembered choice');
	# Tab memory follows the user across guests without
	# affecting other users.
	$result = render({ }, undef, { spa => $spa, user => 'another-user' });
	like($result->{'html'}, qr/SSH service/,
	     'another user starts with their own default');
	$result = render({ }, undef, { spa => $spa });
	like($result->{'html'}, qr/data-console-mode="serial"/,
	     'another user does not change the saved tab');
	$result = render({ }, undef, { spa => $spa, vm => { %$guest,
							    uuid => 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' } });
	like($result->{'html'}, qr/data-console-mode="serial"/,
	     'the user keeps their tab across virtual machines');
	# Disabled memory neither restores nor replaces the saved choice.
	render({ tab => 'graphical' }, undef,
	       { spa => $spa, config => { remote_access_remember => 0 } });
	$result =
		render({ }, undef,
		       { spa => $spa,
			 config => { remote_access_remember => 0 } });
	like($result->{'html'}, qr/SSH service/,
	     'disabled memory opens SSH first');
	$result =
		render({ }, undef,
		       { spa => $spa,
			 config => { remote_access_remember => 1 } });
	like($result->{'html'}, qr/data-console-mode="serial"/,
	     'disabled visits leave the previous choice alone');
	# Missing devices and revoked grants both select an available tab.
	$result =
		render({ }, undef,
		       { spa => $spa, vm => { %$guest,
					      serial_console => undef } });
	like($result->{'html'}, qr/data-console-mode="graphical"/,
	     'missing serial port falls back to Graphical');
	$result = render({ }, { terminal => 1 }, { spa => $spa });
	like($result->{'html'}, qr/SSH service/,
	     'revoked console access falls back to SSH');
	is($result->{'error'}, '',
	   'stale permissions do not block Remote Access');
	# Remembering Webmin must not bypass its connection warning.
	render({ tab => 'webmin' }, { terminal => 1, webmin => 1 },
	       { spa => $spa });
	$result = render({ }, { terminal => 1, webmin => 1 }, { spa => $spa });
	like($result->{'html'}, qr/name="connect_webmin"/,
	     'remembered Webmin still shows its connection choices');
	unlike($result->{'html'}, qr/<iframe/,
	       'tab memory does not authorize the embedded proxy');
	$result = render({ }, { terminal => 1 }, { spa => $spa });
	like($result->{'html'}, qr/SSH service/,
	     'revoked Webmin access falls back to SSH');
	# Rejected navigation cannot change the user's valid saved choice.
	render({ tab => 'serial' }, undef, { spa => $spa });
	render({ tab => 'ssh' }, undef, { spa => $spa, readonly => 1 });
	render({ tab => 'webmin' }, { terminal => 1 }, { spa => $spa });
	render({ tab => 'invalid' }, undef, { spa => $spa });
	$result = render({ }, undef, { spa => $spa });
	like($result->{'html'}, qr/data-console-mode="serial"/,
	     'denied and invalid requests leave tab memory unchanged');
	# A damaged preference is ignored before selecting any backend.
	write_file($tab_file, { tab => 'invalid' });
	$result = render({ }, undef, { spa => $spa });
	like($result->{'html'}, qr/SSH service/,
	     'invalid stored tab falls back to SSH');
	}
# Optional tab memory cannot prevent viewing a tab or starting a signed session.
for my $spa ( 0, 1 ) {
	for my $failure (qw(lock lock_return write)) {
		# A different saved tab forces each request to try writing.
		write_file($tab_file, { tab => 'serial' });
		$result =
			render({ tab => 'ssh' }, undef,
			       { spa => $spa, tab_error => $failure });
		is($result->{'error'}, '',
		   "$failure failure leaves Remote Access usable");
		like($result->{'html'}, qr/name="username"/,
		     'selected SSH form still renders');
		like($result->{'html'},
		     qr/Could not remember the selected tab:/,
		     'tab failure shows a warning');
		unlike($result->{'html'}, qr/<fixture>/,
		       'warning escapes the error detail');
		ok(!-e "$tab_file.lock",
		   'failed save leaves no preference lock');
		my %saved;
		read_file($tab_file, \%saved);
		is($saved{'tab'}, 'serial',
		   'failure before writing retains the saved tab');
		is(scalar(grep { $_->[0] eq 'save_tab' } @{$result->{'calls'}}),
		   $failure eq 'write' ? 1 : 0,
		   'preference writes require a lock');
		}
	# Failed tab memory must not block a terminal that has already started.
	$result =
		render($fields, undef,
		       { method => 'POST', spa => $spa, tab_error => 'write' });
	is($result->{'error'}, '',
	   'preference failure does not abort a signed connection');
	like($result->{'html'}, qr/data-cloudmin-console="ssh"/,
	     'started terminal still renders');
	is(scalar(grep { $_->[0] eq 'connect' } @{$result->{'calls'}}), 1,
	   'one SSH relay starts');
	# The next successful save clears the warning without a separate reset.
	$result = render({ tab => 'ssh' }, undef, { spa => $spa });
	unlike($result->{'html'}, qr/Could not remember the selected tab:/,
	       'warning clears when saving works');
	}
done_testing();
