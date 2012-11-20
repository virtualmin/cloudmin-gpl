#!/usr/local/bin/perl
# Show the details of one backup log

require './server-manager-lib.pl';
&ReadParse();
$log = &get_backup_log($in{'bid'});
$log || &error($text{'viewlog_egone'});

&ui_print_header(undef, $text{'viewlog_title'}, "");

print &ui_form_start("restore_form.cgi");
print &ui_hidden("log", $in{'bid'});
print &ui_table_start($text{'viewlog_header'}, undef, 2);

# Backup destination
$base = $log->{'base_dest'};
if (!$base) {
	$base = $log->{'dest'};
	$base =~ s/\/([^\/]+)$//;
	}
print &ui_table_row($text{'viewlog_base'},
	&nice_backup_destination($base));

# Files in backup
foreach $d (split(/\s+/, $log->{'dests'} || $log->{'dest'})) {
	if ($d =~ s/^\Q$base\/\E//) {
		push(@dests, "<tt>".&html_escape($d)."</tt>");
		}
	else {
		push(@dests, &nice_backup_destination($d));
		}
	}
print &ui_table_row($text{'viewlog_dests'},
	join("<br>\n", @dests));

# Time and date
print &ui_table_row($text{'viewlog_date'}, &make_date($log->{'time'}));

# Total size
if ($log->{'size'}) {
	print &ui_table_row($text{'viewlog_size'}, &nice_size($log->{'size'}));
	}

# System
$server = &get_managed_server($log->{'server'}) ||
	  &get_managed_server_by("host", $log->{'host'});
print &ui_table_row($text{'viewlog_host'},
		$server ? "<a href='edit_serv.cgi?id=$server->{'id'}'>".
			  "$server->{'host'}</a>"
			: &text('viewlog_deleted', $log->{'host'}));

# System owner
if ($log->{'owner'}) {
	print &ui_table_row($text{'viewlog_owner'},
			$log->{'owner'});
	}

# Status / error
if ($log->{'ok'}) {
	print &ui_table_row($text{'viewlog_status'},
		$text{'backuplogs_success'});
	}
elsif ($log->{'empty'}) {
	print &ui_table_row($text{'viewlog_status'},
		$text{'backuplogs_empty'});
	}
else {
	print &ui_table_row($text{'viewlog_status'},
		&text('backuplogs_failed', $log->{'msg'}));
	}

# Log ID
print &ui_table_row($text{'viewlog_id'}, $log->{'id'});

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'viewlog_restore'} ] ]);

&ui_print_footer("list_backuplogs.cgi?search=".&urlize($in{'search'}).
		 "&id=".&urlize($in{'id'})."&log=".&urlize($in{'log'}).
		 "&week=".&urlize($in{'week'}),
		   $text{'backuplogs_return'},
	         "", $text{'index_return'});
