#!/usr/bin/perl
# Check the image selector and ui-demo with the installed Webmin theme. Pass
# --html to render a preview containing only public catalogue choices.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;

BEGIN
{
$webmin_root = abs_path("$FindBin::Bin/../../..");
die "Disposable Linux VM only\n" unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$webmin_root/server-manager") or die $!;
$0 = "$webmin_root/server-manager/check-image-picker.pl";
}
use lib "$FindBin::Bin/../../..";
our (%text, $ui_page_assets_done, $theme_root_directory);
require './server-manager-lib.pl';
# Load the current theme's wrappers before checking the generated controls.
$ENV{'THEME_ROOT'} = $theme_root_directory;
load_theme_library();
my $data = get_images_info();
my $page = show_images_page($data);
my @rows =
	$page =~ /<div\b(?=[^>]*class="[^"]*\bui_multi_item\b)[^>]*>(.*?)<\/div>/sg;
die "Missing image rows\n" unless @rows && @rows == @{$data->{'images'}};
# Each row keeps support information in one compact badge
# without repeated labels.
for my $row (@rows) {
	my @badges = $row =~ /class="[^"]*\bui_badge\b[^"]*"/g;
	die "Expected at most one compact badge\n" unless @badges <= 1;
	die "Badge shape is wrong\n" if @badges &&
		($badges[0] !~ /ui_badge_small/ ||
		 $badges[0] !~ /ui_badge_rounded/);
	die "Redundant metadata remains\n"
		if $row =~ />ARM64<|>Bundled<|Min\. disk:|~\d/;
	die "Missing support information\n"
		unless $row =~ /Support (?:until|ended) \d{4}|Rolling updates|Support date unknown/;
	}
# Every distribution has a heading, independent of release support status.
my %groups = map { get_image_group($_) => 1 } @{$data->{'images'}};
for my $group (keys %groups) {
	my $label = html_escape($group);
	die "Missing distribution heading: $group\n"
		unless $page =~ /ui_multi_group_neutral[^>]*>.*?<span[^>]*>\Q$label\E<\/span>/s;
	}
die "Missing EOL information\n" unless $page =~ /Support ended 2026/;
die "Missing compact layout\n" unless $page =~ /ui_multi_compact/;
die "Unexpected bulk image selection\n"
	if $page =~ /data-ui-multi-action="(?:all|invert)"/;
die "Unexpected selection count\n" if $page =~ /ui_multi_count/;

# Export only the selector, without form tokens, job details or account data.
if (($ARGV[0] || '') eq '--html') {
	my @options = map { get_image_option($_) }
		      @{Cloudmin::ImageChoices::sort_images($data->{'images'})};
	$ui_page_assets_done = 1;
	print '<!doctype html><html><head><meta charset="utf-8">';
	print '<link rel="stylesheet" href="/unauthenticated/css/ui-lib.css">';
	print '<script defer src="/unauthenticated/js/ui-lib.js"></script>';
	print '<style>html{font:14px Arial,sans-serif}body{padding:16px}label{font-weight:400}</style></head><body>';
	print '<section id="cloudmin" class="ui_page">';
	print ui_multi_select_list('images', [ ], \@options,
				   { compact => 1, search => 1, bulk => 0,
				     count => 0,
				     height => '650px', summary =>
								$text{'images_bundled_cloud'},
				     summary_icon => 'download' });
	print '</section></body></html>';
	exit;
	}
print "PASS: ".scalar(@rows).
	" live image rows have compact grouped metadata\n";

# The installed demo exercises the same opt-in API with theme wrappers.
open(my $lang, '<', "$webmin_root/ui-demo/lang/en") or die $!;
while (<$lang>) { $main::text{$1} = $2 if /^([^=]+)=(.*)/; }
close($lang);
require "$webmin_root/ui-demo/ui-demo-pages.pl";
my $demo = demo_choices_tab();
die "Missing grouped demo\n" unless $demo =~ /ui_multi_group_success/ &&
	$demo =~ /ui_multi_metadata/;
print "PASS: ui-demo renders grouped choices with combined metadata\n";
