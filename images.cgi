#!/usr/local/bin/perl

use strict;
use warnings;

our (%in, %text, $remote_user);

# Initialize Webmin and load the image catalogue under the user's module ACL.
require './server-manager-lib.pl';
# VM assignments grant no access to the host image inventory.
error($text{'acl_denied'}) if (!can_access('host'));
ReadParse();

print_image_manager($in{'mode'});
