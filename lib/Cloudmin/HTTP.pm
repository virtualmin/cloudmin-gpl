package Cloudmin::HTTP;

# HTTPS transport for unprivileged image workers. The controller supplies only
# outgoing proxy settings; this process does not load Webmin configuration.
use strict;
use warnings;
use WebminCore qw(parse_http_url make_http_connection complete_http_download
    read_http_connection close_http_connection);

# authority(host, port)
# Preserves IPv6 brackets and non-default ports in HTTP headers and redirects.
sub authority
{
my ($host, $port) = @_;
return ($host =~ /:/ ? "[$host]" : $host).($port == 443 ? '' : ":$port");
}

# redirect(location, host, port, page)
# Resolves a Location header and rejects HTTPS downgrades before connecting.
sub redirect
{
my ($location, $host, $port, $page) = @_;
# A redirect without a destination must not retry the same request.
die "Missing image redirect\n" if (!defined($location) || !length($location));
# Scheme-relative redirects can change the publisher's hostname.
$location = "https:$location" if ($location =~ m{\A//});
if ($location !~ m{\A[a-z][a-z0-9+.-]*:}i) {
	# Resolve relative paths locally; a query-only redirect keeps the
	# filename.
	$page =~ s/[?#].*//;
	my $relative = $location =~ /^\?/ ? $page.$location
		: (parse_http_url($location, $host, $port, $page, 1))[2];
	$location = 'https://'.authority($host, $port).$relative;
	}
return Cloudmin::Images::validate_url($location);
}

# download(url, destination, callback)
# Uses Webmin's HTTP connection and download APIs with verified TLS on every
# redirect. The lower-level entry point accepts CA requirements; http_download
# does not currently expose them. No external downloader or shared cache is
# used. destination is a filename or scalar reference; callback(mode, value)
# receives Webmin's download progress events and may die to cancel the transfer.
sub download
{
my ($url, $dest, $callback) = @_;
my ($ca) = grep { -r $_ } ('/etc/pki/tls/certs/ca-bundle.crt',
	'/etc/ssl/certs/ca-certificates.crt', '/etc/ssl/ca-bundle.pem');
# Certificate validation is required even when a publisher redirects elsewhere.
die "System CA certificates are unavailable.\n" if (!$ca);
my $deadline = time() + 3300;
# alarm_handler(signal): bound connection and stalled-transfer waits.
local $SIG{'ALRM'} = sub { die "Image download timed out.\n" };
# Each redirect gets a new verified connection within the same total deadline.
for (1..10) {
	$url = Cloudmin::Images::validate_url($url);
	my ($host, $port, $page, $ssl) = parse_http_url($url);
	my ($handle, $redirect, $error);
	my $ok = eval {
		alarm(30);
		$handle = make_http_connection($host, $port, 1, 'GET', $page,
			[ [ 'Host', authority($host, $port) ],
			  [ 'User-Agent', 'Webmin Cloudmin' ] ],
			undef, { capath => $ca, host => $host });
		# Webmin returns a text error when it cannot open the
		# connection.
		die "$handle\n" if (!ref($handle));
		complete_http_download($handle, $dest, \$error, sub {
			# progress(mode, value)
			# Checks time, status and redirects before forwarding progress.
			my ($mode, $value) = @_;
			# Activity refreshes the idle timer but cannot extend
			# the overall limit.
			die "Image download timed out.\n"
			if (time() > $deadline);
			alarm(60);
			if ($mode == 1) {
				# Webmin exposes its response line to download
				# callbacks. Its general downloader also accepts
				# 400 and partial responses, which must never
				# become unchecked raw images here.
				no warnings 'once';
				my ($status) = ($WebminCore::line ||
				'') =~ m{\AHTTP/1\.[01]\s+(\d{3})\b};
				# Only complete responses or redirects may enter
				# the import pipeline.
				die "Invalid image server response\n"
				if (!$status);
				# An HTTP error or partial response
				# cannot become an imported disk.
				die "Image server returned HTTP $status instead of a complete file\n"
					if ($status != 200 &&
					$status !~ /\A30[12378]\z/);
				}
			if ($mode == 5) {
				# Reopen redirects ourselves to retain
				# certificate verification.
				$redirect = redirect($value, $host, $port,
					$page);
				die "Redirect\n";
				}
			$callback->(@_);
			}, undef, $host, $port, {}, 1, 1, 60);
		# Webmin may report a download failure through its output
		# parameter.
		die "$error\n" if ($error);
		1;
		};
	my $failure = $@;
	alarm(0);
	# Callbacks can throw before Webmin closes its connection and temporary
	# file.
	eval { close_http_connection($handle) } if (!$ok && ref($handle));
	# On a body failure the worker exits. Its controller stops the whole service
	# before removing the private directory, including Webmin's partial file.
	# Do not depend on Webmin's private handle name or tempfile bookkeeping.
	# Successful transfers stop here; only a validated redirect warrants a
	# retry.
	return if ($ok);
	# Other failures propagate instead of retrying a possibly
	# partial transfer.
	die $failure if (!$redirect);
	$url = $redirect;
	}
die "Too many image download redirects.\n";
}

# probe(url)
# Reads HTTPS response headers within 15 seconds, without downloading the image.
# A range request handles publishers that omit sizes or reject HEAD requests.
# Returns a positive byte count, undef if unavailable, or throws on transport
# errors.
sub probe
{
my ($url) = @_;
my ($ca) = grep { -r $_ } ('/etc/pki/tls/certs/ca-bundle.crt',
	'/etc/ssl/certs/ca-certificates.crt', '/etc/ssl/ca-bundle.pem');
# Size probes require the same verified TLS as image downloads.
die "System CA certificates are unavailable\n" if (!$ca);
my ($handle, $bytes);
my $method = 'HEAD';
# alarm_handler(signal): cap the entire redirect and HEAD/range sequence.
local $SIG{'ALRM'} = sub { die "Image size lookup timed out\n" };
my $ok = eval {
	alarm(15);
	# Request headers only; a one-byte range is the fallback for unusable
	# HEAD.
	for (1..8) {
		$url = Cloudmin::Images::validate_url($url);
		my ($host, $port, $page) = parse_http_url($url);
		my $authority = authority($host, $port);
		$handle = make_http_connection($host, $port, 1, $method, $page,
			[ [ 'Host', $authority ],
			  [ 'User-Agent', 'Webmin Cloudmin' ],
			  [ 'Accept-Encoding', 'identity' ],
			  [ 'Connection', 'close' ],
			  $method eq 'GET' ? ([ 'Range', 'bytes=0-0' ]) : () ],
			undef, { capath => $ca, host => $host });
		# Connection and malformed-status errors must not be cached as
		# file sizes.
		die "$handle\n" if (!ref($handle));
		my $line = read_http_connection($handle) || '';
		my ($status) = $line =~ m{\AHTTP/1\.[01]\s+(\d{3})\b};
		# Without a valid status line, length headers have no
		# usable meaning.
		die "Invalid image server response\n" if (!$status);
		my (%headers, $length);
		# Bound publisher-controlled headers before interpreting length
		# fields.
		while (defined($line = read_http_connection($handle))) {
			$length += length($line);
			die "Image response headers are too large\n"
				if ($length > 32768);
			# Stop at the header boundary without reading
			# the image response body.
			last if ($line =~ /\A\r?\n\z/);
			$line =~ s/\r?\n\z//;
			# Normalize ordinary header names; ignore
			# malformed lines.
			$headers{lc($1)} = $2
				if ($line =~ /\A([^:\s]+):\s*(.*)\z/);
			}
		close_http_connection($handle);
		undef($handle);
		# Resolve redirects, then validate HTTPS again before
		# connecting.
		if ($status =~ /\A30[12378]\z/) {
			$url = redirect($headers{'location'}, $host, $port,
				$page);
			next;
			}
		# An encoded response does not describe the downloadable image's
		# size.
		last if ($headers{'content-encoding'} &&
			$headers{'content-encoding'} ne 'identity');
		if ($status == 206) {
			# The range response length is one byte; Content-Range
			# holds the total.
			($bytes) = ($headers{'content-range'} ||
				'') =~ m{\Abytes 0-0/(\d+)\z}i;
			}
		elsif ($status == 200 && !$headers{'transfer-encoding'}) {
			# A complete, unchunked response can state the total
			# directly.
			$bytes = $headers{'content-length'};
			}
		# Stop probing once a representable, positive size is known.
		last if (Cloudmin::ImageSizes::valid_bytes($bytes));
		if ($method eq 'HEAD' &&
			($status == 200 || $status == 405 || $status == 501)) {
			# Retry once with a range when HEAD is unsupported or
			# lacks a size.
			$method = 'GET';
			next;
			}
		last;
		}
	1;
	};
my $error = $@;
alarm(0);
# Close any connection left open by an exception before returning or failing.
close_http_connection($handle) if (ref($handle));
# Keep failed transport checks distinct from a valid but unknown size.
die $error if (!$ok);
return Cloudmin::ImageSizes::valid_bytes($bytes) ? 0 + $bytes : undef;
}

1;
