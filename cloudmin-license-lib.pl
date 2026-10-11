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

# get_cloudmin_license() uses the shared license file and private Webmin state.
sub get_cloudmin_license
{
return Cloudmin::License->new(directory => "$module_var_directory/license",
    file => '/etc/cloudmin-license',
    host => cloudmin_license_host(),
    request => \&cloudmin_license_request, replace => \&save_cloudmin_license);
}

# cloudmin_license_repo_text(text, serial, key) replaces only Cloudmin credentials.
# Public repositories and Virtualmin licenses are unrelated and stay unchanged.
sub cloudmin_license_repo_text
{
my ($value, $serial, $key) = @_;
# Empty credentials remove authentication when this host is deregistered.
my $clear = !length($serial) && !length($key);
my $host = qr/(?:(?:cloudmin|vm2)\.virtualmin\.com|(?:rc\.)?download\.cloudmin\.(?:com|dev)|rc\.cloudmin\.dev)/;
# APT machine entries carry credentials in separate fields, never in their URL.
$value =~ s{(\bmachine\s+\S+)|(https?://)(?:[^\s/\@]+\@)?($host)(?=[:/\s]|$)}{
    defined($1) ? $1 : $clear ? "$2$3" : "$2$serial:$key\@$3";
}ge;
# APT auth.conf may hold credentials separately from source URLs. Match a whole
# machine stanza, allowing a scheme, port and path after the known hostname.
$value =~ s{(\bmachine\s+(?:https?://)?$host(?=[:/\s]|$)\S*\s+)(.*?)(?=\bmachine\s|\z)}{
    my ($prefix, $body) = ($1, $2);
    $body =~ s/(\blogin\s+)\S+/$1$serial/g;
    $body =~ s/(\bpassword\s+)\S+/$1$key/g;
    # Remove the matching auth stanza rather than leave an empty login.
    $clear ? '' : $prefix.$body;
}gse;
return $value;
}

# cloudmin_license_files() lists the credential file and supported repo formats.
# The second field marks the license file; other entries contain repository text.
sub cloudmin_license_files
{
our $config_directory;
return (['/etc/cloudmin-license', 1],
    map { [$_, 0] }
    '/etc/apt/sources.list', '/etc/apt/auth.conf',
    glob('/etc/apt/sources.list.d/*.list'), glob('/etc/apt/sources.list.d/*.sources'),
    glob('/etc/apt/auth.conf.d/*.conf'), glob('/etc/yum.repos.d/*.repo'),
    "$config_directory/webmin/config");
}

# save_cloudmin_license(serial, key) updates existing repository credentials too.
# Empty serial and key clear credentials without removing repository definitions.
# Stage every replacement first. Roll back completed files if a later write fails.
sub save_cloudmin_license
{
my ($serial, $key) = @_;
my (@changes, @locked);
# Lock paths in a stable order and collect replacements before writing any.
my $prepared = eval {
foreach my $entry (sort { $a->[0] cmp $b->[0] } cloudmin_license_files()) {
    my ($path, $license) = @$entry;
    next if (!-e $path && !-l $path && !$license);
    # Suppress Webmin's configuration diff log: these files contain credentials.
    lock_file($path, undef, undef, 1);
    push(@locked, $path);
    my ($old, $mode, $group);
    if (-e $path || -l $path) {
        # Save the original data and access mode for both success and rollback.
        sysopen(my $fh, $path, Fcntl::O_RDONLY() | Fcntl::O_NOFOLLOW())
            or die "Cannot read license or repository configuration\n";
        my @st = stat($fh);
        die "Unsafe license or repository configuration\n"
            if (!-f $fh || $st[4] != $< || $st[7] > 2*1024*1024);
        local $/;
        $old = <$fh> // '';
        close($fh);
        $mode = $st[2] & 0777;
        $group = $st[5];
    }
    # Credential files are authoritative; other files change only matching hosts.
    my $new = $license ? "SerialNumber=$serial\nLicenseKey=$key\n"
        : cloudmin_license_repo_text($old, $serial, $key);
    push(@changes, [$path, $old, $mode, $new, $license, $group]) if (!defined($old) || $new ne $old);
}
1;
};
if (!$prepared) {
    # No writes have started, so only the acquired locks need releasing.
    my $error = $@;
    unlock_file($_) for reverse @locked;
    die $error;
}
# Record completed replacements in order so rollback can unwind them.
my @saved;
my $ok = eval {
    foreach my $change (@changes) {
        Cloudmin::License::write_private($change->[0], $change->[3]);
        push(@saved, $change);
        # Only the license file needs private mode; preserve repository access.
        # Record the write first so a permission failure also rolls it back.
        if (!$change->[4]) {
            chown(-1, $change->[5], $change->[0]) or die "Cannot preserve repository group\n";
            chmod($change->[2], $change->[0]) or die "Cannot preserve repository permissions\n";
        }
    }
    1;
};
if (!$ok) {
    # Restore every completed write, even if one rollback operation fails.
    my $restored = 1;
    foreach my $change (reverse @saved) {
        my ($path, $old, $mode, undef, undef, $group) = @$change;
        my $one = eval {
            if (defined($old)) {
                # Existing files recover their contents, group and permissions.
                Cloudmin::License::write_private($path, $old);
                chown(-1, $group, $path) or die "Cannot restore group\n";
                chmod($mode, $path) or die "Cannot restore permissions\n";
            }
            # Files created by this attempt must become absent again.
            else { unlink($path) or die "Cannot restore missing file\n"; }
            1;
        } ? 1 : 0;
        $restored = 0 if (!$one);
    }
    unlock_file($_) for reverse @locked;
    die $restored ? "Cannot save the new license (previous credentials restored)\n"
        : "Cannot finish the license change or restore all previous files\n";
}
unlock_file($_) for reverse @locked;
}

# cloudmin_license_status([refresh], [force]) keeps GPL independent of licensing.
# Storage failures deny new changes but cannot make inventory pages fail.
# Both flags default to false and are passed to License::status on Pro hosts.
sub cloudmin_license_status
{
return {edition => 'GPL', state => 'gpl', allowed => 1} if (!cloudmin_pro());
# Turn identity, credential and cache read errors into a displayable state.
my $status = eval { get_cloudmin_license()->status(@_) };
$status ||= {edition => 'Pro', state => 'storage', allowed => 0};
$status->{'message'} = cloudmin_license_message($status);
return $status;
}

# cloudmin_license_message(status, [on_page]) explains the problem and remedy.
# on_page defaults to false; 'manager' omits navigation and 'readonly' asks an
# administrator to add missing credentials. The result is plain text.
sub cloudmin_license_message
{
my ($s, $on_page) = @_;
my %messages = (
    expired => 'The license has expired. Renew it, then recheck.',
    overused => 'This license is used on too many hosts. Finish the migration or assign a separate license to each extra host, then recheck.',
    unavailable => 'The license check failed. Check the host clock and HTTPS access to www.virtualmin.com, then recheck.',
    missing => ($on_page || '') eq 'readonly'
        ? 'Ask an administrator to add a Cloudmin Pro license to enable changes.'
        : 'Add your Cloudmin Pro license '.($on_page ? 'using the fields above'
            : 'in System -> Settings -> License Manager').' to make changes.',
    invalid => 'The license was not accepted. Check the serial number and key, or enter a different license.',
    unverified => 'The license has not been verified on this host. Recheck it to enable changes.',
    clock => 'The host clock appears incorrect. Correct it, then recheck the license.',
    storage => 'License information could not be loaded. Check the host ID (hardware UUID or /etc/machine-id) and permissions on the license file and state directory, then recheck.',
);
my $message = $messages{$s->{'state'}} || '';
# Healthy and GPL states need no advice beside their status.
return '' if (!$message);
# The setup message already explains where to add a license and why.
if ($s->{'state'} ne 'missing') {
    $message .= ' Open System -> Settings -> License Manager to update or recheck the license.' if (!$on_page);
    my $days = $s->{'days_left'} || 0;
    $message .= $s->{'allowed'} ? " You can make changes for $days more ".($days == 1 ? 'day.' : 'days.')
        : ' Changes through Cloudmin are blocked.';
}
return $message.' Existing machines and services keep running. Scheduled backups and queued or running jobs continue.';
}

# require_cloudmin_license() checks stale state before admitting a new change.
sub require_cloudmin_license
{
my $s = cloudmin_license_status(1);
die cloudmin_license_message($s)."\n" if (!$s->{'allowed'});
}

# check_cloudmin_license() is the daily Webmin cron callback.
sub check_cloudmin_license
{
cloudmin_license_status(1, 1);
}

# setup_cloudmin_license_check() installs one daily check on Pro hosts only.
sub setup_cloudmin_license_check
{
return if (!cloudmin_pro());
foreign_require('webmincron');
return if (grep { $_->{'module'} eq 'server-manager' && $_->{'func'} eq 'check_cloudmin_license' }
    webmincron::list_webmin_crons());
# A stable host-specific slot spreads daily checks across the full day.
my $slot = hex(substr(sha256_hex(cloudmin_license_host()), 0, 4));
webmincron::save_webmin_cron({module => 'server-manager', file => 'server-manager-lib.pl',
    func => 'check_cloudmin_license', args => [], mins => $slot % 60,
    hours => int($slot/60) % 24, days => '*', months => '*', weekdays => '*'});
}

# check_cloudmin_license_action(action, input) checks access before forms or writes.
# Confirmation pages and the API share the same ACL, edition and token checks.
sub check_cloudmin_license_action
{
my ($action, $input) = @_;
require_access('host');
die "License changes are disabled in read-only mode\n" if (is_readonly_mode());
die "License management is available in Cloudmin Pro\n" if (!cloudmin_pro());
get_image_jobs()->check_token($remote_user, $input->{'token'});
die "Unknown license action\n" if ($action !~ /\A(?:check_license|change_license|deregister_license)\z/);
}

1;
