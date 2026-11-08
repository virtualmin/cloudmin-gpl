#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
require './cloudmin-backup-pages.pl';
# Bound form parsing and require host access before exposing backup settings.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'backup_delete_error'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
# Check POST, write permission, licensing and CSRF before reviewing deletion.
my $ok = eval {
	die "Use POST for backup changes\n"
		if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	die "Backup changes are disabled in read-only mode\n"
		if (is_readonly_mode());
	get_image_jobs()->check_token($remote_user, $in{'token'});
	require_access('manage');
	get_backup_service()->record($in{'backup'}) || die "Backup not found\n";
	delete_cloudmin_backup($in{'backup'}) if ($in{'confirm'});
	1;
	};
error(error_html(error_message($@))) if (!$ok);
# Require a second POST naming the selected archive before deleting it.
if (!$in{'confirm'}) {
	ui_print_header(undef, $text{'backup_delete_button'}, '');
	print ui_confirmation_form('delete_backup.cgi',
				   $text{'backup_delete_confirm'},
				   [ [ 'token', $in{'token'} ], [ 'backup',
								  $in{'backup'} ] ],
				   [ [ 'confirm',
				       $text{'backup_delete_button'} ] ],
				   '<tt>'.
				   html_escape(
					   get_backup_service()->record(
						   $in{'backup'})->{'filename'}).
				   '</tt>');
	ui_print_footer('backups.cgi', $text{'backups_return'});
	exit;
	}
redirect('backups.cgi');
