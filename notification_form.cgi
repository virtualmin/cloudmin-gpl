#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text);
require './server-manager-lib.pl';
require './cloudmin-notification-pages.pl';
# Bound the request and accept only the two editor kinds.
error('Request is too large') if ($ENV{CONTENT_LENGTH} || 0) > 8192;
ReadParse();
my $kind = $in{kind} || '';
error('Invalid notification form') unless $kind =~ /\A(?:target|rule)\z/;
# Editors require the same host and write grants as their save actions.
my $ok = eval {
	require_access('host');
	require_access('manage');
	die "Notification changes are disabled in read-only mode\n"
		if is_readonly_mode();
	1;
	};
error(html_escape(error_message($@))) unless $ok;
# Render only after authorization, with a return link to the matching list.
ui_print_header(undef, $text{'notifications_'.
	($in{object} ? 'edit_' : 'create_').$kind}, '', 'notifications');
my $html = eval { show_notification_form($kind, $in{object}) };
error(html_escape(error_message($@))) unless defined($html);
print $html;
ui_print_footer('notifications.cgi?tab='.$kind.'s',
	$text{'notifications_return_'.$kind.'s'});
