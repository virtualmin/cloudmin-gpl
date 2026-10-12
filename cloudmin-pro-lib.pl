# Shared Pro previews use the same markup and widgets as Virtualmin.
use strict;
use warnings;
our (%config, %text, $module_root_directory);

# show_pro_features() respects the administrator's advertising preference.
sub show_pro_features { return ($config{'hide_pro_tips'} || 0) != 1; }

# config_pre_load(info, [order]) checks saves and hides unused Pro advertising.
# info maps keys to field definitions; order is an optional list of those keys.
# Webmin calls this hook when displaying and saving configuration.
sub config_pre_load
{
my ($info, $order) = @_;
# Check licensing only on saves so the configuration form remains viewable.
if (($ENV{'SCRIPT_NAME'} || '') =~ m{/config_save\.cgi\z}) {
	my $ok = eval { require_access('manage'); 1 };
	error(error_html(error_message($@))) if (!$ok);
}
# Keep the preference available while any advertised feature is unavailable.
return if (grep { !-r "$module_root_directory/pro/$_" }
	qw(SetupScripts.pm guest-scripts.pl VMImages.pm BackupCloud.pm));
delete($info->{'hide_pro_tips'});
# Keep an explicit field order consistent with the remaining definitions.
@$order = grep { $_ ne 'hide_pro_tips' } @$order if ($order);
}

1;
