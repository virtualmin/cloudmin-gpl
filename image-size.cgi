#!/usr/local/bin/perl

use strict;
use warnings;
our %text;
our (%in);
require './server-manager-lib.pl';
ReadParse();

# Only enabled catalogue entries for this host may trigger a metadata lookup.
my ($result, $error);
eval {
	# Delegated page requests must not open the cache or trigger a host size probe.
	require_access('host');
	my $entry = get_available_server_image($in{'id'});
	die "Image is not available on this host\n" if (!$entry);
	my $sizes = get_image_sizes();
	$result = is_readonly_mode() ? $sizes->get($entry)
		: $sizes->refresh($entry);
	$result = { bytes => $result->{'bytes'},
		checked => $result->{'checked'} };
	};
$error = "$@" if ($@);
print "Cache-Control: no-store\r\n";
print_json($error ? { error => $error } : $result, 0, 1);
