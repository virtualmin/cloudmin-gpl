package Cloudmin::ImageCatalog;

# Validated access to Cloudmin and custom virtual-machine image catalogues.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();
use Time::Local qw(timegm);
use WebminCore qw(read_file_contents write_file_contents convert_from_json
	convert_to_json);
require(dirname(__FILE__).'/Images.pm');
require(Cwd::abs_path(dirname(__FILE__).'/ImageChoices.pm'));

# new(class, path => file, [custom_path => file], [lock_file => callback],
#     [unlock_file => callback], [log => callback])
# Creates a lazy catalogue reader; lock/unlock/log callbacks are required for
# edits.
sub new
{
my ($class, %opts) = @_;
# The bundled manifest is required even when no custom catalogue exists yet.
die "Image catalogue path is required" if (!$opts{'path'});
return bless({ %opts }, $class);
}

# load(self)
# Loads, validates, and caches the catalogue manifest.
sub load
{
my ($self) = @_;
# Cache the immutable bundled manifest for this reader's lifetime.
return $self->{'catalogue'} if ($self->{'catalogue'});

my $json = read_file_contents($self->{'path'});
# Distinguish unreadable files from malformed JSON in operator-facing errors.
die "Cannot read image catalogue $self->{'path'}: $!" if (!defined($json));

my $catalogue = eval { convert_from_json($json) };
# Validate the full manifest before any entry can be listed or downloaded.
die "Cannot parse image catalogue $self->{'path'}: ".error_message($@)
	if (!$catalogue);
validate_catalogue($catalogue);
$self->{'catalogue'} = $catalogue;
return $catalogue;
}

# list_entries(self)
# Combines supplied and custom images, including disabled architectures.
sub list_entries
{
my ($self) = @_;
my $custom = $self->custom_catalogue();
my @records;
foreach my $source ([ $self->load(), 'bundled' ], [ $custom, 'custom' ]) {
	# Flatten each release into architecture-specific rows with stable edit
	# keys.
	foreach my $image (@{$source->[0]->{'images'}}) {
		foreach my $asset (@{$image->{'assets'}}) {
			my $arch = normalize_architecture($asset->{'architecture'});
			my $key = $image->{'id'}.':'.$arch;
			my %record = (%$image, %$asset, architecture => $arch,
				catalogue_key => $key,
				catalogue_origin => $source->[1],
				enabled => $custom->{'disabled'}->{$key} ? 0
				: 1);
			delete($record{'assets'});
			push(@records, \%record);
			}
		}
	}
# Keep catalogue tables and all image selectors in the same release order.
return Cloudmin::ImageChoices::sort_images(\@records);
}

# custom_catalogue(self)
# Reads the separate custom catalogue without creating it during page views.
sub custom_catalogue
{
my ($self) = @_;
my $path = $self->{'custom_path'};
# A fresh installation has an empty custom catalogue without needing a file.
return { schema => 1, images => [], disabled => {} } if (!$path || !-e $path);
my $json = read_file_contents($path);
# Existing but unreadable settings must not be silently overwritten as empty.
die "Cannot read custom image catalogue: $!\n" if (!defined($json));
my $catalogue = convert_from_json($json);
validate_catalogue($catalogue, 1);
$catalogue->{'disabled'} ||= {};
# Disabled entries are an architecture-keyed map, separate from image records.
die "Invalid disabled image settings\n"
	if (ref($catalogue->{'disabled'}) ne 'HASH');
my %bundled = map { $_->{'id'} => 1 } @{$self->load()->{'images'}};
foreach my $image (@{$catalogue->{'images'}}) {
	# Reserve bundled IDs so local edits cannot replace publisher-controlled
	# data.
	die "Invalid custom catalogue ID\n" if ($image->{'id'} !~ /\Acustom-/);
	# Custom releases must not shadow a bundled ID, even with
	# another asset.
	die "Custom image conflicts with Cloudmin catalogue\n"
		if ($bundled{$image->{'id'}});
	}
return $catalogue;
}

# validate_record(record)
# Applies the same schema to custom entries and bundled image assets.
sub validate_record
{
my ($record) = @_;
# Wrap the editor's flat record as a single-asset manifest for shared
# validation.
die "Invalid catalogue entry\n" if (ref($record) ne 'HASH');
validate_catalogue({ schema => 1, images => [ { %$record,
	assets => [ $record ] } ] });
}

# normalize_architecture([architecture])
# Converts common architecture aliases to libvirt and distribution names.
# Omitted input becomes an empty filter; unknown names are lowercased and
# trimmed.
sub normalize_architecture
{
my ($architecture) = @_;
$architecture = lc($architecture || '');
$architecture =~ s/^\s+|\s+$//g;
# Collapse the distribution/vendor spellings used for the same CPU family.
return 'x86_64' if ($architecture =~ /^(?:amd64|x86-64|x86_64)$/);
# Debian's arm64 and libvirt's aarch64 refer to the same 64-bit family.
return 'aarch64' if ($architecture =~ /^(?:arm64|aarch64)$/);
# Keep 32-bit ARM aliases distinct from ARM64 assets.
return 'armv7l' if ($architecture =~ /^(?:arm|armhf|armv7|armv7l)$/);
return $architecture;
}

# validate_catalogue(catalogue, [allow_empty])
# Rejects malformed or unsafe manifests before their values reach the UI.
# allow_empty defaults to false; custom catalogues may opt into an empty list.
sub validate_catalogue
{
my ($catalogue, $allow_empty) = @_;
# Reject incompatible top-level data before walking its release records.
die "Image catalogue must be a JSON object"
	if (ref($catalogue) ne 'HASH');
# Unknown schemas may assign different meanings to required fields.
die "Unsupported image catalogue schema"
	if (($catalogue->{'schema'} || 0) != 1);
# Custom catalogues may be empty, but always retain the array structure.
die "Image catalogue has no images"
	if (ref($catalogue->{'images'}) ne 'ARRAY' ||
	    (!$allow_empty && !@{$catalogue->{'images'}}));

my %ids;
foreach my $image (@{$catalogue->{'images'}}) {
	# Each release needs one safe, unique ID and scalar identifying
	# metadata.
	die "Image catalogue entry must be an object"
		if (ref($image) ne 'HASH');
	my $id = $image->{'id'} || '';
	# IDs enter form values, catalogue keys and generated volume
	# names.
	die "Invalid image catalogue ID '$id'"
		if (length($id) > 96 || $id !~ /\A[a-z0-9][a-z0-9._-]*\z/);
	# One ID must identify one release before its architectures are
	# expanded.
	die "Duplicate image catalogue ID '$id'" if ($ids{$id}++);
	foreach my $field (qw(name vendor os release status source_url)) {
		# UI labels and sorting require nonempty scalar
		# metadata.
		die "Image '$id' is missing $field"
			if (!defined($image->{$field}) ||
			ref($image->{$field}) || $image->{$field} eq '');
		}
	# Source links and status labels are constrained independently of
	# assets.
	die "Image '$id' has an unsafe source_url"
		if (!valid_url($image->{'source_url'}));
	# Status determines which label and sort priority the UI uses.
	die "Image '$id' has an invalid status"
		if ($image->{'status'} !~ /\A(?:recommended|supported|older)\z/);
	# Optional lifecycle dates must be real calendar dates in sortable ISO
	# form.
	foreach my $field (qw(release_date end_of_life)) {
		# Missing dates are allowed; supplied dates must survive
		# calendar validation.
		next if (!defined($image->{$field}) || $image->{$field} eq '');
		my ($year, $month,
			$day) = $image->{$field} =~ /\A([1-9]\d{3})-(\d{2})-(\d{2})\z/;
		die "Image '$id' has an invalid $field; use YYYY-MM-DD\n"
			if (!$year ||
			!eval { timegm(0, 0, 12, $day, $month - 1, $year); 1 });
		}
	# A supported lifetime cannot end before the release begins.
	die "Image '$id' reaches end of life before its release date\n"
		if ($image->{'release_date'} && $image->{'end_of_life'} &&
			$image->{'end_of_life'} lt $image->{'release_date'});
	# Every release must retain at least one architecture that can be
	# downloaded.
	die "Image '$id' has no downloadable assets"
		if (ref($image->{'assets'}) ne 'ARRAY' ||
		!@{$image->{'assets'}});

	my %architectures;
	foreach my $asset (@{$image->{'assets'}}) {
		# Architecture keys must remain unique after alias
		# normalization.
		die "Image '$id' asset must be an object"
			if (ref($asset) ne 'HASH');
		my $architecture = normalize_architecture(
			$asset->{'architecture'});
		# Bound normalized architecture keys before they reach
		# catalogue lookup.
		die "Image '$id' has an invalid architecture"
			if ($architecture !~ /\A[a-z0-9_]+\z/ ||
			length($architecture) > 32);
		# Alias spellings cannot create two assets for the same
		# CPU family.
		die "Image '$id' repeats architecture '$architecture'"
			if ($architectures{$architecture}++);
		# Accept only formats, digests and boot modes the import flow
		# understands.
		die "Image '$id' has an unsupported disk format"
			if (($asset->{'format'} || '') !~ /\A(?:qcow2|raw|iso)\z/);
		# Digest parsing supports only the two algorithms used
		# by the importer.
		die "Image '$id' has an unsupported checksum algorithm"
			if (($asset->{'checksum_algorithm'} ||
			'sha256') !~ /\Asha(?:256|512)\z/);
		# Empty firmware leaves selection to host capabilities
		# and image checks.
		die "Image '$id' has an unsupported firmware type"
			if (($asset->{'firmware'} ||
			'') !~ /\A(?:bios|uefi|uefi-or-bios)?\z/);
		foreach my $field (qw(url checksum_url)) {
			# Both the image and its checksum manifest must pass
			# download URL policy.
			die "Image '$id' has an unsafe $field"
				if (!valid_url($asset->{$field}));
			}
		# Signature links are metadata only today, but still require
		# safe URLs.
		die "Image '$id' has an unsafe signature_url"
			if ($asset->{'signature_url'} &&
			    !valid_url($asset->{'signature_url'}));
		# Disk capacity and optional transfer size describe different
		# quantities.
		die "Image '$id' has an invalid minimum disk size"
			if (!defined($asset->{'min_disk_bytes'}) ||
			$asset->{'min_disk_bytes'} !~ /\A\d+\z/);
		# Optional transfer estimates must remain exact
		# JavaScript integers.
		die "Image '$id' has an invalid download size"
			if (exists($asset->{'download_size_bytes'}) &&
			    (ref($asset->{'download_size_bytes'}) ||
			     ($asset->{'download_size_bytes'} ||
			'') !~ /\A[1-9]\d{0,14}\z/));
		}
	}
}

# valid_url(url)
# Applies the image downloader's URL rules to catalogue metadata too.
sub valid_url
{
my ($url) = @_;
return eval { Cloudmin::Images::validate_url($url); 1 } ? 1 : 0;
}

# error_message(error)
# Removes Perl source locations from manifest errors shown to callers.
sub error_message
{
my ($error) = @_;
my $message = defined($error) ? "$error" : '';
$message =~ s/\s+at\s+\S+\s+line\s+\d+\.?$//;
$message =~ s/\s+$//;
return $message || 'Unknown error';
}

1;
