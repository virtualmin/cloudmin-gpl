#!/usr/local/bin/perl

=head1 enable-domains.pl

Enables Virtualmin domains on managed systems

This command enables a domain (specified with the C<--domain> parameter) on
which every Cloudmin-managed system hosts it. This can be normally worked out
automatically, but if the same domain exists on more than one machine, you
will need to add C<--host> followed by the correct hostname.

When the command is run, it will display all of the output from the
C<enable-domain.pl> command on the remote system. More than one domain can
be disabled by specifying the C<--domain> parameter multiple times.

=head1 Example usage

  cloudmin enable-domains --domain wibble.com
  Enabling Virtualmin domain wibble.com on fudu.home ..
  Enabling virtual server wibble.com ..
  Adding to email domains list ..
  .. done
  Un-locking mail users' accounts ..
  .. done
  Renaming DNS zone to original name ..
  .. done
  Removing error page from website ..
  .. done
  Restoring MySQL user's password ..
  .. MySQL user can only be disabled in master domain
  Saving server details ..
  .. done
  Re-starting DNS server ..
  .. done
  Applying web server configuration ..
  .. done
  All done!.. enabled successfully
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
$0 = "$pwd/enable-domain.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--domain") {
		push(@dnames, shift(@ARGV));
		}
	elsif ($a eq "--host") {
		$host = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for citical parameters
@dnames || &usage("No domains to enable specified");

# Get the domains
if ($host) {
	$server = &get_managed_server_by("host", $host);
	$server || &usage("System $host does not exist");
	@sources = ( $server );
	}
else {
	@sources = &list_managed_servers();
	}
@serverdoms = ( );
foreach $s (@sources) {
	if ($s->{'status'} eq 'virt') {
		@doms = &get_server_domains($s);
		foreach $dn (@dnames) {
			($d) = grep { $_->{'dom'} eq $dn } @doms;
			if ($d) {
				if ($found{$d->{'dom'}}++) {
					&usage("Domain $dn was found on more than one system. Use --host to specify the source you want");
					}
				push(@serverdoms, [ $s, $d ]);
				}
			}
		}
	}
foreach $dn (@dnames) {
	$found{$dn} || &usage("Domain $dn was not found on any system running Virtualmin");
	}

# Delete each one
foreach $sd (@serverdoms) {
	($server, $d) = @$sd;
	&obtain_lock_server($server);

	# Remove the domain
	print "Enabling Virtualmin domain $d->{'dom'} on ",
	      "$server->{'host'} ..\n";
	if (!$d->{'disabled'}) {
		print ".. not currently disabled\n\n";
		}
	else {
		@args = ( [ "domain", $d->{'dom'} ] );
		($err, $out) = &call_virtualmin_api($server, "enable-domain", \@args);
		print $out;
		if ($err) {
			print ".. failed : $err\n\n";
			}
		else {
			print ".. enabled successfully\n\n";
			}
		&release_lock_server($server);
		}
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
print "Enables one or more Virtualmin domains on managed systems.\n";
print "\n";
print "cloudmin enable-domains --domain name [--domain name]*\n";
print "                       [--host source.hostname]\n";
exit(1);
}

