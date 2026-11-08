# Progress callbacks using Virtualmin's output and indentation conventions.

use strict;
use warnings;

our ($first_print, $second_print, $indent_print, $outdent_print);
my $print_indent = 0;

# Preserve callbacks supplied by callers that capture or redirect output.
if (!defined($first_print)) {
	$first_print = \&first_html_print;
	$second_print = \&second_html_print;
	$indent_print = \&indent_html_print;
	$outdent_print = \&outdent_html_print;
	}

# first_html_print(html, [html...]) Starts a progress step with Virtualmin's
# theme markup. Escape dynamic text before calling this function, as callers may
# also supply trusted HTML.

sub first_html_print
{
print ui_tag('span', "@_", { 'data-first-print' => undef }).ui_br()."\n";
}

# second_html_print(html, [html...]) Keeps nested results compact and separates
# top-level steps with a blank line.

sub second_html_print
{
my $break = $print_indent ? '' : ui_brh();
print ui_tag('span', "@_", { 'data-second-print' => undef }).
      ui_br().$break."\n";
}

# indent_html_print() Opens a nested progress section using
# Virtualmin's theme markup.

sub indent_html_print
{
$print_indent++;
print ui_tag_start('ul', { 'data-indent-print' => undef })."\n";
}

# outdent_html_print() Closes the nested progress section opened
# by indent_html_print.

sub outdent_html_print
{
# Extra closes must not make later top-level progress appear nested.
$print_indent-- if ($print_indent);
print ui_tag_end('ul');
}

1;
