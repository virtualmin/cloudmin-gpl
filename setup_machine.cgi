#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text);
require './server-manager-lib.pl';
require './cloudmin-progress.pl';
# Only host administrators may create a guest and view its streamed progress.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'vm_progress_err'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
submit_machine('create');
