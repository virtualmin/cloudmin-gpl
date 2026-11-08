package Cloudmin::ImageSizes;

# Cached download sizes can be refreshed without changing catalogue settings.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use WebminCore qw(read_file_contents write_file_contents make_dir
	convert_from_json convert_to_json);

# new(class, directory => path, [probe => callback], [lock_file => callback],
#     [unlock_file => callback], [test_lock => callback], [now => callback])
# Opens a URL-keyed cache without creating files during ordinary page rendering.
# probe(url) returns bytes; lock callbacks take a cache path and now() defaults
# to time(). The probe and lock callbacks are required when calling refresh().

sub new
{
my ($class, %opts) = @_;
# Cache entries must remain inside an explicitly chosen module directory.
die "Image size cache directory is required\n" if (!$opts{'directory'});
return bless(\%opts, $class);
}

# now(self) Returns the current time, or the clock supplied by a test.

sub now
{
my ($self) = @_;
return $self->{'now'} ? $self->{'now'}->() : time();
}

# valid_bytes(value) Accepts positive byte counts that JavaScript
# can represent exactly.

sub valid_bytes
{
return defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[1-9]\d{0,14}\z/;
}

# path(self, entry) Keys estimates by URL so editing a source cannot
# reuse its previous size.

sub path
{
my ($self, $entry) = @_;
return "$self->{directory}/".sha256_hex(encode_utf8($entry->{'url'})).
       '.json';
}

# get(self, entry) Uses the last successful observation, falling back to
# the bundled estimate.

sub get
{
my ($self, $entry) = @_;
my $path = $self->path($entry);
my $cache =
	-f $path ? eval { convert_from_json(read_file_contents($path)) } : { };
# Invalid cache data falls back to the catalogue estimate.
$cache = { } if (ref($cache) ne 'HASH');
my $bytes = valid_bytes($cache->{'bytes'})
	? $cache->{'bytes'}
	: valid_bytes($entry->{'download_size_bytes'})
		? $entry->{'download_size_bytes'}
		: undef;
my $now = $self->now();
# Successful probes last a day; failures can retry after one hour.
my $retry = ($cache->{'checked'} || 0) == ($cache->{'attempted'} || -1)
	? 86400
	: 3600;
# Validation can stringify Perl numbers; return numeric JSON for the browser.
return { bytes => defined($bytes) ? 0 + $bytes : undef,
	 checked => 0 + ($cache->{'checked'} || 0),
	 refresh => !$cache->{'attempted'} || $cache->{'attempted'} > $now ||
		    $now - $cache->{'attempted'} >= $retry ? 1 : 0 };
}

# refresh(self, entry) Refreshes stale headers once under a Webmin lock;
# failures retain estimates.

sub refresh
{
my ($self, $entry) = @_;
my $result = $self->get($entry);
# Ordinary reads of a fresh entry must not acquire locks or start a worker.
return $result if (!$result->{'refresh'});
make_dir($self->{'directory'}, 0700, 1) ||
	die "Cannot create image size cache\n";
my $path = $self->path($entry);
# Another probe already owns this URL; let the browser keep its cached estimate.
return $result if ($self->{'test_lock'}->($path));
$self->{'lock_file'}->($path, 0, 0, 1) || die "Cannot lock image size cache\n";
my $ok = eval {
	# A concurrent request may already have refreshed this URL.
	$result = $self->get($entry);
	if ($result->{'refresh'}) {
		# A failed probe records its attempt but preserves
		# the last usable size.
		my $bytes = eval { $self->{'probe'}->($entry->{'url'}) };
		my $now = $self->now();
		my $cache = { attempted => $now,
			      checked => $result->{'checked'},
			      bytes => $result->{'bytes'} };
		if (valid_bytes($bytes)) {
			# Replace the estimate only with a valid, newly
			# observed byte count.
			$cache->{'bytes'} = 0 + $bytes;
			$cache->{'checked'} = $now;
			}
		my $mask = umask(0077);
		# Keep private cache permissions and restore umask even
		# after write failure.
		my $written = eval { write_file_contents($path,
							 convert_to_json($cache,
									 0,
									 1)); 1 };
		my $error = $@;
		umask($mask);
		die $error if (!$written);
		$result = $self->get($entry);
		}
	1;
	};
my $error = $@;
$self->{'unlock_file'}->($path);
# Release the URL lock before propagating failures to the request handler.
die $error if (!$ok);
return $result;
}

1;
