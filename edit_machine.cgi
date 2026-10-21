#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user, $module_root_directory);
require './server-manager-lib.pl';
# Check VM assignments below for users with password-reset permission.
error($text{'acl_denied'}) if (!can_access('host') &&
	!access_policy()->{'grants'}->{'password'});
require "$module_root_directory/cloudmin-status-lib.pl";
error_setup($text{'vm_edit_err'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
# Name the submitted action before displaying its validation error.
error_setup($text{'vm_delete_err'})
	if ($in{'delete'} || ($in{'action'} || '') eq 'delete');
error_setup($text{'vm_delete_disk_err'})
	if (defined($in{'delete_disk'}) || ($in{'action'} || '') eq 'delete_disk');
error_setup($text{'vm_control_error'})
	if (($in{'action'} || '') =~ /\A(?:start|shutdown)\z/);
# Return successful saves to the selected editor tab.
my $tab = $in{'vm_edit_tabs'} || 'resources';
$tab = 'resources' if ($tab !~ /\A(?:resources|disks|interfaces)\z/);
error($text{'vm_manage_readonly'}) if (is_readonly_mode());
# The reset form opens even for stopped guests; submission checks readiness.
# Delegates also land here when following an editor link without an action.
if ($in{'password_reset'} || ($in{'action'} || '') eq 'reset_password' ||
	(!can_access('host') && !$in{'action'})) {
	error_setup($text{'vm_password_reset_error'});
	# Check the guest assignment before reading inventory or accepting a reset.
	error($text{'acl_denied'}) if (!can_access('password', $in{'id'}));
	if ($in{'action'}) {
		# Accept only reset POSTs, using the API's ACL and token checks.
		my $result = eval {
			die "Use POST for virtual machine changes\n"
				if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
			die "Unknown password reset action\n" if ($in{'action'} ne 'reset_password');
			call_vm_api(1, 'reset_password', \%in);
			};
		# Report failure before sending any success redirect.
		error(error_html(error_message($@))) if (!$result);
		# Redirect without the password so refreshing cannot repeat the reset.
		redirect('edit_machine.cgi?id='.urlize($result->{'id'}).
			'&password_reset=1&password_saved=1');
		exit;
		}
	# Basic inventory is enough to render the form, even without a guest agent.
	my $vm = eval { get_libvirt()->get_domain($in{'id'}, 1) };
	error(error_html($@ ? error_message($@) : 'Virtual machine not found')) if (!$vm);
	ui_print_header(html_escape($vm->{'name'}), $text{'vm_password_reset'}, '', 'machine');
	select_theme_server($vm);
	# Show confirmation after the successful POST redirects back to this form.
	print ui_alert_box($text{'vm_password_reset_done'}, 'success', undef, undef, '')
		if ($in{'password_saved'});
	print show_vm_password_reset_form($vm, get_image_jobs()->form_token($remote_user));
	# Delegates return to details because the hardware editor is host-only.
	ui_print_footer(can_access('host')
		? ('edit_machine.cgi?id='.urlize($vm->{'uuid'}), $text{'vm_edit_return'})
		: ('machine.cgi?id='.urlize($vm->{'uuid'}), $text{'vm_view'}));
	exit;
	}
# A password grant never permits hardware editing, deletion or power actions.
error($text{'acl_denied'}) if (!can_access('host'));
# Every form uses the same controller validation as API and CLI callers.
if (($ENV{'REQUEST_METHOD'} || '') eq 'POST' && $in{'action'}) {
	my $job = eval {
		die "Unknown virtual machine management action\n" if
			($in{'action'} !~ /\A(?:update|delete|delete_disk|start|shutdown)\z/);
		# One submission covers resources and every selected hardware edit.
		my $result = call_vm_api(1, $in{'action'}, $in{'action'} eq 'update'
			? parse_vm_edit_form(\%in) : \%in);
		# Wait for durable edits without rendering a separate progress page.
		$result = wait_vm_job($result)
			if ($in{'action'} =~ /\A(?:update|delete|delete_disk)\z/);
		$result;
		};
	error(error_html(error_message($@))) if (!$job);
	if ($in{'action'} eq 'start') {
		# After starting, show the guest details page with live status.
		redirect('machine.cgi?id='.urlize($job->{'id'}));
		exit;
		}
	if ($in{'action'} eq 'shutdown') {
		# Shutdown requests are asynchronous, unlike the editor's durable jobs.
		redirect('edit_machine.cgi?id='.urlize($job->{'id'}).
			'&shutdown_requested=1');
		exit;
		}
	if ($in{'action'} eq 'delete_disk') {
		# The retained guest returns to its disk list after confirmed deletion.
		redirect('edit_machine.cgi?id='.urlize($job->{'uuid'}).
			'&vm_edit_tabs=disks&vm_disk_deleted='.urlize($job->{'id'}));
		exit;
		}
	# Deleted guests return to the overview; saved guests stay on the same tab.
	redirect(($in{'action'} eq 'delete' ? 'index.cgi?'
		: 'edit_machine.cgi?id='.urlize($job->{'uuid'}).'&vm_edit_tabs='.$tab.'&').
		'vm_saved='.urlize($job->{'id'}));
	exit;
	}
my $settings = eval { call_vm_api(1, 'settings', \%in) };
error(error_html(error_message($@))) if (!$settings);
my $disk;
if (defined($in{'delete_disk'})) {
	# Resolve confirmation from the current attachment, never a client path.
	error($text{'vm_manage_stopped'}) if ($settings->{'active'});
	($disk) = grep { $_->{'target'} eq $in{'delete_disk'} } @{$settings->{'disks'}};
	error($text{'vm_delete_disk_missing'}) if (!$disk || !$disk->{'volume_info'});
	error($text{'vm_delete_disk_imported'}) if ($disk->{'imported'});
	}
my $token = get_image_jobs()->form_token($remote_user);
# Edit views share status badges; deletion confirmations keep their own heading.
ui_print_header(html_escape($settings->{'name'}).
	(!$disk && !$in{'delete'} ? vm_header_status($settings) : ''),
	$text{$disk ? 'vm_delete_disk_title' : $in{'delete'} ? 'vm_delete' : 'vm_edit'}, '', 'machine');
print_vm_change_result($in{'vm_saved'}, 'update', $settings->{'id'});
print_vm_change_result($in{'vm_disk_deleted'}, 'delete_disk', $settings->{'id'});
select_theme_server($settings);
print $disk ? show_vm_delete_disk_form($settings, $token, $disk)
	: show_vm_edit_form($settings, $token, $in{'delete'},
		$in{'shutdown_requested'}, $tab);
if ($settings->{'active'} && $in{'shutdown_requested'}) {
	# Open the editor once shutdown completes, using the shared socket.
	# Editable pages do not reload over unsaved changes.
	print ui_tag('div', '', { id => 'cloudmin-vm-status',
		'data-config' => get_status_config($settings, 'edit_machine') });
	print show_status_script();
	}
elsif (!$disk && !$in{'delete'}) {
	# Refresh pending values without replacing the form or losing unsaved edits.
	print ui_tag('div', '', { id => 'cloudmin-vm-status',
		'data-config' => html_escape(get_status_config($settings)) });
	print show_status_script();
	}
# Check the previous attempt before resubmitting edits or disk operations.
print submission_script();
ui_print_footer($disk
	? ('edit_machine.cgi?id='.urlize($settings->{'id'}).'&vm_edit_tabs=disks', $text{'vm_edit_return'})
	: ('machine.cgi?id='.$settings->{'id'}, $text{'vm_view'}));
