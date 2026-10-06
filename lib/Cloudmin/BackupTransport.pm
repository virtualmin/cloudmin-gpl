package Cloudmin::BackupTransport;

# Local files stay private. Remote clients run in the existing network worker.
use strict;
use warnings;
no warnings 'once';
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use WebminCore qw(convert_to_json);
require(dirname(__FILE__).'/Worker.pm');
require(dirname(__FILE__).'/BackupSSH.pm');
my $PRO_HELPERS = dirname(__FILE__).'/../../pro/BackupCloud.pm';

# has_pro_providers() checks for the installed Cloudmin Pro transfer helpers.
sub has_pro_providers
{
return -r $PRO_HELPERS;
}

# modes() lists destinations supported by the installed edition.
sub modes
{
return (qw(local ssh s3), has_pro_providers() ? qw(gcs azure bb dropbox drive) : ());
}

1;
