# Render only synthetic form data for browser upload checks.
use strict;
use warnings;
use FindBin qw($Bin);
# Use an installed Webmin tree on test hosts or the sibling checkout locally.
use lib ($ENV{'WEBMIN_ROOT'} || "$FindBin::Bin/../../webmin");
use WebminCore;
our (%text, $root_directory, $ui_page_assets_done);
$root_directory = $ENV{'WEBMIN_ROOT'} || "$Bin/../../webmin";
$ui_page_assets_done = 1;
open(my $lang, '<', "$Bin/../lang/en") or die $!;
while (<$lang>) { $text{$1} = $2 if /^([^=]+)=(.*)/; }
close($lang);
require "$Bin/../cloudmin-pages.pl";
print show_images_page({ mode => 'add', images => [
	{ id => 'size-a', name => 'Size A',
	  download_size_bytes => 1024**3,
	  download_size_refresh => 0 },
	{ id => 'size-b', name => 'Size B',
	  download_size_bytes => 512 * 1024**2,
	  download_size_refresh => 0 },
	{ id => 'size-unknown', name => 'Unknown size',
	  download_size_refresh => 1 },
], catalogue => [ ], jobs => [ ],
			 pools => [ { id => 'fixture-pool', name => 'default',
				      available => 1024**3 } ],
			 token => 'fixture-token' });
