use strict;
use warnings;
our (%in, %text);
require 'server-manager-lib.pl';

# Webmin passes the saved value and config.info metadata to custom widgets.
# Save hooks read submitted controls from %in; old_value is unused below.
# show_cloudmin_fields(value, label, type, handler, key)
# Shows optional columns or initially expanded sections in their display order.
sub show_cloudmin_fields
{
my ($value, undef, undef, undef, $key) = @_;
# Required fields remain selected and disabled in the editor.
my %selected = map { $_->[0] => 1 } view_selection($key, $value);
my @rows = map { ui_checkbox($key.'_'.$_->[0], 1, $text{$_->[1]},
	$selected{$_->[0]} ? 1 : 0, undef, $_->[3]) } view_fields($key);
return ui_grid(\@rows, { min => '180px' });
}

# parse_cloudmin_fields(old_value, label, type, handler, key)
# Saves known checkbox choices, retaining required columns.
sub parse_cloudmin_fields
{
my (undef, undef, undef, undef, $key) = @_;
return join(',', map { $_->[0] }
	grep { $_->[3] || $in{$key.'_'.$_->[0]} } view_fields($key));
}

# show_cloudmin_number(value, label, type, handler, key)
# Shows a whole-number setting with the same bounds used by its save parser.
sub show_cloudmin_number
{
my ($value, undef, undef, undef, $key) = @_;
my (undef, $min, $max) = number_setting($key);
return ui_tag('input', undef, { type => 'number', name => $key, id => $key,
	class => 'ui_textbox', value => config_number($key, $value),
	min => $min, max => $max, step => 1, required => undef,
	style => 'width:8em', inputmode => 'numeric' });
}

# parse_cloudmin_number(old_value, label, type, handler, key)
# Rejects invalid values before Webmin saves any of this section's settings.
sub parse_cloudmin_number
{
my (undef, $label, undef, undef, $key) = @_;
my (undef, $min, $max) = number_setting($key);
# Validate the POST independently of the browser's numeric input constraints.
my $value = $in{$key} // '';
$value =~ s/^\s+|\s+$//g;
error(text('config_number_error', $label, $min, $max))
	if ($value !~ /\A\d{1,10}\z/ || $value < $min || $value > $max);
return 0 + $value;
}

# show_image_max_size(value)
# Offers an optional import cap; available storage remains the default limit.
sub show_image_max_size
{
my ($value) = @_;
return ui_opt_textbox('image_max_size', $value || '', 8,
	$text{'config_image_space'});
}

1;
