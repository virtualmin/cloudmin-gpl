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
	qw(SetupScripts.pm guest-scripts.pl VMImages.pm BackupCloud.pm SSHKeys.pm));
delete($info->{'hide_pro_tips'});
# Keep an explicit field order consistent with the remaining definitions.
@$order = grep { $_ ne 'hide_pro_tips' } @$order if ($order);
}

# pro_feature_badge(feature, [plain]) uses Virtualmin's inline lock and Pro label.
# feature names the documentation anchor. plain defaults to false; true omits
# the link so the badge can be placed inside another link.
sub pro_feature_badge
{
my ($feature, $plain) = @_;
my $label = '&#128274;&nbsp;&nbsp;'.ui_tag('span', 'Pro');
# Standalone badges open the feature details; nested badges keep the outer link.
$label = ui_tag('a', $label, {
	href => 'https://www.cloudmin.com/docs/professional-features/#'.$feature,
	target => '_blank', rel => 'noopener noreferrer', 'data-pro' => $feature }) if (!$plain);
return ui_tag('span', '&nbsp;&nbsp;'.ui_tag('small', $label),
	{'data-pro-disabled' => $feature.'-link'});
}

# pro_feature_preview(html, [feature]) disables the supplied controls.
# feature adds muted styling; omit it when controls are styled individually.
# The fieldset keeps controls disabled when JavaScript changes individual flags.
sub pro_feature_preview
{
my ($html, $feature) = @_;
return ui_tag('fieldset', $html, {disabled => undef,
	$feature ? ('data-pro-disabled' => $feature.'-elem') : (),
	style => 'border:0;padding:0;margin:0;min-width:0'});
}

# pro_feature_tip(feature) explains a preview and links to its documentation.
# feature selects both the translated description and documentation anchor.
sub pro_feature_tip
{
my ($feature) = @_;
return ui_alert_box(html_escape($text{'pro_tip_'.$feature}).' '.
	ui_tag('a', html_escape($text{'pro_learn'}), {
		href => 'https://www.cloudmin.com/docs/professional-features/#'.$feature,
		target => '_blank', rel => 'noopener noreferrer' }),
	'success', undef, undef, $text{'pro_feature'});
}

1;
