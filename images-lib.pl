# Functions for server image management

$server_images_dir = "$ENV{'WEBMIN_VAR'}/$module_name";
$server_images_url = "http://vm2.virtualmin.com/images/images.txt";
$server_images_base = "http://vm2.virtualmin.com/images/";
$server_images_cache = "$module_config_directory/server-images-cache";

# list_server_images([type])
# Returns a list of images that can be used to create servers, possibly of
# some type. Each is a hash ref, representing a file under
# /var/webmin/server-manager with a .img extension. Each may also have other
# associated files or directories containing the image data.
sub list_server_images
{
local ($type) = @_;
local @rv;
opendir(DIR, $server_images_dir);
foreach my $f (readdir(DIR)) {
	next if ($f !~ /^(\S+)\.img$/);
	local %img;
	&read_file_cached("$server_images_dir/$f", \%img);
	$img{'id'} = $1;
	next if (!$type || $img{'manager'} ne $type);
	push(@rv, \%img);
	}
closedir(DIR);
return @rv;
}

# list_available_server_images([type])
# Returns a list of machine images provided by Virtualmin. These are in a tab-
# separated file, containing an ID, type, description, version and size.
sub list_available_server_images
{
local ($type) = @_;

# Use cache if less than 1 hour old
local @st = stat($server_images_cache);
if (@st && $st[9] > time()-3600) {
	local $rv = &unserialise_variable(
			&read_file_contents($server_images_cache));
	return @$rv;
	}

# Need to download actual list
local ($host, $port, $page, $ssl) = &parse_http_url($server_images_url);
local ($out, $err);
local %serial;
&read_file($licence_file, \%serial);
&http_download($host, $port, $page, \$out, \$err, undef, $ssl,
	       $serial{'SerialNumber'}, $serial{'LicenseKey'});
&error("Failed to get server images : $err") if ($err);
local @rv;
foreach my $l (split(/\r?\n/, $out)) {
	local ($id, $manager, $desc, $version, $size) = split(/\t+/, $l);
	push(@rv, { 'id' => $id,
		    'manager' => $manager,
		    'desc' => $desc,
		    'version' => $version,
		    'size' => $size });
	}

# Save to cache and return
&open_tempfile(CACHE, ">$server_images_cache");
&print_tempfile(CACHE, &serialise_variable(\@rv));
&close_tempfile(CACHE);
return @rv;
}

# get_server_image(&avail)
# Downloads a server image from virtualmin.com, saves it locally, and returns
# the new image object on success, or an error string on failure.
sub get_server_image
{
# XXX
}

# get_server_image_files(&image)
# Downloads each of the needed files for some image, and outputs progress.
# Returns undef on success, or an error message on failure.
sub get_server_image_files
{
# XXX
}

1;

