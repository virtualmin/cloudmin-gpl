#!/usr/local/bin/perl
# Compute disk space used by system owners for backups, and storages.
# Also updates files in images.

$main::no_acl_check++;
require './server-manager-lib.pl';
&compute_backup_space();
foreach my $stor (&list_storages()) {
	&compute_storage_size($stor);
	&save_storage($stor);
	}
foreach my $image (&list_server_images()) {
	my $olddest = $image->{'dest'};
	my $err = &compute_image_dests($image);
	if (!$err && $image->{'dest'} && $image->{'dest'} ne $olddest) {
		print STDERR "image=$image->{'id'} dest=$image->{'dest'}\n";
		&save_server_image($image);
		}
	}
