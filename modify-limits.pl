#!/usr/local/bin/perl

=head1 modify-limits.pl

Changes memory and CPU limits on one or more systems

This command changes the allocated memory and limits on CPU use for a virtual
system. At the time of writing this was only possible for Xen instances, but
may be extended to other types in future.

The systems to modify are set using the standard flags like C<--host> and
C<--type>. Memory allocated is set with the C<--memory> flag, which must be
followed by a number in MB. For Xen instances, available memory cannot be
increased above the amount set at boot time without a reboot, but it can be
reduced. Lowering it too much may cause the virtual system to crash though.
On system types that support it (like Vservers and Zones), the memory limit
can be completed removed with the C<--no-memory> flag.

On virtualization types like OpenVZ, you can also set a separate memory
limit with the C<--guaranteed-memory> flag followed by a number in MB. If
the host system is over-comitted, this specifies the amount of memory that
the virtual system is certain to have available, while the C<--memory> flag
sets the upper limit. On other virtualization types both limits are always
the same, and are set by the C<--memory> flag.

The percentage of the host system's CPU that is assigned to the instance
is set with the C<--cpu> flag, which must be followed by a number. This can be
greater than 100 for host systems with more than one CPU. To remove CPU limits
completely, use the C<--no-cpu> flag.

If bandwidth monitoring is enabled in Cloudmin, the C<--bw-limit> flag can be
used to set the maximum bandwidth this system is allowed to consume per
accounting period. It must be followed by a number in MB. To remove the limit,
use the C<--bw-unlimited> flag.

The network interfaces to collect bandwidth usage statistics on can be set
by the C<--bw-interfaces> flag, followed by a quoted list of interface names
like "eth0 eth1". To collect stats on all interfaces, use C<--bw-all-interfaces>
instead.

For virtual system types that support changing the IO scheduling class,
the C<--ioclass> flag can be given followed by a number from 0 (highest
priority) to 7 (lowest).

By default, the command will inform you if a reboot is needed to apply any
CPU or memory limit changes. However, you can force an immediate shutdown
and restart with the C<--reboot> flag, if needed.

=head1 Example usage

  cloudmin modify-limits --host xencentos.home --memory 512 --bw-limit 1024
  Setting memory limit on Xen system xencentos.home to 512 MB ..
  .. already set
  Setting bandwidth limit on Xen system xencentos.home ..
  .. set to 1024 MB

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
$0 = "$pwd/modify-limits.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
        elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
        elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
        elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	elsif ($a eq "--memory") {
		$memory = shift(@ARGV);
		$memory =~ /^[1-9][0-9]*$/ ||
			&usage("--memory must be followed by a number in MB");
		$memory *= 1024*1024;
		}
	elsif ($a eq "--no-memory") {
		$memory = 0;
		}
	elsif ($a eq "--guaranteed-memory") {
		$gmemory = shift(@ARGV);
		$gmemory =~ /^[1-9][0-9]*$/ ||
			&usage("--guaranteed-memory must be followed by ".
			       "a number in MB");
		$gmemory *= 1024*1024;
		}
	elsif ($a eq "--disk") {
		$disk = shift(@ARGV);
		$disk =~ /^[1-9][0-9]*$/ ||
			&usage("--disk must be followed by a number in MB");
		$disk *= 1024*1024;
		}
	elsif ($a eq "--no-disk") {
		$disk = 0;
		}
	elsif ($a eq "--cpu") {
		$cpu = shift(@ARGV);
		$cpu =~ /^\d+$/ && $cpu > 0 ||
			&usage("--cpu must be followed by a percentage");
		}
	elsif ($a eq "--no-cpu") {
		$cpu = 0;
		}
	elsif ($a eq "--weight") {
		$weight = shift(@ARGV);
		$weight =~ /^\d+$/ && $weight > 0 ||
			&usage("--weight must be followed by a number");
		}
	elsif ($a eq "--vcpus") {
		$vcpus = shift(@ARGV);
		if ($vcpus =~ /^\d+$/) {
			# Just a number of CPUs
			$vcpus_count = $vcpus;
			$vcpus || &usage("Number of virtual CPUs cannot be 0");
			$vcpus = join(",", (0..($vcpus-1)));
			}
		else {
			$vcpus ne '' || &usage("--vcpus must be followed by a number of CPUs, or a list of mappings");
			}
		}
	elsif ($a eq "--bw-limit") {
		$bw = shift(@ARGV);
		$bw =~ /^[1-9]\d*$/ ||
			&usage("--bw-limit must be followed by a number in MB");
		$bw *= 1024*1024;
		}
	elsif ($a eq "--bw-unlimited") {
		$bw = '';
		}
	elsif ($a eq '--bw-interfaces') {
		@bw_ifaces = shift(@ARGV);
		@bw_ifaces || &usage("--bw-interfaces must be followed by ".
				     "a list of interfaces");
		foreach $i (@bw_ifaces) {
			$i =~ /^[a-z]+\d+$/ ||
				&usage("--bw-interfaces must be followed by ".
				       "interfaces named like eth1");
			}
		}
	elsif ($a eq '--bw-all-interfaces') {
		@bw_ifaces = ( undef );
		}
	elsif ($a eq "--rate-limit") {
		$rate = shift(@ARGV);
		$rate =~ /^[1-9]\d*$/ ||
			&usage("--rate-limit must be followed by a number in Mbits/s");
		$rate *= 1024*1024;
		}
	elsif ($a eq "--rate-unlimited") {
		$rate = 0;
		}
	elsif ($a eq "--ioclass") {
		$ioclass = shift(@ARGV);
		$ioclass =~ /^[0-7]$/ ||
			&usage("--ioclass must be followed by a number from 0 (high priority) to 7 (low)");
		}
	elsif ($a eq "--reboot") {
		# Reboot after
		$do_reboot = 1;
		}
	else {
		&usage("Unknown flag $a");
		}
	}
defined($cpu) || defined($weight) || defined($memory) || defined($vcpus) ||
   defined($bw) || defined($rate) || defined($disk) || defined(@bw_ifaces) ||
   defined($gmemory) || defined($ioclass) || &usage("Nothing to modify!");

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hoston);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "limits");
if (defined($bw) || defined(@bw_ifaces)) {
	&can_action_usage(\@servers, "bw");
	}

# Check if we can do any of them
foreach $s (@servers) {
	$anycan++ if (&can_edit_limits($s));
	}
$anycan || &usage("None of the specified systems can have their ".
		  "CPU or memory limits changed");

# Parse virtual CPUs list
if (defined($vcpus)) {
	@vcpus = ( );
	foreach $c (split(/,/, $vcpus)) {
		if ($c =~ /^(\d+):((\d+)\-(\d+)|\d+)$/) {
			push(@vcpus, { 'num' => $1, 'pin' => $2 });
			}
		elsif ($c =~ /^\d+$/) {
			push(@vcpus, { 'num' => $c });
			}
		else {
			&usage("Invalid virtual CPU specification $c - must like 0 or 0:0-1");
			}
		}
	}

# Do each system
$failed = 0;
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	$limits = &get_owner_limits();
	$t = $s->{'manager'};
	$tfunc = "type_".$t."_desc";
	$tdesc = &$tfunc();
	&check_server_status($s, 0, 1);
	$vhost = &get_parent_server($s);

	# Change memory, if we can
	$reboot = 0;
	if (defined($memory)) {
		print "Setting memory limit on $tdesc system $s->{'host'} to ",
		      ($memory ? &nice_size($memory) : "Unlimited")," ..\n";
		$cfunc = "type_".$t."_can_memory";
		$ufunc = "type_".$t."_can_unlimited_memory";
		$memfree = &host_free_memory($vhost, $s->{'manager'});
		$checkmem = (($s->{'status'} ne 'down' &&
			      $s->{'status'} ne 'host') ||
			     $vhost->{'floor_mem_down'}) &&
			    !$vhost->{$s->{'manager'}.'_overmemory'};
		if (defined(&$cfunc) && &$cfunc($s)) {
			$gfunc = "type_".$t."_get_memory";
			$oldmemory = &$gfunc($s);
			$incr = $memory - $oldmemory;
			if ($oldmemory && $oldmemory == $memory) {
				# No change
				print ".. already set\n";
				}
			elsif ($limits && $limits->{'max_ram'} && $incr > 0 &&
			       $limits->{'ram'} + $incr >
				$limits->{'max_ram'}) {
				# Over RAM limit for owner
				print ".. this would exceed your memory limit ",
			          "of ",&nice_size($limits->{'max_ram'}),"\n";
				$failed++;
				}
			elsif ($incr > $memfree && $incr > 0 && $checkmem) {
				# Over RAM limit for host
				 print ".. this would exceed the host's free ",
				  "memory of ",&nice_size($memfree),"\n";
				}
			elsif ($limits && $limits->{'max_ram'} && !$memory) {
				# Set to unlimited but not allowed
				print ".. you cannot set memory to unlimited ",
				      "as your limit is ",
				      &nice_size($limits->{'max_ram'}),"\n";
				$failed++;
				}
			elsif ($memory == 0 && defined(&$ufunc) &&
			       !&$ufunc($s)) {
				# Doesn't support unlimited
				print ".. this system does not support ".
				      "unlimited memory\n";
				$failed++;
				}
			else {
				# Actually try it
				$mfunc = "type_".$t."_save_memory";
				$err = &$mfunc($s, $memory);
				if ($err) {
					print ".. failed : $err\n";
					$failed++;
					}
				else {
					print ".. done\n";
					$reboot++ if (&$cfunc($s) == 2);
					}
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change guaranteed memory
	if (defined($gmemory)) {
		print "Setting guaranteed memory on $tdesc system ",
		      "$s->{'host'} to ",&nice_size($gmemory)," ..\n";
		$cfunc = "type_".$t."_can_guaranteed_memory";
		$memfree = &host_free_memory($vhost, $s->{'manager'}, 1);
		$checkmem = ($s->{'status'} ne 'down' &&
			     $s->{'status'} ne 'host') ||
			    $vhost->{'floor_mem_down'};
		if (defined(&$cfunc) && &$cfunc($s)) {
			$gfunc = "type_".$t."_get_guaranteed_memory";
			$oldmemory = &$gfunc($s);
			$incr = $memory - $oldmemory;
			$rgfunc = "type_".$t."_get_memory";
			$rmemory = &$rgfunc($s);
			if ($oldmemory && $oldmemory == $memory) {
				# No change
				print ".. already set\n";
				}
			elsif ($rmemory && $gmemory > $rmemory) {
				# Over upper limit
				print ".. this would exceed the regular ",
				      "memory limit of ",
			              &nice_size($rmemory),"\n";
				$failed++;
				}
			elsif ($incr > $memfree && $incr > 0 && $checkmem) {
				# Over RAM limit for host
				 print ".. this would exceed the host's free ",
				  "memory of ",&nice_size($memfree),"\n";
				}
			elsif ($gmemory == 0) {
				# Doesn't support unlimited
				print ".. guaranteed memory cannot be set ",
				      "to zero\n";
				$failed++;
				}
			else {
				# Actually try it
				$mfunc = "type_".$t."_save_guaranteed_memory";
				$err = &$mfunc($s, $gmemory);
				if ($err) {
					print ".. failed : $err\n";
					$failed++;
					}
				else {
					print ".. done\n";
					$reboot++ if (&$cfunc($s) == 2);
					}
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change CPU and weight, if we can
	if (defined($cpu) || defined($weight)) {
		print "Setting CPU limit on $tdesc system $s->{'host'} to ",
		      ($cpu || "Unlimited")," ..\n";
		$cfunc = "type_".$t."_can_cpu";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$gfunc = "type_".$t."_get_cpu";
			($oldcpu, $oldweight) = &$gfunc($s);
			$incr = $cpu - $oldcpu;
			if ($limits && $limits->{'max_cpu'} && $incr > 0 &&
			    $limits->{'cpu'} + $incr > $limits->{'max_cpu'} &&
			    defined($cpu)) {
				# Over CPU limit
				print ".. this would exceed your CPU limit ",
				      "of ",$limits->{'max_cpu'},"\n";
				$failed++;
				}
			elsif ($limits && $limits->{'max_cpu'} && !$cpu &&
			       defined($cpu)) {
				# Set to unlimited but not allowed
				print ".. you cannot set CPU to unlimited ",
				      "as your limit is ",
				      $limits->{'max_cpu'},"\n";
				$failed++;
				}
			else {
				# Make the change
				$sfunc = "type_".$t."_save_cpu";
				$err = &$sfunc($s, $cpu, $weight);
				if ($err) {
					print ".. failed : $err\n";
					$failed++;
					}
				else {
					print ".. done\n";
					$reboot++ if (&$cfunc($s) == 2 ||
						      &$cfunc($s) == 4);
					}
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change virtual CPUs
	if (defined($vcpus)) {
		print "Setting virtual CPUs on $tdesc system $s->{'host'} ..\n";
		$canvfunc = "type_".$t."_can_vcpus";
		$cansfunc = "type_".$t."_can_smp";
		if (!&can_action($s, "vcpus")) {
			# Not allowed
			print ".. you are not allowed to manage virtual CPUs\n";
			$failed++;
			}
		elsif (defined(&$canvfunc) && &$canvfunc($s)) {
			# Make the change to CPU pinning
			$vfunc = "type_".$t."_save_vcpus";
			$err = &$vfunc($s, \@vcpus);
			if ($err) {
				print ".. failed : $err\n";
				$failed++;
				}
			else {
				print ".. done\n";
				$reboot++ if (&$canvfunc($s) == 2);
				}
			}
		elsif (defined(&$cansfunc) && &$cansfunc($s)) {
			# Make the change to CPU count only
			$sfunc = "type_".$t."_save_smp";
			if (!$vcpus_count) {
				$err = "This virtual system type only ".
				       "supports setting a number of virtual ".
				       "CPUs";
				}
			else {
				$err = &$sfunc($s, $vcpus_count);
				}
			if ($err) {
				print ".. failed : $err\n";
				$failed++;
				}
			else {
				print ".. done\n";
				$reboot++ if (&$cansfunc($s) == 2);
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change disk, if we can
	if (defined($disk)) {
		print "Setting disk limit on $tdesc system $s->{'host'} to ",
		      ($disk ? &nice_size($disk) : "Unlimited")," ..\n";
		$cfunc = "type_".$t."_can_disk";
		$diskfree = &host_free_disk($vhost, $s->{'manager'});
		$checkdisk = !$vhost->{$s->{'manager'}.'_overdisk'};
		if (defined(&$cfunc) && &$cfunc($s)) {
			$gfunc = "type_".$t."_get_disk";
			$olddisk = &$gfunc($s);
			$incr = $disk - $olddisk;
			if ($olddisk && $olddisk == $disk) {
				# No change
				print ".. already set\n";
				}
			elsif ($limits && $limits->{'max_disk'} && $incr > 0 &&
			    $limits->{'disk'} + $incr > $limits->{'max_disk'}) {
				# Over owner disk limit
				print ".. this would exceed your disk limit ",
			          "of ",&nice_size($limits->{'max_ram'}),"\n";
				$failed++;
				}
			elsif ($disk && $incr > 0 && $incr > $diskfree &&
			       $checkdisk) {
				# Over disk limit for host
				 print ".. this would exceed the host's free ",
				  "disk space of ",&nice_size($diskfree),"\n";
				}
			elsif ($limits && $limits->{'max_disk'} && !$disk) {
				# Set to unlimited but not allowed
				print ".. you cannot set disk to unlimited ",
				      "as your limit is ",
				      &nice_size($limits->{'max_ram'}),"\n";
				$failed++;
				}
			else {
				# Make the change
				$dfunc = "type_".$t."_save_disk";
				$err = &$dfunc($s, $disk);
				if ($err) {
					print ".. failed : $err\n";
					$failed++;
					}
				else {
					print ".. done\n";
					$reboot++ if (&$cfunc($s) == 2);
					}
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change network rate, if we can
	if (defined($rate)) {
		print "Setting network rate on $tdesc system $s->{'host'} to ",
		      ($rate ? &nice_rate($rate) : "Unlimited")," ..\n";
		$cfunc = "type_".$t."_can_network_rate";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$gfunc = "type_".$t."_get_network_rate";
			$oldrate = &$gfunc($s);
			if (defined($oldrate) && $oldrate == $rate) {
				print ".. already set\n";
				}
			else {
				$dfunc = "type_".$t."_save_network_rate";
				$err = &$dfunc($s, $rate);
				if ($err) {
					print ".. failed : $err\n";
					$failed++;
					}
				else {
					print ".. done\n";
					$reboot++ if (&$cfunc($s) == 2);
					}
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change IO class, if we can
	if (defined($ioclass)) {
		print "Setting IO class on $tdesc system $s->{'host'} to ",
		      "$opclass ..\n";
		$cfunc = "type_".$t."_can_ioclass";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$gfunc = "type_".$t."_get_ioclass";
			$oldioclass = &$gfunc($s);
			if (defined($oldioclass) && $oldioclass == $ioclass) {
				print ".. already set\n";
				}
			else {
				$dfunc = "type_".$t."_save_ioclass";
				$err = &$dfunc($s, $ioclass);
				if ($err) {
					print ".. failed : $err\n";
					$failed++;
					}
				else {
					print ".. done\n";
					$reboot++ if (&$cfunc($s) == 2);
					}
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change bandwidth limit
	if (defined($bw)) {
		print "Setting bandwidth limit on $tdesc system $s->{'host'} ..\n";
		$rfunc = "type_".$t."_real_interfaces";
		if (defined(&$rfunc)) {
			$s->{'bw_limit'} = $bw;
			if ($bw) {
				print ".. set to ",&nice_size($bw),"\n";
				}
			else {
				print ".. set to unlimited\n";
				}
			}
		else {
			print ".. not supported\n";
			$failed++;
			}
		print "\n";
		}

	# Change bandwidth interfaces
	if (defined(@bw_ifaces)) {
		$s->{'bw_ifaces'} = join(" ", @bw_ifaces);
		}

	# Update and changed parameters
	&save_managed_server($s);

	# Restart if needed
	if ($reboot && $s->{'status'} ne 'down') {
		if ($do_reboot) {
			# Yes .. do it now
			print "Shutting down system $s->{'host'} to ",
			      "apply limits ..\n";
			my $err = &shutdown_server($s);
			if ($err) {
				print ".. failed : $err\n";
				}
			else {
				print ".. done\n";

				print "Starting up system $s->{'host'} with ",
				      "new limits ..\n";
				($ok, $err) = &startup_server($s);
				if (!$ok) {
					print ".. failed : $err\n";
					}
				else {
					print ".. done\n";
					}
				}
			&check_server_status($s, 0, 1);
			&save_managed_server($s);
			print "\n";
			}
		else {
			# Needed to, but user didn't ask
			push(@need_reboot, $s);
			}
		}
	}
&release_lock_server(\@servers);

# Tell the user if he should have given --reboot
if (@need_reboot) {
	print "NOTE: ";
	print "Because the --reboot flag was not given, the following\n";
	print "systems did not have the new limits applied immediately :\n";
	foreach $s (@need_reboot) {
		print $s->{'host'},"\n";
		}
	}
&cloudmin_api_log(\@OLDARGV);
exit($failed);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes memory and CPU limits on one or more managed systems.\n";
print "\n";
print "cloudmin modify-limits [--host name]*\n";
print "                       [--group name]*\n";
my $types = join("|", @server_management_types);
print "                       [--type $types]*\n";
print "                       [--os oscode]*\n";
print "                       [--owner name]*\n";
print "                       [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                       [--host-on name]\n";
print "                       [--cpu percentage | --no-cpu]\n";
print "                       [--weight number]\n";
print "                       [--memory MB | --no-memory]\n";
print "                       [--guaranteed-memory MB]\n";
print "                       [--disk MB | --no-disk]\n";
print "                       [--reboot]\n";
print "                       [--vcpus N | --vcpus list]\n";
print "                       [--bw-limit MB | --bw-unlimited]\n";
print "                       [--bw-interfaces iface | --bw-all-interfaces]\n";
print "                       [--rate-limit Mb/s | --rate-unlimited]\n";
print "                       [--ioclass number]\n";
exit(1);
}

