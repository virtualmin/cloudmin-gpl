# License integration: fixed server, private state and one write policy.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
our (%module_info, %text, $module_root_directory, $module_var_directory, $remote_user);
require "$module_root_directory/lib/Cloudmin/License.pm";

# cloudmin_pro() detects installed extensions independently of display settings.
sub cloudmin_pro
{
return (exists($module_info{'gpl'}) && !$module_info{'gpl'}) ||
    scalar(grep { -f "$module_root_directory/pro/$_" }
        qw(SetupScripts.pm VMImages.pm BackupCloud.pm));
}

# cloudmin_license_host() identifies the host without depending on its IP address.
sub cloudmin_license_host
{
# Prefer the hardware UUID; machine-id also supports hosts without DMI data.
foreach my $path ('/sys/class/dmi/id/product_uuid', '/etc/machine-id') {
    next if (!open(my $fh, '<', $path));
    my $value = <$fh> // '';
    close($fh);
    $value =~ s/\s+//g;
    return lc($value) if ($value =~ /\A[0-9a-f-]{16,64}\z/i && $value =~ /[1-9a-e]/i);
}
die "Cannot identify this host for license checks\n";
}

# cloudmin_license_request(host, key) posts to the license API over verified TLS.
# Keep the key out of URLs. Redirects and transport errors are never passed on.
sub cloudmin_license_request
{
my ($host, $key) = @_;
# Require a system CA bundle rather than accepting an unverified connection.
my ($ca) = grep { -r $_ } ('/etc/pki/tls/certs/ca-bundle.crt',
    '/etc/ssl/certs/ca-certificates.crt', '/etc/ssl/ca-bundle.pem');
return undef if (!$ca);
my ($handle, $body);
# Bound the whole exchange, including connection setup and response reads.
local $SIG{'ALRM'} = sub { die "License check timed out\n" };
my $ok = eval {
    alarm(20);
    my $params = 'id='.urlize($host).'&serial='.urlize($key).'&product=cloudmin';
    $handle = make_http_connection('www.virtualmin.com', 443, 1, 'POST',
        '/api/license/client',
        [['Host', 'www.virtualmin.com'], ['Connection', 'close'],
         ['Content-Type', 'application/x-www-form-urlencoded'],
         ['Content-Length', length($params)],
         ['User-Agent', 'Webmin Cloudmin']], undef,
        {capath => $ca, host => 'www.virtualmin.com'});
    die "License connection failed\n" if (!ref($handle));
    die "Cannot send license check\n" if (!write_http_connection($handle, $params));
    # HTTP/1.0 close framing avoids unbounded line reads and redirect handling.
    my $raw = '';
    while (defined(my $part = read_http_connection($handle, 1024))) {
        $raw .= $part;
        die "License response is too large\n" if (length($raw) > 16384);
    }
    # Accept only a complete 200 response with the framing this reader supports.
    my ($headers, $content) = split(/\r?\n\r?\n/, $raw, 2);
    die "Invalid license response\n" if (!defined($content) || length($content) > 4096 ||
        $headers !~ /\AHTTP\/1\.[01] 200\b/ || $headers =~ /^Transfer-Encoding:/mi);
    my ($length) = $headers =~ /^Content-Length:\s*(\d+)\s*$/mi;
    die "Incomplete license response\n" if (defined($length) && $length != length($content));
    $body = $content;
    1;
};
# Always close the connection; callers treat failures as unavailable checks.
alarm(0);
eval { close_http_connection($handle) } if (ref($handle));
return $ok ? $body : undef;
}

1;
