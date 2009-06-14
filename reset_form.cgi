#!/usr/local/bin/perl
# Show a form for resetting a virtual system based on its original image

require './server-manager-lib.pl';
&ReadParse();
($server) = grep { $_->{'id'} == $in{'id'} } &list_managed_servers();
$server || &error($text{'edit_egone'});
&can_action_error($server, "reset");

&ui_print_header(&server_in($server), $text{'reset_title'}, "", "reset");

@doms = &get_server_domains($server);
$img = &get_server_image($server->{'image'});
print &ui_confirmation_form("reset.cgi",
			    &text('reset_rusure',
				  "<tt>$server->{'host'}</tt>",
				  "<i>".&html_escape($img->{'desc'})."</i>"),
			    [ [ "id", $server->{'id'} ] ],
			    [ [ "confirm", $text{'reset_ok'} ] ],
			    undef,
			    (@doms ? &text('save_deleterusure2',
					   scalar(@doms)) : ""));

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

