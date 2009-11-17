#!/usr/local/bin/perl

=head1 list-systems.pl

Output a table of all systems managed by Cloudmin.

When run with no parameters, this command outputs a table of all virtual
systems known to Cloudmin. You can limit the display to a subset of systems using
the standard options like C<--host>, C<--type> and C<--owner>, have it output all
available information with the C<--multiline> parameter, or just show hostnames
with C<--name-only>.

To limit the display to only systems that can host virtual systems, use the
C<--host-type> flag followed by a virtualization type like C<xen>, C<openvz>
or C<zones>. Or if you want to get all host systems, use C<--host-type all>.

In mutiline mode, uptime, CPU and RAM usage is displayed for the current
account period. To show the previous period instead, use the C<--last-period>
flag. Or to select any period in the past, use the C<--period-ago> flag followed
by a number of weeks or months.

=head1 Example usage

  cloudmin list-systems --type xen
  Hostname                       Type            Description
  ------------------------------ --------------- ------------------------------
  xencentos.home                 Xen             CentOS 5 on Xen
  xencentos4.home                Xen             Test system with CentOS 4
  xengentoo.home                 Xen             Gentoo on Xen
  xenrails.home                  Xen             Test server for Rails on Xen
  xentemplatecentos.home         Xen             Xen Virtualmin template for Ce
  xentemplatecentos4.home        Xen             Xen template for CentOS 4.4
  xentemplatedebian.home         Xen             Xen Virtualmin template for De
  xentemplatefc6.home            Xen             Xen Virtualmin template for Fe
  xentemplateubuntu.home         Xen             Ubuntu on Xen

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
$0 = "$pwd/list-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	elsif ($a eq "--id-only") {
		$idonly = 1;
		}
	elsif ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
	elsif ($a eq "--host-type") { $hosttypes{shift(@ARGV)} = 1; }
	elsif ($a eq "--last-period") { $period_ago = 1; }
	elsif ($a eq "--period-ago") { $period_ago = shift(@ARGV); }
	else {
		&usage();
		}
	}
if (!@hosts && !@groups && !@types && !@managers && !@owners) {
	# If called with no selector, assume all
	$all = 1;
	}

# Work out who to list
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
if (keys %hosttypes) {
	@servers = grep {
		my @pt = &is_parent_server($_);
		scalar(@pt) && ($hosttypes{'all'} ||
				scalar(grep { $hosttypes{$_} } @pt));
		} @servers;
	}
@servers || &usage("No systems specified");

if (defined(&list_locations)) {
	@locs = &list_locations();
	}
if ($multi) {
	# Show a block for each server
	foreach $s (@servers) {
		# Show general information
		$info = &get_server_collected($s);
		$tfunc = "type_".$s->{'manager'}."_desc";
		print $s->{'host'},"\n";
		print "    ID: $s->{'id'}\n";
		foreach $ip (&get_server_ip($s)) {
			print "    IP address: $ip\n";
			}
		if ($s->{'id'} != 0) {
			print "    Description: $s->{'desc'}\n";
			}
		print "    Type: ",&$tfunc(),"\n";
		print "    Type code: $s->{'manager'}\n";
		if ($s->{'location'}) {
			($loc) = grep { $_->{'id'} eq $s->{'location'} } @locs;
			if ($loc) {
				print "Location group: $loc->{'desc'}\n";
				}
			}
		print "    Status: ",$text{'status_'.$s->{'status'}},"\n";
		print "    Status code: $s->{'status'}\n";
		if ($s->{'status_msg'}) {
			print "    Status error: $s->{'status_msg'}\n";
			}
		print "    Status checked: ",
			&make_date($s->{'statustime'}),"\n";
		if ($s->{'status'} eq 'virt' && $s->{'virtualmin_error'}) {
			print "    Virtualmin config error: ",
			      &strip_html_tags($s->{'virtualmin_error'}),"\n";
			}
		if ($s->{'status'} eq 'virt' || $s->{'status'} eq 'novirt') {
			print "    OS: ",&describe_os($s->{'type'}),"\n";
			print "    OS code: ",$s->{'type'},"\n";
			print "    Webmin version: ",
			      $info->{'general'}->{'version'},"\n";
			}
		if ($s->{'status'} eq 'virt') {
			print "    Virtualmin version: ",
			      $info->{'minfo'}->{'version'},"\n";
			}
		$k = $info->{'kernel'};
		if ($k->{'version'}) {
			print "    Kernel version: $k->{'os'} $k->{'version'}\n";
			}
		if ($k->{'arch'}) {
			print "    CPU architecture: $k->{'arch'}\n";
			}
		$bfunc = "type_".$s->{'manager'}."_get_atboot";
		if (defined(&$bfunc)) {
			print "    Start at boot: ",
			      (&$bfunc($s) ? "Yes" : "No"),"\n";
			}

		# Login information
		$sfunc = "type_".$s->{'manager'}."_no_ssh";
		$hasssh = !defined(&$sfunc) || !&$sfunc();
		if ($hasssh) {
			print "    SSH login: $s->{'ssh_user'}\n";
			if ($s->{'ssh_pass'}) {
				print "    SSH password: $s->{'ssh_pass'}\n";
				}
			else {
				print "    SSH key ID: $s->{'key'}\n";
				}
			}
		print "    Webmin same as SSH: ",
			($s->{'ssh_pass_same'} ? "Yes" : "No"),"\n";
		if (!$s->{'ssh_pass_same'}) {
			print "    Webmin login: $s->{'user'}\n";
			print "    Webmin password: $s->{'pass'}\n";
			}
		print "    Webmin port: $s->{'port'}\n";
		print "    Webmin SSL: ",($s->{'ssl'} ? "Yes" : "No"),"\n";

		# Show type-specific info
		$ifunc = "type_".$s->{'manager'}."_server_info";
		if (defined(&$ifunc)) {
			foreach my $i (&$ifunc($s)) {
				print "    $i->[0]: $i->[1]\n";
				}
			}

		# Show host-type-specific info
		foreach my $p (&is_parent_server($s)) {
			$ifunc = "type_".$p."_server_host_info";
			if (defined(&$ifunc)) {
				foreach my $i (&$ifunc($s)) {
					print "    $i->[0]: $i->[1]\n";
					}
				}
			}

		# Show limits, where we can, starting with memory
		$cfunc = "type_".$s->{'manager'}."_can_memory";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$mfunc = "type_".$s->{'manager'}."_get_memory";
			$mem = &$mfunc($s);
			if (defined($mem)) {
				print "    Memory limit: ",
				      ($mem ? &nice_size($mem)
					    : "Unlimited"),"\n";
				}
			}

		# CPU limit
		$cfunc = "type_".$s->{'manager'}."_can_cpu";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$mfunc = "type_".$s->{'manager'}."_get_cpu";
			($cpu, $weight) = &$mfunc($s);
			print "    Maximum CPU use: ",
			      ($cpu ? $cpu."%" : "Unlimited"),"\n";
			if ($weight) {
				print "    CPU allocation weighting: $weight\n";
				}
			}

		# Virtual CPU mappings
		$cfunc = "type_".$s->{'manager'}."_can_vcpus";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$mfunc = "type_".$s->{'manager'}."_get_vcpus";
			$vcpus = &$mfunc($s);
			if (ref($vcpus)) {
				@v = ( );
				foreach $cpu (@$vcpus) {
					push(@v, "ID:$cpu->{'num'}".
					   ($cpu->{'pin'} ne '' ?
					    " RealCPU:$cpu->{'pin'}" : ""));
					}
				print "    Virtual CPUs: ",join(", ", @v),"\n";
				}
			}

		# Disk space limit
		$cfunc = "type_".$s->{'manager'}."_can_disk";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$dfunc = "type_".$s->{'manager'}."_get_disk";
			$disk = &$dfunc($s);
			if (defined($disk)) {
				print "    Disk space limit on host: ",
				      ($disk ? &nice_size($disk)
					    : "Unlimited"),"\n";
				}
			}

		# Disk space used
		$dfunc = "type_".$s->{'manager'}."_get_disk_space";
		if (defined(&$dfunc)) {
			$space = &$dfunc($s);
			if ($space) {
				print "    Disk space used on host: ",
					&nice_size($space),"\n";
				}
			}

		# Network rate
		$cfunc = "type_".$s->{'manager'}."_can_network_rate";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$rfunc = "type_".$s->{'manager'}."_get_network_rate";
			$rate = &$rfunc($s);
			if (defined($rate)) {
				print "    Network rate: ",
				      ($rate ? &nice_rate($rate)
					     : "Unlimited"),"\n";
				}
			}

		# Show bandwidth limit and usage
		$rfunc = "type_".$s->{'manager'}."_real_interfaces";
		if (defined(&$rfunc) && $config{'bw_enabled'}) {
			print "    Bandwidth limit: ",
			      ($s->{'bw_limit'} ? &nice_size($s->{'bw_limit'})
						: "Unlimited"),"\n";
			print "    Bandwidth accounting period: ",
			      ($config{'bw_period'} ?
				"Current ".$config{'bw_period'} :
				"Last ".$config{'bw_days'}." days"),"\n";
			print "    Bandwidth usage towards limit: ",
				&nice_size($s->{'bw_usage'}),"\n";
			print "    Bandwidth usage incoming: ",
				&nice_size($s->{'bw_usage_in'}),"\n";
			print "    Bandwidth usage outgoing: ",
				&nice_size($s->{'bw_usage_out'}),"\n";
			if ($s->{'bw_usage'} > $s->{'bw_limit'} &&
			    $s->{'bw_limit'} && $s->{'bw_notify'}) {
				print "    Bandwidth notification sent: ",
				      &make_date($s->{'bw_notify'}),"\n";
				}
			}

		# Show resource usage
		if (defined(&get_server_usage)) {
			# Get usage and current period
			@usage = &get_server_usage($s);
			($start, $end) = &usage_period_start_end(
						\@usage, $period_ago);
			print "    Resource accounting period: ",
				$config{'bw_period'} ?
					"One ".$config{'bw_period'} :
					"Last ".$config{'bw_days'}." days","\n";
			$ago = time() - $start;
			print "    Start of period: ",
				&make_date($start)," ($ago seconds ago)\n";
			$eago = time() - $end;
			print "    End of period: ",
				&make_date($end)," ($eago seconds ago)\n";

			# System uptime
			$up = &sum_usage_over_period(
				\@usage, $start, $end, 'up');
			print "    System uptime over period: ",
				&nice_hour_mins_secs($up)," ($up seconds)\n";

			# Memory use
			$mem = &sum_usage_over_period(
				\@usage, $start, $end, 'mem');
			if ($mem) {
				$gbh = sprintf("%.2f",
					($mem / (3600*1024*1024*1024)));
				$avgmem = int($mem / ($end - $start));
				$upmem = int($mem / $up);
				print "    Memory used over period: ",
					$gbh," GB hours ($mem byte seconds)\n";
				print "    Memory average over period: ",
					$avgmem," bytes\n";
				print "    Memory average while up: ",
					$upmem," bytes\n";
				}

			# CPU allocation
			$cpu = int(&sum_usage_over_period(
				\@usage, $start, $end, 'cpu'));
			if ($cpu) {
				$cpuh = sprintf("%.2f", ($cpu / 3600));
				print "    CPU allocated over period: ",
					$cpuh," percent hours ",
					"($cpu percent seconds)\n";
				}

			# CPU usage
			$load = int(&sum_usage_over_period(
				\@usage, $start, $end, 'load'));
			if ($load) {
				$loadh = sprintf("%.2f", ($load / 3600));
				$avgcpu = int($load / ($end - $start));
				$upcpu = int($load / $up);
				print "    CPU used over period: ",
					$loadh," percent hours ",
					"($load percent seconds)\n";
				print "    CPU used average over period: ",
					$avgcpu," percent\n";
				print "    CPU used average while up: ",
					$upcpu," percent\n";
				}

			# Disk allocation
			$disk = &sum_usage_over_period(
				\@usage, $start, $end, 'disk');
			if ($disk) {
				$gbh = sprintf("%.2f",
					($disk / (3600*1024*1024*1024)));
				print "    Disk limit over period: ",
					$gbh," GB hours ($disk byte seconds)\n";
				}

			# Disk used
			$space = &sum_usage_over_period(
				\@usage, $start, $end, 'space');
			if ($space) {
				$gbh = sprintf("%.2f",
					($space / (3600*1024*1024*1024)));
				$avgdisk = int($disk / ($end - $start));
				print "    Disk used over period: ",
				       $gbh," GB hours ($space byte seconds)\n";
				print "    Disk average over period: ",
					$avgdisk," bytes\n";
				}
			}

		# Show collected info
		if ($info && scalar(keys %$info) > 1) {
			if ($info->{'load'}) {
				print "    CPU load: ",
				      join(" ", @{$info->{'load'}}[0..2]),"\n";
				}
			if ($info->{'mem'}) {
				print "    Real memory: ",
				      &nice_size($info->{'mem'}->[0]),"\n";
				print "    Real memory free: ",
				      &nice_size($info->{'mem'}->[1]),"\n";
				print "    Virtual memory: ",
				      &nice_size($info->{'mem'}->[2]),"\n";
				print "    Virtual memory free: ",
				      &nice_size($info->{'mem'}->[3]),"\n";
				}
			if ($info->{'disk_total'}) {
				print "    Disk space: ",
				      &nice_size($info->{'disk_total'}),"\n";
				print "    Disk space free: ",
				      &nice_size($info->{'disk_free'}),"\n";
				}
			if ($info->{'startstop'}) {
				@ss = @{$info->{'startstop'}};
				print "    Running services: ",
					join(", ", map { $_->{'name'} }
					     grep { $_->{'status'} } @ss),"\n";
				print "    Down services: ",
					join(", ", map { $_->{'name'} }
					     grep { !$_->{'status'} } @ss),"\n";
				}
			if ($info->{'poss'} && @{$info->{'poss'}}) {
				print "    Available updates: ",
					join(", ", map { "$_->{'name'} ($_->{'version'})" } @{$info->{'poss'}}),"\n";
				}
			if ($info->{'serial'}) {
				print "    Virtualmin serial: ",
					$info->{'serial'}->{'serial'},"\n";
				print "    Virtualmin key: ",
					$info->{'serial'}->{'key'},"\n";
				print "    Virtualmin expiry date: ",
					$info->{'serial'}->{'expiry'},"\n";
				}
			}
	
		# Show cluster packages status
		$pkgs = &get_server_cluster_software($s);
		print "    Package management: ",
		      $pkgs < 0 ? "Not available" :
		      $pkgs ? "Enabled" : "Disabled","\n";
		}
	}
elsif ($nameonly) {
	# Just hostnames
	foreach $s (@servers) {
		print $s->{'host'},"\n";
		}
	}
elsif ($idonly) {
	# Just IDs
	foreach $s (@servers) {
		print $s->{'id'},"\n";
		}
	}
else {
	# Show one server per line
	$fmt = "%-30.30s %-15.15s %-30.30s\n";
	printf $fmt, "Hostname", "Type", "Description";
	printf $fmt, ("-" x 30), ("-" x 15), ("-" x 30);
	foreach $s (@servers) {
		$tfunc = "type_".$s->{'manager'}."_desc";
		printf $fmt, $s->{'host'}, &$tfunc(), $s->{'desc'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists some or all registered managed systems.\n";
print "\n";
print "cloudmin list-systems [--multiline | --name-only | --id-only]\n";
print "                      [--all-hosts] | [--host name]*\n";
print "                      [--group name]*\n";
my $types = join("|", @server_management_types);
print "                      [--type $types]*\n";
print "                      [--os oscode]*\n";
print "                      [--owner name]*\n";
print "                      [--host-type type|\"all\"]\n";
print "                      [--last-period | --period-ago N]\n";
exit(1);
}

