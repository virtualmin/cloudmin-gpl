package Cloudmin::Software;

# Guest provisioning uses pinned SSH. Scripts run only inside the guest;
# license inputs stay out of templates and the seed disk.
use strict;
use warnings;
use WebminCore qw(convert_to_json read_file_contents check_ipaddress check_ip6address);
use File::Basename qw(dirname);
use Time::HiRes ();

# script_fields() names reusable script settings, including inactive sources.
sub script_fields { return qw(before_script before_script_mode before_script_path
	after_script after_script_mode after_script_path); }

# has_scripts() checks both Pro helpers on disk, without caching availability.
sub has_scripts
{
my $pro = dirname(__FILE__).'/../../pro';
return -r "$pro/SetupScripts.pm" && -r "$pro/guest-scripts.pl";
}

# require_scripts() refuses script work when its Pro implementation is absent.
sub require_scripts
{
die "Custom setup scripts require Cloudmin Pro. Set both scripts to None or install Cloudmin Pro.\n"
	if (!has_scripts());
require(dirname(__FILE__).'/../../pro/SetupScripts.pm');
}

1;
