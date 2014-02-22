#!/usr/local/bin/perl
# Show a form for resetting a virtual system based on its original image

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "reset");

&ui_print_header(&server_in($server), $text{'reset_title'}, "", "reset");

@doms = &get_server_domains($server);
$img = &get_server_image($server->{'image'});

print "<b>",&text('reset_rusure', "<tt>$server->{'host'}</tt>"),"</b><p>\n";

print &ui_form_start("reset.cgi");
print &ui_hidden("id", $server->{'id'});
print &ui_table_start($text{'reset_header'}, undef, 2);

print &ui_table_row($text{'reset_desc'}, $server->{'desc'});

@images = &list_server_images($server->{'manager'});
@images = grep { &can_image($_) } @images;
if ($img) {
	($inlist) = grep { $_->{'id'} eq $img->{'id'} } @images;
	if (!$inlist) {
		# Make sure initial image is there
		push(@images, $img);
		}
	}
print &ui_table_row($text{'reset_image'},
	&ui_select("image", $img ? $img->{'id'} : undef,
		   [ map { [ $_->{'id'}, $_->{'desc'} ] }
		      sort { lc($a->{'desc'}) cmp lc($b->{'desc'}) }
			   @images ]));

print &ui_table_end();
print &ui_form_end([ [ 'confirm', $text{'reset_ok'} ] ]);

&ui_print_footer("edit_serv.cgi?id=$in{'id'}", $text{'edit_return'});

