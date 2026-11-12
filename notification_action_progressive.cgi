#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user, $first_print, $second_print);
require './server-manager-lib.pl';

# Validate the whole signed selection before displaying names or changing data.
error('Use POST for notification actions')
	unless ($ENV{REQUEST_METHOD} || '') eq 'POST';
error('Request is too large') if ($ENV{CONTENT_LENGTH} || 0) > 32768;
ReadParse();
my $kind = $in{kind} || '';
my $delete = exists($in{delete});
my (@records, $tab);
my $ok = eval {
	# Deleting and testing need host and management access, write mode
	# and a signed token.
	require_access('host');
	require_access('manage');
	die "Notification changes are disabled in read-only mode\n"
		if is_readonly_mode();
	get_image_jobs()->check_token($remote_user, $in{token});
	# Accept exactly one operation, with sending limited to destinations.
	die "Invalid notification action\n" unless
		$kind =~ /\A(?:rule|target)\z/ &&
		$delete != exists($in{send}) && ($delete || $kind eq 'target');
	$tab = $kind.'s';
	# Limit batch size after removing duplicate selections.
	my @ids = unique(grep { length } split(/[\0,]+/, $in{object} || ''));
	die "$text{'notifications_select_'.$tab}\n" unless @ids;
	die "Select at most 100 items\n" if @ids > 100;
	die "Invalid notification selection\n"
		if grep { !/\A[a-f0-9]{32}\z/ } @ids;
	# Reject missing records before starting any part of a batch.
	my $cfg = call_notification_api('notification_config', { });
	my %saved = map { $_->{id} => $_ } @{$cfg->{$tab}};
	die "Notification not found. Refresh the list and try again.\n"
		if grep { !$saved{$_} } @ids;
	@records = @saved{@ids};
	1;
	};
error(html_escape(error_message($@))) unless $ok;
# Row actions name one record. Requests for several use plural wording.
my $singular = @records == 1;
my $suffix = $singular ? $kind : $tab;
my $title = $text{$delete
	? 'notifications_delete_'.$suffix : 'notifications_test_'.$suffix};

if ($delete && !$in{confirm}) {
	# Use the standard confirmation page for the selected records.
	ui_print_header(undef, $title, '');
	print ui_confirmation_form('notification_action_progressive.cgi',
		$text{'notifications_confirm_'.$suffix},
		[ [ token => $in{token} ], [ kind => $kind ], [ delete => 1 ],
		  [ object => join(',', map { $_->{id} } @records) ] ],
		[ [ confirm => $singular ? $text{delete}
					: $text{notifications_delete_selected} ] ],
		join(', ', map {
			ui_tag('tt', html_escape(notification_bytes($_->{name}))) } @records));
	}
else {
	# Stream a start and an actual result for every selected item.
	ui_print_unbuffered_header(undef, $title, '');
	for my $record (@records) {
		$first_print->(text($delete
			? 'notifications_deleting_'.$kind
			: 'notifications_testing_target',
			ui_tag('tt', html_escape(notification_bytes($record->{name})))));
		# Isolate each attempt so one failure does
		# not abort later records.
		my $done = eval {
			my $result = call_notification_api($delete
				? 'delete_notification_'.$kind
				: 'test_notification_target',
				{ token => $in{token}, object => $record->{id},
				  immediate => 1 });
			die $result->{error} if $result->{error};
			1;
			};
		if ($done) {
			# Report only completed deletions or accepted messages.
			$second_print->($text{images_progress_done});
			}
		else {
			# Continue the selection after a failure.
			my $error = error_message($@);
			$error =~ s/\s+/ /g;
			$error =~ s/^\s+|\s+$//g;
			$second_print->(text('images_progress_failed',
				html_escape(lcfirst($error))));
			}
		}
	}
# Return to the list this action came from.
ui_print_footer('notifications.cgi?tab='.$tab,
	$text{'notifications_return_'.$tab});
