#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
# Check access before parsing input or accessing any user's preferences.
error($text{'acl_denied'}) if (!can_access('host') || is_readonly_mode());
# GET requests must never write a preference.
error('Use a signed POST to save a tab') if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
# The page, tab and token are small; reject oversized forms before parsing.
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 4096);
ReadParse();
# Verify the current user's token before the helper validates and saves the tab.
my $ok = eval {
	get_image_jobs()->check_token($remote_user, $in{'token'});
	save_inventory_tab($in{'page'}, $in{'tab'});
	1;
	};
# Log failures on the host; the browser shows a brief inline explanation.
warn "Cannot save inventory tab: $@" if (!$ok);
# Save results belong to this request and must not be reused by a cache.
print "Cache-Control: no-store\r\n";
print_json({ saved => $ok ? 1 : 0 }, 0, 1);
