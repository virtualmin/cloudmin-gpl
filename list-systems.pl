#!/usr/local/bin/perl

=head1 list-systems.pl

Output a table of all systems managed by Cloudmin.

When run with no parameters, this command outputs a table of all virtual
systems known to Cloudmin. You can limit the display to a subset of systems using
the standard options like C<--host> and C<--type>, have it output all
available information with the C<--multiline> parameter, or just show hostnames
with C<--name-only>.

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
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
if (@ARGV == 0) {
	$all = 1;	# If called with no args, assume all systems
	}
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	elsif ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	else {
		&usage();
		}
	}

# Work out who to list
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");

if ($multi) {
	# Show a block for each server
	foreach $s (@servers) {
		# Show general information
		$info = &get_server_collected($s);
		$tfunc = "type_".$s->{'manager'}."_desc";
		print $s->{'host'},"\n";
		print "    ID: $s->{'id'}\n";
		if ($s->{'id'} != 0) {
			print "    Description: $s->{'desc'}\n";
			}
		print "    Type: ",&$tfunc(),"\n";
		print "    Type code: $s->{'manager'}\n";
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

		# Show limits, where we can
		$cfunc = "type_".$s->{'manager'}."_can_memory";
		if (defined(&$cfunc) && &$cfunc($s)) {
			$mfunc = "type_".$s->{'manager'}."_get_memory";
			$mem = &$mfunc($s);
			if ($mem) {
				print "    Memory limit: ",
				      &nice_size($mem),"\n";
				}
			}
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
			($start, $now) = &usage_period_start_end(\@usage);
			print "    Resource accounting period: ",
				$config{'bw_period'} ?
					"Current ".$config{'bw_period'} :
					"Last ".$config{'bw_days'}." days","\n";
			$ago = time() - $start;
			print "    Start of period: ",
				&make_date($start)," ($ago seconds ago)\n";

			# System uptime
			$up = &sum_usage_over_period(
				\@usage, $start, $now, 'up');
			print "    System uptime over period: ",
				&nice_hour_mins_secs($up)," ($up seconds)\n";

			# Memory use
			$mem = &sum_usage_over_period(
				\@usage, $start, $now, 'mem');
			if ($mem) {
				$gbh = sprintf("%.2f",
					($mem / (3600*1024*1024*1024)));
				print "    Memory used over period: ",
					$gbh," GB hours ($mem byte seconds)\n";
				}

			# CPU allocation
			$cpu = &sum_usage_over_period(
				\@usage, $start, $now, 'cpu');
			if ($cpu) {
				$cpuh = sprintf("%.2f", ($cpu / 3600));
				print "    CPU allocated over period: ",
					$cpuh," percent hours ",
					"($cpu percent seconds)\n";
				}

			# CPU usage
			$load = &sum_usage_over_period(
				\@usage, $start, $now, 'load');
			if ($load) {
				$loadh = sprintf("%.2f", ($load / 3600));
				print "    CPU used over period: ",
					$loadh," percent hours ",
					"(loadu percent seconds)\n";
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
print "cloudmin list-systems [--multiline | --name-only]\n";
print "                      [--all-hosts] | [--host name]*\n";
print "                      [--group name]*\n";
local $types = join("|", @server_management_types);
print "                      [--type $types]*\n";
print "                      [--os oscode]*\n";
exit(1);
}

