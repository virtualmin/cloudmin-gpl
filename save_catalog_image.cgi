#!/usr/local/bin/perl

use strict;
use warnings;
our (%in, %text, $remote_user);
require './server-manager-lib.pl';
# Refuse delegated users before processing shared catalogue changes.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'catalogue_save_err'});

# Enforce write access and the signed token before validating catalogue fields.
error($text{'catalogue_epost'}) if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
error($text{'catalogue_ereadonly'}) if (is_readonly_mode());
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
my $jobs = get_image_jobs();
eval { require_access('manage'); $jobs->check_token($remote_user,
						    $in{'token'}); };
error(error_html("$@")) if ($@);

my $ok = eval {
	save_catalogue_form(\%in);
	1;
	};
if (!$ok) {
	# Keep submitted values available when catalogue
	# validation rejects the edit.
	my $error = error_message($@);
	ui_print_header(undef,
			$text{$in{'new'} ? 'catalogue_add' : 'catalogue_edit'},
			'');
	print show_catalogue_form(\%in, $in{'new'},
				  $jobs->form_token($remote_user),
				  $error);
	ui_print_footer('images.cgi?mode=catalogue', $text{'images_return'});
	}
else {
	# Successful writes return to the catalogue with fresh data.
	redirect('images.cgi?mode=catalogue');
	}
