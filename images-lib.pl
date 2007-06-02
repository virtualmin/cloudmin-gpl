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
	next if ($type && $img{'manager'} ne $type);
	local $size = 0;
	foreach my $fl (split(/\s+/, $img{'files'})) {
		local @st = stat("$server_images_dir/$fl");
		$size += $st[7];
		}
	$img{'size'} = $size;
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
local ($img) = @_;
local ($host, $port, $page, $ssl) = &parse_http_url($server_images_base);
local %serial;
&read_file($licence_file, \%serial);
local $temp = &transname();
&http_download($host, $port, "$page/$img->{'id'}.img", $temp, \$err,
	       undef, $ssl, $serial{'SerialNumber'}, $serial{'LicenseKey'});
return $err if ($err);
local %got;
&read_file($temp, \%got);
$got{'id'} ||= $img->{'id'};
$got{'size'} = $img->{'size'};
&make_dir($server_images_dir, 0700);
&write_file("$server_images_dir/$got{'id'}.img", \%got);
return \%got;
}

# get_server_image_files(&image)
# Downloads each of the needed files for some image, and outputs progress.
# Returns undef on success, or an error message on failure.
sub get_server_image_files
{
local ($img) = @_;
local @files = split(/\s+/, $img->{'files'});
local ($host, $port, $page, $ssl) = &parse_http_url($server_images_base);
local %serial;
&read_file($licence_file, \%serial);
foreach my $f (@files) {
	$progress_callback_url = $server_images_base.$f;
	&http_download($host, $port, "$page/$f", "$server_images_dir/$f",
		       \$err, \&progress_callback, $ssl,
		       $serial{'SerialNumber'}, $serial{'LicenseKey'});
	if ($err) {
		unlink("$server_images_dir/$f");
		return $err;
		}
	}
return undef;
}

# transfer_image_files(&server)
# Transfers all files for some system's image to a parent host, and returns
# the path to the temp directory created for them.
sub transfer_image_files
{
local ($server) = @_;
local $pfunc = "type_".$server->{'manager'}."_parent";
local $vhost = &$pfunc($server);
$vhost || return (0, "Could not find parent system");
local ($img) = grep { $_->{'id'} eq $server->{'image'} } &list_server_images();
$img || return (0, "Could not find image with ID $server->{'image'}");

# Choose a temp dir
local $temp;
if ($vhost->{'status'} eq 'virt' || $vhost->{'status'} eq 'novirt') {
	# Ask the remote Webmin
	&remote_foreign_require($vhost, "webmin", "webmin-lib.pl");
	$temp = &remote_foreign_call($vhost, "webmin", "tempname",
				     $img->{'id'});
	$temp || return (0, $remote_webmin_error);
	}
else {
	# Use configure dir, or /tmp
	local $tempdir = $config{'img_temp'} || "/tmp";
	$temp = "$tempdir/$img->{'id'}";
	}
local ($out, $ex, $err) = &execute_command_on_server($vhost,
				"mkdir ".quotemeta($temp));
return (0, $err) if ($err);
return (0, $out) if ($ex);

# Copy files from local to that dir
# XXX not if local
# XXX show progress indicator
foreach my $f (split(/\s+/, $img->{'files'})) {
	# XXX
	}

return (1, $temp);
}

1;

