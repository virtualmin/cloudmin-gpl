# Browser attempts share job identity without changing signed form tokens.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use WebminCore qw(convert_to_json);
our ($remote_user, $module_var_directory);

# prepare_submission(input) selects one attempt after checking saved job state.
# Failed or cancelled jobs can retry after cleanup unless the virtual machine
# was already created for software setup.

sub prepare_submission
{
my ($input) = @_;
# This only selects an attempt. The final form submission checks the license and
# reports any refusal through the page's normal error handler.
require_access('host');
die "Changes are disabled in read-only mode\n" if (is_readonly_mode());
# Signed tokens enforce ownership and expiry before reading job state.
my $result;
my $images = get_image_jobs();
$images->check_token($remote_user, $input->{'token'});
my $jobs = get_vm_jobs();
# lock(name, callback) shares the job store's cross-process lock namespace.
my $attempts =
	Cloudmin::Attempts->new(
		directory => "$module_var_directory/submissions",
		lock => sub { $jobs->lock(@_); });
if (($input->{'kind'} || '') eq 'image') {
	# Track attempts per image so batch retries keep successful imports.
	my @selected = unique(split(/[\r\n\0]+/, $input->{'selection'} || ''));
	@selected = ('') if (!@selected);
	die "Select at most 16 images\n" if (@selected > 16);
	my $previous = Cloudmin::Attempts::image_attempts($input);
	my %next;
	foreach my $selection (@selected) {
		die "Invalid image selection\n"
			if ($selection !~ /\A[a-zA-Z0-9._-]*\z/);
		$next{$selection} =
			$attempts->choose(
				"$remote_user:$input->{token}:image:$selection",
				$previous->{$selection}, $input->{'proposed'},
				sub {
					# inspect(attempt) permits a new attempt
					# after import cleanup. Unsubmitted,
					# active and successful
					# imports keep their attempt.
					my $id = substr(sha256_hex(Cloudmin::Attempts::key($input->{'token'}, $_[0]).':'.$selection), 0, 32);
					return 0 if (!-f $images->path($id,
								       'json'));
					my $job = $images->get($id,
							       $remote_user);
					return 0 if ($job->{'state'} !~ /\A(?:failed|deleted)\z/);
					# Older failures need removal
					# to confirm cleanup.
					die "The previous image import needs cleanup. Remove the failed import in Image Manager before retrying.\n"
						if ($job->{'cleanup_pending'} || $images->{'test_lock'}->($images->path($id, 'json')) ||
						    (!exists($job->{'cleanup_pending'}) && $job->{'state'} ne 'deleted'));
					return 1;
					});
		}
	$result = { image_attempts => convert_to_json(\%next) };
	# Uploads normally create jobs through AJAX. Send license refusals
	# through the ordinary form instead, where Webmin
	# renders the error page.
	$result->{'native_submit'} = 1 if (defined(&cloudmin_license_status) &&
					   !cloudmin_license_status(1)->{'allowed'});
	}
else {
	# Only background jobs need attempt IDs; ordinary power calls do not.
	my $action = $input->{'operation'} || '';
	die "Unknown submission operation\n"
		if (
			$action !~ /\A(?:create|clone|capture_image|update|delete|delete_disk|power_cycle|snapshot_create|snapshot_restore|snapshot_delete|grow_disk|add_disk|attach_disk|detach_disk|add_interface|update_interface|remove_interface|change_media)\z/);
	my $prefix = $action eq 'create'
		? 'vm-create:'
		: $action eq 'clone'
			? 'vm-clone:'
			: $action eq 'capture_image'
				? 'vm-image:'
				: 'vm-manage:'.$action.':';
	my $attempt =
		$attempts->choose("$remote_user:$input->{token}:$action",
				  $input->{'attempt'}, $input->{'proposed'},
				  sub {
				# inspect(attempt) permits a new job after
				# worker shutdown and cleanup.
				my $id =
					substr(
						sha256_hex($prefix.
							   Cloudmin::Attempts::key($input->{'token'}, $_[0])), 0,
						32);
				my $job = $jobs->get($id, $remote_user) ||
					  return 0;
				return 0
					if (
						$job->{'state'} !~ /\A(?:failed|cancelled)\z/);
				die "The previous attempt needs recovery. Open Active Jobs to finish it before retrying.\n"
					if ($job->{'cleanup_pending'} ||
					    $jobs->busy($id));
				# Failed or cancelled setup must not
				# create another guest.
				if ($job->{'resources'}->{'software'}) {
					$result =
						{ error =>
							  'The virtual machine was created. Resubmitting creation cannot restart software setup. Refresh the page to start a new creation.',
						  retryable => 0 };
					return 0;
					}
				return 1;
				});
	$result ||= { attempt => $attempt };
	}
return $result;
}

1;
