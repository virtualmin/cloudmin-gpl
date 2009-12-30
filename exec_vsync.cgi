#!/usr/local/bin/perl
# Run one replication manually and print output

require './server-manager-lib.pl';
&ReadParse();
$vsync = &get_virtualmin_sync($in{'id'});
$vsync || &error($text{'vsync_egone'});
&can_virtualmin_sync($vsync) || &error($text{'vsync_ecannot'});

&ui_print_unbuffered_header(undef, $text{'vsync_title3'}, "");

$src = &get_managed_server($vsync->{'src'});
@doms = split(/\s+/, $vsync->{'doms'});
print "<b>",&text(@doms ? 'vsync_starting' : 'vsync_starting2',
		  $src->{'host'}, join(" , ", @doms)),"</b>\n";

&$indent_print();
$ok = &sync_virtualmin_domains($vsync);
&$outdent_print();

if ($ok) {
	print "<b>$text{'vsync_allok'}</b><p>\n";
	}
else {
	print "<b>$text{'vsync_failed'}</b><p>\n";
	}
&webmin_log("exec", "vsync", $src->{'host'}, { 'doms' => \@doms });

&ui_print_footer("list_vsyncs.cgi", $text{'vsyncs_return'});

