# Functions for server image management

use POSIX;

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
	next if ($type && $img{'manager'} ne $type);	# Don't want this type
	next if (!$server_management_types{$img{'manager'}});	# Not supported
	local $size = 0;
	foreach my $fl (split(/\s+/, $img{'files'})) {
		local @st = stat("$server_images_dir/$fl");
		if (@st) {
			$size += $st[7];
			}
		else {
			$img{'partial'} = 1;
			}
		}
	$img{'size'} = $size;
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
local ($id) = @_;
local ($img) = grep { $_->{'id'} eq $id } &list_server_images();
return $img;
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
&save_server_image(\%got);
return \%got;
}

# download_server_image_files(&image)
# Downloads each of the needed files for some image, and outputs progress.
# Returns undef on success, or an error message on failure.
sub download_server_image_files
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

# create_image_files_tempdir(&vhost, id)
# Attempts to create a temp directory for image files on some host, and returns
# either (1, dir) or (0, some error).
sub create_image_files_tempdir
{
local ($vhost, $id) = @_;

local $temp;
if ($vhost->{'status'} eq 'virt' || $vhost->{'status'} eq 'novirt') {
	# Ask the remote Webmin
	&remote_foreign_require($vhost, "webmin", "webmin-lib.pl");
	$temp = &remote_foreign_call($vhost, "webmin", "tempname", $id);
	$temp || return (0, $last_remote_error);
	}
else {
	# Use configure dir, or /tmp
	local $ostemp = $vhost->{'type'} eq 'solaris' ? '/var/tmp' : '/tmp';
	local $tempdir = $config{'img_temp'} || $ostemp;
	$temp = "$tempdir/$id";
	}
local ($out, $ex, $err) = &execute_command_on_server($vhost,
				"rm -rf ".quotemeta($temp)." ; ".
				"mkdir ".quotemeta($temp));
return (0, $err) if ($err);
return (0, $out) if ($ex);
return (1, $temp);
}

# transfer_image_files(&server, [show-progress-dots])
# Transfers all files for some system's image to a parent host, and returns
# a success flag (0=failed, 1=transferred, 2=not needed) the path to the temp
# directory created for them.
sub transfer_image_files
{
local ($server, $progress) = @_;
local $pfunc = "type_".$server->{'manager'}."_parent";
local $vhost = &$pfunc($server);
$vhost || return (0, "Could not find parent system");
local ($img) = grep { $_->{'id'} eq $server->{'image'} } &list_server_images();
$img || return (0, "Could not find image with ID $server->{'image'}");

# No need to transfer if the host is the VM2 master
if ($vhost->{'manager'} eq 'this') {
	return (2, $server_images_dir);
	}

# Choose a temp dir
local ($tempok, $temp) = &create_image_files_tempdir($vhost, $img->{'id'});
return (0, $temp) if (!$tempok);

# Copy files from local to that dir
# XXX not if local
foreach my $f (split(/\s+/, $img->{'files'})) {
	local $path = "$server_images_dir/$f";
	local $pid = fork();
	local $outtemp = &tempname();
	if (!$pid) {
		local $err = &put_file_to_server($vhost, $path, "$temp/$f");
		open(OUT, ">$outtemp");
		print OUT $err;
		close(OUT);
		exit($err ? 1 : 0);
		}
	while(1) {
		local $expid = waitpid($pid, WNOHANG);
		last if ($expid == $pid);
		print "." if ($progress);
		sleep(1);
		}
	local $err = &read_file_contents($outtemp);
	&unlink_file($outtemp);
	if ($err) {
		return (0, "Failed to copy $f : $err");
		}
	}

return (1, $temp);
}

# cleanup_image_files(&server, imagetemp)
# Deletes any image files transferred to the host of some server
sub cleanup_image_files
{
local ($server, $temp) = @_;
return if (!$temp);
local $pfunc = "type_".$server->{'manager'}."_parent";
local $vhost = &$pfunc($server);
$vhost || return "Could not find parent system";
local ($out, $ex, $err) = &execute_command_on_server($vhost,
				"rm -rf ".quotemeta($temp));
return $err ? $err : $ex ? $out : undef;
}

# save_server_image(&image)
# Just writes out an image .img info file
sub save_server_image
{
local ($image) = @_;
&make_dir($server_images_dir, 0700);
&write_file("$server_images_dir/$image->{'id'}.img", $image);
}

# delete_server_image(&image)
# Deletes a local image and all files
sub delete_server_image
{
local ($img) = @_;
foreach my $fl (split(/\s+/, $img->{'files'})) {
	unlink("$server_images_dir/$fl");
	}
unlink("$server_images_dir/$img->{'id'}.img");
}

# generate_image_md5s(&image)
# Create the md5 key in the image hash, which is a list of MD5 checksums
# for image files
sub generate_image_md5s
{
local ($image) = @_;
$image->{'md5'} = join(" ", &get_image_md5s($image));
}

# get_image_md5s(&image)
# Generate MD5 checksums for image files, and return them as a list
sub get_image_md5s
{
local ($image) = @_;
local @rv;
foreach my $f (split(/\s+/, $image->{'files'})) {
	local $out = &backquote_command("md5sum ".
		quotemeta("$server_images_dir/$f")." 2>/dev/null </dev/null");
	$out =~ s/\r|\n//g;
	$out =~ s/^(\S+)\s+.*/$1/;
	push(@rv, $out || "-");
	}
return @rv;
}

# compare_md5_lists(&list1, &list2)
# Check if two lists are case-insentively the same
sub compare_md5_lists
{
local ($l1, $l2) = @_;
return join(" ", map { lc($_) } @$l1) eq join(" ", map { lc($_) } @$l2);
}

# fix_virtualmin_licence_files(&server, serial, key)
# Once a server has been started, fix up any files containing Virtualmin
# licence keys. Also clears any virtualmin host-specific cache files.
sub fix_virtualmin_licence_files
{
local ($server, $serial, $key) = @_;

# Put serial into licence and update config files
local %hash = ( 'SERIAL' => $serial,
		'KEY' => $key );
foreach my $fix ("/etc/virtualmin-license",
		 "/etc/apt/sources.list",
		 "/etc/yum.repos.d/virtualmin.repo",
		 "/etc/webmin/webmin/config") {
	local $temppath = &transname();
	local $err = &get_file_from_server($server, $fix, $temppath);
	next if ($err);
	local $data = &read_file_contents($temppath);
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
local ($server) = @_;
if (&has_command_on_server($server, "apt-key")) {
	foreach my $url ($virtualmin_apt_package_key,
			 $virtualmin_webmin_apt_package_key) {
		local ($out, $ex, $err) = &execute_command_on_server($server,
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
local ($server, $ip, $host, $fullhost, $vhost, $dir, $resolv) = @_;

# Check if the target has Virtualmin, and thus needs 127.0.0.1 in
# /etc/resolv.conf
local $vconfig = &transname();
local $err = &get_file_from_server($vhost,
		"$dir/etc/webmin/virtual-server/config", $vconfig);
local $needs_localhost;
if (!$err) {
	local %vconfig;
	&read_file($vconfig, \%vconfig);
	$needs_localhost = $vconfig{'dns'};
	}

foreach my $fix ("/etc/hosts", "/etc/hostname", "/etc/HOSTNAME",
		 "/etc/mailname", "/etc/nodename", "/etc/resolv.conf",
		 "/etc/sysconfig/network", "/etc/postfix/main.cf",
		 "/etc/conf.d/hostname") {
	local $fixpath = "$dir/$fix";
	local $temppath = &transname();

	# Only do files that exist, apart from /etc/hosts and /etc/resolv.conf
	# which should be everywhere
	local $err = &get_file_from_server($vhost, $fixpath, $temppath);
	next if ($err && $fix ne "/etc/hosts" &&
			 $fix ne "/etc/resolv.conf");

	local $data = &read_file_contents($temppath);
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
		$data =~ s/HOSTNAME="(.*)"/HOSTNAME="$fullhost"/ ||
		   $data =~ s/HOSTNAME='(.*)'/HOSTNAME='$fullhost'/ ||
		   $data =~ s/HOSTNAME=(\S+)/HOSTNAME=$fullhost/;
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

# fix_network_config_files(&server, ip, netmask, gateway, vhost, dir)
# Update network config files like /etc/sysconfig/network-scripts/ifcfg-eth0 or
# /etc/network/interfaces to use the given static IP.
sub fix_network_config_files
{
local ($server, $ip, $netmask, $gw, $vhost, $dir) = @_;

# Work out broadcast and network addresses
local $broadcast = &net::compute_broadcast($ip, $netmask);
local $network = &net::compute_network($ip, $netmask);

# Fix relevant files
foreach my $fix ("/etc/sysconfig/network-scripts/ifcfg-eth0",
		 "/etc/network/interfaces",
		 "/etc/conf.d/net") {
	local $fixpath = "$dir/$fix";
	local $temppath = &transname();
	local $err = &get_file_from_server($vhost, $fixpath, $temppath);
	next if ($err);
	local $data = &read_file_contents($temppath);
	if ($fix =~ /ifcfg-eth0$/) {
		# Redhat config file
		$data = "TYPE=Ethernet\n".
			"DEVICE=eth0\n".
			"IPADDR=$ip\n".
			"NETMASK=$netmask\n".
			"BROADCAST=$broadcast\n".
			"NETWORK=$network\n".
			"ONBOOT=yes\n".
			($gw ? "GATEWAY=$gw\n" : "");
		}
	elsif ($fix eq "/etc/network/interfaces") {
		# Debian-style config file. Just blow away any existing config
		$data = "auto eth0 lo\n".
			"\n".
			"iface lo inet loopback\n".
			"\n".
			"iface eth0 inet static\n".
			"	address $ip\n".
			"	netmask $netmask\n".
			"	broadcast $broadcast\n".
			"	network $network\n".
			($gw ? "	gateway $gw\n" : "");
		}
	elsif ($fix eq "/etc/conf.d/net") {
		# Gentoo networking config filer
		$data = "config_eth0=( \"$ip netmask $netmask\" )\n";
		if ($gw) {
			$data .= "routes_eth0=( \"default via $gw\" )\n";
			}
		}
	&open_tempfile(FIXED, ">$temppath");
	&print_tempfile(FIXED, $data);
	&close_tempfile(FIXED);
	$err = &put_file_to_server($vhost, $temppath, $fixpath);
	return "Failed to save network config $fix : $err" if ($err);
	}
return undef;
}

# fix_ssh_root_login(&server)
# Configure a server to allow SSH logins by root. Returns undef if it was done,
# OK if already allowed, NONE if no SSH config was found, or an error message
sub fix_ssh_root_login
{
local ($server) = @_;
local $sc = &transname();
local $sshd_config = "/etc/ssh/sshd_config";
if (!&get_file_from_server($server, $sshd_config, $sc)) {
	local $changed = 0;
	local $lref = &read_file_lines($sc);
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
local ($server) = @_;
local $info = &get_server_collected($server);
if ($server->{'status'} eq 'virt' && $info && @{$info->{'poss'}}) {
	&$first_print(&text('update_ipackages', scalar(@{$info->{'poss'}})));
	my @allgot;
	&$indent_print();
	foreach $p (&sort_package_updates(@{$info->{'poss'}})) {
		&$first_print(&text('update_ipkg', $p->{'name'},
						   $p->{'version'}));
		local $got = &install_package_update($server, $p);
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
local ($server) = @_;
local @rv;
foreach my $fix ("/etc/virtualmin-license",
		 "/etc/apt/sources.list",
		 "/etc/yum.repos.d/virtualmin.repo",
		 "/etc/webmin/webmin/config") {
	local $temppath = &transname();
	local $err = &get_file_from_server($server, $fix, $temppath);
	next if ($err);
	local $data = &read_file_contents($temppath);
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
local ($server) = @_;
local @rv;
local $salt = substr(time(), -2);

# Do /etc/shadow or /etc/passwd
local $shadow = &transname();
local $passfile = "/etc/shadow";
local $err = &get_file_from_server($server, $passfile, $shadow);
if ($err) {
	$passfile = "/etc/passwd";
	$err = &get_file_from_server($server, $passfile, $shadow);
	}
if (!$err) {
	# Fix password in first column for root
	local $data = &read_file_contents($shadow);
	push(@rv, [ $passfile, $data ]);
	local $lref = &read_file_lines($shadow);
	foreach my $l (@$lref) {
		local @w = split(/:/, $l, -1);
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
local $users = &transname();
local $passfile = "/etc/webmin/miniserv.users";
local $err = &get_file_from_server($server, $passfile, $users);
if (!$err) {
	local $data = &read_file_contents($users);
	push(@rv, [ $passfile, $data ]);
	local $lref = &read_file_lines($users);
	local $changed;
	foreach my $l (@$lref) {
                local @w = split(/:/, $l, -1);
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

# munge_authorized_key(&server)
# Removes all keys from ~root/.ssh/authorized_keys* .  Returns a list of files
# changed and original contents, or an error string
sub munge_authorized_key
{
local ($server) = @_;
local ($roothome, $ex, $err) = &execute_command_on_server($server, "echo ~");
$roothome =~ s/\r|\n//g;
$roothome ||= "/root";
local @rv;
foreach my $fix ("$roothome/.ssh/authorized_keys",
		 "$roothome/.ssh/authorized_keys2") {
	local $data = &get_file_data_from_server($server, $fix);
	if ($data) {
		local $err = &put_file_data_to_server($server, "", $fix);
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

# fetch_image_files(&vhost, &image, tempdir, [show-progress-dots])
# Fetches from some host system the files that make up some image, and saves
# them in the /var/webmin/server-manager directory on this system. Since this
# can take some time, outputs progress dots.
sub fetch_image_files
{
local ($vhost, $image, $temp, $progress) = @_;

foreach my $f (split(/\s+/, $image->{'files'})) {
	local $path = "$server_images_dir/$f";
	local $pid = fork();
	local $outtemp = &tempname();
	if (!$pid) {
		local $err = &get_file_from_server($vhost, "$temp/$f", $path);
		open(OUT, ">$outtemp");
		print OUT $err;
		close(OUT);
		exit($err ? 1 : 0);
		}
	while(1) {
		local $expid = waitpid($pid, WNOHANG);
		last if ($expid == $pid);
		print "." if ($progress);
		sleep(1);
		}
	local $err = &read_file_contents($outtemp);
	&unlink_file($outtemp);
	if ($err) {
		return "Failed to copy $f : $err";
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
local ($server, $noauth, $noserial) = @_;
local @munged;
local $ok = 1;
foreach my $m ([ \&munge_virtualmin_licence_files, 'mkimage_mungelicence' ],
	       [ \&munge_shadow_root_password, 'mkimage_mungeshadow' ],
	       [ \&munge_authorized_key, 'mkimage_mungessh' ]) {
	next if ($m->[1] eq 'mkimage_mungessh' && $noauth);
	next if ($m->[1] eq 'mkimage_mungelicence' && $noserial);
	&$first_print($text{$m->[1]});
	local $mfunc = $m->[0];
	local $munged = &$mfunc($server);
	if (!ref($munged)) {
		&$second_print(&text('mkimage_emunge', $err));
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
local ($server, $munged) = @_;
&$first_print($text{'mkimage_unmunge'});
foreach my $m (@$munged) {
	local ($file, $data) = @$m;
	local $err = &put_file_data_to_server($server, $data, $file);
	if ($err) {
		&$second_print(&text('create_eunmunge', $file, $err));
		return 0;
		}
	}
&$second_print($text{'create_done'});
return 1;
}

1;

