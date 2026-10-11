# Shared distribution labels and grouped image selectors.
use strict;
use warnings;
use File::Basename ();
use Cwd ();
require(Cwd::abs_path(File::Basename::dirname(__FILE__).'/lib/Cloudmin/ImageChoices.pm'));
our %text;

# get_image_group(image, [fallback])
# Uses catalogue distribution names, with a translated label for unknown images.
# fallback defaults to the translated Other images label.
sub get_image_group
{
my ($image, $fallback) = @_;
# Captures need their own group even when the source OS is known.
return $text{'vm_image_captures'} if (($image->{'source'} || '') eq 'vm');
return $image->{'os'} || $fallback || $text{'vm_image_other'};
}

# get_image_icon(image)
# Returns a module-relative SVG path from the image's OS and catalogue origin.
# Only names in this map can select files; catalogue values cannot supply paths.
sub get_image_icon
{
my ($image) = @_;
my %icons = (
	'AlmaLinux' => 'alma', 'Alpine Linux' => 'alpine', 'Arch Linux' => 'arch',
	'CentOS Stream' => 'centos', 'Debian' => 'debian', 'Fedora' => 'fedora',
	'openSUSE Leap' => 'suse', 'openSUSE Tumbleweed' => 'suse',
	'Rocky Linux' => 'rocky', 'Ubuntu' => 'ubuntu',
);
# Custom and unrecognized images use the module's generic disk icon.
my $icon = ($image->{'catalogue_origin'} || '') eq 'custom' ? 'custom'
	: $icons{$image->{'os'} || ''} || 'custom';
return 'images/os/'.$icon.'.svg';
}

1;
