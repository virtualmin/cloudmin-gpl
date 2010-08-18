# Functions for server image management

# list_server_images([type])
# Returns a list of images that can be used to create servers, possibly of
# some type. Each is a hash ref, representing a file under
# /var/webmin/server-manager with a .img extension. Each may also have other
# associated files or directories containing the image data.
sub list_server_images
{
my ($type) = @_;
my @rv;
opendir(DIR, $server_images_dir);
foreach my $f (readdir(DIR)) {
	next if ($f !~ /^(\S+)\.img$/);
	my %img;
	&read_file_cached("$server_images_dir/$f", \%img);
	$img{'file'} = "$server_images_dir/$f";
	$img{'id'} = $1;
	next if ($type && $img{'manager'} ne $type);	# Don't want this type
	next if (!$server_management_types{$img{'manager'}});	# Not supported
	my $size = 0;
	my $partialsize = 0;
	if (!$img{'dest'}) {
		# Assume stored on master
		$img{'dest'} = "master:".$server_images_dir;
		}
	foreach my $deststr (split(/\s+/, $img{'dest'})) {
		my $dest = &parse_backup_destination($deststr);
		if ($dest->{'mode'} == 0) {
			# Only compute size if local
			foreach my $fl (split(/\s+/, $img{'files'})) {
				my @st = stat("$dest->{'path'}/$fl");
				if (@st) {
					$size += $st[7];
					}
				else {
					$img{'partial'} = 1;
					my ($tmp) = glob(
						"$server_images_dir/$fl.webmintmp.*");
					if ($tmp) {
						my @tst = stat($tmp);
						$partialsize += $tst[7];
						}
					}
				}
			$img{'size'} = $size;
			last;
			}
		}
	$img{'partialsize'} = $partialsize;
	$img{'longdesc'} = $img{'desc'};
	if (@server_management_types > 1) {
		my $dfunc = "type_".$img{'manager'}."_desc";
		if (defined(&$dfunc)) {
			$img{'longdesc'} .= " - ".&$dfunc();
			}
		}
	if ($img{'rawsize'}) {
		$img{'longdesc'} .= " - ".&nice_size($img{'rawsize'});
		}
	push(@rv, \%img);
	}
closedir(DIR);
return sort { $b->{'priority'} <=> $a->{'priority'} ||
	      $a->{'desc'} cmp $b->{'desc'} } @rv;
}

# get_server_image(id)
# Returns a server image object with the given ID
sub get_server_image
{
my ($id) = @_;
my ($img) = grep { $_->{'id'} eq $id } &list_server_images();
return $img;
}

# list_available_server_images([type])
# Returns a list of machine images provided by Virtualmin. These are in a tab-
# separated file, containing an ID, type, description, version and size.
sub list_available_server_images
{
my ($type) = @_;

# Use cache if less than 1 hour old
my @st = stat($server_images_cache);
if (@st && $st[9] > time()-3600) {
	my $rv = &unserialise_variable(
			&read_file_contents($server_images_cache));
	return @$rv;
	}

# Need to download actual list
my ($host, $port, $page, $ssl) = &parse_http_url($server_images_url);
my ($out, $err);
my %serial;
&read_file($licence_file, \%serial);
&http_download($host, $port, $page, \$out, \$err, undef, $ssl,
	       $serial{'SerialNumber'}, $serial{'LicenseKey'});
&error("Failed to get server images : $err") if ($err);
my @rv;
foreach my $l (split(/\r?\n/, $out)) {
	my ($id, $manager, $desc, $version, $size) = split(/\t+/, $l);
	if ($server_management_types{$manager}) {
		push(@rv, { 'id' => $id,
			    'manager' => $manager,
			    'desc' => $desc,
			    'version' => $version,
			    'size' => $size });
		}
	}

# Save to cache and return
&open_tempfile(CACHE, ">$server_images_cache");
&print_tempfile(CACHE, &serialise_variable(\@rv));
&close_tempfile(CACHE);
return @rv;
}

# download_server_image(&avail)
# Downloads a server image from virtualmin.com, saves it locally, and returns
# the new image object on success, or an error string on failure.
sub download_server_image
{
my ($img) = @_;
my ($host, $port, $page, $ssl) = &parse_http_url($server_images_base);
my %serial;
&read_file($licence_file, \%serial);
my $temp = &transname();
&http_download($host, $port, "$page/$img->{'id'}.img", $temp, \$err,
	       undef, $ssl, $serial{'SerialNumber'}, $serial{'LicenseKey'});
return $err if ($err);
my %got;
&read_file($temp, \%got);
$got{'id'} ||= $img->{'id'};
$got{'size'} = $img->{'size'};
&save_server_image(\%got);
return \%got;
}

# download_server_image_files(&image)
# Downloads each of the needed files for some image, and outputs progress.
# Returns undef on success, or an error message on failure.
sub download_server_image_files
{
my ($img) = @_;
my @files = split(/\s+/, $img->{'files'});
my ($host, $port, $page, $ssl) = &parse_http_url($server_images_base);
my $vhost = $img->{'vhost'} ? &get_managed_server($img->{'vhost'}) : undef;

# Find storage location on the master, if any
my $master_dir = $server_images_dir;
foreach $stor (&list_storages()) {
	($destserver, $destpath) = &get_image_dest_path($stor->{'dest'},
							$vhost);
	if ($destserver && $destserver->{'id'} == 0) {
		$master_dir = $destpath;
		last;
		}
	}

# Fetch each one via HTTP
my %serial;
&read_file($licence_file, \%serial);
foreach my $f (@files) {
	$progress_callback_url = $server_images_base.$f;
	&http_download($host, $port, "$page/$f", "$master_dir/$f",
		       \$err, \&progress_callback, $ssl,
		       $serial{'SerialNumber'}, $serial{'LicenseKey'});
	if ($err) {
		unlink("$master_dir/$f");
		return $err;
		}
	}
my @dests = ( "master:$master_dir" );
$img->{'dest'} = join(" ", @dests);

# Copy to default locations
foreach $stor (&list_storages()) {
	my ($destserver, $destpath) = &get_image_dest_path($stor->{'dest'},
							   $vhost);
	next if (!$destserver);
	next if ($destserver->{'id'} == 0 && $destpath eq $master_dir);
	my $err = &transfer_image_files_to_storage($img, $stor);
	if (!$err) {
		push(@dests, $stor->{'dest'});
		}
	}

$img->{'dest'} = join(" ", @dests);
return undef;
}

# create_image_files_tempdir(&vhost, id)
# Attempts to create a temp directory for image files on some host, and returns
# either (1, dir) or (0, some error).
sub create_image_files_tempdir
{
my ($vhost, $id) = @_;

my $temp;
if ($vhost->{'status'} eq 'virt' || $vhost->{'status'} eq 'novirt') {
	# Ask the remote Webmin
	&remote_foreign_require($vhost, "webmin", "webmin-lib.pl");
	$temp = &remote_foreign_call($vhost, "webmin", "tempname", $id);
	$temp || return (0, $last_remote_error);
	}
else {
	# Use configure dir, or /tmp
	my $ostemp = $vhost->{'type'} eq 'solaris' ? '/var/tmp' : '/tmp';
	my $tempdir = $config{'img_temp'} || $ostemp;
	$temp = "$tempdir/$id";
	}
&delete_file_on_server($vhost, $temp);
my $err = &make_dir_on_server($vhost, $temp, 0700);
return (0, $err) if ($err);
return (1, $temp);
}

# transfer_image_files(&server, [show-progress-dots])
# Transfers all files for some system's image to a parent host, and returns
# a success flag (0=failed, 1=transferred, 2=not needed, 3=in cache, 4=
# transferred to cache) the path to the temp directory created for them.
sub transfer_image_files
{
my ($server, $progress) = @_;
my $pfunc = "type_".$server->{'manager'}."_parent";
my $vhost = &$pfunc($server);
$vhost || return (0, "Could not find parent system");
my $img = &get_server_image($server->{'image'});
$img || return (0, "Could not find image with ID $server->{'image'}");
my @files = split(/\s+/, $img->{'files'});
my @md5s = split(/\s+/, $img->{'md5'});

# Check if the host has image caching enabled, and if we have the image
# already
my $prefix = $server->{'manager'};
$prefix = "zone" if ($prefix eq "zones");
my $cachedir = $vhost->{$prefix.'_cachedir'} || $images_cache_dir;
my $imagedir;
if ($vhost->{$prefix.'_cachesize'}) {
	# Make the directory if needed
	my $err = &make_dir_on_server($vhost, $cachedir, 0700, 1);
	if ($err) {
		return (0, "Failed to create cache directory $cachedir : $err");
		}

	# See if we have all the needed files in the cache
	my $missing = 0;
	foreach my $f (@files) {
		my @st = &stat_file_on_server($vhost, "$cachedir/$f");
		$missing++ if (!@st);
		}
	if (!$missing &&
	    !&verify_image_md5s($vhost, $cachedir, \@files, \@md5s)) {
		# Failed MD5 check
		$missing++;
		}
	if (!$missing) {
		# We have them all, so no need to transfer. Touch the image
		# files to indicate most recent use
		foreach my $f (@files) {
			&execute_command_on_server(
				$vhost, "touch ".quotemeta("$cachedir/$f"));
			}
		return (3, $cachedir, $vhost);
		}

	# No, need to transfer to the cache
	$imagedir = $cachedir;

	# If cache is too big, clean up some files first
	my $maxsize = $vhost->{$prefix.'_cachesize'} * 1024 * 1024 * 1024;
	my $err = &cleanup_cache_dir($vhost, $cachedir,
					$maxsize, $img->{'size'});
	return (0, $err) if ($err);
	}
else {
	# Choose a temp dir that we transfer to
	my ($tempok, $temp) = &create_image_files_tempdir(
					$vhost, $img->{'id'});
	return (0, $temp) if (!$tempok);
	$imagedir = $temp;
	}

# Find all the image locations, check if any are on this host already
my @dests;
foreach my $dstr (split(/\s+/, $img->{'dest'})) {
	my ($destserver, $destpath) = &get_image_dest_path($dstr);
	if ($destserver->{'id'} eq $vhost->{'id'}) {
		# Already got it!
		my $missing = 0;
		foreach my $f (@files) {
			my @st = &stat_file_on_server($vhost, "$destpath/$f");
			$missing++ if (!@st);
			}
		if (!$missing) {
			return (2, $destpath, $destserver);
			}
		}
	push(@dests, [ $destserver, $destpath,
			&distance_from_server($vhost, $destserver) ]);
	}

# Sort by distance, closest first, then try in that order
@dests = sort { $a->[2] <=> $b->[2] } @dests;
my $lasterr;
my $lastserver;
foreach my $sp (@dests) {
	# Transfer files from image location to dir on host
	$lasterr = undef;
	foreach my $f (@files) {
		my ($destserver, $destpath) = @$sp;
		my $path = "$destpath/$f";
		my $pid = fork();
		my $outtemp = &tempname();
		if (!$pid) {
			my $err = &transfer_file_between_servers(
					$destserver, $vhost,
					$path, "$imagedir/$f", 0, 1);
			open(OUT, ">$outtemp");
			print OUT $err;
			close(OUT);
			exit($err ? 1 : 0);
			}
		while(1) {
			my $expid = waitpid($pid, WNOHANG);
			last if ($expid == $pid);
			print "." if ($progress);
			sleep(1);
			}
		my $err = &read_file_contents($outtemp);
		&unlink_file($outtemp);
		if ($err) {
			$lasterr = "Failed to copy $f from ".
				   "$destserver->{'host'} : $err";
			last;
			}
		$lastserver = $destserver;
		}
	last if (!$lasterr);
	}

# Return status and directory
if ($lasterr) {
	return (0, $lasterr);
	}
elsif ($cachedir eq $imagedir) {
	return (4, $imagedir, $lastserver);
	}
else {
	return (1, $imagedir, $lastserver);
	}
}

# cleanup_cache_dir(vhost, cachedir, max-size, need-size)
# If the cache size is larger than some maximum, delete older files. Returns
# undef on success or an error message on failure.
sub cleanup_cache_dir
{
my ($vhost, $cachedir, $maxsize, $incr) = @_;
return undef if ($incr <= 0);
my ($out, $ex, $err) = &execute_command_on_server(
			$vhost, "du -k ".quotemeta($cachedir)."/*");
my $totalsize = $incr;
my %sizemap;
foreach my $l (split(/\r?\n/, $out)) {
	my ($kb, $f) = split(/\s+/, $l);
	$f =~ s/^\Q$cachedir\E\///g;
	$totalsize += $kb*1024;
	$sizemap{$f} = $kb*1024;
	}
if ($totalsize > $maxsize) {
	# Too big! Delete images, ordered by time
	my ($out, $ex, $err) = &execute_command_on_server(
		$vhost, "ls -t ".quotemeta($cachedir));
	if ($ex || $err) {
		return "Failed to list cache files for cleanup : ".
		       ($err || $out);
		}
	my @delfiles = reverse(split(/\r?\n/, $out));
	while(@delfiles && $totalsize > $maxsize) {
		my $f = shift(@delfiles);
		my $err = &delete_file_on_server(
			$vhost, "$cachedir/$f");
		if ($err) {
			return "Failed to delete old cached file $f : $err";
			}
		$totalsize -= $sizemap{$f};
		}
	}
return undef;
}

# cleanup_image_files(&server, imagetemp)
# Deletes any image files transferred to the host of some server
sub cleanup_image_files
{
my ($server, $temp) = @_;
return if (!$temp);
my $pfunc = "type_".$server->{'manager'}."_parent";
my $vhost = &$pfunc($server);
$vhost || return "Could not find parent system";
my ($out, $ex, $err) = &execute_command_on_server($vhost,
				"rm -rf ".quotemeta($temp));
return $err ? $err : $ex ? $out : undef;
}

# save_server_image(&image)
# Just writes out an image .img info file
sub save_server_image
{
my ($image) = @_;
&make_dir($server_images_dir, 0700);
$image->{'file'} = "$server_images_dir/$image->{'id'}.img";
&lock_file($image->{'file'});
&write_file($image->{'file'}, $image);
&unlock_file($image->{'file'});
}

# delete_server_image(&image)
# Deletes an image and all files
sub delete_server_image
{
my ($img) = @_;
if (!$img->{'nodelete'}) {
	# Only delete actual files if image doesn't have flag set to keep them
	foreach my $dest (split(/\s+/, $img->{'dest'})) {
		my ($destserver, $destpath) = &get_image_dest_path($dest);
		foreach my $fl (split(/\s+/, $img->{'files'})) {
			&delete_file_on_server($destserver, "$destpath/$fl");
			}
		}
	}
&unlink_logged("$server_images_dir/$img->{'id'}.img");
}

# generate_image_md5s(&image)
# Create the md5 key in the image hash, which is a list of MD5 checksums
# for image files
sub generate_image_md5s
{
my ($image) = @_;
$image->{'md5'} = join(" ", &get_image_md5s($image));
}

# generate_image_size(&image)
# Set the size key in the image hash to the size of all files
sub generate_image_size
{
my ($image) = @_;
my @dests = split(/\s+/, $image->{'dest'});
foreach my $dstr (@dests) {
	my ($destserver, $destpath) = &get_image_dest_path($dstr);
	$image->{'size'} = 0;
	foreach my $f (split(/\s+/, $image->{'files'})) {
		my @st = &stat_file_on_server($destserver, "$destpath/$f");
		$image->{'size'} += $st[7];
		}
	last if ($image->{'size'});
	}
}

# get_image_md5s(&image)
# Generate MD5 checksums for image files, and return them as a list
sub get_image_md5s
{
my ($image) = @_;
my @rv;
my @dests = split(/\s+/, $image->{'dest'});
foreach my $dstr (@dests) {
	my ($destserver, $destpath) = &get_image_dest_path($dstr);
	@rv = ( );
	my $failed;
	foreach my $f (split(/\s+/, $image->{'files'})) {
		my ($ok, $cs) = &checksum_file_on_server(
					$destserver, $destpath."/".$f);
		push(@rv, $ok ? $cs : "-");
		$failed++ if (!$ok);
		}
	last if (!$failed);
	}
return @rv;
}

# compare_md5_lists(&list1, &list2)
# Check if two lists are case-insentively the same
sub compare_md5_lists
{
my ($l1, $l2) = @_;
return join(" ", map { lc($_) } @$l1) eq join(" ", map { lc($_) } @$l2);
}

# verify_image_md5s(&vhost, dir, &files, &expected-mds5)
# Verify that a list of files have the expected MD5 checksums
sub verify_image_md5s
{
my ($vhost, $dir, $files, $md5s) = @_;
for(my $i=0; $i<scalar(@$files); $i++) {
	if ($md5s->[$i]) {
		my $realmd5 = &checksum_file_on_server(
				$vhost, $dir."/".$files->[$i]);
		return 0 if ($realmd5 ne $md5s->[$i]);
		}
	}
return 1;
}

# fix_virtualmin_licence_files(&server, serial, key)
# Once a server has been started, fix up any files containing Virtualmin
# licence keys. Also clears any virtualmin host-specific cache files.
sub fix_virtualmin_licence_files
{
my ($server, $serial, $key) = @_;

# Put serial into licence and update config files
my %hash = ( 'SERIAL' => $serial,
		'KEY' => $key );
foreach my $fix ("/etc/virtualmin-license",
		 "/etc/apt/sources.list",
		 "/etc/yum.repos.d/virtualmin.repo",
		 "/etc/webmin/webmin/config") {
	my $temppath = &transname();
	my $err = &get_file_from_server($server, $fix, $temppath);
	next if ($err);
	my $data = &read_file_contents($temppath);
	$data = &substitute_template($data, \%hash);
	&open_tempfile(FIXED, ">$temppath");
	&print_tempfile(FIXED, $data);
	&close_tempfile(FIXED);
	$err = &put_file_to_server($server, $temppath, $fix);
	return "Failed to save fixed $fix : $err" if ($err);
	}

# Clear collected info cache
&delete_file_on_server($server, "/etc/webmin/virtual-server/collected");

return undef;
}

# fix_virtualmin_after_boot(&server)
# Called after a new virtual system has been booted, to perform various
# tasks :
# - Import the Virtualmin GPG keys for packages. This is needed for older images
#   that don't have the latest keys. It can only be called on a running system.
# - Run freshclam for the first time, to load the virus DB.
sub fix_virtualmin_after_boot
{
my ($server) = @_;
if (&has_command_on_server($server, "apt-key")) {
	foreach my $url ($virtualmin_apt_package_key,
			 $virtualmin_webmin_apt_package_key) {
		my ($out, $ex, $err) = &execute_command_on_server($server,
			"wget -q $url -O - | apt-key add -");
		return $err if ($err);
		return $out if ($ex);
		}
	}
if (&has_command_on_server($server, "freshclam")) {
	&execute_command_on_server($server, "freshclam", 120);
	}
return undef;
}

# fix_hostname_config_files(&server, ip, shorthost, fullhost, &vhost,
#			    &dir-on-vhost, [resolv-conf])
# Fixes up all configuration files that contain the IP address or hostname
sub fix_hostname_config_files
{
my ($server, $ip, $host, $fullhost, $vhost, $dir, $resolv) = @_;

# Check if the target has Virtualmin, and thus needs 127.0.0.1 in
# /etc/resolv.conf
my $vconfig = &transname();
my $err = &get_file_from_server($vhost,
		"$dir/etc/webmin/virtual-server/config", $vconfig);
my $needs_localhost;
if (!$err) {
	my %vconfig;
	&read_file($vconfig, \%vconfig);
	$needs_localhost = $vconfig{'dns'};
	}

# Work out files we create regardless of whether the new system has them or not
my @critcal = ( "/etc/resolv.conf" );
if ($server->{'manager'} ne 'zones') {
	push(@critical, "/etc/hosts");
	}

foreach my $fix ("/etc/hosts", "/etc/hostname", "/etc/HOSTNAME",
		 "/etc/mailname", "/etc/nodename", "/etc/resolv.conf",
		 "/etc/sysconfig/network", "/etc/postfix/main.cf",
		 "/etc/conf.d/hostname", "/etc/mailman/mm_cfg.py") {
	my $fixpath = "$dir/$fix";
	my $temppath = &transname();

	# Only do files that exist, apart from /etc/hosts and /etc/resolv.conf
	# which should be everywhere
	my $err = &get_file_from_server($vhost, $fixpath, $temppath);
	next if ($err && &indexof($fix, @critical) < 0);

	my $data = &read_file_contents($temppath);
	if ($fix eq "/etc/hosts") {
		$data = "127.0.0.1 localhost\n".
			"$ip $fullhost $host\n";
		}
	elsif ($fix eq "/etc/sysconfig/network") {
		if ($data !~ s/HOSTNAME=(\S+)/HOSTNAME=$fullhost/) {
			$data .= "HOSTNAME=$fullhost\n";
			}
		}
	elsif ($fix eq "/etc/postfix/main.cf") {
		if ($data !~ s/myhostname\s*=.*/myhostname = $fullhost/) {
			$data .= "myhostname = $fullhost\n";
			}
		$data =~ s/mydestination\s*=.*/mydestination = $fullhost, $host, localhost/;
		}
	elsif ($fix eq "/etc/resolv.conf") {
		if ($resolv) {
			# From master
			$data = &read_file_contents($resolv);
			}
		else {
			# From xen host
			$data = &get_file_data_from_server($vhost, $fix);
			}
		if ($needs_localhost &&
		    $data !~ /nameserver\s+127.0.0.1/i) {
			$data = "nameserver 127.0.0.1\n".
				$data;
			}
		}
	elsif ($fix eq "/etc/conf.d/hostname") {
		# Gentoo hostname file
		$data =~ s/(HOSTNAME|hostname)="(.*)"/$1="$fullhost"/ ||
		   $data =~ s/(HOSTNAME|hostname)='(.*)'/$1='$fullhost'/ ||
		   $data =~ s/(HOSTNAME|hostname)=(\S+)/$1=$fullhost/;
		}
	elsif ($fix eq "/etc/mailman/mm_cfg.py") {
		# Mailman config file
		$data =~ s/DEFAULT_EMAIL_HOST\s*=\s*'(.*)'/DEFAULT_EMAIL_HOST = '$fullhost'/;
		$data =~ s/DEFAULT_EMAIL_HOST\s*=\s*"(.*)"/DEFAULT_EMAIL_HOST = "$fullhost"/;
		$data =~ s/DEFAULT_URL_HOST\s*=\s*'(.*)'/DEFAULT_URL_HOST = '$fullhost'/;
		$data =~ s/DEFAULT_URL_HOST\s*=\s*"(.*)"/DEFAULT_URL_HOST = "$fullhost"/;
		}
	else {
		# Other hostname file
		$data = $fullhost."\n";
		}
	&open_tempfile(FIXED, ">$temppath");
	&print_tempfile(FIXED, $data);
	&close_tempfile(FIXED);
	$err = &put_file_to_server($vhost, $temppath, $fixpath);
	return "Failed to save fixed $fix : $err" if ($err);
	}
return undef;
}

# fix_network_config_files(&server, ip, netmask, gateway, vhost, dir, [iface])
# Update network config files like /etc/sysconfig/network-scripts/ifcfg-eth0 or
# /etc/network/interfaces to use the given static IP.
sub fix_network_config_files
{
my ($server, $ip, $netmask, $gw, $vhost, $dir, $iface) = @_;
$gw = '' if ($gw eq "*");
$iface ||= "eth0";

# Work out broadcast and network addresses
my $broadcast = &net::compute_broadcast($ip, $netmask);
my $network = &net::compute_network($ip, $netmask);

# Fix relevant files
foreach my $fix ("/etc/sysconfig/network-scripts/ifcfg-$iface",
		 "/etc/network/interfaces",
		 "/etc/conf.d/net") {
	my $fixpath = "$dir/$fix";
	my $temppath = &transname();
	my $err = &get_file_from_server($vhost, $fixpath, $temppath);
	next if ($err);
	my $data = &read_file_contents($temppath);
	if ($fix =~ /ifcfg-$iface/) {
		# Redhat config file
		$data = "TYPE=Ethernet\n".
			"DEVICE=$iface\n".
			"IPADDR=$ip\n".
			"NETMASK=$netmask\n".
			"BROADCAST=$broadcast\n".
			"NETWORK=$network\n".
			"ONBOOT=yes\n".
			($gw ? "GATEWAY=$gw\n" : "");
		}
	elsif ($fix eq "/etc/network/interfaces" && $iface =~ /^venet0:/) {
		# Debian-style config, for OpenVZ
		$data = "auto venet0 $iface lo\n".
			"\n".
			"iface lo inet loopback\n".
			"\n".
			"iface venet0 inet static\n".
			"	address 127.0.0.1\n".
			"	netmask 255.255.255.255\n".
			"	broadcast 0.0.0.0\n".
			"	up route add -net 192.0.2.1 netmask 255.255.255.255 dev venet0\n".
			"	up route add default gw 192.0.2.1\n".
			"\n".
			"iface $iface inet static\n".
			"	address $ip\n".
			"	netmask $netmask\n".
			"	broadcast $broadcast\n".
			"	network $network\n".
			($gw ? "	gateway $gw\n" : "");
		}
	elsif ($fix eq "/etc/network/interfaces") {
		# Debian-style config file. Just blow away any existing config
		$data = "auto $iface lo\n".
			"\n".
			"iface lo inet loopback\n".
			"\n".
			"iface $iface inet static\n".
			"	address $ip\n".
			"	netmask $netmask\n".
			"	broadcast $broadcast\n".
			"	network $network\n".
			($gw ? "	gateway $gw\n" : "").
			"\n";
		}
	elsif ($fix eq "/etc/conf.d/net") {
		# Gentoo networking config filer
		$data = "config_$iface=( \"$ip netmask $netmask\" )\n";
		if ($gw) {
			$data .= "routes_$iface=( \"default via $gw\" )\n";
			}
		}
	&open_tempfile(FIXED, ">$temppath");
	&print_tempfile(FIXED, $data);
	&close_tempfile(FIXED);
	$err = &put_file_to_server($vhost, $temppath, $fixpath);
	return "Failed to save network config $fix : $err" if ($err);
	}

# Remove Debian network config file that is specific to MAC address
&delete_file_on_server($vhost,
	"$dir/etc/udev/rules.d/70-persistent-net.rules");

return undef;
}

# fix_additional_network_interface_files(&server, &ips, &netmasks, &gateways,
# 					 vhost, dir, [base-iface])
# Create boot-time configs for additional network interfaces, assumed to
# start with eth1.
sub fix_additional_network_interface_files
{
my ($server, $ips, $netmasks, $gws, $vhost, $dir, $iface) = @_;
$iface ||= "eth0";

# Work out file we are editing
my ($fix, $data);
foreach my $f ("/etc/sysconfig/network-scripts/ifcfg-$iface",
	       "/etc/network/interfaces",
	       "/etc/conf.d/net") {
	my $fixpath = "$dir/$f";
	$data = &get_file_data_from_server($vhost, $fixpath);
	if ($data) {
		$fix = $f;
		last;
		}
	}
return "No networking configuration file found" if (!$fix);

# Add each of the IPs
for(my $i=0; $i<@$ips; $i++) {
	my $ip = $ips->[$i];
	my $netmask = $netmasks->[$i];
	my $gw = $gws->[$i];
	$gw = '' if ($gw eq "*");
	if ($iface =~ /^(\S+)(\d+)$/) {
		$iface = $1.($2+1);
		}
	my $broadcast = &net::compute_broadcast($ip, $netmask);
	my $network = &net::compute_network($ip, $netmask);
	if ($fix =~ /^(\/etc\/sysconfig\/network-scripts\/ifcfg-)\S+$/) {
		# Create new redhat-style config file
		$data = "TYPE=Ethernet\n".
			"DEVICE=$iface\n".
			"IPADDR=$ip\n".
			"NETMASK=$netmask\n".
			"BROADCAST=$broadcast\n".
			"NETWORK=$network\n".
			"ONBOOT=yes\n".
			($gw ? "GATEWAY=$gw\n" : "");
		$fix = $1.$iface;
		}
	elsif ($fix eq "/etc/network/interfaces") {
		# Append Debian networking block
		$data .= "auto $iface\n".
			 "\n".
			 "iface $iface inet static\n".
			 "	address $ip\n".
			 "	netmask $netmask\n".
			 "	broadcast $broadcast\n".
			 "	network $network\n".
			 ($gw ? "	gateway $gw\n" : "");
		}
	elsif ($fix eq "/etc/conf.d/net") {
		# Add Gentoo networking line
		$data .= "config_$iface=( \"$ip netmask $netmask\" )\n";
		if ($gw) {
			$data .= "routes_$iface=( \"default via $gw\" )\n";
			}
		}
	my $fixpath = "$dir/$fix";
	my $err = &put_file_data_to_server($vhost, $data, $fixpath);
	return "Failed to save network config $fix : $err" if ($err);
	}
return undef;
}

# fix_ssh_root_login(&server)
# Configure a server to allow SSH logins by root. Returns undef if it was done,
# OK if already allowed, NONE if no SSH config was found, or an error message
sub fix_ssh_root_login
{
my ($server) = @_;
my $sc = &transname();
my $sshd_config = "/etc/ssh/sshd_config";
if (!&get_file_from_server($server, $sshd_config, $sc)) {
	my $changed = 0;
	my $lref = &read_file_lines($sc);
	foreach my $l (@$lref) {
		if ($l =~ /^\s*PermitRootLogin\s+(\S+)/ && $1 ne 'yes') {
			$l = "PermitRootLogin yes";
			$changed = 1;
			}
		}
	&flush_file_lines($sc);
	if ($changed) {
		return &put_file_to_server($server, $sc, $sshd_config);
		}
	else {
		return "OK";
		}
	}
return "NONE";
}

# update_virtualmin_packages(&server)
# On a server created from an image with Virtualmin installed, update all
# packages that need it May call the print functions.
sub update_virtualmin_packages
{
my ($server) = @_;
my $info = &get_server_collected($server);
if ($server->{'status'} eq 'virt' && $info && @{$info->{'poss'}}) {
	&$first_print(&text('update_ipackages', scalar(@{$info->{'poss'}})));
	my @allgot;
	&$indent_print();
	foreach $p (&sort_package_updates(@{$info->{'poss'}})) {
		&$first_print(&text('update_ipkg', $p->{'name'},
						   $p->{'version'}));
		my $got = &install_package_update($server, $p);
		push(@allgot, @$got) if (ref($got));
		if (ref($got)) {
			&$second_print($text{'update_idone'});
			}
		else {
			&$second_print(&text('update_ipkgerr', $got));
			}
		}
	&$outdent_print();
	&$second_print(&text('update_itotal', scalar(@allgot)));
	if (@allgot) {
		&refresh_server_updates($server, \@allgot);
		&check_server_status($server);
		&save_managed_server($server);
		}
	}
}

# munge_virtualmin_licence_files(&server)
# On a server that is being prepared for imaging, modify the serial number in
# all Virtualmin licence files. Returns a list of original filenames and
# contents (for later restoring) on success, or an error string on failure.
sub munge_virtualmin_licence_files
{
my ($server) = @_;
my @rv;
foreach my $fix ("/etc/virtualmin-license",
		 "/etc/apt/sources.list",
		 "/etc/yum.repos.d/virtualmin.repo",
		 "/etc/webmin/webmin/config") {
	my $temppath = &transname();
	my $err = &get_file_from_server($server, $fix, $temppath);
	next if ($err);
	my $data = &read_file_contents($temppath);
	if ($fix eq "/etc/virtualmin-license" &&
	    $data =~ /SerialNumber=GPL/) {
		# No need to munge GPL licence file
		next;
		}
	push(@rv, [ $fix, $data ]);
	if ($fix eq "/etc/virtualmin-license") {
		# Can create entirely
		$data = "SerialNumber=\${SERIAL}\n".
			"LicenseKey=\${KEY}\n";
		}
	elsif ($fix eq "/etc/apt/sources.list" ||
	       $fix eq "/etc/yum.repos.d/virtualmin.repo") {
		# Need to replace login to Virtualmin repo
		$data =~ s/http:\/\/(.*)\@software.virtualmin.com/http:\/\/\$SERIAL:\$KEY\@software.virtualmin.com/g;
		}
	elsif ($fix eq "/etc/webmin/webmin/config") {
		# Need to change updates server lines
		$data =~ s/upuser=.*/upuser=\$SERIAL/g;
		$data =~ s/uppass=.*/uppass=\$KEY/g;
		}
	$err = &put_file_data_to_server($server, $data, $fix);
	return "Failed to save munged $fix : $err" if ($err);
	}
return \@rv;
}

# munge_shadow_root_password(&server)
# Changes the root password in /etc/shadow or /etc/passwd to 'changeme', and
# in /etc/webmin/miniserv.users if needed. Returns a list of files changed and
# original contents, or an error string
sub munge_shadow_root_password
{
my ($server) = @_;
my @rv;
my $salt = substr(time(), -2);

# Do /etc/shadow or /etc/passwd
my $shadow = &transname();
my $passfile = "/etc/shadow";
my $err = &get_file_from_server($server, $passfile, $shadow);
if ($err) {
	$passfile = "/etc/passwd";
	$err = &get_file_from_server($server, $passfile, $shadow);
	}
if (!$err) {
	# Fix password in first column for root
	my $data = &read_file_contents($shadow);
	push(@rv, [ $passfile, $data ]);
	my $lref = &read_file_lines($shadow);
	foreach my $l (@$lref) {
		my @w = split(/:/, $l, -1);
		if ($w[0] eq "root") {
			$w[1] = &unix_crypt("changeme", $salt);
			$l = join(':', @w);
			}
		}
	&flush_file_lines($shadow);
	$err = &put_file_to_server($server, $shadow, $passfile);
	return "Failed to save munged $passfile : $err" if ($err);
	}

# Do /etc/webmin/miniserv.users for root or admin
my $users = &transname();
my $passfile = "/etc/webmin/miniserv.users";
my $err = &get_file_from_server($server, $passfile, $users);
if (!$err) {
	my $data = &read_file_contents($users);
	push(@rv, [ $passfile, $data ]);
	my $lref = &read_file_lines($users);
	my $changed;
	foreach my $l (@$lref) {
                my @w = split(/:/, $l, -1);
		if (($w[0] eq "root" || $w[0] eq "admin") && $w[1] ne "x") {
			$w[1] = &unix_crypt("changeme", $salt);
			$l = join(':', @w);
			$changed++;
			}
		}
	&flush_file_lines($users);
	if ($changed) {
		$err = &put_file_to_server($server, $users, $passfile);
		return "Failed to save munged miniserv.users : $err" if ($err);
		}
	}

return \@rv;
}

# munge_log_files(&server)
# Clears root's shell history files, everything in /tmp, and most logs
sub munge_log_files
{
my ($server) = @_;

# Clear history files
foreach my $f (".bash_history", ".mysql_history",
	       ".psql_history", ".history") {
	&delete_file_on_server($server, "/root/$f");
	&delete_file_on_server($server, "/$f");
	}

# Clear all of /tmp
&delete_file_on_server($server, "/tmp/*", 1);

# Clear common logs
my $logdir = "/var/log";
foreach my $f ("messages", "auth.log", "secure", "daemon.log", "syslog",
	       "dmesg", "mailman", "mysql.err", "mysql.log", "lastlog",
	       "wtmp", "dpkg.log", "anaconda.log", "boot.log", "cron",
	       "faillog", "freshclam.log", "maillog", "mail.*", "mysqld.log",
	       "rpmpkgs", "xferlog", "yum.log") {
	&delete_file_on_server($server, "$logdir/$f", 1);
	}

# Clear rotated logs
&delete_file_on_server($server, "$logdir/*.gz", 1);
&delete_file_on_server($server, "$logdir/*.[0-9]", 1);
&delete_file_on_server($server, "$logdir/*-[0-9]*[0-9]", 1);

# Clear Webmin logs
&delete_file_on_server($server, "/var/webmin/miniserv.log");
&delete_file_on_server($server, "/var/webmin/webmin.log");

return [ ];	# Files cannot be reverted
}

# munge_authorized_key(&server)
# Removes all keys from ~root/.ssh/authorized_keys* .  Returns a list of files
# changed and original contents, or an error string
sub munge_authorized_key
{
my ($server) = @_;
my ($roothome, $ex, $err) = &execute_command_on_server($server, "echo ~");
$roothome =~ s/\r|\n//g;
$roothome ||= "/root";
my @rv;
foreach my $fix ("$roothome/.ssh/authorized_keys",
		 "$roothome/.ssh/authorized_keys2",
		 "$roothome/.ssh/known_hosts",
		 "$roothome/.ssh/known_hosts2",) {
	my $data = &get_file_data_from_server($server, $fix);
	if ($data) {
		my $err = &put_file_data_to_server($server, "", $fix);
		if ($err) {
			return "Failed to truncate $fix : $err";
			}
		else {
			push(@rv, [ $fix, $data ]);
			}
		}
	}
return \@rv;
}

# fetch_image_files(&vhost, &image, tempdir, show-progress-dots?, &server)
# Transfers from some host system the files that make up some image to
# the destination defined in the image. Since this can take some time, outputs
# progress dots.
# May transfer to multiple destinations if defined
sub fetch_image_files
{
my ($vhost, $image, $temp, $progress, $server) = @_;
my $totalsize = 0;
my $oldsize;
my $tohost = 0;
my @stors = &list_storages();

foreach my $dest (split(/\s+/, $image->{'dest'})) {
	# Work out where to transfer the image to
	my ($destserver, $destpath) = &get_image_dest_path($dest);
	&make_dir_on_server($destserver, $destpath, 0700, 1);
	if ($destserver->{'id'} eq $vhost->{'id'}) {
		$tohost = 1;
		}

	# Transfer each file in the image
	my $i_totalsize = 0;
	my $i_oldsize;
	my @imgfiles = split(/\s+/, $image->{'files'});
	foreach my $f (@imgfiles) {
		my $path = "$destpath/$f";
		my @oldst = &stat_file_on_server($destserver, $path);
		$i_oldsize += $st[7];
		my $pid = fork();
		my $outtemp = &tempname();
		if (!$pid) {
			my $err = &transfer_file_between_servers(
				$vhost, $destserver, "$temp/$f", $path, 0, 1);
			open(OUT, ">$outtemp");
			print OUT $err;
			close(OUT);
			exit($err ? 1 : 0);
			}
		while(1) {
			my $expid = waitpid($pid, WNOHANG);
			last if ($expid == $pid);
			print "." if ($progress);
			sleep(1);
			}
		my $err = &read_file_contents($outtemp);
		&unlink_file($outtemp);
		if ($err) {
			return "Failed to copy $f : $err";
			}
		my @st = &stat_file_on_server($destserver, $path);
		if (!@st) {
			return "Copy of $f to $path failed";
			}
		$i_totalsize += $st[7];
		}
	if (!$totalsize) {
		$totalsize = $i_totalsize;
		$oldsize = $i_oldsize;
		}

	# Update size for this storage location
	my ($stor) = grep { $_->{'dest'} eq $dest } @stors;
	if ($stor) {
		&compute_storage_size($stor);
		&save_storage($stor);
		}
	}

# If caching is enabled, save in the cache too .. unless the image was stored
# locally anyway.
my $prefix = $server->{'manager'};
$prefix = "zone" if ($prefix eq "zones");
if ($vhost->{$prefix.'_cachesize'} && !$vhost) {
	# Create the cache dir if needed
	my $cachedir = $vhost->{$prefix.'_cachedir'} || $images_cache_dir;
	my $err = &make_dir_on_server($vhost, $cachedir, 0700, 1);
	if ($err) {
		return "Failed to create cache directory $cachedir : $err";
		}

	# If the cache would be too big after adding the new images,
	# clean it up first
	my $maxsize = $vhost->{$prefix.'_cachesize'} * 1024 * 1024 * 1024;
	my $err = &cleanup_cache_dir($vhost, $cachedir, $maxsize,
					$totalsize - $oldsize);
	return "Cache cleanup failed : $err" if ($err);

	# Copy them into the cache
	foreach my $f (@imgfiles) {
		my ($out, $ex, $err) = &execute_command_on_server(
			$vhost, "cp ".quotemeta("$temp/$f")." ".
				      quotemeta("$cachedir/$f"));
		if ($ex || $err) {
			return "Failed to copy $f to cache : ".($err || $out);
			}
		}
	}

return undef;
}

# munge_all_files(&server, [no-authkeys], [no-serials])
# Munges Virtualmin licences, the root password and authorized keys, printing
# progress reports as they are done. Returns a status code and a list of munged
# files and their original content.
sub munge_all_files
{
my ($server, $noauth, $noserial) = @_;
my @munged;
my $ok = 1;
foreach my $m ([ \&munge_virtualmin_licence_files, 'mkimage_mungelicence' ],
	       [ \&munge_shadow_root_password, 'mkimage_mungeshadow' ],
	       [ \&munge_log_files, 'mkimage_mungelogs' ],
	       [ \&munge_authorized_key, 'mkimage_mungessh' ]) {
	next if ($m->[1] eq 'mkimage_mungessh' && $noauth);
	next if ($m->[1] eq 'mkimage_mungelicence' && $noserial);
	&$first_print($text{$m->[1]});
	my $mfunc = $m->[0];
	my $munged = &$mfunc($server);
	if (!ref($munged)) {
		&$second_print(&text('mkimage_emunge', $munged));
		$ok = 0;
		}
	else {
		push(@munged, @$munged);
		&$second_print($text{'create_done'});
		}
	}
return ($ok, \@munged);
}

# unmunge_all_files(&server, &files)
# Puts back munged files, while outputting messages to the user. Return 1 on
# success, 0 on failure.
sub unmunge_all_files
{
my ($server, $munged) = @_;
&$first_print($text{'mkimage_unmunge'});
foreach my $m (@$munged) {
	my ($file, $data) = @$m;
	my $err = &put_file_data_to_server($server, $data, $file);
	if ($err) {
		&$second_print(&text('create_eunmunge', $file, $err));
		return 0;
		}
	}
&$second_print($text{'create_done'});
return 1;
}

# show_host_images_cache_table(&server, prefix)
# Output a table for configuring image caching on a host system
sub show_host_images_cache_table
{
my ($server, $prefix) = @_;
print &ui_hidden_table_start($text{'xen_header3'}, "width=100%", 2,
			     "cache", 0);

# Cache size (in GB)
print &ui_table_row($text{'xen_cachesize'},
	&ui_opt_textbox("cachesize", $server->{$prefix.'_cachesize'},
			10, $text{'xen_nocache'}, $text{'xen_atmost'})." GB");

# Directory on host
print &ui_table_row($text{'xen_cachedir'},
	&ui_opt_textbox("cachedir", $server->{$prefix.'_cachedir'}, 50,
			$text{'default'}." (<tt>$images_cache_dir</tt>)<br>",
			$text{'xen_cachein'}));

print &ui_hidden_table_end("cache");
}

# parse_host_images_cache_table(&server, &in, prefix)
# Update a host system with inputs from show_host_images_cache_table
sub parse_host_images_cache_table
{
my ($server, $in, $prefix) = @_;

# Parse cache size
if ($in->{'cachesize_def'}) {
	delete($server->{$prefix.'_cachesize'});
	}
else {
	$in->{'cachesize'} =~ /^\d+$/ ||
		&error($text{'xen_ecachesize'});
	$server->{$prefix.'_cachesize'} = $in->{'cachesize'};
	}

# Parse cache directory
if ($in->{'cachedir_def'}) {
	delete($server->{$prefix.'_cachedir'});
	}
else {
	$in->{'cachedir'} =~ /^\/\S+/ ||
		&error($text{'xen_ecachedir'});
	$server->{$prefix.'_cachedir'} = $in->{'cachedir'};
	}
}

# nice_image_destination(string)
# Convert a image storage string into a human-readable format. Can be empty,
# indicating the cloudmin master. Supports a space-separated list of dests.
sub nice_image_destination
{
my ($str) = @_;
return $text{'images_tomaster'} if (!$str);
my @dests = split(/\s+/, $str);
return join(", ", map { &nice_backup_destination($_) } @dests);
}

# get_image_dest_path(dest, [&vhost])
# Returns the Cloudmin server object and path for an image destination. Assumes
# the master system if blank.
sub get_image_dest_path
{
my ($deststr, $vhost) = @_;
my $dest = &parse_backup_destination($deststr || $server_images_dir);
my $destserver;
if ($dest->{'mode'} == 0) {
	$destserver = &get_this_managed_server();
	}
elsif ($dest->{'mode'} == 1) {
	if ($vhost) {
		$destserver = $vhost;
		}
	else {
		return ( );
		}
	}
elsif ($dest->{'mode'} == 2) {
	$destserver = &get_managed_server_by("id", $dest->{'id'});
	}
return ( $destserver, $dest->{'path'} );
}

# set_image_location(&image, &host-system)
# Sets an image's 'dest' field based on the global default image locations.
# Returns undef on success or an error message on failure.
sub set_image_location
{
my ($image, $vhost) = @_;
my @storages = &list_storages();
my @dests;
foreach my $storage (@storages) {
	my $dest = &parse_backup_destination($storage->{'dest'});
	if ($dest->{'mode'} == 1) {
		# Convert to actual host system ID
		$dest->{'mode'} = 2;
		$dest->{'id'} = $vhost->{'id'};
		}
	if ($storage->{'location'}) {
		# Check if host is in one of the location groups
		my @locs = split(/\s+/, $storage->{'location'});
		next if (&indexof($vhost->{'location'}, @locs) < 0);
		}
	my $deststr = &join_backup_destination($dest);
	my ($destserver, $destpath) = &get_image_dest_path($deststr);
	if (&can_ssh_status($destserver)) {
		push(@dests, $deststr);
		}
	}
if (!@dests) {
	return "All possible image storage systems are down";
	}
$image->{'dest'} = join(" ", @dests);
return undef;
}

# list_storages()
# Returns a list of image storage locations, each of which is a hash ref with
# 'id', 'dest', 'desc' and 'location' fields.
sub list_storages
{
my @rv;
opendir(STORAGES, $image_storages_dir);
foreach my $f (readdir(STORAGES)) {
	next if ($f eq "." || $f eq "..");
	my %storage;
	&read_file("$image_storages_dir/$f", \%storage);
	$storage{'id'} = $f;
	push(@rv, \%storage);
	}
closedir(STORAGES);
if (!@rv) {
	# Create default storage
	push(@rv, { 'id' => 1,
		    'default' => 1,
		    'desc' => $text{'storages_defstor'},
		    'dest' => "master:".$server_images_dir });
	&save_storage($rv[0]);
	}
foreach my $s (@rv) {
	if (!$s->{'size'}) {
		&compute_storage_size($s);
		}
	}
return @rv;
}

# get_storage(id)
# Returns an image storage location looked up by ID
sub get_storage
{
my ($id) = @_;
my ($rv) = grep { $_->{'id'} eq $id } &list_storages();
return $rv;
}

# save_storage(&storage)
# Create or update an image storage location
sub save_storage
{
my ($storage) = @_;
if (!-d $image_storages_dir) {
	&make_dir($image_storages_dir, 0700);
	}
$storage->{'id'} ||= &server_id();
&lock_file("$image_storages_dir/$storage->{'id'}");
&write_file("$image_storages_dir/$storage->{'id'}", $storage);
&unlock_file("$image_storages_dir/$storage->{'id'}");
}

# delete_storage(&delete)
# Delete an existing image storage location (but not files in it)
sub delete_storage
{
my ($storage) = @_;
&unlink_logged("$image_storages_dir/$storage->{'id'}");
}

# compute_storage_size(&storage)
# Sets the size field to the size in bytes of a storage location
sub compute_storage_size
{
my ($storage) = @_;
my ($server, $path) = &get_image_dest_path($storage->{'dest'});
if ($server) {
	my $size = &disk_usage_on_server($server, $path);
	if ($size =~ /^\d+$/) {
		$storage->{'size'} = $size;
		}
	}
}

# transfer_image_files_to_storage(&image, &storage)
# Transfer all files in some image to some storage location
sub transfer_image_files_to_storage
{
my ($image, $stor) = @_;
my $err = &transfer_image_files_to_dest($image, split(/\s+/, $stor->{'dest'}));
if (!$err) {
	&compute_storage_size($stor);
	&save_storage($stor);
	}
return $err;
}

# transfer_image_files_to_dest(&image, dest, ...)
# Transfer all files in some image to some list of destinations
sub transfer_image_files_to_dest
{
my ($image, @dests) = @_;

# Find the first usable source location
my @imgfiles = split(/\s+/, $image->{'files'});
my ($copyserver, $copypath, %copysize);
foreach my $src (split(/\s+/, $image->{'dest'})) {
	my ($srcserver, $srcpath) = &get_image_dest_path($src);
	my $missing = 0;
	foreach my $f (@imgfiles) {
		my @st = &stat_file_on_server($srcserver, "$srcpath/$f");
		$missing++ if (!@st);
		$copysize{$f} = $st[7] if (@st);
		}
	if (!$missing) {
		($copyserver, $copypath) = ($srcserver, $srcpath);
		last;
		}
	}
if (!$copyserver) {
	return "No source to copy from found!";
	}

# Copy to each of the destinations that are missing any files
foreach my $dest (@dests) {
	my ($destserver, $destpath) = &get_image_dest_path($dest);
	foreach my $f (@imgfiles) {
		my @st = &stat_file_on_server($destserver, "$destpath/$f");
		next if (@st && $st[7] == $copysize{$f});	# Already got it
		my $err = &transfer_file_between_servers(
			$copyserver, $destserver,
			"$copypath/$f", "$destpath/$f", 0, 1);
		if ($err) {
			return "Failed to copy from $copyserver->{'host'} to ".
			       "$destserver->{'host'} : $err";
			}
		}
	}

return undef;
}

# delete_image_files_from_dest(&image, dest, ...)
# Delete all files in some image from some list of destinations
sub delete_image_files_from_dest
{
my ($image, @dests) = @_;
my @imgfiles = split(/\s+/, $image->{'files'});
# Copy to each of the destinations that are missing any files
foreach my $dest (@dests) {
	my ($destserver, $destpath) = &get_image_dest_path($dest);
        foreach my $f (@imgfiles) {
		my @st = &stat_file_on_server($destserver, "$destpath/$f");
		next if (!@st);		# Already gone
		my $err = &delete_file_on_server($destserver, "$destpath/$f");
		return $err if ($err);
		}
	}
return undef;
}

# image_storage_mismatches(&image, &storages)
# Compares the locations an image is in with those defined in the given
# storages, and returns the number of missing destinations, and the number
# of extra.
sub image_storage_mismatches
{
my ($image, $stors) = @_;
my $vhost = $image->{'vhost'} ? &get_managed_server($image->{'vhost'}) : undef;
my (%gotdests, %stordests, $onhost);
foreach my $dstr (split(/\s+/, $image->{'dest'})) {
	$gotdests{&normalize_backup_destination($dstr)} = 1;
	}
foreach my $stor (@$stors) {
	$stordests{&normalize_backup_destination($stor->{'dest'})} = 1;
	my $dest = &parse_backup_destination($stor->{'dest'});
	if ($dest->{'mode'} == 1 && !$vhost) {
		# On-host that we don't know, so can't really compare
		$onhost++;
		}
	}
my @missing = grep { !$gotdests{$_} } keys %stordests;
my @extra = grep { !$stordests{$_} } keys %gotdests;
return ( scalar(@missing)-$onhost, scalar(@extra) );
}

# compute_image_dests(&image)
# Updates the dest field of an image with the locations in which image files
# actually exist.
sub compute_image_dests
{
my ($image) = @_;
my @okdests;
my @files = split(/\s+/, $image->{'files'});
foreach my $dest (split(/\s+/, $image->{'dest'})) {
	my ($destserver, $destpath) = &get_image_dest_path($dest);
	if (!$destserver) {
		# Host no longer exists
		}
	elsif (!&can_ssh_status($destserver)) {
		# If cannot connect right now, assume OK
		push(@okdests, $dest);
		}
	else {
		# Check each file
		my $missing = 0;
		foreach my $f (@files) {
			my @st = &stat_file_on_server($destserver,
						      "$destpath/$f");
			$missing++ if (!@st);
			}
		if (!$missing) {
			push(@okdests, $dest);
			}
		}
	}
$image->{'dest'} = join(" ", @okdests);
return undef;
}

1;

