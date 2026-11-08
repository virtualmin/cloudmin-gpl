#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user, $module_root_directory);
require './server-manager-lib.pl';
# Both the capture form and its GPL preview require host-administrator access.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'vm_image_error'});
# Host visibility alone does not grant permission to capture a guest.
error($text{'vm_manage_readonly'}) if (is_readonly_mode());
# Reject oversized requests before parsing source-selection fields.
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
# The preview preference also applies to direct GPL page requests.
my $preview = !-r "$module_root_directory/pro/VMImages.pm";
error($text{'acl_denied'}) if ($preview && !show_pro_features());
# GPL uses clone metadata to show the form without loading the Pro service.
my $source = eval { $preview
	? call_vm_api(1, 'clone_options', { id => $in{'id'} })
	: call_vm_api(1, 'image_options', { id => $in{'id'} }) };
# A missing or inaccessible source cannot provide a valid form or preview.
error(html_escape(error_message($@))) if (!$source);
require "$module_root_directory/cloudmin-image-pages.pl";
# Render the same fields in both editions, with an explanation for GPL previews.
ui_print_header(html_escape($source->{'name'}), $text{'vm_image_title'}, '',
		'image_machine_form');
print pro_feature_tip('image-capture') if ($preview);
# Only an enabled form receives a capture token and retry-aware submission code.
print show_vm_image_form($source, $preview
	? ''
	: get_image_jobs()->form_token($remote_user), $preview);
print submission_script() if (!$preview);
ui_print_footer('machine.cgi?id='.urlize($source->{'id'}), $text{'vm_view'});
