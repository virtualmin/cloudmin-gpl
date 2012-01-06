#!/usr/local/bin/perl
# Delete multiple disk image directories

require './server-manager-lib.pl';
&can_action_error(undef, "global");
&ReadParse();
&error_setup($text{'directory_err3'});
&error_if_cloudmin_replica();

# Validate inputs
@directories = &list_directories();
@d = split(/\0/, $in{'d'});
@d || &error($text{'directory_enone'});

# Do the deletion
foreach $d (@d) {
	($directory) = grep { $_->{'id'} eq $d } @directories;
	if ($directory) {
		&delete_directory($directory);
		}
	}

&webmin_log("delete", "directories", scalar(@d));
&redirect("list_directories.cgi");
