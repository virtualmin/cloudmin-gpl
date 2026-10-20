#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, $remote_user);
require './server-manager-lib.pl';
my ($result, $error);
my $ok = eval {
	# Bound memory use before either JSON or form parsing reads the body.
	die "Request is too large\n" if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
	if (($ENV{'CONTENT_TYPE'} || '') =~ m{^application/json(?:;|$)}i) {
		# JSON callers supply one bounded object, never an arbitrary
		# list or scalar.
		my $body = '';
		my $length = $ENV{'CONTENT_LENGTH'} || 0;
		die "Incomplete JSON request\n"
			if (read_fully(\*STDIN, \$body, $length) != $length);
		my $input = convert_from_json($body);
		die "Request must be a JSON object\n"
			if (ref($input) ne 'HASH');
		%in = %$input;
		}
	else {
		# Retain Webmin form parsing for browser and form-encoded API
		# callers.
		ReadParse();
		}
	my $action = $in{'action'} || 'options';
	# Read operations allow GET; all other actions require POST and a signed
	# token.
	die "Use POST for virtual machine changes\n"
		if ($action !~ /\A(?:options|machines|settings|status|list|snapshots|clone_options|image_options|backups|bridges|bridge_status|storage|license)\z/ &&
		($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	$result = call_vm_api($in{'version'} || '1', $action, \%in);
	# Administrators and users with action grants get tokens unless read-only.
	$result->{'token'} = get_image_jobs()->form_token($remote_user)
		if ($action eq 'options' && !is_readonly_mode() &&
		(can_access('host') || grep { $_ } values %{access_policy()->{'grants'}}));
	1;
	};
$error = error_message($@) if (!$ok);
print "Cache-Control: no-store\r\n";
print_json({ version => 1, $ok ? (result => $result) : (error => $error) }, 0,
	1);
