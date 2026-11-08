use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
our (%in, %text, $root_directory);
$root_directory = $CloudminTest::webmin_root;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { $text{$1} = $2 if /^([^=]+)=(.*)/; }
close($lang);
require "$Bin/../cloudmin-pages.pl";

# Load only config widgets; workstation tests must not initialize Webmin.
$INC{'server-manager-lib.pl'} = 1;
require "$Bin/../config_info.pl";
my @defaults = map { $_->{'id'} } list_catalogue_columns();
for my $value ( undef, '', 'unknown-column' ) {
	is_deeply([ map { $_->{'id'} } get_catalogue_columns($value) ],
		  \@defaults,
		  'old or invalid settings retain the complete default table');
	}
is_deeply(
	[ map { $_->{'id'} } get_catalogue_columns('state,size,size,unknown') ],
	[ qw(name size state) ],
	'selection retains the name, removes duplicates and uses display order');
%in = ( cataloguecol_size => 1, cataloguecol_state => 1,
	cataloguecol_unknown => 1 );
is(parse_catalogue_columns(''), 'name,size,state',
   'config parser saves only known selected columns');
%in = ();
is(parse_catalogue_columns(''), 'name',
   'clearing optional columns leaves the entry link');
my $widget = show_catalogue_columns('name,size');
like($widget,
     qr/<input\b(?=[^>]*name=['"]cataloguecol_name['"])(?=[^>]*checked)(?=[^>]*disabled)/,
     'the required Image column is visibly checked and locked');
like($widget,
     qr/<input\b(?=[^>]*name=['"]cataloguecol_size['"])(?=[^>]*checked)/,
     'configuration reopens with the saved size selection');
unlike($widget,
       qr/<input\b(?=[^>]*name=['"]cataloguecol_state['"])(?=[^>]*checked)/,
       'unselected columns stay unchecked');

# Capture the table contract to check alignment and sorting
# for configured views.
my ($heads, $rows, $types);
{
	no warnings 'redefine';
	local *main::ui_form_columns_table = sub {
		($heads, $rows, $types) = @_[5, 7, 8];
		return '';
		};
	my $entry = { catalogue_key => 'fixture:aarch64', name => 'Fixture',
		      os => 'Linux', release => '1', architecture => 'aarch64',
		      format => 'qcow2',
		      download_size_bytes => 536870912, enabled => 1,
		      catalogue_origin => 'bundled' };
	show_catalogue_page({ catalogue_columns => 'state,size',
			      catalogue_entries => [ $entry ] });
	is_deeply($heads, [ '', 'Image', 'Download size', 'State' ],
		  'configured headings match the selected columns');
	is_deeply($types, [ undef, 'string', 'bytes', 'string' ],
		  'size keeps numeric byte sorting after columns are hidden');
	is(scalar(@{$rows->[0]}), scalar(@$heads),
	   'data cells align with selected headings');
	is($rows->[0]->[0]->{'value'}, 'fixture:aarch64',
	   'bulk selection keeps the correct catalogue key');
	like($rows->[0]->[1], qr/edit_catalog_image\.cgi\?key=fixture/,
	     'entry remains accessible');
	like($rows->[0]->[2]->{'value'}, qr/data-filesize-bytes="536870912"/,
	     'size carries its raw bytes for theme sorting');
	is($rows->[0]->[2]->{'td'}, 'data-order="536870912"',
	   'table cell has an exact numeric sort value');
	is($rows->[0]->[3], 'Enabled', 'state is in the correct column');
	delete($entry->{'download_size_bytes'});
	show_catalogue_page({ readonly => 1, catalogue_columns => 'size',
			      catalogue_entries => [ $entry ] });
	is($rows->[0]->[2]->{'value'}, 'Unknown',
	   'missing sizes are unknown rather than zero');
	is($rows->[0]->[0], '', 'read-only rows have no selection checkbox');
	}
done_testing();
