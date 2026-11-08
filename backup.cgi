#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user, $first_print, $second_print, $indent_print,
     $outdent_print);
require './server-manager-lib.pl';
require './cloudmin-backup-pages.pl';
# Bound form parsing and require host access before exposing backup settings.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'backup_error'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
require './cloudmin-progress.pl';
error('Use POST to start a backup')
	if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
my (@jobs, @errors);
# Check write permission and parse the selection before submitting jobs.
my $ok = eval {
	die "Backup changes are disabled in read-only mode\n"
		if (is_readonly_mode());
	get_image_jobs()->check_token($remote_user, $in{'token'});
	my @guests = $in{'all'}
		? map { $_->{'uuid'} } @{get_libvirt()->list_domains(1)}
		: split(/[\s\0,]+/, $in{'guests'} || '');
	die "Select one or more virtual machines\n" if (!@guests);
	my $target = parse_backup_target(\%in, 'dest0');
	# Each guest gets a stable attempt ID; one failure must
	# not hide other jobs.
	foreach my $uuid (@guests) {
		my $job =
			eval { call_vm_api(1, 'backup',
					   { %in, id => $uuid,
					     target => $target,
					     attempt => substr(Digest::SHA::sha256_hex(($in{'attempt'} || '').':'.$uuid), 0, 32) }) };
		# Keep successful submissions and report per-guest
		# failures alongside them.
		if ($job) {
			push(@jobs, $job);
			}
		else {
			push(@errors, error_message($@));
			}
		}
	1;
	};
error(error_html(error_message($@))) if (!$ok);
# If no job was accepted, use error() before streaming to allow Back.
error(join('<br>', map { error_html($_) } unique(@errors)))
	if (!@jobs && @errors);
# Workers share the disk-work lock; stream the submitted jobs one at a time.
ui_print_unbuffered_header(undef, $text{'backup_title'}, '');
print ui_alert_box(error_html($_), 'danger') for @errors;
foreach my $job (@jobs) {
	$first_print->(text('backup_progress_system',
			    '<tt>'.html_escape($job->{'name'}).'</tt>'));
	$indent_print->();
	my $result = show_machine_progress({ job => $job->{'id'} }, 1);
	$outdent_print->();
	if ($result->{'state'} eq 'complete') {
		# Report the whole backup only after all its
		# phases have completed.
		$second_print->($text{'images_progress_done'});
		}
	elsif ($result->{'state'} =~ /\A(?:failed|cancelled)\z/) {
		# The indented progress already contains the error details.
		$second_print->($text{'images_progress_failed_summary'});
		}
	else {
		# A lost status connection or polling deadline
		# does not fail the job.
		$second_print->($text{'vm_progress_pending'});
		}
	}
ui_print_footer('backups.cgi', $text{'backups_return'}, 'jobs.cgi',
		$text{'index_jobs_return'});
