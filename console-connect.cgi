#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
require './cloudmin-console-lib.pl';
local $main::error_must_die = 1;
my ($result, $error);
eval {
	# Opening a keyboard connection requires a signed POST, including
	# reconnects.
	die "Use the console page to connect\n"
		if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
	die "Form is too large\n" if (($ENV{'CONTENT_LENGTH'} || 0) > 4096);
	ReadParse();
	# Require this VM's console grant before token lookup or route allocation.
	# Read-only accounts cannot connect even if a grant or token is present.
	die "$text{'console_readonly'}\n" if (is_readonly_mode());
	require_access('console', $in{'id'});
	get_image_jobs()->check_token($remote_user, $in{'token'});
	my $vm = get_libvirt()->get_domain($in{'id'}, 1)
		|| die "Virtual machine not found\n";
	# The launcher checks the mode and device before allocating a route.
	$result = start_console($vm, $in{'mode'});
	};
$error = error_message($@) if ($@);
print "Cache-Control: no-store\r\n";
print_json($error ? { error => $error } : $result, 0, 1);
