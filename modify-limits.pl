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

The percentage of the host system's CPU that is assigned to the instance
is set with the C<--cpu> flag, which must be followed by a number. This can be
greater than 100 for host systems with more than one CPU. To remove CPU limits
completely, use the C<--no-cpu> flag.

If bandwidth monitoring is enabled in Cloudmin, the C<--bw-limit> flag can be
used to set the maximum bandwidth this system is allowed to consume per
accounting period. It must be followed by a number in MB. To remove the limit,
use the C<--bw-unlimited> flag.

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
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/modify-limits.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	elsif ($a eq "--memory") {
		$memory = shift(@ARGV);
		$memory =~ /^\d+$/ ||
			&usage("--memory must be followed by a number in MB");
		$memory *= 1024*1024;
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
	elsif ($a eq "--reboot") {
		# Reboot after
		$do_reboot = 1;
		}
	else {
		&usage();
		}
	}
defined($cpu) || defined($weight) || $memory || defined($vcpus) ||
   defined($bw) || &usage("Nothing to modify!");

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

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
&obtain_lock_server(\@servers);
foreach $s (@servers) {
	$t = $s->{'manager'};
	$tfunc = "type_".$t."_desc";
	$tdesc = &$tfunc();
	&check_server_status($s, 0, 1);

	# Change memory, if we can
	$reboot = 0;
	if ($memory) {
		print "Setting memory limit on $tdesc system $s->{'host'} to ",
		      &nice_size($memory)," ..\n";
		$cfunc = "type_".$t."_can_memory";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$gfunc = "type_".$t."_get_memory";
			$oldmemory = &$gfunc($s);
			if ($oldmemory && $oldmemory == $memory) {
				print ".. already set\n";
				}
			else {
				$mfunc = "type_".$t."_save_memory";
				$err = &$mfunc($s, $memory);
				if ($err) {
					print ".. failed : $err\n";
					}
				else {
					print ".. done\n";
					$reboot++ if (&$cfunc($s) == 2);
					}
				}
			}
		else {
			print ".. not supported\n";
			}
		print "\n";
		}

	# Change CPU and weight, if we can
	if (defined($cpu) || defined($weight)) {
		print "Setting CPU limit on $tdesc system $s->{'host'} ..\n";
		$cfunc = "type_".$t."_can_cpu";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$sfunc = "type_".$t."_save_cpu";
			$err = &$sfunc($s, $cpu, $weight);
			if ($err) {
				print ".. failed : $err\n";
				}
			else {
				print ".. done\n";
				$reboot++ if (&$cfunc($s) == 2 ||
					      &$cfunc($s) == 4);
				}
			}
		else {
			print ".. not supported\n";
			}
		print "\n";
		}

	# Change virtual CPUs
	if (defined($vcpus)) {
		print "Setting virtual CPUs on $tdesc system $s->{'host'} ..\n";
		$cfunc = "type_".$t."_can_vcpus";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$vfunc = "type_".$t."_save_vcpus";
			$err = &$vfunc($s, \@vcpus);
			if ($err) {
				print ".. failed : $err\n";
				}
			else {
				print ".. done\n";
				$reboot++ if (&$cfunc($s) == 2);
				}
			}
		else {
			print ".. not supported\n";
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
			}
		print "\n";
		}

	# Update and changed parameters
	&save_managed_server($s);

	# Restart if needed
	if ($reboot && $s->{'status'} ne 'down') {
		if ($do_reboot) {
			# Yes .. do it now
			print "Rebooting system $s->{'host'} to ",
			      "apply limits ..\n";
			my $err = &reboot_server($s);
			if ($err) {
				print ".. failed : $err\n";
				}
			else {
				print ".. done\n";
				}
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

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Changes memory and CPU limits on one or more managed systems.\n";
print "\n";
print "cloudmin modify-limits [--host name]*\n";
print "                       [--group name]*\n";
local $types = join("|", @server_management_types);
print "                       [--type $types]*\n";
print "                       [--os oscode]*\n";
print "                       [--cpu percentage]\n";
print "                       [--weight number]\n";
print "                       [--memory MB]\n";
print "                       [--reboot]\n";
print "                       [--vcpus N | --vcpus list]\n";
print "                       [--bw-limit MB | --bw-unlimited]\n";
exit(1);
}

