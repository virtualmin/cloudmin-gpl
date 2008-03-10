#!/usr/local/bin/perl
# Changes memory and CPU limits on one or more systems

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
	elsif ($a eq "--reboot") {
		# Reboot after
		$do_reboot = 1;
		}
	else {
		&usage();
		}
	}
$cpu || $memory || &usage("Nothing to modify!");

# Get the systems
@servers = &find_managed_servers(0, \@hosts, \@groups, \@managers, \@types);
@servers || &usage("No systems specified");

# Check if we can do any of them
foreach $s (@servers) {
	$anycan++ if (&can_edit_limits($s));
	}
$anycan || &usage("None of the specified systems can have their ".
		  "CPU or memory limits changed");

# Do each system
foreach $s (@servers) {
	$t = $s->{'manager'};
	$tfunc = "type_".$t."_desc";
	$tdesc = &$tfunc();

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

	# Change CPU, if we can
	if ($cpu) {
		# XXX
		}

	# Restart if needed
	if ($reboot && $s->{'status'} ne 'down') {
		if ($do_reboot) {
			# Yes .. do it now
			print "Rebooting system $s->{'host'} to ",
			      "apply limits ..\n";
			my $err = &shutdown_server($s);
			$err = &startup_server($s) if (!$err);
			if ($err) {
				print ".. failed : $err\n";
				}
			else {
				print ".. done\n";
				}
			print "\n";
			}
		else {
			# Needed to, but user didn't ask
			push(@need_reboot, $s);
			}
		}
	}

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
print "usage: modify-limits.pl [--host name]*\n";
print "                        [--group name]*\n";
local $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--cpu percentage]\n";
print "                        [--memory MB]\n";
print "                        [--reboot]\n";
exit(1);
}

