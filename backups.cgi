#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
require './cloudmin-backup-pages.pl';
# Bound form parsing and require host access before exposing backup settings.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'backup_error'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
# Render inventory without mutation controls for read-only administrators.
my $token = is_readonly_mode() ? '' : get_image_jobs()->form_token($remote_user);
ui_print_header(undef, $text{'backups_title'}, '', 'backups');
my $html = eval { show_backup_list($token) };
error(html_escape(error_message($@))) if (!defined($html));
print $html;
ui_print_footer('index.cgi', $text{'vm_return'});
