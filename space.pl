#!/usr/local/bin/perl
# Compute disk space used by system owners for backups

$main::no_acl_check++;
require './server-manager-lib.pl';
&compute_backup_space();
