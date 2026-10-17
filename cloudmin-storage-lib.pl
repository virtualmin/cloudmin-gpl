# Storage integration uses Webmin's existing access, form-token and audit APIs.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
our ($module_root_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/Storage.pm";
require "$module_root_directory/cloudmin-disk-labels.pl";

# get_storage_service([writable])
# Opens the configured connection without changing pools during inventory reads.
# writable defaults to false; true requests a libvirt connection for changes.
sub get_storage_service
{
# Pools and volumes are host resources, including during read-only inventory.
require_access('host');
my ($writable) = @_;
return Cloudmin::Storage->new(adapter => get_libvirt($writable),
	jobs => get_vm_jobs(), images => get_image_jobs());
}

# check_storage_request(input)
# Requires POST, host management and input.token for UI reviews and changes.
sub check_storage_request
{
my ($in) = @_;
die "Use the Storage form to make changes\n" if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
check_storage_access($in);
}

# check_storage_access(input) checks host/manage access and input.token.
# Shared by browser and local API calls; read-only sessions cannot proceed.
sub check_storage_access
{
my ($in) = @_;
require_access('host');
die "Storage changes are disabled in read-only mode\n" if (is_readonly_mode());
require_access('manage');
get_image_jobs()->check_token($remote_user, $in->{'token'});
}

# storage_volume_selection(input, [confirmed])
# Keeps names paired with pool IDs and, on confirmation, reviewed revisions.
sub storage_volume_selection
{
my ($in, $confirmed) = @_;
my @values = split(/\0/, $in->{'volume'} || '', -1);
die "Select between 1 and 100 unused volumes\n" if (!@values || @values > 100);
my @revisions = split(/\0/, $in->{'revision'} || '', -1);
die "Review the selected volumes again before deleting\n" if ($confirmed && @revisions != @values);
my (@selected, %seen);
foreach my $value (@values) {
	my ($uuid, $name) = split(m{/}, $value, 2);
	die "Invalid storage volume selection\n" if (!$uuid || !defined($name) || !length($name) ||
		$uuid !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i ||
		$name =~ /[\x00-\x1f\x7f]/ || length($name) > 4096 || $seen{lc($uuid).'/'.$name}++);
	my $revision = shift(@revisions);
	die "Review the selected volumes again before deleting\n"
		if ($confirmed && ($revision || '') !~ /\A[0-9a-f]{64}\z/);
	push(@selected, { uuid => $uuid, name => $name, $confirmed ? (revision => $revision) : () });
	}
return \@selected;
}

1;
