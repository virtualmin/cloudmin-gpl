# Functions for general setup and management of multiple Virtualmin servers
# XXX what about adding 'self' ?

do '../web-lib.pl';
&init_config();
do '../ui-lib.pl';
&foreign_require("servers", "servers-lib.pl");

@possible_server_management_types = ( [ "real", undef ],
				      [ "zones", "zones" ],
				      [ "ec2", undef ],
				    );
@server_management_types = ( );
foreach my $smt (@possible_server_management_types) {
	if (!$smt->[1] || &foreign_installed($smt->[1])) {
		push(@server_management_types, $smt->[0]);
		do "$smt->[0]-type-lib.pl";
		}
	}

$managed_servers_dir = "$module_config_directory/servers";
$ssh_keys_dir = "$module_config_directory/keys";

# list_managed_servers()
# Returns a list of all servers managed by this module. The objects are also
# Webmin server hashes, if available
sub list_managed_servers
{
local @rv;
opendir(DIR, $managed_servers_dir);
foreach my $f (readdir(DIR)) {
	local %serv;
	next if ($f !~ /^\d+$/ ||
		 !&read_file("$managed_servers_dir/$f", \%serv));
	local $wserv = &servers::get_server($f);
	if ($wserv) {
		# Has a Webmin server too .. merge it in
		foreach my $k (keys %$wserv) {
			$serv{$k} = $wserv->{$k} if (!defined($serv{$k}));
			}
		}
	push(@rv, \%serv);
	}
closedir(DIR);
return @rv;
}

# describe_os(os)
# Converts an OS code as used by the 'servers' module into a name
sub describe_os
{
local ($t) = @_;
local ($type) = grep { $_->[0] eq $t } @servers::server_types;
return $type->[1];
}

# describe_status(&server, [withcolor])
# Returns a string describing the status of some server (down, nossh,
# nowebmin, novirt, virt)
sub describe_status
{
local ($s, $withcol) = @_;
local $cmap = { 'down' => 'ff0000',
		'nossh' => 'ff00ff',
		'nowebmin' => 'ffff00',
		'novirt' => 'aaff00',
		'virt' => '00aa00' };
local $msg = $text{'status_'.$s->{'status'}} || $text{'status_unknown'};
if ($withcol) {
	local $col = $cmap{$s->{'status'}};
	if ($col) {
		return "<font color=#$col>$msg</font>";
		}
	}
return $msg;
}

# list_ssh_keys()
# Returns a list of SSH keys used to login to servers
sub list_ssh_keys
{
local @rv;
opendir(DIR, $ssh_keys_dir);
foreach my $f (readdir(DIR)) {
	next if ($f !~ /^(\S+)\.info$/i);
	local %key;
	&read_file("$ssh_keys_dir/$f", \%key);
	$key{'keydata'} = &read_file_contents($key{'file'});
	push(@rv, \%key);
	}
closedir(DIR);
return @rv;
}

# save_ssh_key(&key)
# Creates or updates an SSH key
sub save_ssh_key
{
local ($key) = @_;
if (!-d $ssh_keys_dir) {
	&make_dir($ssh_keys_dir, 0700);
	}
if (!$key->{'id'}) {
	# New, need to choose an ID
	$key->{'id'} = time();
	if (!$key->{'file'}) {
		# No file specified .. so this is a generated key
		$key->{'file'} = "$ssh_keys_dir/$key->{'id'}.key";
		$key->{'external'} = 0;
		}
	else {
		# Key is in existing file
		$key->{'external'} = 1;
		}
	}
local %nodata = %$key;
delete($nodata{'keydata'});
&write_file("$ssh_keys_dir/$key->{'id'}.info", \%nodata);
if (!$key->{'external'}) {
	&open_lock_tempfile(DATA, ">$key->{'file'}");
	&print_tempfile(DATA, $key->{'keydata'});
	&close_tempfile(DATA);
	&set_ownership_permissions(undef, undef, 0600, $key->{'file'});
	}
}

# delete_ssh_key(&key)
# Removes a known SSH key
sub delete_ssh_key
{
local ($key) = @_;
&unlink_logged("$ssh_keys_dir/$key->{'id'}.info");
if (!$key->{'external'}) {
	&unlink_logged($key->{'file'});
	}
}

# generate_public_key(&key)
# Returns the public key string for some key
sub generate_public_key
{
local ($key) = @_;
local $qp = quotemeta($key->{'file'});
local $out = `ssh-keygen -y -f $qp 2>/dev/null`;
if ($out =~ /((\d+)\s+(\d+)\s+(\d+))$/) {
	# Version 1
	return $1;
	}
elsif ($out =~ /((\S+)\s+([A-Za-z0-9\/=\+]+))$/) {
	# Version 2
	return $1;
	}
else {
	return undef;
	}
}

# check_ssh_key_data(text)
# Returns 1 if the text looks like an SSH 1 key, 2 for an SSH version 2 key,
# 0 otherwise
sub check_ssh_key_data
{
local ($text) = @_;
if ($text =~ /-----BEGIN\s+(RSA|DSA)\s+PRIVATE\s+KEY-----\n([A-Za-z0-9\+\/=\n]+)-----END\s+(\S+)\s+PRIVATE\s+KEY-----/ && $1 eq $3) {
	return 2;
	}
elsif ($text =~ /^SSH\s+PRIVATE\s+KEY\s+FILE/) {
	return 1;
	}
else {
	return 0;
	}
}

# generate_ssh_key()
# Create a new SSH private key, in the default format
sub generate_ssh_key
{
local $temp = &transname();
local $out = &backquote_command("ssh-keygen -f $temp -N '' 2>&1");
if ($? || !-r $temp) {
	&error("<tt>$out</tt>");
	}
local $data = &read_file_contents($temp);
unlink($temp, $temp.".pub");
return $data;
}

sub wrap_long_line
{
local ($text, $cols) = @_;
local @rv;
while($text) {
	local $l = substr($text, 0, $cols);
	$text = substr($text, $cols);
	push(@rv, $l);
	}
return join("\n", @rv);
}

1;

