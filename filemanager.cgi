#!/usr/local/bin/perl
# Show the Java file manager

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

&ui_print_header(&server_in($server), $text{'filemanager_title'}, "");

# Work out config params from file manager module
%fconfig = &foreign_config("file");
$iconsize = int($fconfig{'iconsize'});
if ($main::session_id) {
        $session = "<param name=session value=\"sid=$main::session_id\">";
        }

print <<EOF;
<applet code=FileManager name=FileManager archive=../file/file.jar width=100% height=80% MAYSCRIPT>
<param name=root value="/">
<param name=extra value="&id=$server->{'id'}">
<param name=sharing value="0">
<param name=mounting value="0">
<param name=ro value="0">
<param name=follow value="0">
<param name=iconsize value="$iconsize">
<param name=doarchive value="0">
<param name=unarchive value="0">
<param name=dostounix value="0">
<param name=fixed value="$fconfig{'fixed'}">
<param name=small_fixed value="$fconfig{'small_fixed'}">
<param name=force_text value="1">
<param name=htmlexts value="$fconfig{'htmlexts'}">
<param name=images value="../file/images">
$session
$text{'index_nojava'} <p>
</applet>
EOF

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});
