# Explicit job controls submitted from Active Jobs.
use strict;
use warnings;
our ($remote_user);

# get_job_action(input) validates access, the action and the current job state.
# Filters VM records through get_public_vm_job; keeps image records internal.
sub get_job_action
{
my ($input) = @_;
require_access('host');
# Permission to read jobs does not grant permission to change them.
die "Job changes are disabled in read-only mode\n" if (is_readonly_mode());
# Restrict dispatch before opening either job store.
die "Unknown job action\n" if (($input->{'action'} || '') !~ /\A(?:cancel|cancel_cleanup|recover|discard)\z/ ||
	($input->{'type'} || '') !~ /\A(?:vm|image)\z/);
my $job;
# VM cancellation depends on the operation and whether setup has committed it.
if ($input->{'type'} eq 'vm') {
	my $saved = get_vm_jobs()->get($input->{'job'}) || die "Job not found\n";
	$job = get_public_vm_job($saved);
	$job->{'software'} = $saved->{'resources'}->{'software'} ? 1 : 0;
}
else {
	# Import removal uses its existing volume-reference and staging checks.
	die "Unknown image job action\n" if ($input->{'action'} ne 'cancel');
	$job = get_image_jobs()->get($input->{'job'});
	$job->{'can_cancel'} = 1;
}
# Finished jobs allow further actions only when cleanup is pending.
die "This job has already finished\n" if (!$job->{'cleanup_pending'} &&
	$job->{'state'} =~ /\A(?:complete|failed|cancelled|ready|deleted)\z/);
# Started hardware changes cannot use the rollback path of copy jobs.
die "This operation has started; use recovery if it fails\n"
	if ($input->{'action'} =~ /\Acancel/ && !$job->{'can_cancel'});
# Recovery and discard apply only to retained resources after a failure.
die "This job does not need recovery\n"
	if ($input->{'action'} =~ /\A(?:recover|discard)\z/ && !$job->{'cleanup_pending'});
# Only failed edits can retain disk growth and discard their remaining changes.
die "Only failed virtual machine edits can be discarded\n"
	if ($input->{'action'} eq 'discard' && $job->{'operation'} ne 'update');
# Cleanup must never turn a backup or edit cancellation into guest deletion.
die "Only creation jobs can remove their virtual machine\n"
	if ($input->{'action'} eq 'cancel_cleanup' && $job->{'operation'} ne 'create');
return $job;
}

1;
