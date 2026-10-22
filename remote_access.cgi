#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, %config, $remote_user, $module_root_directory,
     $module_var_directory);
require './server-manager-lib.pl';
require './cloudmin-console-lib.pl';
require './cloudmin-status-lib.pl';
require './cloudmin-webmin-lib.pl';
error_setup($text{'console_error'});
# Connection forms contain only a guest ID and small connection settings.
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 8192);
ReadParse();
# Read-only mode overrides every interactive access method.
error($text{'console_readonly'}) if (is_readonly_mode());
# Each tab retains its own grant, checked before guest or key lookups.
my @tabs = grep { can_access($_ eq 'ssh' ? 'terminal' : 'console', $in{'id'}) }
	qw(ssh serial graphical);
push(@tabs, 'webmin') if (can_vm_webmin($in{'id'}));
# Remember navigation per Webmin user, without storing connection settings.
my $remember_tab = ($config{'remote_access_remember'} // 1) eq '1';
my $tab_file = "$module_var_directory/remote-access-tab-".urlize($remote_user);
my %tab_preference;
read_file($tab_file, \%tab_preference) if ($remember_tab && @tabs);
# Explicit links take precedence; a saved choice cannot restore revoked access.
my $saved_tab = $tab_preference{'tab'} || '';
$saved_tab = '' if (!grep { $_ eq $saved_tab } @tabs);
my $tab = $in{'tab'} || $in{'mode'} || $saved_tab || $tabs[0] || 'ssh';
# Reject unknown or ungranted tabs before opening libvirt or reading guest keys.
error('Invalid console tab') if ($tab !~ /\A(?:ssh|serial|graphical|webmin)\z/);
error($text{'acl_denied'}) if (!grep { $_ eq $tab } @tabs);
error_setup($text{$tab eq 'ssh' ? 'terminal_error' : 'console_error'});
# Network access needs guest addresses; hypervisor consoles do not.
my $network_tab = $tab eq 'ssh' || $tab eq 'webmin';
my $vm = eval { get_libvirt($network_tab ? 1 : 0)->
	get_domain($in{'id'}, $network_tab ? 0 : 1) };
# Stop if the guest lookup fails.
error(error_html($@ || 'Virtual machine not found')) if (!$vm);
# Console-only users can still open a guest without a serial port.
$tab = 'graphical' if (!$in{'tab'} && !$in{'mode'} && $tab eq 'serial' &&
	!$vm->{'serial_console'});
my $mode = $tab;
# Keep normal theme navigation on tab links and SSH form submissions.
my $navigation = $in{'xnavigation'} ? '&xnavigation=1' : '';
my $unavailable = !foreign_check('xterm');
my @addresses = $tab eq 'ssh' ? list_terminal_addresses($vm) : ();
my ($socket, $port, $attempt, $terminal_error);
my $ssh_login = $tab eq 'ssh' ? get_terminal_login($vm->{'uuid'}) : {};
# Auto-connect requires a usable guest and no pending or failed login.
# Explicit settings and failed-login links always retain the editable form.
my $ssh_auto = $tab eq 'ssh' && !$unavailable && @addresses &&
	$vm->{'state'} =~ /\A(?:running|blocked)\z/ &&
	($config{'terminal_auto'} || '') eq '1' &&
	!$in{'ssh_settings'} && !$in{'ssh_failed'} && !$in{'connect'} &&
	(!$ssh_login->{'state'} || $ssh_login->{'state'} eq 'connected');
# Existing installations and failed registrations use the same signed action.
if ($tab eq 'webmin' && $in{'register_webmin'}) {
	my $ok = eval {
		require_webmin_registration();
		# Require an explicit POST with a valid token.
		die "Use the Open embedded Webmin button to configure access\n"
			if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
		get_image_jobs()->check_token($remote_user, $in{'token'});
		# Require a finished creation for this guest, with no rollback
		# pending.
		my $job = get_vm_jobs()->get($vm->{'cloudmin'}->{'job'});
		die "Wait for virtual machine setup to finish\n" if (
			!$job || ($job->{'state'} || '') !~ /\A(?:complete|failed|cancelled)\z/ ||
			$job->{'cleanup_pending'} || $job->{'request'}->{'uuid'} ne $vm->{'uuid'});
		# Refuse registration while another job holds the guest reservation.
		get_vm_jobs()->assert_guest_available($vm->{'uuid'});
		register_vm_webmin($job);
		# A successful retry also resolves the warning on the progress page.
		get_vm_jobs()->update($job->{'id'}, sub { delete($_[0]->{'webmin_warning'}); });
		1;
		};
	# Permission and registration failures must be escaped before display.
	error(error_html(error_message($@))) if (!$ok);
	}
# A navigation POST displays the form; only a signed Connect submission starts
# SSH.
if ($tab eq 'ssh' && $in{'connect'}) {
	# Reject unsigned requests before starting SSH or saving form settings.
	my $signed = eval {
		die "Use the Connect button to start SSH\n"
			if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
		get_image_jobs()->check_token($remote_user, $in{'token'});
		1;
		};
	error(error_html(error_message($@))) if (!$signed);
	my $ok = eval {
		# Do not start a relay when Webmin cannot render its terminal.
		die "$text{'terminal_unavailable'}\n" if ($unavailable);
		# Validate the current guest address before starting SSH.
		($socket, $port, $attempt) =
			start_terminal(parse_terminal_request($vm, \%in));
		1;
		};
	# Keep the editable form available after a setup or validation failure.
	$terminal_error = error_message($@) if (!$ok);
	}
my $spa = get_current_theme_info_cached()->{'spa'};
my $extra_head = '';
# Inline the small console stylesheet so the loading surface paints with the
# page, even when later client assets or the guest connection are slow.
my $console_styles = ui_tag('style', read_file_contents(
	"$module_root_directory/console.css"));
# Load xterm assets with the document for an active full-page terminal.
# SPA navigation initializes it later from the embedded configuration.
if ($socket && !$spa) {
	my $path = get_webprefix().'/xterm';
	my $version = get_webmin_version();
	$extra_head = ui_tag('link', undef,
		{ rel => 'stylesheet', href => "$path/xterm.css?$version" });
	$extra_head .= join('',
		map { ui_tag('script', '', { src => "$path/$_.js?$version" }) }
		qw(xterm xterm-addon-attach xterm-addon-fit));
	$extra_head .= ui_tag('link', undef, { rel => 'stylesheet',
		href => get_webprefix().'/server-manager/terminal.css?'.
		(stat('terminal.css'))[9] });
	}
# Show connection progress during automatic submission and relay startup.
my $ssh_status = $socket || $ssh_auto ? ui_tag('span',
	ui_badge($text{'console_connecting'}, 'info',
	{ rounded => 1, dot => 1, small => 1 }),
	{ class => 'ui_page', 'data-console-status' => 1,
	  'data-terminal-status' => 1, role => 'status' }) : '';
# Resolve Webmin access before the header so themes place its links themselves.
my ($webmin_url, $webmin_error, $webmin_direct, $webmin_register, $header_links);
my $ssh_form_url = 'remote_access.cgi?id='.urlize($vm->{'uuid'}).
	'&tab=ssh&ssh_settings=1'.$navigation;
if ($socket || $ssh_auto) {
	# Keep the form reachable even when automatic connection is enabled.
	$header_links = ui_tag('a', html_escape($text{'terminal_settings'}),
		{href => $ssh_form_url, 'data-terminal-action' => 'settings'});
	}
my %webmin_change;
my $webmin_requested = $in{'connect_webmin'} || $in{'accept_webmin_address'} || $in{'register_webmin'};
# Only an explicit configuration choice skips the initial connection page.
my $webmin_auto = ($config{'webmin_confirm'} // 1) eq '0';
if ($tab eq 'webmin') {
	# Direct access never starts the proxy or updates its saved destination.
	$webmin_direct = eval { vm_webmin_direct_url($vm) };
	$webmin_error = $@;
	if (!$webmin_error) {
		# Resolve proxy details only after the shared access checks pass.
		my $url = eval {
			# Explicit actions require POST even when automatic opening is enabled.
			if ($webmin_requested) {
				die "Use the confirmation button to open embedded Webmin\n"
					if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
				get_image_jobs()->check_token($remote_user, $in{'token'});
				}
			my $approval;
			if ($in{'accept_webmin_address'}) {
				# Accept only the displayed address pair from the signed POST.
				$approval = {old => $in{'webmin_old_ip'}, new => $in{'webmin_new_ip'}};
				}
			my $target = vm_webmin_url($vm, \%webmin_change, $approval);
			if (!$target && !%webmin_change) {
				# Offer registration with the same button when the caller may add it.
				$webmin_register = eval { require_webmin_registration(); 1 };
				die $@ if (!$webmin_register && $webmin_requested);
				}
			$target;
			};
		$webmin_error = $@;
		# Automatic opening still stops for changed addresses or missing entries.
		$webmin_url = $url if ($webmin_requested || $webmin_auto);
		}
	if ($webmin_url) {
		# Keep fullscreen ahead of the separate-window link in every theme.
		$header_links = ui_tag('a', html_escape($text{'console_fullscreen'}),
			{ href => '#', 'data-webmin-action' => 'fullscreen',
			  # Legacy frames cannot request fullscreen from their own document.
			  onclick => 'const view = document.fullscreenEnabled ? document.querySelector(".cloudmin-webmin-view") : window.frameElement; '.
				'if (view?.requestFullscreen) { const doc = view.ownerDocument; '.
				'if (doc.fullscreenElement) { doc.exitFullscreen(); } else { view.requestFullscreen().catch(() => {}); } } return false;' }).'<br>'.
			ui_tag('a', html_escape($text{'webmin_new_tab'}),
			{ href => $webmin_direct,
			  target => '_blank', rel => 'noopener noreferrer',
			  'data-webmin-action' => 'new-tab' });
		}
	}
# Save only an allowed, resolved tab after request validation has finished.
my $tab_warning;
if ($remember_tab && ($tab_preference{'tab'} || '') ne $tab) {
	my $locked;
	my $ok = eval {
		local $main::error_must_die = 1;
		# Navigation preferences do not belong in file-change or undo logs.
		$locked = lock_file($tab_file, 0, 0, 1);
		# Do not write when this request failed to acquire its own lock.
		die "Cannot lock saved Remote Access tab: $!\n" if (!$locked);
		write_file($tab_file, {tab => $tab});
		chmod(0600, $tab_file) || die "Cannot protect saved Remote Access tab: $!\n";
		1;
		};
	my $error = $@;
	# A failed lock acquisition must not release another caller's lock.
	unlock_file($tab_file) if ($locked);
	# A failed preference must not block the selected tab or an active terminal.
	$tab_warning = text('console_tab_save_failed',
		html_escape(error_message($error))) if (!$ok);
	}
ui_print_header(html_escape($vm->{'name'}).vm_header_status($vm, 1).$ssh_status,
	$text{'console_title'}, '', 'remote_access', 0, 1, 0, $header_links, $extra_head);
select_theme_server($vm);
print show_vm_pending_styles();
print $console_styles;
# Distinguish SSH, the serial port, the guest display and Webmin with small,
# decorative icons. The adjacent text supplies each link's accessible name.
my %tab_icons = (
	ssh => 'M1.8 3h12.4v10H1.8z M4.5 6.3L7 8.4l-2.5 2.1 M8.5 10.7h3',
	serial => 'M2.5 4h11l1 1.5-1.5 6h-10L1.5 5.5z M5 6.5h.01 M8 6.5h.01 M11 6.5h.01 M6.5 9h.01 M9.5 9h.01',
	graphical => 'M1.5 2.5h13v9h-13z M8 11.5v2 M5 13.5h6',
);
# Let Webmin and the active theme render the tab strip and selected panel.
my @console_tabs = map {
	my $url = 'remote_access.cgi?id='.urlize($vm->{'uuid'}).'&tab='.$_.$navigation;
	# Every tab uses an inline SVG so theme sizing and alignment apply equally.
	my $icon = $_ eq 'webmin' ?
		read_file_contents("$module_root_directory/images/webmin.svg") :
		ui_tag('svg', ui_tag('path', '', { d => $tab_icons{$_} }),
		{ class => 'ui_svg_icon', width => 18, height => 18,
		  viewBox => '0 0 16 16', fill => 'none', stroke => 'currentColor',
		  'stroke-width' => 1.5, 'stroke-linecap' => 'round',
		  'stroke-linejoin' => 'round', 'aria-hidden' => 'true' });
	[$_, ui_tag('span', $icon.ui_tag('span', $text{'console_'.$_}), {
		class => 'vm-console-tab-label', 'data-console-tab-url' => $url }), $url]
	} @tabs;
print ui_tabs_start(\@console_tabs, 'cloudmin_console_tabs', $tab).
	ui_tabs_start_tab('cloudmin_console_tabs', $tab);
# Optional tab memory may fail without replacing the requested page.
print ui_alert($tab_warning, 'warning', [undef, '', 1]) if ($tab_warning);
# SSH uses guest networking and its own form, relay and terminal renderer.
if ($tab eq 'ssh') {
	# Show the terminal after Connect starts its SSH relay.
	if ($socket) {
		# Use the same terminal configuration contract as Webmin and Podman.
		my %xterm = foreign_config('xterm');
		# Include the current user's Xterm preference and its shared palettes.
		load_module_preferences('xterm', \%xterm);
		foreign_require('xterm');
		my $terminal_options = xterm::get_terminal_options($xterm{'theme'});
		# Auto needs both palettes so a theme change can update the live terminal.
		my $terminal_themes = {
			dark => xterm::get_terminal_options('dark'),
			light => xterm::get_terminal_options('light'),
			} if (($xterm{'theme'} || '') eq 'auto');
		my $terminal_theme_script = xterm::get_terminal_theme_script($xterm{'theme'});
		my $terminal_background = $terminal_options->{'theme'}->{'background'};
		my $terminal_foreground = $terminal_options->{'theme'}->{'foreground'};
		my $version = get_webmin_version();
		# Give both clients the same labels, settings and asset URLs.
		my $data = { status => { map { $_ => $text{'console_'.$_} }
			qw(connecting connected disconnected failed) }, socket_url => $socket, port => $port, cols => 80,
			rows => 24,
			failed => $text{'terminal_failed'},
			disconnected => $text{'terminal_disconnected'},
			options => $terminal_options, themes => $terminal_themes,
			conf => \%xterm, uinfo => [], files => {
				css => [ "xterm.css?$version" ],
				js => [ map { "$_.js?$version" }
					qw(xterm xterm-addon-attach xterm-addon-fit
					   xterm-addon-webgl) ] } };
		# Apply the initial palette before xterm loads to avoid a background flash.
		print ui_tag('div', '', { id => 'terminal', 'data-cloudmin-console' => 'ssh',
			style => "--terminal-background: $terminal_background; ".
			         "--terminal-foreground: $terminal_foreground" });
		# Only Auto needs the theme change listener.
		print $terminal_theme_script if ($terminal_theme_script);
		print '<script>var xterm_argv = '.convert_to_json($data).
			";</script>\n";
		# Observe the supervisor's login result in either terminal renderer.
		print ui_tag('a', html_escape($text{'terminal_settings'}), {
			id => 'cloudmin-ssh-attempt', hidden => undef,
			href => $ssh_form_url.'&ssh_failed=1',
			'data-status-url' => get_webprefix().'/server-manager/terminal-status.cgi?id='.
				urlize($vm->{'uuid'}).'&attempt='.urlize($attempt) });
		# Full-page themes start the terminal with the page.
		if (!$spa) {
			print ui_tag('script', '', { src => get_webprefix().
				'/server-manager/terminal.js?'.(stat('terminal.js'))[9],
				defer => undef });
			}
		}
	elsif ($unavailable) {
		# Explain the missing terminal module before offering a connection.
		print ui_alert_box($text{'terminal_unavailable'}, 'warn', undef, undef,
			'');
		}
	elsif ($vm->{'state'} !~ /\A(?:running|blocked)\z/ || !@addresses) {
		# A stopped or booting guest keeps a useful page instead of an empty
		# selector.
		print show_status_summary($vm, 'terminal');
		}
	else {
		# Show login guidance after the SSH status check finishes.
		my $paused = ($config{'terminal_auto'} || '') eq '1' &&
			($terminal_error || $ssh_login->{'state'} && $ssh_login->{'state'} ne 'connected');
		my @messages;
		if ($terminal_error || ($ssh_login->{'state'} || '') eq 'failed') {
			# Use the saved outcome; an old failure URL cannot override a later success.
			push(@messages, $terminal_error || $text{'terminal_retry'});
			}
		# Explain why an unfinished attempt pauses automatic entry.
		push(@messages, $text{'terminal_auto_paused'}) if ($paused);
		# Only manual entry needs the readiness card and retry guidance.
		print show_status_summary($vm, undef, join(' ', @messages)) if (!$ssh_auto);
		my $default_user = get_vm_form_defaults(\%config)->{'username'};
		# Prefer the account used when Cloudmin created this guest, when
		# available.
		my $job = eval { get_vm_jobs()->get($vm->{'cloudmin'}->{'job'},
			$remote_user) }
			if ($vm->{'cloudmin'}->{'job'});
		$default_user = $vm->{'cloudmin'}->{'username'} || $default_user;
		# The creation record takes precedence when it is still available.
		$default_user = $job->{'request'}->{'username'} if ($job);
		# Report unsafe or unreadable stored keys instead of ignoring them.
		my $key = eval { get_terminal_key($vm) };
		error(error_html(error_message($@))) if ($@);
		# Default to passwords if key login is unavailable or disabled.
		my $auth = $key &&
			($config{'terminal_auth'} || 'key') eq 'key' ? 'key'
			: 'password';
		# Keep submitted corrections on failure; otherwise use saved settings.
		my $settings = $in{'connect'} ? \%in : $ssh_login;
		$default_user = $settings->{'username'} if ($settings->{'username'});
		# Saved key authentication still needs an available guest key.
		$auth = $settings->{'auth'} if (($settings->{'auth'} || '') eq 'password' ||
			($key && ($settings->{'auth'} || '') eq 'key'));
		# Do not reuse an address that the guest no longer reports.
		my $address = $settings->{'address'} || '';
		$address = $addresses[0] if (!grep { $_ eq $address } @addresses);
		# Keep submitted or unfinished ports for corrections. After success,
		# use the port shared by all users of this virtual machine.
		my $ssh_port = get_terminal_port($vm->{'uuid'});
		$ssh_port = $settings->{'port'} if ($settings->{'port'} &&
			($in{'connect'} || ($ssh_login->{'state'} || '') ne 'connected'));
		print ui_tag('style',
			'form[action^="remote_access.cgi"] :is(select[name="address"], input[name="port"]) { field-sizing: content; min-width: 0; }');
		# Keep the guest and tab in the URL, including navigation refreshes.
		print ui_form_start('remote_access.cgi?id='.urlize($vm->{'uuid'}).
			'&tab=ssh'.$navigation, 'post');
		print ui_hidden('token',
			get_image_jobs()->form_token($remote_user));
		if ($ssh_auto) {
			# Submit the same defaults without briefly rendering editable controls.
			print ui_hidden('address', $address).ui_hidden('port', $ssh_port).
				ui_hidden('username', $default_user).ui_hidden('auth', $auth);
			# Reserve the terminal's space without starting its renderer yet.
			# The visible surface also lets navigation detect the form's POST method.
			print ui_tag('div', '', {id => 'terminal',
				'data-cloudmin-console' => 'ssh-loading',
				'aria-label' => $text{'console_connecting'}, 'aria-busy' => 'true'});
			}
		else {
			# Group destination and login fields in two columns.
			print ui_table_start(undef, 'width=100%', 2);
			print ui_table_row($text{'terminal_address'},
				ui_select('address', $address,
				[ map { [ $_, $_ ] } @addresses ]));
			print ui_table_row($text{'terminal_port'},
				ui_textbox('port', $ssh_port, 5));
			print ui_table_hr();
			# Hide key authentication when this guest has no managed key.
			print ui_table_row($text{'terminal_username'},
				ui_textbox('username', $default_user, 30));
			print ui_table_row($text{'vm_auth_type'}, ui_select('auth', $auth, [
				($key ? [ 'key', $text{'terminal_auth_key'} ] : ()),
				[ 'password', $text{'vm_auth_password'} ] ]));
			print ui_table_end();
			}
		# Both entry modes submit through the same named Connect button.
		print ui_action_button($text{'terminal_connect'}, 'primary',
			{type => 'submit', name => 'connect', value => 1,
			 icon => 'terminal',
			 attrs => $ssh_auto ? {hidden => undef, style => 'display:none'} : {}}).
			ui_form_end();
		if ($ssh_auto) {
			# JavaScript submits the signed form; GET never starts SSH.
			print ui_tag('span', '', {id => 'cloudmin-ssh-auto', hidden => undef});
			}
		}
	# The connection client submits automatic logins and handles failures.
	print ui_tag('script', '', {src => get_webprefix().
		'/server-manager/terminal-connect.js?'.(stat('terminal-connect.js'))[9],
		defer => undef});
	# Connection forms already subscribe through their SSH status summary.
	if ($socket || $unavailable) {
		print ui_tag('div', '', { id => 'cloudmin-vm-status',
			'data-config' => html_escape(get_status_config($vm)) }).
			show_status_script();
		}
}
elsif ($tab eq 'webmin') {
	# Render the guest only after the selected connection policy permits it.
	if ($webmin_url) {
		# A signed submission or saved preference opens the embedded view.
		print show_vm_webmin_frame($webmin_url);
		}
	else {
		# Address changes appear first, outside the connection card.
		print ui_page_start({class => 'cloudmin-webmin-notice'});
		if (%webmin_change) {
			# Show the saved and proposed destinations before requesting consent.
			print ui_alert(text('webmin_address_changed',
				html_escape($webmin_change{'old'}), html_escape($webmin_change{'new'})).
				'<br>'.html_escape($text{'webmin_address_'.$webmin_change{'source'}}),
				'warning', [undef, '', 1]);
			}
		# Place the warning below the title, as in the SSH status summary.
		my @notices = (ui_list([{ title => $text{'webmin_access_title'},
			desc => $text{'webmin_proxy_warning'} }]));
		if ($webmin_error) {
			# Errors cannot leave an iframe running or expose connection controls.
			push(@notices, ui_alert(html_escape(error_message($webmin_error)),
				'warning', [undef, '', 1]));
			}
		else {
			# Use an ordinary action row instead of the card's footer controls.
			push(@notices, show_vm_webmin_options($vm, $webmin_direct, $webmin_register,
				\%webmin_change));
			}
		print ui_card({state => 'warning',
				body => ui_stack(\@notices) }).ui_page_end();
		}
}
else {
	# Serial and graphical keep their existing clients and controls.
	my $allowed = eval { check_console($vm, $mode); 1 };
	my $waiting;
	if (!$allowed) {
		# A stopped or unsupported guest gets an explanation instead of a blank
		# screen.
		print ui_alert_box(html_escape(error_message($@)), 'warn', undef,
			undef, '');
		# A stopped guest can reopen the same tab when live status reports it ready.
		$waiting = !$vm->{'active'} && !is_readonly_mode();
		print show_status_summary($vm, $mode eq 'serial' ? 'serial' : 'console')
			if ($waiting);
		}
	else {
		# Cloudmin supplies the complete client and layout for every theme.
		my $data = { id => $vm->{'uuid'}, mode => $mode,
			token => get_image_jobs()->form_token($remote_user),
			endpoint => get_webprefix().
			'/server-manager/console-connect.cgi',
			client_version => (stat('console.js'))[9],
			map { $_ => $text{'console_'.$_} }
			qw(connecting connected disconnected failed) };
		if ($mode eq 'serial') {
			# Use Webmin's terminal palettes and preferences, without its SSH client.
			my %xterm = foreign_config('xterm');
			load_module_preferences('xterm', \%xterm);
			foreign_require('xterm');
			# Send both palettes so Auto follows theme changes without reconnecting.
			$data->{'serial_version'} = (stat('serial-console.js'))[9];
			$data->{'xterm'} = { path => get_webprefix().'/xterm',
				version => get_webmin_version(),
				conf => { map { $_ => $xterm{$_} } qw(theme fontsize screen_reader) },
				options => xterm::get_terminal_options($xterm{'theme'}),
				themes => { map { $_ => xterm::get_terminal_options($_) } qw(dark light) } };
			}
		# Both console modes use the same fullscreen button and badge.
		my $buttons = ui_tag('button', $text{'console_fullscreen'},
			{ type => 'button', 'data-console-action' => 'fullscreen' });
		if ($mode eq 'serial') {
			# Disconnect this tab's serial session while keeping its output visible.
			$buttons = ui_tag('button', $text{'console_disconnect'},
				{ type => 'button', 'data-console-action' => 'disconnect',
				  disabled => undef }).$buttons;
			}
		my $status = ui_tag('span',
			ui_badge($text{'console_connecting'}, 'info',
			{ rounded => 1, dot => 1, small => 1 }),
			{ 'data-console-status' => 1, role => 'status' });
		# Keep guest shortcuts in one compact menu, using standard keyboard
		# codes.
		my @shortcuts = (
			[ 'ControlLeft AltLeft Delete', $text{'console_ctrlaltdel'} ],
			[ 'ControlLeft AltLeft Backspace',
			  $text{'console_ctrlaltbackspace'} ],
			[ 'ControlLeft AltLeft End', $text{'console_ctrlaltend'} ],
			(map { [ "ControlLeft AltLeft F$_",
			text('console_ctrlaltfn', $_) ] } 1..12),
			[ 'AltLeft Tab', $text{'console_alttab'} ],
			[ 'AltLeft F4', $text{'console_altf4'} ],
			[ 'AltLeft Enter', $text{'console_altenter'} ],
			[ 'Escape', $text{'console_escape'} ],
			[ 'PrintScreen', $text{'console_printscreen'} ],
			[ 'Pause', $text{'console_pause'} ],
			[ 'ControlLeft Pause', $text{'console_ctrlbreak'} ],
		);
		my $items = join('', map { ui_tag('button', html_escape($_->[1]),
			{ type => 'button', 'data-console-key' => $_->[0],
			  role => 'menuitem', tabindex => -1 }) } @shortcuts);
		# Inline SVG keeps the keyboard icon independent of theme icon fonts.
		my $keyboard = ui_tag('svg', ui_tag('path', '', {
			d => 'M1 3h14v10H1z M3 5h1 M6 5h1 M9 5h1 M12 5h1 M3 8h1 M6 8h1 M9 8h1 M12 8h1 M4 11h8' }),
			{ viewBox => '0 0 16 16', width => 18, height => 18,
			  fill => 'none',
			  stroke => 'currentColor', 'stroke-width' => 1.2,
			  'aria-hidden' => 'true' });
		# Enable guest keyboard shortcuts only after VNC connects.
		my $keymenu = ui_tag('div',
			ui_tag('button',
			$keyboard.ui_svg_icon('chevron-down', { size => 10 }),
			{ type => 'button', 'data-console-action' => 'keys',
			  title => $text{'console_keys'},
			  'aria-label' => $text{'console_keys'},
			  'aria-haspopup' => 'menu', 'aria-expanded' => 'false',
			  'aria-controls' => 'cloudmin-console-keys',
			  disabled => undef }).
			ui_tag('div', $items,
			{ id => 'cloudmin-console-keys', role => 'menu',
			  'aria-label' => $text{'console_keys'},
			  hidden => undef }), { 'data-console-keyboard' => 1,
			  # Existing theme hooks expect this node even when serial hides it.
			  ($mode eq 'serial' ? (hidden => undef) : ()) });
		# Keep controls inside the console for use in fullscreen.
		print ui_page_start().ui_tag('div',
			ui_tag('div',
			$buttons.
			ui_tag('div', $status.$keymenu, { 'data-console-tools' => 1 }),
				{ 'data-console-toolbar' => 1 }).
			ui_tag('div', '', { 'data-console-screen' => 1,
				# Match a fixed terminal palette before its renderer is downloaded.
				($mode eq 'serial' ? (style =>
					'--terminal-background: '.$data->{'xterm'}->{'options'}->{'theme'}->{'background'}.'; '.
					'--terminal-foreground: '.$data->{'xterm'}->{'options'}->{'theme'}->{'foreground'}) : ()) }),
			{ id => 'cloudmin-console',
			  'data-console-mode' => $mode,
			  'data-console-config' => convert_to_json($data) }).
			ui_page_end();
		# SPA themes initialize views after navigation; full-page themes load
		# the client with the document.
		if (!get_current_theme_info_cached()->{'spa'}) {
			print ui_tag('script', '',
				{ type => 'module', src => get_webprefix().
				'/server-manager/console.js?'.
				$data->{'client_version'} });
			}
		}
	# The waiting summary already subscribes; connected consoles need only badges.
	if (!$waiting) {
		print ui_tag('div', '', { id => 'cloudmin-vm-status',
			'data-config' => html_escape(get_status_config($vm)) }).
			show_status_script();
		}
}
print ui_tabs_end_tab('cloudmin_console_tabs', $tab).(ui_tabs_end() || '');
# Each mode has a separate request and relay lifecycle. Use ordinary links
# instead of the widget's in-page panel switching.
print ui_tag('script', <<'JS');
(() => {
    document.querySelectorAll('.vm-console-tab-label').forEach(label => {
        let link = label.closest('a');
        // A selected Webmin tab must still return from the embedded view.
        if (!link && new URL(label.dataset.consoleTabUrl, location.href).searchParams.get('tab') === 'webmin') {
            link = document.createElement('a');
            label.replaceWith(link);
            link.append(label);
        }
        // Other selected tabs may remain plain text.
        if (!link) return;
        link.href = label.dataset.consoleTabUrl;
        link.removeAttribute('onclick');
        link.removeAttribute('data-toggle');
    });
})();
JS
ui_print_footer();
