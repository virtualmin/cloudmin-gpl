#!/usr/local/bin/perl
# Creates a copy of some virtual system

=head1 clone-system.pl

Creates a new virtual system that is a copy of some existing one.

This command creates an exact duplicate of a existing virtual system, 
specified using the C<--host> flag. The name of the new system is set
with the C<--new-host> parameter, which only needs to be the first part of
the hostname - a domain will be appended automatically. 

To set a description for the new cloned system, use the C<--new-desc> flag - 
otherwise, a description will be generated automatically.

By default, the new system will have IP address(es) for it selected
automatically based on the allocation ranges set on the host system. However,
you can override this with the C<--address> parameter, which can be given
multiple times for systems with more than one interface. This parameter is
mandatory when the host system does not have IP allocation setup.

By default the virtual system will be shut down if running. However, for
KVM and Xen instances with disks on LVM can use the C<--live> flag to
perform an online copy using a LVM snapshot. However, the filesystem may
not be in a fully consistent state when this method is used. This flag
can also be used to force use of a snapshot when the virtual system is down.
If not given, a regular copy of the LVM logical volumes will be made.

If your Cloudmin system manages multiple Xen or KVM hosts, you can specify
an different host system for the clone to be created on with the C<--dest>
flag. This must be followed by the hostname of a system that can host virtual
systems of the type being cloned.

=head1 Example usage

  cloudmin clone-system --host citrixsrc.home --new-host citrixdest
  Creating clone of Citrix Xen system citrixsrc.home named citrixdest ..
      Allocating new IP addresses ..
      .. allocated 193.9.101.213
      Cloning Citrix Xen VM ..
      .. done
      Adding DNS entry citrixdest.home. for IP address 193.9.101.213 ..
      .. done
      Mounting new instance's filesystem ..
      .. mounted on /mnt/citrix-0b1b8691-98c6-af92-8fe2-4b0e864bab33
      Updating configuration files with hostname and IP address ..
      .. done
      Updating network configuration files ..
      .. done
      Un-mounting instance's filesystem ..
      .. done
      Refreshing status of original system ..
      .. done. New status is : Down
      Refreshing status of new system ..
      .. done. New status is : Down
  .. clone citrixdest.home created.

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
$0 = "$pwd/clone-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
$shutdown = 0;
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--new-host") {
		$newhost = shift(@ARGV);
		}
	elsif ($a eq "--new-desc") {
		$newdesc = shift(@ARGV);
		}
	elsif ($a eq "--address") {
		$ips ||= [ ];
		$ip = shift(@ARGV);
		&check_ipaddress($ip) ||
			&usage("$ip is not a valid IP address");
		push(@$ips, $ip);
		}
	elsif ($a eq "--live") {
		$live = 1;
		}
	elsif ($a eq "--dest") {
		$desthost = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args
$host || &usage("Missing --host parameter");
$newhost || &usage("Missing --new-host parameter");
$newhost =~ /^[a-z0-9\.\-]+$/ || &usage("Invalid new hostname");

# Get the system
$server = &get_managed_server_by("host", $host);
$server || &usage("No system named $host exists");
if ($ips) {
	&can_action_usage($server, 'ips');
	}
if ($desthost) {
	$dest = &get_managed_server_by("host", $desthost);
	$dest || &usage("No destination system named $desthost exists");
	}

# Check if supported
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_clone";
defined(&$cfunc) || &usage("Systems of type $desc cannot be cloned");
$can = &$cfunc($server);
$can || &usage("The selected system cannot be cloned");
!$live || $can == 2 || &usage("The selected system cannot be cloned live");
$vhost = &get_parent_server($server);
if ($dest) {
	$rcfunc = "type_".$server->{'manager'}."_can_clone_remote";
	$rcan = defined(&$rcfunc) && &$rcfunc($server, $dest);
	$rcan || &usage("The --dest flag cannot be used with this ".
			"virtualization type");
	&can_action_usage($server, "move");
	}

# Validate owner resource limits
&can_create_server_usage($server->{'manager'});
$limits = &get_owner_limits();
if ($limits) {
	# Validate disk limit
	$dsfunc = "type_".$server->{'manager'}."_get_disk_size";
	$incr = defined(&$dsfunc) ? &$dsfunc($server) : undef;
	if ($incr && $limits->{'max_disk'}) {
		# May be over disk limit
		if ($limits->{'disk'} + $incr > $limits->{'max_disk'}) {
			&usage("Cloning this system would exceed your disk ",
			       "limit of ",&nice_size($limits->{'max_disk'}));
			}
		}
	elsif (!$incr && $limits->{'max_disk'}) {
		# System has no disk limits, but owner does
		&usage("You cannot clone a system with unlimited disk as ",
		       "your limit is ",&nice_size($limits->{'max_disk'}));
		}

	# Validate RAM limit
	$mfunc = "type_".$server->{'manager'}."_get_memory_size";
	$incr = defined(&$mfunc) ? &$mfunc($server) : undef;
	if ($incr && $limits->{'max_ram'}) {
		# May be over RAM limit
		if ($limits->{'ram'} + $incr > $limits->{'max_ram'}) {
			&usage("Cloning this system would exceed your memory ",
			       "limit of ",&nice_size($limits->{'max_ram'}));
			}
		}
	elsif (!$incr && $limits->{'max_ram'}) {
		# System has no RAM limits, but owner does
		&usage("You cannot clone a system with unlimited memory as ",
		       "your limit is ",&nice_size($limits->{'max_ram'}));
		}

	# Validate CPU limit
	$cfunc = "type_".$server->{'manager'}."_get_cpu_size";
	$incr = defined(&$cfunc) ? &$cfunc($server) : undef;
	if ($incr && $limits->{'max_cpu'}) {
		# May be over CPU limit
		if ($limits->{'cpu'} + $incr > $limits->{'max_cpu'}) {
			&usage("Cloning this system would exceed your CPU ",
			       "limit of ",$limits->{'max_cpu'});
			}
		}
	elsif (!$incr && $limits->{'max_cpu'}) {
		# System has no CPU limit, but owner does
		&usage("You cannot clone a system with unlimited CPU as ",
		       "your limit is ",$limits->{'max_cpu'});
		}

	# Validate IPs limit
	$incr = $ips ? scalar(@$ips)
		     : scalar(split(/\s+/, $server->{'ip_addresses'})) || 1;
	if ($limits->{'max_ips'}) {
		if ($limits->{'ips'} + $incr > $limits->{'max_ips'}) {
			&usage("Cloning this system would exceed your IP ",
			       "address limit of ",$limits->{'max_ips'});
			}
		}
	}

# Call the clone function
&obtain_lock_server($server);
print "Creating clone of $desc system $server->{'host'} named $newhost ..\n\n";
&$indent_print();
($newserver, $err) = &clone_system($server, $newhost, $newdesc, $ips, $live,
				   $dest);
&$outdent_print();
&release_lock_server($server);
if ($newserver && $err) {
	print "Failed : ",$err,"\n";
	print ".. clone $newserver->{'host'} partially created.\n";
	}
elsif ($newserver && !$err) {
	print ".. clone $newserver->{'host'} created.\n";
	}
elsif (!$newserver && $err) {
	print "Failed : ",$err,"\n";
	}
if ($newserver) {
	&cloudmin_api_log(\@OLDARGV);
	}
if ($err) {
	exit(1);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Creates a new virtual system that is a copy of some existing one.\n";
print "\n";
print "cloudmin clone-system --host name\n";
print "                      --new-host new-name\n";
print "                     [--new-desc new-description]\n";
print "                     [--address ip]*\n";
print "                     [--live]\n";
print "                     [--dest new-host-system-name]\n";
exit(1);
}

