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

# uses_scripts(settings) detects selected sources, even when their text is empty.
# Explicit None overrides stale text or paths; older records infer the source.
sub uses_scripts
{
my ($settings) = @_;
return scalar grep {
	my $mode = $settings->{$_.'_mode'};
	defined($mode) && length($mode) ? $mode ne 'none'
		: length($settings->{$_} // '') || length($settings->{$_.'_path'} // '')
} qw(before_script after_script);
}

# script_settings(input) returns normalized script fields for supplied options.
# GPL can clear fields; active sources require Pro validation. Omitted fields
# remain absent so callers can preserve template inheritance.
sub script_settings
{
my ($input) = @_;
if (uses_scripts($input)) {
	# This gate also protects direct API requests and recovered creation data.
	require_scripts();
	return Cloudmin::Pro::SetupScripts::settings($input);
}
my %values;
foreach my $field (qw(before_script after_script)) {
	# Omitted fields still inherit; explicit None discards either old source.
	next if (!grep { exists($input->{$_}) } ($field, $field.'_mode', $field.'_path'));
	@values{$field.'_mode', $field, $field.'_path'} = ('none', '', '');
}
return \%values;
}

# enabled(settings) checks for packages, scripts or a Virtualmin installation.
sub enabled
{
my ($settings) = @_;
return (($settings->{'software'} || 'none') ne 'none' ||
	length($settings->{'packages'} || '') || grep {
		($settings->{$_.'_mode'} || '') ne 'none' &&
		(length($settings->{$_} || '') || length($settings->{$_.'_path'} || ''))
	} qw(before_script after_script)) ? 1 : 0;
}

1;
