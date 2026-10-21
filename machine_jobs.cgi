#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
# Job history and recovery are not part of delegated VM power controls.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'vm_jobs_err'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
# Theme navigation is a page load unless a job control was submitted.
if (($ENV{'REQUEST_METHOD'} || '') eq 'POST' && $in{'action'}) {
	my $ok = eval {
		die "Unknown virtual machine job action\n"
			if ($in{'action'} !~ /\A(?:cancel|recover|discard)\z/);
		call_vm_api(1, $in{'action'}, \%in);
		1;
		};
	error(error_html(error_message($@))) if (!$ok);
	}
# Old bookmarks and cached forms share the live Active Jobs view.
redirect('jobs.cgi');
