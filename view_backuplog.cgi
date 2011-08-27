#!/usr/local/bin/perl
# Show the details of one backup log

require './server-manager-lib.pl';
&ReadParse();
$log = &get_backuplog($in{'bid'});
$log || &error($text{'viewlog_egone'});

&ui_print_header(undef, $text{'viewlog_title'}, "");

print &ui_form_start("restore_form.cgi");
print &ui_hidden("log", $in{'bid'});
print &ui_table_start($text{'viewlog_header'}, undef, 2);

# Backup destination

# Files in backup

# Time and date

# Total size

# System

# Status / error

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'viewlog_restore'} ] ]);

&ui_print_footer("list_backuplogs.cgi?search=".&urlize($in{'search'}).
		 "&id=".&urlize($in{'id'})."&log=".&urlize($in{'log'}),
		   $text{'backuplogs_return'},
	         "", $text{'index_return'});
