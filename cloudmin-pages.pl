# Widget-based page builders for Cloudmin.

use strict;
use warnings;
use File::Basename ();
use Cwd ();
# Keep page columns and section defaults in sync with Module Configuration.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-config-lib.pl'));
# Load ACL helpers once, even when callers use different paths.
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-access-lib.pl'));
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-image-choices.pl'));
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/cloudmin-pro-lib.pl'));
# Page builders also run outside the initialized module in rendering tests.
require(File::Basename::dirname(__FILE__).'/lib/Cloudmin/Presets.pm');
no warnings 'once';

our (%text, %config, %access, $module_root_directory, $remote_user);

require(File::Basename::dirname(__FILE__)."/cloudmin-disk-labels.pl");

# show_network_recovery(data)
# Offers recovery only for a diagnosed failure and an authorized host writer.
sub show_network_recovery
{
my ($data) = @_;
# A token, write grants and a repairable diagnosis are all required.
return '' if (!$data->{'token'} || !can_access('host') || !can_access('manage') ||
	!grep { $_->{'repairable'} } @{$data->{'readiness'}->{'checks'}});
return ui_tag('p', html_escape($text{'check_network_restore_desc'})).
	ui_form_start('index.cgi', 'post').
	ui_hidden('action', 'restore_network_rules').ui_hidden('token', $data->{'token'}).
	ui_action_button($text{'check_network_restore'}, 'primary',
		{type => 'submit', icon => 'refresh', size => 'small'}).ui_form_end();
}

# describe_image_check(job)
# Describes disk inspection and the checksum source used for this import.
sub describe_image_check
{
my ($job) = @_;
if (($job->{'source'} || '') eq 'download') {
	# Bundled and custom catalogue entries both declare a checksum source.
	my $algorithm = uc($job->{'checksum_algorithm'} || 'sha256');
	$algorithm =~ s/^SHA(?=\d)/SHA-/;
	return text(($job->{'checksum_source'} || '') eq 'catalogue'
		? 'images_check_catalogue' : 'images_check_vendor', $algorithm);
	}
elsif ($job->{'sha256'}) {
	# Custom imports compare against the checksum supplied in the form.
	return $text{'images_check_supplied'};
	}
# Disk inspection still runs when a custom import has no checksum.
return $text{'images_job_verifying'};
}

1;
