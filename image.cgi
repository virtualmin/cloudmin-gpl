#!/usr/local/bin/perl

use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
# Importing shared images requires host access before any form processing.
error($text{'acl_denied'}) if (!can_access('host'));

# All imports require a signed form token and POST, including AJAX submissions.
my ($records, $error);
eval {
	# Limit form size before parsing; validation below reports AJAX errors as JSON.
	die "Form is too large\n" if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
	ReadParse();
	die "$text{'image_epost'}\n"
		if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	# Imports change storage even when submitted through AJAX.
	die "$text{'image_ereadonly'}\n" if (is_readonly_mode());
	$records = start_image_imports(\%in);
	};
$error = "$@" if ($@);

# AJAX callers receive JSON; ordinary submissions use Webmin errors and
# redirects.
if ($in{'ajax'}) {
	my $retry;
	# A known failed attempt can be retried with a fresh idempotency token.
	# Keep the old token on transport failures, where completion is uncertain.
	if (!$error && $records->[0]->{'state'} eq 'failed') {
		$error = $records->[0]->{'error'} || $text{'image_failed'} || 'Image import failed';
		$retry = get_image_jobs()->form_token($remote_user);
		}
	print "Cache-Control: no-store\r\n";
	print_json($error ? { error => $error, ($retry ? (retry_token => $retry) : ()) } : {
		id => $records->[0]->{'id'}, state => $records->[0]->{'state'},
		jobs => [ map { $_->{'id'} } @$records ] }, 0, 1);
	}
else {
	# Start the progress page only after all submitted imports have been
	# accepted.
	error_setup($text{($in{'install_type'} || '') =~ /\A(?:download|url)\z/
		? 'images_download_err' : 'images_import_err'});
	error(error_html($error)) if ($error);
	redirect('setup_image.cgi?job='.
		join(',', map { $_->{'id'} } @$records));
	}
