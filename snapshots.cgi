#!/usr/local/bin/perl
use strict;
use warnings;
our (%in, %text, $remote_user, $module_root_directory);
require './server-manager-lib.pl';
# Snapshot inventory and changes remain host-administrator operations.
error($text{'acl_denied'}) if (!can_access('host'));
require './cloudmin-snapshot-pages.pl';
error_setup($text{'snapshots_error'});
error($text{'snapshots_form_large'}) if (($ENV{'CONTENT_LENGTH'} || 0) > 16384);
ReadParse();
my $data;
if ($in{'action'}) {
	# Only a signed POST may submit work; GET links open review pages.
	my $ok = eval {
		die "Snapshot changes require POST\n" if (($ENV{'REQUEST_METHOD'} || '') ne 'POST');
		die "Unknown snapshot action\n" if ($in{'action'} !~ /\Asnapshot_(?:create|restore|delete)\z/);
		my $job = call_vm_api(1, $in{'action'}, \%in);
		redirect('progress.cgi?job='.urlize($job->{'id'}).
			(($in{'from'} || '') eq 'all' ? '&from=all' : ''));
		1;
		};
	exit if ($ok);
	error(error_html(error_message($@)));
	}
$data = eval { call_vm_api(1, 'snapshots', { id => $in{'id'} }) };
$data = { error => error_message($@) } if (!$data);
my $token = is_readonly_mode() ? '' : get_image_jobs()->form_token($remote_user);
my $view = $in{'view'} || (($in{'action'} || '') eq 'snapshot_create' ? 'create' : '');
my $title = $in{'id'} && $view =~ /\A(?:create|restore|delete)\z/
	? 'snapshots_'.$view : $in{'id'} ? 'snapshots_title' : 'snapshots_all';
ui_print_header($data->{'guest'} ? html_escape($data->{'guest'}->{'name'}) : undef,
	$text{$title}, '', 'snapshots');
print ui_page_start({ class => 'cloudmin-snapshots-page' });
print ui_tag('link', undef, { rel => 'stylesheet', href => 'snapshots.css?'.(stat("$module_root_directory/snapshots.css"))[9] });
print show_snapshots_page($data, $token, \%in);
print ui_page_end();
# Check earlier snapshot attempts before forwarding repeated form submissions.
print submission_script();
ui_print_footer($in{'id'} && $view && ($in{'from'} || '') eq 'all' ? ('snapshots.cgi', $text{'snapshots_all_return'})
	: $in{'id'} && $view ? (snapshot_url($in{'id'}), $text{'snapshots_return'})
	: $in{'id'} ? ('machine.cgi?id='.urlize($in{'id'}), $text{'vm_view'})
	: ('index.cgi', $text{'vm_return'}));
