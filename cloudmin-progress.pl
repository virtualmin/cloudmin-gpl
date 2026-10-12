use strict;
use warnings;
our (%in, %text, $first_print, $second_print, $progress_callback_url);

# submit_machine(operation)
# Validates a create, clone or capture form and streams its job.
sub submit_machine
{
my ($operation) = @_;
error_setup($text{$operation eq 'capture_image' ? 'vm_image_error' : $operation eq 'clone' ? 'vm_clone_error' : 'vm_create_err'});
my $created = eval {
	# Validate the submission route before passing its fields to the controller.
	die "Use POST for virtual machine changes\n"
		if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	die "Unknown virtual machine form action\n"
		if (($in{'vm_operation'} || '') ne $operation);
	delete($in{'vm_operation'});
	# Normalize clone checkboxes and ignore an unchecked separate hostname.
	if ($operation eq 'clone') {
		$in{'hostname'} = '' if (!$in{'hostname_set'});
		$in{$_} = $in{$_} ? 1 : 0 for qw(confirm_license confirm_unchanged);
		}
	call_vm_api(1, $operation, \%in);
	};
my $error = error_message($@);
# Discard submitted secrets before rendering either an error or progress.
delete(@in{qw(password password_again password_hash virtualmin_serial virtualmin_key)});
if (!$created) {
	# Escape backend text and add the known recovery links.
	my $html = error_html($error);
	$html =~ s{(\. Open )Host Overview( and use Restore Network Rules)(?=\s*\z)}
		{$1.ui_link('index.cgi', html_escape($text{'left_overview'})).$2}e;
	error($html);
}
# Poll only the job ID; submitted credentials are no longer needed.
show_machine_progress({job => $created->{'id'}});
}

# show_machine_progress(input, [embedded]) streams the job named by input.job.
# Optional input.from and input.vm_edit_tabs select validated return links.
# embedded omits the page header and footer for a list of backup jobs.
sub show_machine_progress
{
local %in = %{$_[0]};
my $embedded = $_[1];
my $job = eval { call_vm_api(1, 'status', \%in) };
error(error_html(error_message($@))) if (!$job);
# Recover interrupted jobs from their journals before polling status.
recover_vm_jobs();
# Show the selected image and software beside the name on creation progress.
my @subtitle = ($job->{'name'}, $job->{'operation'} eq 'create'
	? @{$job}{qw(image_name software_name)} : ());
my $subtitle = join(' &middot; ', map { html_escape($_) }
	grep { defined($_) && length($_) } @subtitle);
ui_print_unbuffered_header($subtitle, $text{$job->{'operation'} eq 'create'
	? 'vm_progress_title' : $job->{'operation'} eq 'clone'
	? 'vm_clone_progress' : $job->{'operation'} eq 'capture_image' ? 'vm_image_title' : $job->{'operation'} =~ /^snapshot_/
	? 'snapshots_progress' : $job->{'operation'} eq 'backup' ? 'backup_title' :
	$job->{'operation'} eq 'backup_inspect' ? 'restore_inspect' : $job->{'operation'} eq 'restore' ? 'restore_title' : 'vm_manage_progress'}, '') if (!$embedded);
my (%started, %finished, %transfer_total);
my $failures = 0;
# Allow source download and guest setup to outlast ordinary disk creation.
my $deadline = time() + 11800;
while (1) {
	# A transient job-store error must not abort the streamed page mid-way.
	my $current = eval { call_vm_api(1, 'status', \%in) };
	if (!$current) {
		# Retry briefly, then report a status error without marking the job failed.
		if (++$failures >= 3 || time() >= $deadline) {
			print ui_alert_box(text('vm_progress_unavailable',
				html_escape(error_message($@))), 'warn',
				undef, undef, '');
			last;
			}
		sleep(1);
		next;
		}
	$failures = 0;
	$job = $current;
	foreach my $i (0..$#{$job->{'events'}}) {
		my $event = $job->{'events'}->[$i];
		next if ($finished{$i});
		my $download = $event->{'step'} eq 'image' ? $job->{'image_progress'} : undef;
		if (!$started{$i}) {
			# Replay each recorded start once, even after
			# reconnecting to a fast job.
			my $label = $text{'vm_phase_'.$event->{'step'}};
			$label = $text{'vm_phase_start_stopped'}
				if ($event->{'step'} eq 'start' &&
				!$job->{'start'});
			if ($download && !$download->{'cached'} && ($download->{'total'} || $download->{'bytes'})) {
				# Use Webmin's transfer progress output when
				# byte counters exist.
				$progress_callback_url = $download->{'name'};
				$transfer_total{$i} = $download->{'total'} || 0;
				progress_callback(2, $transfer_total{$i});
				}
			elsif ($event->{'step'} eq 'image' && $event->{'state'} eq 'running' && !($download || {})->{'cached'}) {
				# Wait for transfer counters so the native download line can open.
				next;
				}
			# Cached images and non-transfer phases use the normal
			# step label.
			else { $first_print->(html_escape($label)); }
			$started{$i} = 1;
			}
		# Update an open transfer line without replaying its start
		# message.
		if (exists($transfer_total{$i}) && $download && $download->{'bytes'}) {
			# An underestimated total must not produce percentages above 100%.
			# Unknown totals stay in Webmin's byte-only mode for this transfer.
			my $bytes = $download->{'bytes'};
			$bytes = $transfer_total{$i} if ($transfer_total{$i} && $bytes > $transfer_total{$i});
			progress_callback(3, $bytes);
		}
		if ($event->{'state'} eq 'done') {
			# Pair a completed phase with its original start
			# message.
			$second_print->($text{'images_progress_done'});
			$finished{$i} = 1;
			}
		elsif ($event->{'state'} eq 'failed') {
			# Show the stored failure on its phase and do not replay
			# it again.
			$second_print->(text('images_progress_failed',
				html_escape(lcfirst($job->{'error'}))));
			$finished{$i} = 1;
			}
		elsif ($event->{'state'} eq 'cancelled') {
			# Cancellation ends the phase without claiming installation succeeded.
			$second_print->(html_escape($job->{'error'} || $text{'jobs_state_cancelled'}));
			$finished{$i} = 1;
			}
		}
	if ($job->{'state'} =~ /\A(?:complete|failed|cancelled)\z/) {
		# A failure can precede the first phase or happen between completed phases.
		$second_print->(text('images_progress_failed',
			html_escape(lcfirst($job->{'error'}))))
			if ($job->{'error'} && !grep { $_->{'state'} =~ /\A(?:failed|cancelled)\z/ } @{$job->{'events'}});
		last;
		}
	if (time() >= $deadline) {
		# Stop holding the browser connection without cancelling the
		# durable job.
		$second_print->($text{'vm_progress_pending'});
		last;
		}
	sleep(1);
	}
# Batch callers own the surrounding page and its navigation links.
return $job if ($embedded);
# Captures return to reusable images, without adding a VM to navigation.
if ($job->{'operation'} eq 'capture_image') {
	ui_print_footer('images.cgi', $text{'images_return'}, 'jobs.cgi', $text{'jobs_return'});
	return $job;
}
# Inspection leads to confirmation; it has not created or changed a guest.
if ($job->{'operation'} eq 'backup_inspect' && $job->{'state'} eq 'complete') {
	print ui_link('restore_form.cgi?inspection='.$job->{'id'}, $text{'restore_review_link'});
	ui_print_footer('backups.cgi', $text{'backups_return'});
	return $job;
}
# A completed backup returns to archives without changing guest navigation.
if ($job->{'operation'} eq 'backup' && $job->{'state'} eq 'complete') {
	ui_print_footer('backups.cgi', $text{'backups_return'});
	return $job;
}
if ($job->{'state'} eq 'complete') {
	# Show the administration link when the public job reports Virtualmin.
	print ui_alert_box(ui_link($job->{'software_url'}, $text{'vm_software_open'}),
		'success', undef, undef, '') if ($job->{'software_url'});
	# Refresh guest navigation after creation, editing or removal.
	notify_theme_save($job, $job->{'operation'} eq 'delete' ? 'delete'
		: $job->{'operation'} =~ /\A(?:create|clone|restore)\z/ ? 'create' : 'modify');
	# A completed operation remains successful when its audit log failed.
	print ui_alert_box(html_escape($job->{'cleanup_warning'}), 'warn',
		undef, undef, '') if ($job->{'cleanup_warning'});
	print ui_alert_box(html_escape($job->{'audit_warning'}), 'warn',
		undef, undef, '') if ($job->{'audit_warning'});
	# A successful installation can still need a Webmin registration retry.
	print ui_alert_box(html_escape($job->{'webmin_warning'}), 'warn',
		undef, undef, '') if ($job->{'webmin_warning'});
	if ($job->{'operation'} eq 'delete') {
		# The deleted guest no longer has a details page.
		ui_print_footer('index.cgi', $text{'vm_return'});
		}
	else {
		# Continue editing after a saved change, or inspect the finished VM.
		my @links = ('machine.cgi?id='.$job->{'uuid'}, $text{'vm_view'});
		my $edit_url = 'edit_machine.cgi?id='.$job->{'uuid'};
		$edit_url .= '&vm_edit_tabs='.$in{'vm_edit_tabs'}
			if (($in{'vm_edit_tabs'} || '') =~
				/\A(?:resources|disks|interfaces)\z/);
		if ($job->{'operation'} =~ /^snapshot_/) {
			# Return direct inventory actions to the host-wide snapshot list.
			unshift(@links, ($in{'from'} || '') eq 'all'
				? ('snapshots.cgi', $text{'snapshots_all_return'})
				: ('snapshots.cgi?id='.$job->{'uuid'}, $text{'snapshots_return'}));
			}
		elsif ($job->{'operation'} !~ /\A(?:create|clone|restore)\z/ && !is_readonly_mode()) {
			# Only writers can return to the guest editor after an edit.
			unshift(@links, $edit_url, $text{'vm_edit_return'});
			}
		ui_print_footer(@links,
			'index.cgi', $text{'vm_return'});
		}
	}
else {
	# Running jobs and pending cleanup remain accessible through the jobs
	# page.
	ui_print_footer(($job->{'vm_created'} ? ('machine.cgi?id='.$job->{'uuid'}, $text{'vm_view'}) : ()),
		'jobs.cgi', $text{'index_jobs_return'}, 'index.cgi',
		$text{'vm_return'});
	}
}

1;
