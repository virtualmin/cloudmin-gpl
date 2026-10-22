#!/usr/local/bin/perl

use strict;
use warnings;
our (%in, %text, $progress_callback_url, $first_print, $second_print,
     $indent_print, $outdent_print);
require './server-manager-lib.pl';
# Host access is required to start imports or reconnect to their progress.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'images_progress_err'});

# New imports require POST; existing jobs can reconnect through either method.
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
# Navigation may POST a progress link while the import form is still visible.
# A POST carrying an image source always takes the token-checked creation path.
my $start = ($ENV{'REQUEST_METHOD'} || '') eq 'POST' &&
	(!$in{'job'} || exists($in{'install_type'}));
# Explain the requested action before displaying its validation error.
my $error_key = $start
	? ($in{'install_type'} || '') =~ /\A(?:download|url)\z/
		? 'images_download_err' : 'images_import_err'
	: 'images_progress_err';
error_setup($text{$error_key});
my $jobs = get_image_jobs();
my @ids;
my $ok = eval {
	if ($start) {
		# The import API validates the source, write access and signed
		# form token.
		my $records = start_image_imports(\%in);
		@ids = map { $_->{'id'} } @$records;
		}
	else {
		# Reconnection accepts only a bounded list of existing job
		# identifiers.
		@ids = split(/,/, $in{'job'} || '');
		die "$text{'images_enone'}\n" if (!@ids || @ids > 16);
		$jobs->get($_) for @ids;
		}
	1;
	};
error(error_html("$@")) if (!$ok);

# Stream progress as each job advances.
ui_print_unbuffered_header(undef, $text{'images_progress_title'}, '');
foreach my $id (@ids) {
	my (%started, %done, $last_phase, $download, $group_started);
	my $result = $text{'images_progress_pending'};
	my $deadline = time() + 3700;
	while (1) {
		my $job = $jobs->get($id);
		# Name each batch member before nesting its download and import
		# steps.
		if (@ids > 1 && !$group_started) {
			$first_print->(text('images_progress_image', '<tt>'.html_escape($job->{'name'}).'</tt>'));
			$indent_print->();
			$group_started = 1;
			}
		my $s = get_image_job_status($job);
		my $state = $s->{'state'};
		my %phases = (downloading => 1, copying => 1, uploading => 1,
			verifying => 2, importing => 3, ready => 4);
		# Failed jobs retain their last phase so a missed poll cannot
		# make a checksum or storage failure look like a failed
		# download.
		my $phase = $phases{$state} ||
			$phases{$job->{'failure_state'} || $job->{'state'}} ||
			$last_phase || 0;
		$last_phase = $phase;
		$download ||= ($job->{'source'} ||
			'') =~ /^(?:download|url)$/ ||
			$state eq 'downloading';

		# Replay completed phases for fast jobs and later members of a
		# batch. Only download counters go through Webmin's HTTP
		# progress callback.
		foreach my $step (1..3) {
			next if ($step > $phase || $done{$step});
			if (!$started{$step}) {
				# Emit each phase heading once, including phases
				# completed before polling.
				if ($step == 1 && $download) {
					# Wait for size data before starting
					# Webmin's download counter.
					my $total = $job->{'total'} ||
						($phase > 1 ? $job->{'bytes'}
						: 0);
					next if (!$total && !$job->{'bytes'} &&
						!$s->{'terminal'});
					$progress_callback_url = $job->{'name'};
					progress_callback(2, $total);
					}
				elsif ($step == 1) {
					# A local copy or completed browser
					# upload needs an image name, but must
					# not be described as a download.
					my $key = ($job->{'source'} ||
						'') eq 'upload'
						? 'images_progress_upload'
						: 'images_progress_copy';
					$first_print->(text($key,
						'<tt>'.html_escape($job->{'name'}).'</tt>'));
					}
				else {
					# Status labels also appear in tables;
					# add dots only here.
					$first_print->(html_escape($step == 2
						? describe_image_check($job).' ..'
						: $text{'images_progress_import'}));
					}
				$started{$step} = 1;
				}
			if ($step == 1 && $download && $job->{'bytes'}) {
				# Only the acquisition phase reports downloaded
				# bytes.
				progress_callback(3, $job->{'bytes'});
				}
			# A later phase proves this step completed successfully.
			# Never print success for the phase that failed or was
			# interrupted.
			if ($phase > $step) {
				if ($step == 1 && $download) {
					# Keep download results consistent with
					# the other steps.
					$second_print->(text('progress_done'));
					}
				else {
					# Non-download phases use the shared
					# completion wording.
					$second_print->($text{'images_progress_done'});
					}
				$done{$step} = 1;
				}
			}
		# Only a completed import can mark the enclosing image step as
		# done.
		if ($state eq 'ready') {
			$result = $text{'images_progress_done'};
			last;
			}
		if ($s->{'terminal'}) {
			# Failed, interrupted and deleted jobs close the image
			# block as failures.
			$first_print->('<tt>'.html_escape($job->{'name'}).'</tt>'.' ..')
				if (!%started);
			my $detail = $state eq 'deleted'
				? $text{'images_job_deleted'} : $s->{'detail'};
			$second_print->(text('images_progress_failed',
				html_escape(lcfirst($detail))));
			$result = $text{'images_progress_failed_summary'};
			last;
			}
		if ($state eq 'waiting') {
			# The browser has not sent its raw upload yet, so there
			# is nothing to poll.
			$first_print->('<tt>'.html_escape($job->{'name'}).'</tt>'.': '.
				html_escape($s->{'label'}).' ..');
			$result = html_escape($s->{'label'});
			last;
			}
		if (time() >= $deadline) {
			# The background import continues after this streaming
			# response ends.
			$second_print->(html_escape($text{'images_progress_pending'}));
			last;
			}
		sleep(1);
		}
	# Close the nested details before reporting this image's overall result.
	if ($group_started) {
		$outdent_print->();
		$second_print->($result);
		}
	}
ui_print_footer('images.cgi', $text{'images_return'});
