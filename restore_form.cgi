#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
require './cloudmin-backup-pages.pl';
# Bound form parsing and require host access before exposing backup settings.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'restore_error'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
# Render archive selection or the verified restore confirmation.
my $token = is_readonly_mode() ? '' : get_image_jobs()->form_token($remote_user);
ui_print_header(undef, $text{'restore_title'}, '', 'restore_form');
my $html = eval { show_restore_form(\%in, $token) };
error(html_escape(error_message($@))) if (!defined($html));
print $html;
ui_print_footer('backups.cgi', $text{'backups_return'});
