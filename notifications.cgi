#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text);
require './server-manager-lib.pl';
require './cloudmin-notification-pages.pl';
# Check the requested scope before reading settings or generating controls.
error('Request is too large') if ($ENV{CONTENT_LENGTH} || 0) > 8192;
ReadParse();
my $tab = $in{tab} || 'history';
error('Invalid notification page')
	unless $tab =~ /\A(?:history|rules|targets)\z/;
my ($vm, $data);
my $ok = eval {
	# A one-event read checks access for this scope and reports its mute.
	$data = call_notification_api('notifications', { id => $in{id}, limit => 1 });
	if (defined($in{id}) && $in{id} ne 'host') {
		# Keep guest navigation and the footer scoped to this VM.
		die "Guest notifications only have history\n"
			if $tab ne 'history';
		$vm = get_libvirt()->get_domain($in{id}, 1) ||
			die "Virtual machine not found\n";
		}
	1;
	};
error(html_escape(error_message($@))) unless $ok;
# The mute control is a plain header link that themes can style, as on
# Remote Access and Apache.
my ($mute_link, $mute_form) = show_notification_mute($in{id}, $data);
# Use the authorized scope for the title, theme selection and return link.
# Omit the module index link and show the mute link on the right.
ui_print_header(html_escape($vm ? $vm->{name} : get_system_hostname()),
	$text{$vm ? 'notifications_guest_title' : 'notifications_title'},
	'', 'notifications', 0, 1, 0, $mute_link);
select_theme_server($vm) if $vm;
# Print the signed form in the body. Its noscript button works without JS.
print $mute_form;
my $html = eval { show_notifications($tab, $in{id}, $in{target}) };
error(html_escape(error_message($@))) unless defined($html);
print $html;
# Guest pages return to the machine. Host pages return to the overview.
ui_print_footer($vm
	? ( 'machine.cgi?id='.urlize($vm->{uuid}), $text{vm_view} )
	: ( 'index.cgi', $text{vm_return} ));
