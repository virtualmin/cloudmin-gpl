#!/usr/local/bin/perl

use strict;
use warnings;

our (%in, %text, %module_info, $remote_user);

# Initialize Webmin and load the dashboard functions under the user's ACL.
require './server-manager-lib.pl';
require './cloudmin-status-lib.pl';

error_setup($text{'vm_control_error'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 8192);
ReadParse();
# Network recovery has host-only permissions and its own
# token-checked controller.
if (($in{'action'} || '') eq 'restore_network_rules') {
	error_setup($text{'check_network_restore_error'});
	my $ok = eval {
		require './cloudmin-network-lib.pl';
		change_network('restore_rules', \%in);
		1;
		};
	error(error_html(error_message($@))) if (!$ok);
	redirect('index.cgi?network_rules_restored=1');
	exit;
	}
# Lifecycle requests share the API's permission and token checks.
if ($in{'action'}) {
	my $ok = eval {
		# Merely following a URL must not change a guest's power state.
		die "Use POST for virtual machine changes\n"
			if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
		# Other controller actions belong to their dedicated pages.
		die "Unknown virtual machine action\n"
			if (
				$in{'action'} !~ /\A(?:start|shutdown|reboot|suspend|resume|autostart)\z/);
		call_vm_api(1, $in{'action'}, \%in);
		1;
		};
	error(error_html(error_message($@))) if (!$ok);
	# Redirect so refreshing the inventory cannot repeat a power action. The
	# boot toggle displays its saved state without a success message.
	redirect($in{'action'} eq 'autostart'
		? 'index.cgi'
		: 'index.cgi?vm_action='.urlize($in{'action'}).'&id='.
		 urlize($in{'id'}));
	exit;
	}
# Recover existing jobs without preventing inventory when the job store fails.
eval { recover_vm_jobs(); };
my $dashboard = get_dashboard();
# Replace the overview subtext with the collected libvirt version.
my $version = $dashboard->{'host'}->{'libvirt_version'};
ui_print_header(
	$version ? text('index_subtitle', html_escape($version)) : undef,
	$text{'left_overview'},
	'',
	'intro',
	1,
	1,
);
# Refresh the menu after a collection switch, once headers are sent.
notify_theme_save({ }, 'modify') if ($in{'refresh'});
print_vm_change_result($in{'vm_saved'}, 'delete');
# The recovery handler redirects here only after its verification succeeds.
print ui_alert_box($text{'check_network_restored'}, 'success', undef, undef, '')
	if ($in{'network_rules_restored'});

# Issue tokens only for permitted overview controls. Keep inventory visible if
# the token store fails. Force-only users get their controls on VM detail pages.
$dashboard->{'token'} = eval { get_image_jobs()->form_token($remote_user) }
	if (can_access('manage') ||
	    (!is_readonly_mode() &&
	     access_policy()->{'grants'}->{'power'}));
# Power requests are asynchronous; report acceptance rather than completion.
if (($in{'vm_action'} ||
     '') =~ /\A(?:start|shutdown|reboot|suspend|resume)\z/) {
	my ($vm) = grep { $_->{'uuid'} eq ($in{'id'} || '') }
		   @{$dashboard->{'servers'}};
	print ui_alert_box(text('vm_control_'.$in{'vm_action'}.'_sent',
				'<tt>'.html_escape($vm->{'name'}).'</tt>'),
			   'info',
			   undef, undef,
			   '') if ($vm);
	}
$dashboard->{'live'} = 1;
# Load widget CSS and JavaScript before building row templates. Otherwise their
# tags go into JSON and load only on the first live update.
print ui_page_assets();
# The page builder attaches configuration to its existing container.
$dashboard->{'status_config'} =
	get_overview_status_config($dashboard->{'token'});
print show_dashboard_page($dashboard).show_status_script();

ui_print_footer('/', $text{'index_title'});
