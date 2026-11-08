#!/usr/local/bin/perl

use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
# Catalogue changes affect the host, not an individual assigned VM.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'catalogue_action_err'});

# Bulk catalogue changes are POST-only and use the same signed form tokens.
error($text{'catalogue_epost'}) if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
error($text{'catalogue_ereadonly'}) if (is_readonly_mode());
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
my ($catalogue, $action, @keys, @entries);
eval {
	# License admission applies to submitted changes,
	# not catalogue browsing.
	get_image_jobs()->check_token($remote_user, $in{'token'});
	require_access('manage');
	my @actions = grep { $in{$_} } qw(enable disable delete);
	$action = $in{'action'} || (@actions == 1 ? $actions[0] : '');
	# Only the catalogue's three bulk actions may reach confirmation.
	die "Invalid catalogue action\n"
		if ($action !~ /\A(?:enable|disable|delete)\z/);
	@keys = unique(grep { length } split(/\0/, $in{'key'} || ''));
	# An empty selection must not appear to complete a bulk change.
	die "$text{'catalogue_enone'}\n" if (!@keys);
	$catalogue = get_image_catalogue();
	@entries = map { $catalogue->find_entry($_) ||
		die "Catalogue entry no longer exists\n" } @keys;
	# Reject unsuitable mixed selections before asking for confirmation.
	die "$text{'catalogue_edelete'}\n"
		if ($action eq 'delete' &&
		    grep { $_->{'catalogue_origin'} ne 'custom' } @entries);
	};
error(error_html("$@")) if ($@);

# Confirm operations that discard local settings, naming every selected entry.
if ($action eq 'delete' && !$in{'confirm'}) {
	ui_print_header(undef, $text{'catalogue_'.$action}, '');
	print ui_confirmation_form(
		'catalogue.cgi', $text{'catalogue_confirm_'.$action},
		[ [ 'token', $in{'token'} ], [ 'action', $action ],
		  map { [ 'key', $_ ] } @keys ],
		[ [ 'confirm', $text{'catalogue_'.$action.'_button'} ] ],
		ui_text_color(join(', ', map {
			ui_tag('tt', html_escape($_->{'name'}.' ('.
				describe_architecture(
					$_->{'architecture'}).')'))
			} @entries), 'danger'));
	ui_print_footer('images.cgi?mode=catalogue', $text{'images_return'});
	}
else {
	# The backend rechecks entries under the lock before
	# applying the selection.
	eval { $catalogue->update_entries($action, \@keys); };
	error(error_html("$@")) if ($@);
	redirect('images.cgi?mode=catalogue');
	}
