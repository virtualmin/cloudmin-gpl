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

1;
