#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
require './cloudmin-status-lib.pl';
error_setup($text{'vm_view_err'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 8192);
ReadParse();
# Reject foreign VM IDs before actions or detail lookup can reach libvirt.
error($text{'acl_denied'}) if (!can_access('view', $in{'id'}));
# Power links use the same permission, token and
# current-state checks as the API.
if ($in{'action'}) {
	error_setup($text{'vm_control_error'});
	my $result = eval {
		die "Use POST for virtual machine changes\n"
			if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
		die "Unknown virtual machine action\n"
			if (
				$in{'action'} !~ /\A(?:start|shutdown|reboot|suspend|resume|reset|force_off|power_cycle)\z/);
		my $job = call_vm_api(1, $in{'action'}, \%in);
		# A power cycle is a worker job; other power
		# actions return immediately.
		$in{'action'} eq 'power_cycle' ? wait_vm_job($job, 180) : $job;
		};
	error(error_html(error_message($@))) if (!$result);
	# A redirect keeps refreshes from repeating the request
	# and stays in this view.
	my $return_to = $in{'action'} =~ /\A(?:force_off|power_cycle)\z/ &&
			($in{'return'} || '') eq 'edit_machine'
				? 'edit_machine'
				: 'machine';
	redirect($return_to.'.cgi?id='.
		 urlize($in{'action'} eq 'power_cycle'
			 ? $result->{'uuid'}
			 : $result->{'id'}).
		 '&vm_action='.urlize($in{'action'}));
	exit;
	}
# Render inventory promptly; the live status request discovers addresses later.
my $vm = eval { get_libvirt()->get_domain($in{'id'}, 1) };
error(error_html($vm
	? ''
	: $@ ? error_message($@) : 'Virtual machine not found')) if (!$vm);
# The confirmation makes no change, but requires the
# separate forced-power grant.
if ($in{'force_off'} || $in{'reset'}) {
	error($text{'vm_manage_readonly'}) if (is_readonly_mode());
	error($text{'acl_denied'}) if (!can_access('force', $vm->{'uuid'}));
	error($text{'vm_control_stopped'}) if (!$vm->{'active'});
	ui_print_header(html_escape($vm->{'name'}), $text{$in{'reset'}
		? 'vm_control_reset_button'
		: 'vm_control_force_off_button'}, '', 'machine');
	select_theme_server($vm);
	print show_vm_force_off_form($vm,
				     get_image_jobs()->form_token($remote_user),
				     $in{'return'},
				     $in{'reset'} ? 'reset' : 'force_off');
	# Cancelling emergency power-off keeps the editor's
	# pending shutdown view.
	ui_print_footer(($in{'return'} || '') eq 'edit_machine'
		? ( 'edit_machine.cgi?id='.urlize($vm->{'uuid'}).
		    ($in{'force_off'} && !$in{'reset'}
			    ? '&shutdown_requested=1'
			    : ''),
		    $text{'vm_edit_return'} )
		: ( 'machine.cgi?id='.urlize($vm->{'uuid'}),
		    $text{'vm_view'} ));
	exit;
	}
# Issue tokens only for power controls; token failures must not hide VM details.
my $token = eval { get_image_jobs()->form_token($remote_user) }
	if (can_access('power', $vm->{'uuid'}) ||
	    can_access('force', $vm->{'uuid'}));
ui_print_header(html_escape($vm->{'name'}).vm_header_status($vm),
		$text{'vm_details'}, '', 'machine');
select_theme_server($vm);
# Report request acceptance while live status follows the actual power state.
if (($in{'vm_action'} ||
     '') =~ /\A(?:start|shutdown|reboot|suspend|resume|reset|force_off)\z/) {
	print ui_tag('div',
		     ui_alert_box(text('vm_control_'.$in{'vm_action'}.'_sent',
				       '<tt>'.html_escape($vm->{'name'}).'</tt>'), 'info',
				  undef, undef, ''),
		     { 'data-vm-action-notice' => $in{'vm_action'},
		       'data-vm-action-id' => $vm->{'uuid'},
		       # A successful start can already be
		       # confirmed by this fresh read.
		       ($in{'vm_action'} eq 'start' && $vm->{'active'} &&
			$vm->{'state'} =~ /\A(?:running|blocked)\z/
				? ( hidden => undef )
				: ()) });
	}
print show_vm_details(
	$vm, $token,
	($in{'vm_action'} || '') eq 'shutdown' && $vm->{'active'}).
	show_status_script();
# Check previous attempts before resubmitting background guest actions.
print submission_script();
ui_print_footer();
