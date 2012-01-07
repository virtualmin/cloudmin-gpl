# log_parser.pl
# Functions for parsing this module's logs

do 'server-manager-lib.pl';

# parse_webmin_log(user, script, action, type, object, &params)
# Converts logged information from this module into human-readable form
sub parse_webmin_log
{
my ($user, $script, $action, $type, $object, $p, $long) = @_;
if ($type eq "server") {
	# Operation on one server
	my $typestr;
	if ($p->{'type'}) {
		my $tfunc = "type_".$p->{'type'}."_desc";
		if (defined(&$tfunc)) {
			$typestr = &$tfunc();
			}
		else {
			$typestr = ucfirst($p->{'type'});
			}
		}
	if ($action eq 'gateway' && $p->{'gw'}) {
		return &text('log_gateway_server', $object, $p->{'gw'});
		}
	elsif ($action eq 'gateway') {
		return &text('log_nogateway_server', $object);
		}
	elsif ($action eq 'bwifaces' && $p->{'ifaces'}) {
		return &text('log_bwifaces_server', $object, $p->{'ifaces'});
		}
	elsif ($action eq 'bwifaces') {
		return &text('log_nobwifaces_server', $object);
		}
	else {
		return &text('log_'.$action.'_server', $object,
			     &html_escape(&un_urlize($p->{'cmd'})),
			     $typestr);
		}
	}
elsif ($type eq "servers") {
	# Operation on multiple servers
	my @hosts = split(/\0/, $p->{'hosts'});
	if ($object == 1) {
		return &text('log_'.$action.'_server', $hosts[0]);
		}
	return &text('log_'.$action.'_servers'.($long ? '_l' : ''),
		     $object, join(" ", @hosts),
		     &html_escape(&un_urlize($p->{'cmd'})));
	}
elsif ($type eq "file") {
	# File upload / download
	return &text('log_'.$action.'_file', $object,
		     &html_escape($p->{'file'}),
		     &html_escape($p->{'dest'}));
	}
elsif ($type eq "disk") {
	# Disk operation
	return &text('log_'.$action.'_disk', $object,
		     &html_escape($p->{'real'}));
	}
elsif ($type eq "disks") {
	# Multi-disk operation
	my @reals = split(/\0/, $p->{'real'});
	return &text('log_'.$action.'_disks', $object,
		     &html_escape(join(" ", @reals)));
	}
elsif ($type eq "iface") {
	# Network interface operation
	return &text('log_'.$action.'_iface', $object,
		     $p->{'address'});
	}
elsif ($type eq "key") {
	# SSH key
	return &text('log_'.$action.'_key',
		     "<i>".&html_escape($p->{'desc'})."</i>");
	}
elsif ($type eq "keys") {
	# Multiple SSH keys
	return &text('log_'.$action.'_keys', $object);
	}
elsif ($type eq "image") {
	# System image
	return &text('log_'.$action.'_image', &html_escape($object));
	}
elsif ($type eq "images") {
	# Multiple system images
	return &text('log_'.$action.'_images', $object);
	}
elsif ($type eq "owner") {
	# One system owner
	return &text('log_'.$action.'_owner', &html_escape($object));
	}
elsif ($type eq "owners") {
	# Multiple system owners
	return &text('log_'.$action.'_owners', $object);
	}
elsif ($type eq "plan") {
	# One account plan
	return &text('log_'.$action.'_plan', &html_escape($p->{'desc'}));
	}
elsif ($type eq "plans") {
	# Multiple account plans
	return &text('log_'.$action.'_plans', $object);
	}
elsif ($type eq "licence") {
	# One license
	return &text('log_'.$action.'_licence', $object);
	}
elsif ($type eq "licences") {
	# Many licenses
	return &text('log_'.$action.'_licences', $object);
	}
elsif ($type eq "domain") {
	# One Virtualmin domain
	return &text('log_'.$action.'_domain', $object,
		     $p->{'host'});
	}
elsif ($type eq "domains") {
	# Many domains
	my @hosts = &unique(split(/\0/, $p->{'host'}));
	my @doms = split(/\0/, $p->{'dom'});
	if ($long || @doms == 1) {
		return &text('log_'.$action.'_domains_l',
			     join(' ', @doms), join(' ', @hosts), $p->{'dest'});
		}
	else {
		return &text('log_'.$action.'_domains',
			     scalar(@doms), scalar(@hosts), $p->{'dest'});
		}
	}
elsif ($type eq "ec2") {
	# One EC2 account
	return &text('log_'.$action.'_ec2', &html_escape($p->{'desc'}));
	}
elsif ($type eq "ec2s") {
	# Many accounts
	return &text('log_'.$action.'_ec2s', $object);
	}
elsif ($type eq "ami") {
	# One Amazon AMI
	return &text('log_'.$action.'_ami', &html_escape($object));
	}
elsif ($type eq "amis") {
	# Multiple AMIs
	my @amis = split(/\0/, $p->{'ami'});
	if ($long || @amis == 1) {
		return &text('log_'.$action.'_amis_l', join(' ', @amis));
		}
	else {
		return &text('log_'.$action.'_amis', $object);
		}
	}
elsif ($type eq "sgroup") {
	# One security group
	return &text('log_'.$action.'_sgroup', &html_escape($object));
	}
elsif ($type eq "sgroups") {
	# Multiple security groups
	my @groups = split(/\0/, $p->{'group'});
	return &text('log_'.$action.'_sgroups', join(' ', @groups));
	}
elsif ($type eq "address") {
	# EC2 addresses
	return &text('log_'.$action.'_address',
		     join(' ', split(/\0/, $p->{'ip'})), $object);
	}
elsif ($type eq "volume") {
	# EC2 volume
	if ($action eq "attach" || $action eq "detach") {
		return &text('log_'.$action.'_volume', $object, $p->{'host'});
		}
	elsif ($p->{'size'}) {
		return &text('log_'.$action.'_volume', $object, $p->{'size'});
		}
	else {
		return &text('log_'.$action.'_volumeof', $object, $p->{'snap'});
		}
	}
elsif ($type eq "volumes") {
	# EC2 volumes
	return &text('log_'.$action.'_volumes', 
		     join(' ', split(/\0/, $p->{'vol'})));
	}
elsif ($type eq "snap") {
	# EC2 snapshot
	return &text('log_'.$action.'_snap', $object, $p->{'snap'});
	}
elsif ($type eq "snaps") {
	# EC2 snapshots
	return &text('log_'.$action.'_snaps', 
		     join(' ', split(/\0/, $p->{'snap'})));
	}
elsif ($type eq "backup") {
	# Changing or running a backup
	my @hosts = split(/\0/, $p->{'host'});
	return &text('log_'.$action.'_backup'.($long ? '_l' : ''),
		     $p->{'dest'} ? &nice_backup_destination($p->{'dest'})
				  : $text{'log_host_backup'},
		     $long ? join(' ', @hosts) : scalar(@hosts));
	}
elsif ($type eq "backuplog") {
	# Deleting backup logs
	my @dests = split(/\0/, $p->{'dest'});
	if ($long) {
		return &text('log_'.$action.'_backuplogs_l',
		     join(' ', map { &nice_backup_destination($_) } @dests));
		}
	else {
		return &text('log_'.$action.'_backuplogs', scalar(@dests));
		}
	}
elsif ($type eq "vsync") {
	# Domain sync
	my @doms = split(/\0/, $p->{'doms'});
	if (!@doms) {
		return &text('log_'.$action.'_vsync_g', $object);
		}
	elsif (!$long) {
		return &text('log_'.$action.'_vsync', $object, scalar(@doms));
		}
	else {
		@doms = @doms[0..4] if (@doms > 4);
		return &text('log_'.$action.'_vsync_l', $object,
				join(' ', @doms));
		}
	}
elsif ($type eq "storage") {
	# One image storage location
	return &text('log_'.$action.'_storage', &html_escape($p->{'desc'}));
	}
elsif ($type eq "storages") {
	# Multiple storage locations
	return &text('log_'.$action.'_storages', $object);
	}
elsif ($type eq "directory") {
	# One disk image directory
	return &text('log_'.$action.'_directory', &html_escape($p->{'dir'}));
	}
elsif ($type eq "directories") {
	# Multiple disk image directories
	return &text('log_'.$action.'_directories', $object);
	}
elsif ($type eq "alert") {
	# One system alert
	return &text('log_'.$action.'_alert', $p->{'servers'});
	}
elsif ($type eq "alerts") {
	# Multiple system alerts
	return &text('log_'.$action.'_alerts', $object);
	}
elsif ($type eq "roundrobin") {
	# One DNS roundrobin
	return &text('log_'.$action.'_roundrobin', $p->{'name'});
	}
elsif ($type eq "roundrobins") {
	# Multiple DNS roundrobins
	return &text('log_'.$action.'_roundrobins', $object);
	}
elsif ($type eq "scalegroup") {
	# Auto-scaling group
	return &text('log_'.$action.'_scalegroup', $p->{'name'});
	}
elsif ($type eq "scalegroups") {
	# Multiple auto-scaling groups
	return &text('log_'.$action.'_scalegroups', $object);
	}
elsif ($type eq "failover") {
	# One failover group
	return &text('log_'.$action.'_failover', &html_escape($p->{'desc'}));
	}
elsif ($type eq "failovers") {
	# Multiple failover groups
	return &text('log_'.$action.'_failovers', $object);
	}
elsif ($action eq "cmd" || $action eq "remote") {
	# Local or remote API call
	return &text('log_'.$action.($long ? '_l' : ''),
		     "<tt>$type</tt>",
		     "<tt>".&un_urlize($p->{'argv'})."</tt>");
	}
else {
	return $text{'log_'.$action};
	}
return undef;
}

