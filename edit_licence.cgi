#!/usr/local/bin/perl
# Shows full details of one licence

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ui_print_header(undef, $text{'ledit_title'}, "");
&ReadParse();

@lics = &list_virtualmin_licences();
($lic) = grep { $_->{'serial'} eq $in{'serial'} } @lics;
$lic || &error($text{'ledit_egone'});

if (!$lic->{'vm2'}) {
	print &ui_form_start("delete_licences.cgi");
	print &ui_hidden("d", $in{'serial'});
	}

print &ui_table_start($text{'ledit_header'}, undef, 2);

# Serial and key
print &ui_table_row($text{'ledit_serial'}, $lic->{'serial'});
print &ui_table_row($text{'ledit_key'}, $lic->{'key'});

# Source and status
print &ui_table_row($text{'ledit_source'},
		    $lic->{'vm2'} ? $text{'ledit_vm2'} : $text{'ledit_normal'});
print &ui_table_row($text{'ledit_status'},
		    $lic->{'invalid'} ? $text{'licences_invalid'}
				      : $text{'licences_valid'});

# Domains and systems
print &ui_table_row($text{'ledit_domains'},
		    $lic->{'domains'} || $text{'licences_unlimited'});
print &ui_table_row($text{'ledit_systems'},
		    $lic->{'servers'} || $text{'licences_unlimited'});

# Current users
$ucount = scalar(@{$lic->{'users'}});
print &ui_table_row($text{'ledit_ucount'},
	 	    $lic->{'progress'} ? &text('ledit_progress',
						$lic->{'progress'}, $ucount) :
		    $ucount ? &text('ledit_unum', $ucount) :
			      $text{'ledit_unone'});
if ($ucount) {
	print &ui_table_row($text{'ledit_users'},
		join("<br>\n", map { "<a href='edit_serv.cgi?id=$_->{'id'}'>".
				     $_->{'host'}."</a>" } @{$lic->{'users'}}));
	}

print &ui_table_end();
if (!$lic->{'vm2'}) {
	print &ui_form_end([ [ undef, $text{'ledit_delete'} ] ]);
	}

&ui_print_footer("list_licences.cgi?mode=list",
		 $text{'licences_return'});

