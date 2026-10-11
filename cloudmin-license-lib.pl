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

1;
