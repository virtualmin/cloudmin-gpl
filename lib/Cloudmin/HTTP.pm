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

1;
