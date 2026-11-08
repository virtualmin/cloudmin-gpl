package CloudminTest;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

our $webmin_root;

# import(class) Find Webmin for source and installed tests, and run CGI
# fixtures from the module.

sub import
{
my $module_root = abs_path(dirname(__FILE__).'/../..');
# An explicit override must resolve on its own, without
# choosing another version.
my @roots = defined($ENV{'WEBMIN_ROOT'})
	? ($ENV{'WEBMIN_ROOT'})
	: ( "$module_root/..", "$module_root/../webmin",
	    grep { !ref($_) } @INC );
($webmin_root) = grep { length($_) && -r "$_/WebminCore.pm" } @roots;
die "Cannot find WebminCore.pm; set WEBMIN_ROOT to the Webmin directory\n"
	if (!defined($webmin_root));
# Use the same root for Perl imports and tests that read native Webmin files.
$webmin_root = abs_path($webmin_root);
unshift(@INC, $webmin_root);
# CGI handlers use relative requires, regardless of where prove was started.
chdir($module_root) || die "Cannot enter Cloudmin module directory: $!\n";
}

1;
