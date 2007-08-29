#!/usr/local/bin/perl
# Show the mass command execution form

require './server-manager-lib.pl';
if ($ENV{'REQUEST_METHOD'} ne 'GET') {
	&ReadParseMime();
	}
else {
	&ReadParse();
	}
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
&ui_print_header(undef, $text{'mshell_title'}, "", "mshell",
		 0, 0, undef, undef, undef,
	"onLoad='window.scroll(0, 10000); document.forms[0].cmd.focus()'");

print &text('mshell_on', join(" , ", map { "<tt>$_->{'host'}</tt>" }
					 @servers)),"<br>\n";

$prevfile = "$module_config_directory/previous.mass";
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

if (!$in{'clear'}) {
	$history = &un_urlize($in{'history'});
	if ($cmd) {
		# Execute the entered command, on each server
		$fullcmd = $cmd;
		$history .= "<b>&gt; ".&html_escape($cmd, 1)."</b>\n";
		foreach $server (@servers) {
			$cmd = $in{'doprev'} ? $in{'pcmd'} : $in{'cmd'};
			$pwd = $in{'pwd_'.$server->{'id'}} || "/";
			$pwdmap{$server->{'id'}} = $pwd;
			if ($cmd =~ /^cd\s+"([^"]+)"\s*(;?\s*(.*))$/ ||
			    $cmd =~ /^cd\s+'([^']+)'\s*(;?\s*(.*))$/ ||
			    $cmd =~ /^cd\s+([^; ]*)\s*(;?\s*(.*))$/) {
				# Directory change, possibly followed by a
				# command .. work out where we end up after
				# the chdir
				$cmd = undef;
				local $newdir = $1;
				local $aftercmd = $3;
				($out, $ex, $err) = &execute_command_on_server(
					$server, "cd ".quotemeta($pwd)." ; cd ".quotemeta($newdir)." && pwd");
				if ($ex) {
					# Remote chdir failed!
					$history .= "<b>$server->{'host'}</b> : ";
					$history .= &html_escape(
						"$newdir: $out\n");
					}
				else {
					# Save the new directory
					($pwd = $out) =~ s/\r|\n//g;
					$pwdmap{$server->{'id'}} = $pwd;
					$cmd = $aftercmd;
					}
				}
			if ($cmd) {
				($out, $ex, $err) = &execute_command_on_server(
					$server, "cd ".quotemeta($pwd)." ; $cmd");
				$history .= "<b>$server->{'host'}</b> : ";
				$out = "ERROR: $err\n" if ($err);
				$out = &html_escape($out, 1);
				$history .= $out;
				}
			}
		@previous = &unique(@previous, $fullcmd);
		&lock_file($prevfile);
		&open_tempfile(PREVFILE, ">>$prevfile");
		&print_tempfile(PREVFILE, $fullcmd,"\n");
		&close_tempfile(PREVFILE);
		&unlock_file($prevfile);
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
print &ui_form_start("massshell.cgi", "form-data");
foreach $d (keys %d) {
	print &ui_hidden("d", $d);
	}

print "<table width=100%><tr>\n";

# Command to run
print "<td width=10%>",&ui_submit($text{'shell_ok'}),"</td>\n";
print "<td>",&ui_textbox("cmd", undef, 50, 0, undef,
			 "style='width:100%'"),"</td>\n";
print "<td align=right width=10%>",&ui_submit($text{'shell_clear'}, "clear"),
      "</td>\n";
print "</tr>\n";

foreach $id (keys %pwdmap) {
	print &ui_hidden("pwd_".$id, $pwdmap{$id});
	}
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

