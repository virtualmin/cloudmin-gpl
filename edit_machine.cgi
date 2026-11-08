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
	if (defined($in{'delete_disk'}) ||
	    ($in{'action'} || '') eq 'delete_disk');
error_setup($text{'vm_control_error'})
	if (($in{'action'} || '') =~ /\A(?:start|shutdown)\z/);
# Return successful saves to the selected editor tab.
my $tab = $in{'vm_edit_tabs'} || 'resources';
$tab = 'resources' if ($tab !~ /\A(?:resources|disks|interfaces|access)\z/);
# Old password links now open the Access tab, including delegated sessions.
$tab = 'access' if ($in{'password_reset'} || !can_access('host'));
# Read-only sessions may view Access but cannot submit or review changes.
error($text{'vm_manage_readonly'}) if (is_readonly_mode() &&
				       ($tab ne 'access' || $in{'password_reset'} || $in{'action'} ||
					$in{'delete'} ||
					defined($in{'delete_disk'}) || $in{'shutdown_requested'}));
# Password submissions use the reset API without applying hardware fields.
if (($in{'action'} || '') eq 'reset_password') {
	error_setup($text{'vm_password_reset_error'});
	my $result = eval {
		die "Use POST for virtual machine changes\n"
			if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
		# A listed account overrides the hidden manual field;
		# Other keeps its value.
		$in{'username'} = $in{'password_username'}
			if (length($in{'password_username'} // ''));
		call_vm_api(1, 'reset_password', \%in);
		};
	error(error_html(error_message($@))) if (!$result);
	# Drop the submitted password from navigation and
	# prevent a refresh replay.
	redirect(
		'edit_machine.cgi?id='.urlize($result->{'id'}).
		'&vm_edit_tabs=access&vm_access_tabs=password&password_saved=1');
	exit;
	}
# A password grant does not permit hardware, power or deletion actions.
error($text{'acl_denied'}) if (!can_access('host') &&
			       ($in{'action'} || $in{'delete'} || defined($in{'delete_disk'}) ||
				$in{'shutdown_requested'}));
# Every form uses the same controller validation as API and CLI callers.
if (($ENV{'REQUEST_METHOD'} || '') eq 'POST' && $in{'action'}) {
	my $job = eval {
		die "Unknown virtual machine management action\n" if
			(
				$in{'action'} !~ /\A(?:update|delete|delete_disk|start|shutdown)\z/);
		# One submission covers resources and every
		# selected hardware edit.
		my $result =
			call_vm_api(1, $in{'action'}, $in{'action'} eq 'update'
				? parse_vm_edit_form(\%in)
				: \%in);
		# Wait for durable edits without rendering a
		# separate progress page.
		$result = wait_vm_job($result)
			if (
				$in{'action'} =~ /\A(?:update|delete|delete_disk)\z/);
		$result;
		};
	error(error_html(error_message($@))) if (!$job);
	if ($in{'action'} eq 'start') {
		# After starting, show the guest details page with live status.
		redirect('machine.cgi?id='.urlize($job->{'id'}));
		exit;
		}
	if ($in{'action'} eq 'shutdown') {
		# Shutdown requests are asynchronous, unlike the
		# editor's durable jobs.
		redirect('edit_machine.cgi?id='.urlize($job->{'id'}).
			 '&shutdown_requested=1');
		exit;
		}
	if ($in{'action'} eq 'delete_disk') {
		# The retained guest returns to its disk list
		# after confirmed deletion.
		redirect('edit_machine.cgi?id='.urlize($job->{'uuid'}).
			 '&vm_edit_tabs=disks&vm_disk_deleted='.
			 urlize($job->{'id'}));
		exit;
		}
	# Deleted guests return to the overview; saved guests
	# stay on the same tab.
	redirect(($in{'action'} eq 'delete'
		? 'index.cgi?'
		: 'edit_machine.cgi?id='.urlize($job->{'uuid'}).
		  '&vm_edit_tabs='.$tab.'&').
		 'vm_saved='.urlize($job->{'id'}));
	exit;
	}
# Access needs only guest inventory; it must also work for password delegates.
my $access_only = !can_access('host') || is_readonly_mode();
error($text{'acl_denied'})
	if (!can_access('host') && !can_access('password', $in{'id'}));
# Read-only rendering must not open the writable token store.
my $token = is_readonly_mode()
	? ''
	: get_image_jobs()->form_token($remote_user);
my $access_vm;
# Confirmation and shutdown pages do not render guest access controls.
if (!$in{'delete'} && !defined($in{'delete_disk'}) &&
    !$in{'shutdown_requested'}) {
	$access_vm = eval { get_libvirt()->get_domain($in{'id'}, 1) };
	error(error_html($@
		? error_message($@)
		: 'Virtual machine not found')) if (!$access_vm);
	}
# Restricted sessions render Access without querying hardware edit settings.
if ($access_only) {
	ui_print_header(html_escape($access_vm->{'name'}), $text{'vm_edit'}, '',
			'machine');
	select_theme_server($access_vm);
	print ui_page_assets().vm_edit_tabs_start('access', 1).
		ui_tabs_start_tab('vm_edit_tabs',
				  'access').show_vm_access($access_vm, $token,
							   \%in).
		ui_tabs_end_tab('vm_edit_tabs', 'access').ui_tabs_end(1);
	ui_print_footer('machine.cgi?id='.urlize($access_vm->{'uuid'}),
			$text{'vm_view'});
	exit;
	}
my $settings = eval { call_vm_api(1, 'settings', \%in) };
error(error_html(error_message($@))) if (!$settings);
my $disk;
if (defined($in{'delete_disk'})) {
	# Resolve confirmation from the current attachment, never a client path.
	error($text{'vm_manage_stopped'}) if ($settings->{'active'});
	($disk) =
		grep { $_->{'target'} eq
			$in{'delete_disk'} } @{$settings->{'disks'}};
	error($text{'vm_delete_disk_missing'})
		if (!$disk || !$disk->{'volume_info'});
	error($text{'vm_delete_disk_imported'}) if ($disk->{'imported'});
	}
# Edit views share status badges; deletion confirmations keep their own heading.
ui_print_header(html_escape($settings->{'name'}).
		(!$disk && !$in{'delete'} ? vm_header_status($settings) : ''),
		$text{$disk
			? 'vm_delete_disk_title'
			: $in{'delete'}
				? 'vm_delete'
				: 'vm_edit'}, '', 'machine');
print_vm_change_result($in{'vm_saved'}, 'update', $settings->{'id'});
print_vm_change_result($in{'vm_disk_deleted'}, 'delete_disk',
		       $settings->{'id'});
select_theme_server($settings);
print $disk
	? show_vm_delete_disk_form($settings, $token, $disk)
	: show_vm_edit_form($settings, $token, $in{'delete'},
			    $in{'shutdown_requested'}, $tab,
			    $access_vm
				    ? show_vm_access($access_vm, $token, \%in)
				    : undef);
if ($settings->{'active'} && $in{'shutdown_requested'}) {
	# Open the editor once shutdown completes, using the shared socket.
	# Editable pages do not reload over unsaved changes.
	print ui_tag('div', '', { id => 'cloudmin-vm-status',
				  'data-config' =>
					  get_status_config($settings,
							    'edit_machine') });
	print show_status_script();
	}
elsif (!$disk && !$in{'delete'}) {
	# Refresh pending values without replacing the form or
	# losing unsaved edits.
	print ui_tag('div', '', { id => 'cloudmin-vm-status',
				  'data-config' =>
					  html_escape(get_status_config($settings)) });
	print show_status_script();
	}
# Check the previous attempt before resubmitting edits or disk operations.
print submission_script();
ui_print_footer($disk
	? ( 'edit_machine.cgi?id='.urlize($settings->{'id'}).
	    '&vm_edit_tabs=disks', $text{'vm_edit_return'} )
	: ( 'machine.cgi?id='.$settings->{'id'}, $text{'vm_view'} ));
