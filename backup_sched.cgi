#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
require './cloudmin-backup-pages.pl';
# Bound form parsing and require host access before exposing backup settings.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'backup_save_error'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
# Use the delete error prefix only after the submitted action is available.
error_setup($text{'backup_delete_schedule_error'}) if ($in{'delete'});
# Check POST, write permission, licensing and CSRF before changing a schedule.
my $ok = eval {
 die "Use POST for backup changes\n" if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
 die "Backup changes are disabled in read-only mode\n" if (is_readonly_mode());
 get_image_jobs()->check_token($remote_user,$in{'token'});
 require_access('manage');
 $in{'target'} = parse_backup_target(\%in,'dest0');
 save_backup_schedule({%in, %{parse_backup_time(\%in)}});
 1;
};
error(error_html(error_message($@))) if (!$ok);
redirect('backups.cgi');
