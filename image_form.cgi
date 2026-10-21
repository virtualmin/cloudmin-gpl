#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text);
require './server-manager-lib.pl';
# Image imports require access to host storage and the catalogue.
error($text{'acl_denied'}) if (!can_access('host'));
ReadParse();
print_image_manager($in{'mode'} || 'add');
