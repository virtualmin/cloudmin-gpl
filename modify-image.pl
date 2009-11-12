#!/usr/local/bin/perl

=head1 modify-image.pl

Modify the details or location of an image.

This command can be used to change the description or OS type of an image,
add it to some storage location, or remove it from one.

The image ID is specified with the C<--id> parameter. The new description is
set with the C<--desc> flag followed by a description, and the new OS type
with the C<--os> flag. Valid OS codes are like I<centos>, I<debian> and 
I<solaris>.

To add a new storage location for the image's files, use the C<--add-storage>
flag followed by a storage spec, typically in host:path format. The spec can
also be just a path, indicating that the image will be stored on the Cloudmin
master.

To remove a storage location, use the C<--remove-storage> flag followed by
a storage spec. All files in the image in the given directory will be removed.

=head1 Example usage

  cloudmin modify-image --id xen-centos-test1 --desc "My test image"
  Image xen-centos-test1 successfully updated.

  cloudmin modify-image --id xen-centos-test1 --add-storage imageserver:/images
  Copying image files to imageserver:/image ..
  ..done

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*)\/[^\/]+$/) {
	chdir($pwd = $1);
	}
else {
	chop($pwd = `pwd`);
	}
$0 = "$pwd/modify-image.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--id") {
		$id = shift(@ARGV);
		}
	elsif ($a eq "--desc") {
		$desc = shift(@ARGV);
		}
	elsif ($a eq "--os") {
		$type = shift(@ARGV);
		}
	elsif ($a eq "--add-storage") {
		push(@addstor, shift(@ARGV));
		}
	elsif ($a eq "--remove-storage") {
		push(@delstor, shift(@ARGV));
		}
	else {
		&usage();
		}
	}
&set_all_text_print();
$id || &usage();

# Get the image
($image) = grep { $_->{'id'} eq $id } &list_server_images();
$image || &usage("No image with ID $id was found");

# Apply changes
if (defined($desc)) {
	$image->{'desc'} = $desc;
	$changed++;
	}
if (defined($type)) {
	($st) = grep { $_->[0] eq $type } @servers::server_types;
	$st || &usage("Invalid value for --os. Known operating system ".
		      "codes are : ".join(" ", map { $_->[0] }
						@servers::server_types));
	$image->{'type'} = $type;
	$changed++;
	}
if ($changed) {
	&save_server_image($image);
	print "Image $id successfully updated.\n";
	}

@dests = split(/\s+/, $image->{'dest'});
@stors = &list_storages();

# Copy to new locations
foreach $deststr (@addstor) {
	$dest = &parse_backup_destination($deststr);
	$dest || &usage("Invalid image location $deststr");
	&$first_print("Copying image files to $deststr ..");
	$deststr = &join_backup_destination($dest);
	($stor) = grep { $_->{'dest'} eq $deststr } @stors;
	if ($stor) {
		$err = &transfer_image_files_to_storage($image, $stor);
		}
	else {
		$err = &transfer_image_files_to_dest($image, $deststr);
		}
	if ($err) {
		&$second_print(".. failed : $err");
		}
	else {
		push(@dests, $deststr);
		&$second_print(".. done");
		}
	}

# Remove from old locations
foreach $deststr (@delstor) {
	$dest = &parse_backup_destination($deststr);
        $dest || &usage("Invalid image location $deststr");
	&$first_print("Removing image files from $deststr ..");
	$deststr = &join_backup_destination($dest);
	$idx = &indexof($deststr, @dests);
	if ($idx < 0) {
		&$second_print(".. not at that location");
		}
	else {
		$err = &delete_image_files_from_dest($image, $deststr);
		($stor) = grep { $_->{'dest'} eq $deststr } @stors;
		if ($stor && !$err) {
			&compute_storage_size($stor);
			&save_storage($stor);
			}
		if ($err) {
			&$second_print(".. failed : $err");
			}
		else {
			splice(@dests, $idx, 1);
			&$second_print(".. done");
			}
		}
	}

$image->{'dest'} = join(" ", @dests);
&save_server_image($image);

&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Modify the details or location of an image.\n";
print "\n";
print "cloudmin modify-image --id image-id\n";
print "                     [--desc new-description]\n";
print "                     [--os os-code]\n";
print "                     [--add-storage storagespec]\n";
print "                     [--remove-storage storagespec]\n";
exit(1);
}

