#!/usr/local/bin/perl
# index.cgi
# Show the shell user interface

require './server-manager-lib.pl';
if ($ENV{'REQUEST_METHOD'} ne 'GET') {
	&ReadParseMime();
	}
else {
	&ReadParse();
	}
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "run");
&ui_print_header(&server_in($server), $text{'shell_title'}, "", "shell",
		 0, 0, undef, undef, undef,
	"onLoad='window.scroll(0, 10000); document.forms[0].cmd.focus()'");

$prevfile = "$shell_previous_dir/$in{'id'}";
if ($in{'clearcmds'}) {
	&lock_file($prevfile);
	unlink($prevfile);
	&unlock_file($prevfile);
	&webmin_log("clear");
	}
else {
	open(PREVFILE, $prevfile);
	chop(@previous = <PREVFILE>);
	close(PREVFILE);
	}
$cmd = $in{'doprev'} ? $in{'pcmd'} : $in{'cmd'};
$pwd = $in{'pwd'} || "/";

if (!$in{'clear'}) {
	$history = &un_urlize($in{'history'});
	if ($cmd) {
		# Execute the entered command
		$fullcmd = $cmd;
		$history .= "<b>&gt; ".&html_escape($cmd, 1)."</b>\n";
		if ($cmd =~ /^cd\s+"([^"]+)"\s*(;?\s*(.*))$/ ||
		    $cmd =~ /^cd\s+'([^']+)'\s*(;?\s*(.*))$/ ||
		    $cmd =~ /^cd\s+([^; ]*)\s*(;?\s*(.*))$/) {
			# Directory change, possibly followed by a command ..
			# work out where we end up after the chdir
			$cmd = undef;
			my $newdir = $1;
			my $aftercmd = $3;
			($out, $ex, $err) = &execute_command_on_server(
				$server, "cd ".quotemeta($pwd)." ; cd ".quotemeta($newdir)." && pwd");
			if ($ex) {
				# Remote chdir failed!
				$history .= &html_escape("$newdir: $out\n");
				}
			else {
				# Save the new directory
				($pwd = $out) =~ s/\r|\n//g;
				$cmd = $aftercmd;
				}
			}
		if ($cmd) {
			($out, $ex, $err) = &execute_command_on_server(
				$server, "cd ".quotemeta($pwd)." ; $cmd");
			$out = "ERROR: $err\n" if ($err);
			$out = &html_escape($out, 1);
			$history .= $out;
			}
		@previous = &unique(@previous, $fullcmd);
		&make_dir($shell_previous_dir, 0700);
		&open_lock_tempfile(PREVFILE, ">>$prevfile");
		&print_tempfile(PREVFILE, $fullcmd,"\n");
		&close_tempfile(PREVFILE);
		&webmin_log("shell", "server", $server->{'host'},
			    { 'cmd' => &urlize($cmd) });
		}
	}

# Show the history and command input
if ($history) {
	print &ui_table_start($text{'shell_history'}, "width=100%", 2);
	print &ui_table_row(undef, "<pre>$history</pre>", 2);
	print &ui_table_end();
	print "<hr>\n";
	}

print &text('shell_desc', "<tt>$server->{'host'}</tt>"),"<br>\n";
print &ui_form_start("shell.cgi", "form-data");
print &ui_hidden("id", $in{'id'});

print "<table width=100%><tr>\n";

# Command to run
print "<td width=10%>",&ui_submit($text{'shell_ok'}),"</td>\n";
print "<td>",&ui_textbox("cmd", undef, 50, 0, undef,
			 "style='width:100%'"),"</td>\n";
print "<td align=right width=10%>",&ui_submit($text{'shell_clear'}, "clear"),
      "</td>\n";
print "</tr>\n";

print &ui_hidden("pwd", $pwd);
print &ui_hidden("history", &urlize($history));
foreach $p (@previous) {
	print &ui_hidden("previous", $p);
	}

# Previous command menu
if (@previous) {
	print "<tr>\n";
	print "<td width=10%>",&ui_submit($text{'shell_pok'}, "doprev"),
	      "</td>\n";
	print "<td>",&ui_select("pcmd", undef,
			[ reverse(@previous) ]);
	print "<input type=button name=movecmd ",
	      "value='$text{'shell_edit'}' ",
	      "onClick='cmd.value = pcmd.options[pcmd.selectedIndex].value'>\n";
	print "</td>\n";
	print "<td align=right width=10%>",
	      &ui_submit($text{'shell_clearcmds'}, "clearcmds"),"</td>\n";
	print "</tr>\n";
	}
print "</table>\n";
print &ui_form_end();

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

