#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, %config, $remote_user);
require './server-manager-lib.pl';
# VM delegation covers existing guests, not creation on the host.
error($text{'acl_denied'}) if (!can_access('host'));
error_setup($text{'vm_create_err'});
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 131072);
ReadParse();
error('Virtual machine changes are disabled in read-only mode')
	if (is_readonly_mode());
my $token = get_image_jobs()->form_token($remote_user);
# Never populate password or license fields from request parameters.
delete(
	@in{qw(password password_again password_hash virtualmin_serial virtualmin_key)});
# Template and inventory failures use the error page before the normal header.
my $options = eval {
	# Reject old links to templates disabled by the host's
	# installation policy.
	get_presets()->get('template', $in{'template'}) if ($in{'template'});
	call_vm_api(1, 'options', { });
	};
error(html_escape(error_message($@))) if (!$options);
ui_print_header(undef, $text{'vm_create'}, '', 'machine_form');
my $empty_images = !@{get_vm_form_images($options)};
$options->{'form_defaults'} = get_vm_form_defaults(\%config);
# Generate only on first opening, including a theme navigation POST.
my $generated_password = !$empty_images &&
			 $options->{'form_defaults'}->{'generate_password'}
				 ? generate_random_password()
				 : '';
print show_vm_form($options, \%in, $token, $generated_password);
# Share retry handling with other forms that launch background jobs.
print submission_script();
# The empty state already offers the next step; keep its footer uncluttered.
ui_print_footer($empty_images ? () : ( 'index.cgi', $text{'vm_return'} ));
