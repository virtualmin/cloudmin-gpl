package Cloudmin::ImageChoices;

# Shared ordering for catalogue entries and imported image choices.
use strict;
use warnings;
use WebminCore qw(compare_version_numbers);

# sort_images(images) Keeps distributions together, newest releases first, then
# unclassified images. Returns a new array; support status does not split
# distribution groups.
sub sort_images
{
my ($images) = @_;
return [ sort {
	!length($a->{'os'} || '') <=> !length($b->{'os'} || '') ||
		lc($a->{'os'} || '') cmp lc($b->{'os'} || '') ||
		compare_version_numbers($b->{'release'} || '',
					$a->{'release'} || '') ||
		lc($a->{'name'} || '') cmp lc($b->{'name'} || '') ||
		lc($a->{'architecture'} ||
		   '') cmp lc($b->{'architecture'} || '')
	} @$images ];
}

1;
