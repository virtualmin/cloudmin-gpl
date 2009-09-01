#!/usr/local/bin/perl
# Upload a file to server Cloudmin systems

require './server-manager-lib.pl';
&ReadParseMime();
%d = map { $_, 1 } split(/\0/, $in{'d'});
@servers = grep { $d{$_->{'id'}} } &list_managed_servers();
&error_setup($text{'mupload_err'});
&can_action_error(\@servers, "upload");

# Validate inputs, and get the file
if ($in{'source'} == 0) {
	$in{'local'} || &error($text{'upload_elocal'});
	$in{'local_filename'} =~ s/^.*[\\\/]//;
	$source = &transname($in{'local_filename'});
	$sourcename = $in{'local_filename'};
	&open_tempfile(SOURCE, ">$source", 0, 1);
	&print_tempfile(SOURCE, $in{'local'});
	&close_tempfile(SOURCE);
	}
else {
	-f $in{'file'} || &error($text{'upload_efile'});
	$source = $in{'file'};
	$sourcename = $source;
	}
$in{'dest'} =~ /^\// || &error($text{'upload_edest'});

# Build temp files for results
%tempmap = ( );
foreach $s (@servers) {
	$tempmap{$s->{'id'}} = &tempname();
	}

# Do the uploads, in parallel
&ui_print_unbuffered_header(&server_in($server), $text{'mupload_title'}, "");

sub upload_cbfunc
{
my ($server, $args) = @_;
my ($source, $dest, $tempmap) = @$args;
my $err = &put_file_to_server($server, $source, $dest);
my $temp = $tempmap->{$server->{'id'}};
open(TEMP, ">$temp");
print TEMP $err;
close(TEMP);
}

print &text('mupload_doing', "<tt>$sourcename</tt>",
			     "<tt>$in{'dest'}</tt>", scalar(@servers)),"<br>\n";
&parallel_server_function(\@servers, \&upload_cbfunc,
			  [ $source, $in{'dest'}, \%tempmap ]);

# Read all the results and show them
foreach $s (@servers) {
	$err = &read_file_contents($tempmap{$s->{'id'}});
	unlink($tempmap{$s->{'id'}});
	if ($err) {
		print &text('mupload_failed',
			    "<tt>$s->{'host'}</tt>", $err),"<br>\n";
		}
	else {
		print &text('mupload_done', "<tt>$s->{'host'}</tt>"),"<br>\n";
		}
	}
print "<p>\n";

&ui_print_footer("", $text{'index_return'});

