# Storage integration uses Webmin's existing access, form-token and audit APIs.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(
	Cwd::abs_path(File::Basename::dirname(__FILE__).
		      '/cloudmin-access-lib.pl'));
our ($module_root_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/Storage.pm";
require "$module_root_directory/cloudmin-disk-labels.pl";

# get_storage_service([writable]) Opens the configured connection without
# changing pools during inventory reads. writable defaults to false; true
# requests a libvirt connection for changes.

sub get_storage_service
{
# Pools and volumes are host resources, including during read-only inventory.
require_access('host');
my ($writable) = @_;
return Cloudmin::Storage->new(adapter => get_libvirt($writable),
			      jobs => get_vm_jobs(),
			      images => get_image_jobs());
}

# check_storage_request(input) Requires POST, host management and input.token
# for UI reviews and changes.

sub check_storage_request
{
my ($in) = @_;
die "Use the Storage form to make changes\n"
	if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
check_storage_access($in);
}

# check_storage_access(input) checks host/manage access and input.token. Shared
# by browser and local API calls; read-only sessions cannot proceed.

sub check_storage_access
{
my ($in) = @_;
require_access('host');
die "Storage changes are disabled in read-only mode\n" if (is_readonly_mode());
require_access('manage');
get_image_jobs()->check_token($remote_user, $in->{'token'});
}

# storage_volume_selection(input, [confirmed]) Keeps names paired with pool IDs
# and, on confirmation, reviewed revisions.

sub storage_volume_selection
{
my ($in, $confirmed) = @_;
my @values = split(/\0/, $in->{'volume'} || '', -1);
die "Select between 1 and 100 unused volumes\n" if (!@values || @values > 100);
my @revisions = split(/\0/, $in->{'revision'} || '', -1);
die "Review the selected volumes again before deleting\n"
	if ($confirmed && @revisions != @values);
my (@selected, %seen);
foreach my $value (@values) {
	my ($uuid, $name) = split(m{/}, $value, 2);
	die "Invalid storage volume selection\n"
		if (!$uuid || !defined($name) || !length($name) ||
		    $uuid !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i ||
		    $name =~ /[\x00-\x1f\x7f]/ || length($name) > 4096 ||
		    $seen{lc($uuid).'/'.$name}++);
	my $revision = shift(@revisions);
	die "Review the selected volumes again before deleting\n"
		if ($confirmed && ($revision || '') !~ /\A[0-9a-f]{64}\z/);
	push(@selected, { uuid => $uuid, name => $name, $confirmed
		? ( revision => $revision )
		: () });
	}
return \@selected;
}

# inspect_storage_selection(service, selection) Checks the whole selection
# before deletion and records each file identity.

sub inspect_storage_selection
{
my ($service, $selection) = @_;
my @records;
foreach my $item (@$selection) {
	my (undef, undef, $record) =
		$service->inspect_volume(@$item{qw(uuid name)});
	die "The storage volume changed; review it again before deleting\n"
		if ($item->{'revision'} &&
		    $item->{'revision'} ne $record->{'revision'});
	push(@records, $record);
	}
return \@records;
}

# review_storage_volumes(input) Resolves selected files under the user's access
# rules without changing data.

sub review_storage_volumes
{
my ($in) = @_;
check_storage_request($in);
local $main::error_must_die = 1;
return inspect_storage_selection(get_storage_service(),
				 storage_volume_selection($in));
}

# change_storage(action, input) Checks authorization before opening a writable
# connection or touching paths.

sub change_storage
{
my ($action, $in) = @_;
check_storage_request($in);
return apply_storage_change($action, $in);
}

# apply_storage_change(action, input) applies and audits an authorized change.
# Callers must check access, input.token and any HTTP method before dispatch.

sub apply_storage_change
{
my ($action, $in) = @_;
local $main::error_must_die = 1;
my $service = get_storage_service(1);
if ($action eq 'unregister') {
	# Removing a definition preserves all files and logical volumes.
	my $record = $service->unregister(@$in{qw(id revision confirm stop)});
	webmin_log('unregister', 'pool', $record->{'id'},
		   { name => $record->{'name'}, stopped =>
							$record->{'stop_required'} });
	return $record;
	}
if ($action eq 'delete_volume') {
	# Single-volume API requests use the same deletion and
	# audit as UI batches.
	return delete_storage_volume($service,
				     @$in{qw(pool volume revision confirm)});
	}
if ($action eq 'delete_volumes') {
	# Revalidate the reviewed batch before deleting any selected volume.
	die "Confirm permanent volume deletion\n"
		if (($in->{'confirm'} || '') ne '1');
	my $records =
		inspect_storage_selection($service,
					  storage_volume_selection($in, 1));
	my (@deleted, @errors);
	foreach my $record (@$records) {
		# Each file is rechecked under the host lock. Audit successes
		# even if another deletion fails, and report
		# partial results explicitly.
		my $volume =
			eval { delete_storage_volume($service,
						     @$record{qw(uuid name revision)}, 1) };
		# Retain individual failures while continuing
		# the confirmed batch.
		if (!$volume) {
			# Summaries use display names; submitted
			# values retain exact IDs.
			push(@errors,
			     $record->{'pool'}.'/'.
			     storage_volume_label($record).': '.
			     error_message($@));
			next;
			}
		push(@deleted,
		     $volume->{'pool'}.'/'.storage_volume_label($volume));
		}
	die((@deleted ? 'Deleted: '.join(', ', @deleted).'. ' : '').
	    'Could not delete: '.join('; ', @errors)."\n")
		if (@errors);
	return join(', ', @deleted);
	}
# The NFS form has its own mount field; the API uses path for both backends.
$in = { %$in, path => $in->{'mount'} }
	if ($action eq 'create' && ($in->{'type'} || '') eq 'netfs' &&
	    exists($in->{'mount'}));
my $name = $action eq 'create'
	? $service->create($in)
	: $service->change($action, @$in{qw(id revision enabled)});
webmin_log($action, 'pool', $in->{'id'} || $name,
	   { name => $name, enabled => $in->{'enabled'} });
return $name;
}

# delete_storage_volume(service, pool, volume, revision, confirmed) Deletes the
# named volume through the service and audits only successful calls.

sub delete_storage_volume
{
my ($service, @args) = @_;
my $record = $service->delete_volume(@args);
webmin_log('delete', 'volume', $record->{'key'},
	   { name => $record->{'name'}, pool => $record->{'pool'}, path =>
									   $record->{'path'} });
return $record;
}

# call_storage_api(action, input) exposes the same storage service as the page.
# Reviews and changes require POST over HTTP and input.token on every route.
# Local root entry points enforce permissions without REQUEST_METHOD.

sub call_storage_api
{
my ($action, $in) = @_;
require_access('host');
local $main::error_must_die = 1;
if ($action eq 'storage') {
	# Inventory needs host access but no write permission or token.
	my $service = get_storage_service();
	my $data = $service->inventory();
	$data->{'lvm_groups'} = [ ];
	if ($data->{'local'}) {
		# Discover local groups without hiding usable
		# pools if LVM tools fail.
		$data->{'lvm_groups'} = eval { $service->lvm_groups() } || [ ];
		$data->{'lvm_group_error'} = error_message($@) if ($@);
		}
	return $data;
	}
# Reject unknown actions and unsafe HTTP methods before any writable lookup.
my %actions =
	( register_pool => 'create', pool_start => 'start', pool_stop => 'stop',
	  pool_autostart => 'autostart', unregister_pool => 'unregister',
	  delete_volume => 'delete_volume' );
die "Unknown storage action\n" if (!$actions{$action} &&
				   $action ne 'volume_review' && $action ne 'pool_review');
die "Use POST for storage changes\n" if (exists($ENV{'REQUEST_METHOD'}) &&
					 ($ENV{'REQUEST_METHOD'} || '') ne 'POST');
check_storage_access($in);
if ($action eq 'volume_review') {
	# A blocked review reports its owners without granting
	# a deletion revision.
	my (undef, undef, $record) =
		get_storage_service(1)->review_volume(@$in{qw(pool volume)}, 1);
	return $record;
	}
if ($action eq 'pool_review') {
	# Review and final unregistration both inspect the
	# entire registered group.
	my (undef, $record) =
		get_storage_service(1)->review_pool(@$in{qw(id stop)});
	return $record;
	}
my $result = apply_storage_change($actions{$action}, $in);
# Deletion and unregistration already return their removed object's identity.
return $result if (ref($result));
# Return the changed pool's fresh state, not a private libvirt object.
my ($record) = grep { $action eq 'register_pool'
	? $_->{'name'} eq $result
	: $_->{'uuid'} eq $in->{'id'} }
	       @{get_storage_service()->inventory()->{'pools'}};
die "Storage changed, but its updated pool record could not be read\n"
	if (!$record);
return $record;
}

1;
