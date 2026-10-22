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
require './cloudmin-progress.pl';
error('Use POST to inspect or restore a backup') if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
# First inspect the archive; only a confirmed inspection can start restore.
my $action = $in{'inspection'} ? 'restore' : 'backup_inspect';
my $job = eval { call_vm_api(1,$action,{%in,target => parse_backup_target(\%in,'src')}) };
error(error_html(error_message($@))) if (!$job);
show_machine_progress({job => $job->{'id'}});
