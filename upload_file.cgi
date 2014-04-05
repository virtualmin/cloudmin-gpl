#!/usr/local/bin/perl
# Actually upload a file

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse(\%getin, 'GET');
$server = &get_managed_server($getin{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");
&ReadParseMime(undef, \&read_parse_mime_callback, [ $getin{'upid'} ]);
&popup_header();

# Work out filename
$in{'file_filename'} || &error($text{'upload_elocal'});
$in{'file_filename'} =~ /([^\\\/]+)$/;
$path = $in{'dir'}."/".$1;

# Send to the server
$err = &put_file_data_to_server($server, $in{'file'}, $path);
&error($err) if ($err);
if ($in{'user'} ne 'root') {
	# Chown the file
	&set_ownership_permissions_on_server($server, $in{'user'}, undef, undef,
					     $path);
	}

# Tell the applet about the upload
$info = &file_info_line($server, $path);
$qpath = &quote_escape($path);
$qinfo = &quote_escape($info);
print <<EOF;
<script>
opener.document.FileManager.upload_notify("$qpath", "$qinfo");
close();
</script>
EOF

&popup_footer();
