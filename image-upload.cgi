#!/usr/local/bin/perl

use strict;
use warnings;
our %text;
our ($remote_user);
require './server-manager-lib.pl';

# The raw upload body is streamed, avoiding multipart buffering of large disks.
my ($error, $jobs, $id, $retry);
eval {
	# Reject delegated callers before reading upload bytes
	# or creating job files.
	require_access('host');
	# Validate the method and permissions before consuming the upload body.
	die "Upload requires POST\n"
		if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	# Read-only users may view images but cannot supply disk contents.
	die "Image imports are disabled in read-only mode.\n"
		if (is_readonly_mode());
	$jobs = get_image_jobs();
	$jobs->check_token($remote_user, $ENV{'HTTP_X_CLOUDMIN_TOKEN'});
	($id) = ($ENV{'QUERY_STRING'} || '') =~ /\Ajob=([a-f0-9]{32})\z/;
	# The query identifies one previously authorized upload job.
	die "Invalid image job\n" if (!$id);
	# MiniServ's tied input handle is already binary and
	# has no BINMODE method.
	$jobs->receive($id, $remote_user, \*STDIN, $ENV{'CONTENT_LENGTH'});
	};
$error = "$@" if ($@);
if ($error && $id && $jobs) {
	# Only an owned, terminal failure permits a new attempt
	# after upload errors.
	eval {
		my $job = $jobs->get($id, $remote_user);
		$retry = $jobs->form_token($remote_user)
			if ($job->{'state'} eq 'failed');
		};
	}
print "Cache-Control: no-store\r\n";
print_json($error
	? { error => $error, ($retry ? ( retry_token => $retry ) : ()) }
	: { ok => 1 }, 0, 1);
