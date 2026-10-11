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

# show_image_select(name, value, choices, [disabled], [required])
# Adds native headings from each choice's fourth field to Webmin's select.
# Choices use [value, label, attributes, group]; an empty group has no heading.
# disabled and required default to false. Callers supply the display order.
sub show_image_select
{
my ($name, $value, $choices, $disabled, $required) = @_;
my @groups;
foreach my $choice (@$choices) {
	# Inheritance and missing-image choices stay outside distribution groups.
	my $label = $choice->[3] || '';
	push(@groups, [$label, []]) if (!@groups || $groups[-1]->[0] ne $label);
	push(@{$groups[-1]->[1]}, $choice);
}
my $content = '';
foreach my $group (@groups) {
	# ui_select does not support optgroup; reuse its escaped option markup.
	my $options = ui_select($name, $value, $group->[1]);
	$options =~ s/\A<select\b[^>]*>//;
	$options =~ s{</select>\s*\z}{};
	$content .= $group->[0] ? ui_tag('optgroup', $options, {label => html_escape($group->[0])}) : $options;
}
# Build the outer control once so its ID and validation attributes stay intact.
my $select = ui_select($name, $value, [], 1, 0, 0, $disabled, $required ? 'required' : undef);
$select =~ s{</select>}{$content</select>};
return $select;
}

1;
