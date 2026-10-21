#!/usr/local/bin/perl

use strict;
use warnings;
our (%in, %text, $remote_user, $first_print, $second_print);
require './server-manager-lib.pl';
# Reject delegated users before reading deletion selections or image jobs.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'images_delete_err'});

# Confirm bulk deletion before entering the streaming progress view.
error($text{'images_delete_epost'}) if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
error($text{'image_ereadonly'}) if (is_readonly_mode());
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
my $jobs = get_image_jobs();
my @ids = unique(grep { length } split(/[\0,]+/, $in{'job'} || ''));
my @records;
eval {
	# Refuse unlicensed changes before looking up images or opening confirmation.
	$jobs->check_token($remote_user, $in{'token'});
	require_access('manage');
	die "$text{'images_enone'}\n" if (!@ids || @ids > 100);
	@records = map { $jobs->get($_) } @ids;
	};
error(error_html("$@")) if ($@);
if (!$in{'confirm'}) {
	# A cached selection may still contain images deleted by an earlier
	# request.
	my @deleted = grep { $_->{'state'} eq 'deleted' } @records;
	error(text('images_delete_estale', join(', ',
		map { '<tt>'.html_escape($_->{'name'}).'</tt>' } @deleted))) if (@deleted);
	ui_print_header(undef, $text{'images_delete_selected'}, '');
	print ui_confirmation_form('delete_images.cgi',
		$text{'images_delete_confirm'},
		[ [ 'token', $in{'token'} ], [ 'job', join(',', @ids) ] ],
		[ [ 'confirm', $text{'images_delete_button'} ] ],
		ui_text_color(join(', ', map { '<tt>'.html_escape($_->{'name'}).'</tt>' }
			@records), 'danger'));
	ui_print_footer('images.cgi', $text{'images_return'});
	exit;
	}

# Request cancellation for the whole selection before waiting for any worker.
ui_print_unbuffered_header(undef, $text{'images_delete_selected'}, '');
my %cancel_errors;
foreach my $job (@records) {
	# Keep remove() idempotent for worker cleanup, but do not report a stale
	# browser resubmission as another successful deletion.
	if ($job->{'state'} eq 'deleted') {
		$cancel_errors{$job->{'id'}} = $text{'images_delete_edeleted'};
		next;
		}
	eval { $jobs->cancel($job->{'id'}) };
	$cancel_errors{$job->{'id'}} = "$@" if ($@);
	}

# Keep each image's start and result together while workers finish cleanup.
my $deadline = time() + 90;
foreach my $job (@records) {
	$first_print->(text('images_delete_doing',
		'<tt>'.html_escape($job->{'name'}).'</tt>'));
	my $error = $cancel_errors{$job->{'id'}};
	my $removed;
	while (!$error) {
		$removed = eval { $jobs->remove($job->{'id'}) };
		$error = "$@" if ($@);
		last if ($error || $removed || time() >= $deadline);
		sleep(1);
		}
	if ($removed) {
		# Report success only after the volume and staging cleanup have
		# completed.
		$second_print->($text{'images_progress_done'});
		}
	else {
		# A timeout leaves cancellation in progress; it is not a
		# deletion.
		$error ||= $text{'images_delete_timeout'};
		# Inline failure reasons use one line with a lowercase opening.
		$error =~ s/\s+/ /g;
		$error =~ s/^\s+|\s+$//g;
		$second_print->(text('images_progress_failed',
			html_escape(lcfirst($error))));
		}
	}
ui_print_footer('images.cgi', $text{'images_return'});
