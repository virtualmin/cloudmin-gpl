#!/usr/local/bin/perl
# Prints nothing - exists only because the file manager expects it

require './server-manager-lib.pl';

&print_content_type("text/plain");
print "0\n";

