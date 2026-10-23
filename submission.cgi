#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, $remote_user, $module_var_directory);
require './server-manager-lib.pl';
my $result;
my $ok = eval {
    # Reject unauthorized or oversized requests before parsing form input.
    require_access('host');
    die "Changes are disabled in read-only mode\n" if (is_readonly_mode());
    die "Submission checks require POST\n" if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
    die "Request is too large\n" if (($ENV{'CONTENT_LENGTH'} || 0) > 16384);
    ReadParse();
    require './cloudmin-submission-lib.pl';
    $result = prepare_submission(\%in);
    1;
};
# Return a fresh decision or a safe error, never a cacheable form response.
my $error = error_message($@) if (!$ok);
print "Cache-Control: no-store\r\n";
print_json($ok ? $result : { error => $error }, 0, 1);
