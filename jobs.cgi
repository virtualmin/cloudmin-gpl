#!/usr/local/bin/perl

use strict;
use warnings;
use Digest::SHA ();
our (%in, %text, $module_root_directory, $remote_user);
require './server-manager-lib.pl';
# Background jobs can expose host resources outside a delegated VM scope.
error($text{'acl_denied'}) if (!can_access('host'));
error('Form is too large') if (($ENV{'CONTENT_LENGTH'} || 0) > 65536);
ReadParse();

# Buttons submit signed requests directly; navigation never changes a job.
if ($in{'action'}) {
	require "$module_root_directory/cloudmin-job-actions.pl";
	error_setup($text{'jobs_action_error'});
	my $ok = eval { change_job_action(\%in); 1 };
	error(error_html(error_message($@))) if (!$ok);
	redirect('jobs.cgi');
	exit;
	}

# Refresh only the status content; never start, recover or cancel work here.
my $data = get_active_jobs();
# Completed work remains available in the existing host action log.
$data->{'log_url'} = get_action_log_url() if (foreign_available('webminlog'));
# Keep progress readable if the token store is unavailable, without controls.
if ($data->{'can_control'}) {
	$data->{'token'} = eval { get_image_jobs()->form_token($remote_user) };
	if (!$data->{'token'}) {
		# Without a signed token, show diagnostics
		# but no action buttons.
		$data->{'can_control'} = 0;
		push(@{$data->{'errors'}},
		     text('jobs_error_image', error_message($@)));
		}
	}
if ($in{'refresh'}) {
	# Fragment responses skip the page header that normally
	# loads theme widgets.
	load_theme_library();
	print "Cache-Control: no-store\r\n";
	# Stable revisions avoid replacing unchanged widgets just because HTML
	# attributes were serialized in a different order by
	# another CGI process.
	my $revision = Digest::SHA::sha256_hex(
		convert_to_json($data, 1, 1));
	print_json({ html => show_jobs_status($data), revision => $revision },
		   0,
		   1);
	exit;
	}
ui_print_header(undef, $text{'index_jobs'}, '');
my $css_version = (stat("$module_root_directory/jobs.css"))[9] || 0;
print ui_tag('link', undef,
	     { rel => 'stylesheet', href => 'jobs.css?'.$css_version });
$data->{'refresh_url'} = get_webprefix().'/server-manager/jobs.cgi?refresh=1';
print show_jobs_page($data);
my $version = (stat("$module_root_directory/jobs.js"))[9] || 0;
print ui_tag('script', '', { src => 'jobs.js?'.$version });
ui_print_footer();
