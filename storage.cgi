#!/usr/local/bin/perl

use strict;
use warnings;

our (%in, %text, $remote_user, $module_root_directory);

# Initialize Webmin and load storage inventory under the user's module ACL.
require './server-manager-lib.pl';
# Storage inventory includes volumes outside any one VM assignment.
error($text{'acl_denied'}) if (!can_access('host'));
require './cloudmin-storage-lib.pl';
require './cloudmin-storage-pages.pl';

error_setup($text{'storage_error'});
error($text{'storage_form_large'}) if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();
# Explicit links and pool actions take precedence over the remembered tab.
my $explicit_tab = $in{'tab'} || ($in{'action'} || $in{'pool'} ? 'pools' : '');
my $tab = inventory_tab('storage', $explicit_tab ? 'storage_'.$explicit_tab : undef);
$tab =~ s/^storage_//;
my ($deletion, $pool_review);
if (($in{'action'} || '') eq 'review_pool') {
	# Review ownership and any required stop without changing the pool.
	$tab = 'pools';
	$pool_review = eval {
		check_storage_request(\%in);
		# Offer Stop and Unregister when needed; only submission permits it.
		my (undef, $record) = get_storage_service(1)->review_pool($in{'id'}, 1);
		$record;
		};
	error(error_html(error_message($@))) if (!$pool_review);
	}
elsif (($in{'action'} || '') eq 'review_volumes') {
	# Selection is a POST, but only the separately confirmed POST deletes.
	$tab = 'volumes';
	$deletion = eval { review_storage_volumes(\%in) };
	error(error_html(error_message($@))) if (!$deletion);
	}
elsif ($in{'action'}) {
	# Report failed changes through Webmin's error page.
	my $ok = eval { change_storage($in{'action'}, \%in); 1 };
	# Reload after a change to prevent resubmission. A removed registration
	# must not remain the focused pool.
	if ($ok) {
		redirect('storage.cgi?tab='.$tab.($in{'id'} && $in{'action'} ne 'delete_volumes' && $in{'action'} ne 'unregister' ? '&pool='.urlize($in{'id'}) : ''));
		exit;
		}
	error(error_html(error_message($@)));
	}
my $service;
my $data = eval { $service = get_storage_service(); $service->inventory() };
$data = { error => error_message($@) } if (!$data);
my $token = is_readonly_mode() ? '' : get_image_jobs()->form_token($remote_user);
if ($token && $data->{'local'}) {
	# Group discovery is needed only for the local creation form. Its failure
	# must not hide existing pools or prevent directory-pool creation.
	$data->{'lvm_groups'} = eval { $service->lvm_groups() };
	$data->{'lvm_group_error'} = error_message($@) if ($@);
	}
ui_print_header(undef, $text{'storage_title'}, '', 'storage');
print ui_page_start({ class => 'cloudmin-storage-page' });
print ui_tag('link', undef, { rel => 'stylesheet',
	href => 'storage.css?'.(stat("$module_root_directory/storage.css"))[9] });
print show_storage_page($data, $token, $tab, \%in, undef, $in{'pool'} || $in{'id'}, $deletion, $pool_review);
# Reviews have no inventory tab selection to remember.
print inventory_tab_script('storage', $token) if (!$deletion && !$pool_review);
print ui_page_end();
ui_print_footer();
