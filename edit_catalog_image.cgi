#!/usr/local/bin/perl

use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
# Catalogue configuration remains host-only, including read-only viewing.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'catalogue_edit_err'});
ReadParse();

# Editing a disabled entry is allowed; creating entries requires write access.
my $readonly = is_readonly_mode();
error($text{'catalogue_ereadonly'}) if ($readonly && $in{'new'});
my $entry;
eval {
	$entry = $in{'new'} ? {
		id => 'custom-'.substr(Cloudmin::Images::generate_id(), 0, 16),
		architecture => get_host_image_architecture(),
		status => 'supported',
	} : get_image_catalogue()->find_entry($in{'key'});
	die "Catalogue entry no longer exists\n" if (!$entry);
	$entry->{'download_size_bytes'} =
		get_image_sizes()->get($entry)->{'bytes'}
		if (!$in{'new'});
	};
error(html_escape("$@")) if ($@);
$readonly ||= $entry->{'catalogue_origin'} && $entry->{'catalogue_origin'}
	eq 'bundled';
my $token = $readonly ? '' : get_image_jobs()->form_token($remote_user);
ui_print_header(undef,
	$text{$in{'new'} ? 'catalogue_add' : $readonly ? 'catalogue_details'
	: 'catalogue_edit'}, '');
print show_catalogue_form($entry, $in{'new'}, $token, undef, $readonly);
ui_print_footer('images.cgi?mode=catalogue', $text{'images_return'});
