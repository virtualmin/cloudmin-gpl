#!/usr/local/bin/perl

=head1 delete-domains.pl

Removes Virtualmin domains from managed systems

This command deletes a domain (specified with the C<--domain> parameter) from
which every Cloudmin-managed system hosts it. This can be normally worked out
automatically, but if the same domain exists on more than one machine, you
will need to add C<--host> followed by the correct hostname. Or use
C<--all-hosts> to remove the domain from every system that it is on.

When the command is run, it will display all of the output from the
C<delete-domain.pl> command on the remote system. More than one domain can
be deleted by specifying the C<--domain> parameter multiple times.
Be careful using it, as it will not prompt for any confirmation before deletion.

=head1 Example usage

  cloudmin delete-domains --domain wibble.com
  Deleting Virtualmin domain wibble.com from xencentos.home ..
  Deleting virtual server wibble.com ..
  Deleting mail aliases ..
  .. done
  Deleting Webmin login ..
  .. done
  Deleting virtual website ..
  .. done
  Deleting administration user ..
  .. done
  Deleting administration group ..
  .. done
  Deleting home directory ..
  .. done
  Deleting server details for wibble.com ..
  .. done
  Re-loading Webmin ..
  .. done
  Applying web server configuration ..
  .. done
  All done!.. deleted successfully
  Refreshing status of changed systems ..
  .. done

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
$0 = "$pwd/delete-domain.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--domain") {
		push(@dnames, shift(@ARGV));
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--all-hosts") {
		$allhosts = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Check for citical parameters
@dnames || &usage("No domains to delete specified");
$hosr && $allhosts && &usage("--host and --all-hosts cannot both be used");

if ($host) {
	$server = &find_one_managed_server($host);
	$server || &usage("System $host does not exist");
	}

# Get the domains
@serverdoms = ( );
foreach $s (&list_managed_servers()) {
	# Get the domains from this system, and count up the number of
	# domains that exist with the same name
	@doms = &get_server_domains($s);
	foreach $d (@doms) {
		$dcount{$d->{'dom'}}++;
		}

	if ($s->{'status'} eq 'virt') {
		# If in single host mode and this isn't that host, skip
		next if ($host && $s->{'host'} ne $host);

		# Find all the requested domains by name
		foreach $dn (@dnames) {
			($d) = grep { $_->{'dom'} eq $dn } @doms;
			if ($d) {
				if ($found{$d->{'dom'}}++ && !$allhosts) {
					&usage("Domain $dn was found on more than one system. Use --host to specify the source you want");
					}
				push(@serverdoms, [ $s, $d ]);
				}
			}
		}
	}
&can_action_usage([ map { $_->[0] } @serverdoms ], "domains");
foreach $dn (@dnames) {
	$found{$dn} || &usage("Domain $dn was not found on any system running Virtualmin");
	}

# Delete each one
foreach $sd (@serverdoms) {
	($server, $d) = @$sd;
	&obtain_lock_server($server);

	# Remove the domain
	print "Deleting Virtualmin domain $d->{'dom'} from ",
	      "$server->{'host'} ..\n";
	@args = ( [ "domain", $d->{'dom'} ] );
	$dcount{$d->{'dom'}}--;
	if ($dcount{$d->{'dom'}}) {
		# Another copy exists - preserve remote resources
		push(@args, [ "preserve-remote" ]);
		}
	($err, $out) = &call_virtualmin_api($server, "delete-domain", \@args);
	print $out;
	if ($err) {
		print ".. failed : $err\n\n";
		}
	else {
		print ".. deleted successfully\n\n";
		}

	# Remove the virtual IP
	$iface = &get_domain_interface($server, $d);
	if ($iface && !$err) {
		print "Removing network interface $iface->{'address'} ",
		      "from $server->{'host'} ..\n";
		$dfunc = "type_".$server->{'manager'}."_delete_interface";
		$err = &$dfunc($server, $iface);
		if ($err) {
			print ".. failed : $err\n\n";
			}
		else {
			print ".. deleted successfully\n\n";
			}
		}
	&release_lock_server($server);
	}

# Recheck server statuses
print "Refreshing status of changed systems ..\n";
foreach my $sd (@serverdoms) {
	$server = $sd->[0];
	if (!$donerecheck{$server->{'host'}}++) {
		&check_server_status($server);
		&save_managed_server($server);
		}
	}
print ".. done\n\n";
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Deletes one or more Virtualmin domains from managed systems.\n";
print "\n";
print "cloudmin delete-domains --domain name [--domain name]*\n";
print "                       [--host source.hostname | --all-hosts]\n";
exit(1);
}

