#!/usr/local/bin/perl
use strict;
use warnings;
our %in;
require './server-manager-lib.pl';
require './cloudmin-status-lib.pl';
local $main::error_must_die = 1;
my ($result, $error);
# This endpoint discovers or starts the shared channel; it does not poll guests.
eval {
	die "Request is too large\n" if (($ENV{'CONTENT_LENGTH'} || 0) > 2048);
	ReadParse();
	$result = start_status();
	};
$error = error_message($@) if ($@);
print "Cache-Control: no-store\r\n";
print_json($error ? { error => $error } : $result, 0, 1);
