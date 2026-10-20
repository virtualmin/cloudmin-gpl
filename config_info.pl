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

1;
