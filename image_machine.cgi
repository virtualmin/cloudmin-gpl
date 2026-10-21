#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text);
require './server-manager-lib.pl';
require './cloudmin-progress.pl';
# The controller enforces Pro, CSRF, source reservations and read-only access.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'vm_image_error'});
# Bound parsing before handing the form to the shared submission controller.
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
submit_machine('capture_image');
