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
# Render creation or schedule settings with the current theme loaded.
my $token = is_readonly_mode()
	? ''
	: get_image_jobs()->form_token($remote_user);
ui_print_header(undef, $text{'backup_title'}, '', 'backup_form');
my $html = eval { show_backup_form(\%in, $token) };
error(html_escape(error_message($@))) if (!defined($html));
print $html;
ui_print_footer('backups.cgi', $text{'backups_return'});
