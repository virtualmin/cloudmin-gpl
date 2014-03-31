#!/usr/local/bin/perl
# list.cgi
# Return a list of files in some directory

require './server-manager-lib.pl';
&ReadParse();
$server = &get_managed_server($in{'id'});
$server || &error($text{'edit_egone'});
&can_action_error($server, "transfer");
print "Content-type: text/plain\n\n";

$files = &list_dir_on_server($server, $in{'dir'}, 1, 1);
if (!ref($files)) {
	print $files,"\n";
	return;
	}
print "\n";
@files = sort { lc($a->[13]) cmp lc($b->[13]) } @$files;
$d = $in{'dir'} eq '/' ? '' : $in{'dir'};
foreach $f (@files) {
	my $fil = &file_info_line($server, "$d/$f->[13]", $f);
	print "$fil\n" if (defined($fil));
	}

