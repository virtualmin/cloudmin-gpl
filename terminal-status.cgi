#!/usr/local/bin/perl
# Return only this user's authorized SSH attempt outcome, never login settings.
use strict;
use warnings;
our (%in, $module_root_directory);
require './server-manager-lib.pl';
require "$module_root_directory/cloudmin-terminal-lib.pl";
local $main::error_must_die = 1;
my $result = eval {
	# Validate request size and attempt ID before reading saved state.
	die "Request is too large\n" if (($ENV{'CONTENT_LENGTH'} || 0) > 2048);
	ReadParse();
	die "Invalid SSH attempt\n" if (($in{'attempt'} || '') !~ /\A[a-f0-9]{32}\z/);
	# Recheck read-only mode and terminal access before reading user state.
	die "$main::text{'terminal_readonly'}\n" if (is_readonly_mode());
	my $login = get_terminal_login($in{'id'});
	# An older attempt cannot send a newer connection back to settings.
	{state => ($login->{'attempt'} || '') eq $in{'attempt'} ?
		$login->{'state'} : 'gone'};
	};
my $error = $@;
# Polls must see current state; errors also stay inside the JSON response.
print "Cache-Control: no-store\r\n";
print_json($error ? {error => error_message($error)} : $result, 0, 1);
