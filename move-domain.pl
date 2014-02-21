#!/usr/local/bin/perl

=head1 move-domain.pl

Moves a domain from one system to another

This command allows you to transfer one or more Virtualmin domains from their
current host systems to another system managed by Cloudmin. Like the web-based
domain move feature, it operates by backing them up on the source and
restoring on the destination - so it is recommended that you transfer only
between similar systems where possible.

The domains to move are selected by the C<--domain> parameter. If a domain
exists on more than one host, you will also need to specify C<--host> followed
by the correct source hostname. The final system is selected by the C<--dest>
parameter. If the C<--include-sub-servers> parameter is given and a top-level
domain is selected, any sub-servers owned by the same user will be transferred
at the same time.

To have Cloudmin delete the domains from the source, use the C<--delete> parameter
(this is recommended). Or to just disable them when moving, use C<--disable>.

Once a domain has been moved, you will almost certainly need to make DNS
changes to reflect the new website or nameserver IP address.

By default, Cloudmin attempts to transfer the domain backup first to the master
system, and then to the target. However, the C<--direct> parameter will
trigger the attempted use of a direct copy from the source to the target
system, which can be faster if the network connectivity between the managed
systems and the Cloudmin master is poor. 

=head1 Example usage

  cloudmin move-domain --domain wibble.com --dest xenrails.home --delete
  Creating backup of wibble.com on xencentos.home ..
  .. created backup of 32.53 kB.
  Downloading backup of wibble.com in file wibble.com.tar.gz ..
  .. download of 32.53 kB complete.
  Uploading backup of wibble.com in file wibble.com.tar.gz to xenrails.home ..
  .. upload of 32.53 kB complete.
  Deleting wibble.com on xencentos.home ..
  .. deletion complete.
  Restoring backup of wibble.com on xenrails.home ..
  .. restore of wibble.com complete. Domain move was successfull!
  Refreshing status of 2 systems ..
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
$0 = "$pwd/move-domain.pl";
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
	elsif ($a eq "--dest") {
		$desthost = shift(@ARGV);
		}
	elsif ($a eq "--delete") {
		$deletesource = 1;
		}
	elsif ($a eq "--disable") {
		$deletesource = 2;
		}
	elsif ($a eq "--force") {
		$force = 1;
		}
	elsif ($a eq "--direct") {
		$direct = 1;
		}
	elsif ($a eq "--allocate-ip") {
		$realloc = 1;
		}
	elsif ($a eq "--include-sub-servers") {
		$incsubs = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}
@dnames || &usage("No domains to move specified");
$desthost || &usage("Missing --dest parameter");
$dest = &get_managed_server_by("host", $desthost);
$dest || &usage("System $desthost does not exist");
$dest->{'status'} eq 'virt' || &usage("System $desthost is not running Virtualmin");
&can_action_usage($dest, "domains");

# Get the domains
if ($host) {
	$server = &find_one_managed_server($host);
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
&can_action_usage([ map { $_->[0] } @serverdoms ], "domains");
foreach $dn (@dnames) {
	$found{$dn} || &usage("Domain $dn was not found on any system running Virtualmin");
	}

if ($incsubs) {
	# Automatically add sub-servers
	@serverdoms = &unique_serverdoms([ @serverdoms,
					   &find_sub_servers(\@serverdoms) ]);
	}

# Validate move
$err = &check_domain_move(\@serverdoms, $dest,
			  $deletesource, $direct, $realloc);
&usage("Selected domains cannot be moved : $err") if ($err);

# Check for missing features
if (!$force) {
	@missing = &check_move_features(\@serverdoms, $dest);
	if (@missing) {
		print "The following domains cannot be moved, as they use ".
		      "features not available on\n".
		      "the destination. Use --force to override.\n\n";
		$fmt = "%-40.40s %-35.35s\n";
		printf $fmt, "Domain", "Missing feature";
		printf $fmt, ("-" x 40), ("-" x 35);
		foreach $m (@missing) {
			printf $fmt, $m->[1]->{'dom'}, $m->[2]->{'desc'};
			}
		exit(1);
		}
	}

# Do it!
&set_all_text_print();
&obtain_lock_server($dest);
&obtain_lock_server([ map { $_->[0] } @serverdoms ]);
&move_domains_to_server(\@serverdoms, $dest,
			$deletesource, $direct, $realloc);
&release_lock_server([ map { $_->[0] } @serverdoms ]);
&release_lock_server($dest);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Moves one or more Virtualmin domains to another system.\n";
print "\n";
print "cloudmin move-domain --domain name [--domain name]*\n";
print "                     --dest hostname\n";
print "                    [--host source.hostname]\n";
print "                    [--disable | --delete]\n";
print "                    [--force]\n";
print "                    [--direct]\n";
print "                    [--include-sub-servers]\n";
exit(1);
}

