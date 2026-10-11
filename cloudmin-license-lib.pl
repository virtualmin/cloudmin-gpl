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

1;
