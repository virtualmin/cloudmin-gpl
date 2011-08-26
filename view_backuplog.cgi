#!/usr/local/bin/perl
# Show the details of one backup log

require './server-manager-lib.pl';
&ReadParse();
$log = &get_backuplog($in{'log'});
$log || &error($text{'viewlog_egone'});

&ui_print_header(undef, $text{'viewlog_title'}, "");

&ui_print_footer("list_backuplogs.cgi?search=".&urlize($in{'search'}),
		  $text{'backuplogs_return'},
	         "", $text{'index_return'});
