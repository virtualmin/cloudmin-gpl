#!/usr/local/bin/perl
# Creates a copy of some virtual system

=head1 clone-system.pl

Creates a new virtual system that is a copy of some existing one.

XXX

=head1 Example usage

  cloudmin clone-system --host xengtest.home --new-host xencopy
  XXX

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
	else {
		&usage();
		}
	}

# Check for mandatory args
$host || &usage("Missing --host parameter");
$newhost || &usage("Missing --new-host parameter");
$newhost =~ /^[a-z0-9\.\-]+$/ || &usage("Invalid new hostname");
$newhost =~ /\./ && &usage("No . is needed in the new hostname - the domain will be automatically appended");

# Get the system
$server = &get_managed_server_by("host", $host);
$server || &usage("No system named $host exists");

# Check if supported
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_clone";
defined(&$cfunc) || &usage("Systems of type $desc cannot be cloned");
&$cfunc($server) || &usage("The selected system cannot be cloned");

# Validate owner resource limits
&can_create_server_usage($server->{'manager'});
$limits = &get_owner_limits();
if ($limits) {
	# Validate disk limit
	$dsfunc = "type_".$type."_get_disk_size";
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
	$mfunc = "type_".$type."_get_memory_size";
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
	$cfunc = "type_".$type."_get_cpu_size";
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
	$incr = scalar(split(/\s+/, $server->{'ip_addresses'})) || 1;
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
($newserver, $err) = &clone_system($server, $newhost, $newdesc);
&$outdent_print();
&release_lock_server($server);
if ($newserver && $err) {
	print $err,"\n";
	print ".. clone $newserver->{'host'} partially created.\n";
	}
elsif ($newserver && !$err) {
	print ".. clone $newserver->{'host'} created.\n";
	}
elsif (!$newserver && $err) {
	print $err,"\n";
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
exit(1);
}

