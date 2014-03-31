#!/usr/local/bin/perl
# Write data to a file

require './server-manager-lib.pl';
&foreign_require("file");
&ReadParse(undef, 'GET');
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");

$p = $ENV{'PATH_INFO'};
print "Content-type: text/plain\n\n";

# Read posted data
$clen = $ENV{'CONTENT_LENGTH'};
&read_fully(STDIN, \$buf, $clen) == $clen ||
	&error("Failed to read POST input : $!");

if (defined($in{'length'}) && length($buf) != $in{'length'}) {
	print $file::text{'edit_elength'},"\n";
	}
else {
	my $temp = &transname();
	&open_tempfile(TEMP, ">$temp", 0, 1);
	&print_tempfile(TEMP, $buf);
	&close_tempfile(TEMP);
	my $err = &put_file_to_server($server, $temp, $p);
	if ($err) {
		print $err,"\n";
		}
	else {
		print "\n";
		print &file_info_line($server, $p);
		}
	}
