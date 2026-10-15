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

# show_disk_location(path, [local])
# Keeps full storage filenames available without making them the disk heading.
# local defaults to true; remote paths must not open this host's File Manager.
sub show_disk_location
{
my ($path, $local) = @_;
return '' if (!length($path || ''));
return ui_details({ html => 1, class => 'inline inlined',
	title => html_escape($text{'vm_disk_location'}),
	content => !defined($local) || $local ? show_image_path($path) : ui_tag('tt', html_escape($path)) });
}

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

# show_image_path(path)
# Shows a file path and links to its allowed File Manager directory when
# available.
sub show_image_path
{
my $path = $_[0] || '';
my $label = ui_tag('tt', html_escape($path));
return $label if ($path !~ m{^/});
my $dir = $path;
$dir =~ s{/[^/]+$}{};
$dir ||= '/';
return show_filemin_directory($dir, $label);
}

# show_filemin_directory(dir, [label])
# Links a local directory within the user's File Manager roots. An optional
# HTML label lets image paths retain their full filename.
sub show_filemin_directory
{
my ($dir, $label) = @_;
$label = ui_tag('tt', html_escape($dir)) if (!defined($label));
# Missing modules, denied access and non-filesystem paths stay plain text.
return $label if ($dir !~ m{^/} || !foreign_available('filemin'));
foreign_require('filemin', 'filemin-lib.pl');
my @allowed = filemin::get_allowed_paths($dir);
foreach my $root (@allowed) {
	# Do not link a directory outside the user's File Manager roots.
	next if (!is_under_directory($root, $dir));
	my $relative = $dir;
	if (@allowed == 1 && $root ne '/') {
		# File Manager resolves relative paths under its sole allowed
		# root. Resolve aliases before making the requested path
		# relative to it.
		$relative = resolve_links($dir);
		my $base = resolve_links($root);
		$relative =~ s{^\Q$base\E}{};
		}
	return ui_link('../filemin/index.cgi?path='.
		urlize($relative || '/'), $label, 'text-link');
	}
return $label;
}

# list_catalogue_columns()
# Defines available columns and their sort types in the table's display order.
sub list_catalogue_columns
{
return (
	{ id => 'name', label => 'images_name', type => 'string' },
	{ id => 'os', label => 'catalogue_os_release', type => 'string' },
	{ id => 'architecture', label => 'catalogue_architecture',
	  type => 'string' },
	{ id => 'format', label => 'image_format', type => 'string' },
	{ id => 'size', label => 'catalogue_download_size', type => 'bytes' },
	{ id => 'checksum', label => 'image_verification', type => 'string' },
	{ id => 'release_date', label => 'catalogue_release_date',
	  type => 'string' },
	{ id => 'end_of_life', label => 'catalogue_end_of_life',
	  type => 'string' },
	{ id => 'origin', label => 'catalogue_origin', type => 'string' },
	{ id => 'state', label => 'index_state', type => 'string' },
	{ id => 'download', label => 'catalogue_download', type => undef },
);
}

# get_catalogue_columns([value])
# Filters a stored column list; missing or invalid settings use all columns.
# value is a comma- or whitespace-separated list of IDs; name always remains.
sub get_catalogue_columns
{
my ($value) = @_;
my @defs = list_catalogue_columns();
my %wanted = map { $_ => 1 } split(/[,\s]+/, $value || '');
my @columns = grep { $wanted{$_->{'id'}} } @defs;
# An empty or unrecognized selection uses the complete default table.
return @defs if (!@columns);
$wanted{'name'} = 1;
return grep { $wanted{$_->{'id'}} } @defs;
}

# catalogue_link(url, [label])
# Shows the full URL, or a compact download button when a label is supplied.
sub catalogue_link
{
my ($url, $label) = @_;
# Optional publisher links should not produce empty anchors.
return '' if (!$url);
return ui_tag('a', defined($label)
	? ui_svg_icon('download').' '.html_escape($label)
	: html_escape($url),
	{ href => $url, target => '_blank', rel => 'noopener noreferrer',
	  defined($label) ? (class => 'ui_link', download => '') : () });
}

# describe_architecture([architecture])
# Returns a short human-readable CPU architecture label.
sub describe_architecture
{
my ($architecture) = @_;
# Translate the common libvirt names to the labels used throughout the
# UI.
return 'x86-64' if (($architecture || '') eq 'x86_64');
return 'ARM64' if (($architecture || '') eq 'aarch64');
return 'ARMv7' if (($architecture || '') eq 'armv7l');
return $architecture || $text{'index_unknown'};
}

# show_resource_placeholder(field, [total]) shows capacity while usage loads.
sub show_resource_placeholder
{
my ($field, $total) = @_;
return ui_tag('span', html_escape(defined($total)
	? text('vm_usage_missing', $total) : $text{'vm_usage_unavailable'}),
	{ 'data-vm-resource' => $field, title => $text{'vm_usage_'.$field} });
}

1;
