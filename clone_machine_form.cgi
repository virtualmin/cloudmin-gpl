#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
# Copying disks and credentials requires host administrator access.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'vm_clone_error'});
error($text{'vm_manage_readonly'}) if (is_readonly_mode());
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
# Validate the source before rendering its choices or issuing a form token.
my $source = eval { call_vm_api(1, 'clone_options', {id => $in{'id'}}) };
error(html_escape(error_message($@))) if (!$source);
ui_print_header(html_escape($source->{'name'}), $text{'vm_clone_button'}, '', 'clone_machine_form');
print show_vm_clone_form($source, get_image_jobs()->form_token($remote_user));
# Share retry handling with creation without submitting while opening the form.
print submission_script();
ui_print_footer('machine.cgi?id='.urlize($source->{'id'}), $text{'vm_view'});
