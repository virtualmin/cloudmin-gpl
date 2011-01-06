#!/usr/local/bin/perl

=head1 list-owners.pl

Lists some or all Cloudmin system owners

By default, this command outputs a table of all Cloudmin system owners. To switch
to a more complete and parsable format, use the C<--multiline> flag, or to
get a list of just logins use C<--name-only>. To limit the listing to just
some owners, use the C<--name> flag followed by a owner's login. This can be
given more than once.

In mutiline mode, uptime, CPU and RAM usage is displayed for the current
account period. To show the previous period instead, use the C<--last-period>
flag. Or to select any period in the past, use the C<--period-ago> flag followed
by a number of weeks or months.

=head1 Example usage

  cloudmin list-owners
  Login                Real name            Systems                               
  -------------------- -------------------- ----------------------------------
  freeman              Gordon Freeman       xenbacula.home xencentos.home
  joe                  Joe Cooper           xencentos.home xensendmail.home    
  
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
$0 = "$pwd/list-owners.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@allservers = &list_managed_servers();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--name") {
		push(@onames, shift(@ARGV));
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
		}
	elsif ($a eq "--last-period") {
		$period_ago = 1;
		}
	elsif ($a eq "--period-ago") {
		$period_ago = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Get the owners
@owners = &list_system_owners();
if (@onames) {
	@owners = grep { &indexof($_->{'name'}, @onames) >= 0 } @owners;
	}
if ($access{'owner'}) {
	@owners = grep { $_->{'name'} eq $remote_user } @owners;
	}

# Print them
if ($multi) {
	# Full details
	@oplugins = grep { &plugin_defined($_, "list_owner_fields") } @plugins;
	foreach $o (@owners) {
		print $o->{'name'},"\n";
		print "    Real name: $o->{'real'}\n";
		print "    Email address: $o->{'acl'}->{'email'}\n";
		print "    Temporarily locked: ",
			$o->{'pass'} =~ /^\!/ ? "Yes" : "No","\n";
		%canservers = map { $_, 1 }
			split(/\s+/, $o->{'acl'}->{'servers'});
		@users = grep { $canservers{$_->{'id'}} } @allservers;
		foreach $s (@users) {
			print "    Managed system: $s->{'host'}\n";
			}
		if (&supports_plans()) {
			# Limits and usage
			$plan = &get_plan($o->{'acl'}->{'plan'});
			$limits = &get_owner_limits($o->{'name'});
			print "    Plan: ",$plan->{'desc'},"\n";
			foreach $l (@plan_limit_types) {
				$n = &indexof($l, @nice_plan_limit_types) >= 0;
				$m = $limits->{'max_'.$l};
				$c = $limits->{$l};
				print "    Max ${l}: ",
					!$m ? "Unlimited" :
					$n ? &nice_size($m) : $m,"\n";
				if ($n) {
					print "    Max ${l} in bytes: ",
						!$m ? "Unlimited" : $m,"\n";
					}
				if ($c) {
					print "    Current ${l}: ",
						$n ? &nice_size($c) : $c,"\n";
					}
				if ($c && $n) {
					print "    Current ${l} in bytes: ",
						$c,"\n";
					}
				}
			print "    Actions from plan: ",
				($o->{'acl'}->{'actions_def'} ? "Yes" : "No"),
				"\n";
			}
		%actions = map { $_, 1 } split(/\s+/, $o->{'acl'}->{'actions'});
		print "    Allowed actions: ",
		    join(" ", grep { $actions{$_} } &list_owner_actions()),"\n";

		# Limits from plugins
		foreach $p (@oplugins) {
			foreach $f (&plugin_call($p, "list_owner_fields",
						 $o, 0)) {
				print "    ".$f->{'desc'}.": ".
					     $f->{'value'}."\n";
				}
			}

		# Find all usage for managed systems
		@allusage = ( );
		foreach $s (@users) {
			push(@allusage, &get_server_usage($s));
			}
		@allusage = sort { $a->{'start'} cmp $b->{'start'} } @allusage;
		($start, $end) = &usage_period_start_end(\@allusage,
							 $period_ago);

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
			\@allusage, $start, $end, 'up');
		print "    System uptime over period: ",
			&nice_hour_mins_secs($up)," ($up seconds)\n";

		# Memory use
		$mem = &sum_usage_over_period(
			\@allusage, $start, $end, 'mem');
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
			\@allusage, $start, $end, 'cpu'));
		if ($cpu) {
			$cpuh = sprintf("%.2f", ($cpu / 3600));
			print "    CPU allocated over period: ",
				$cpuh," percent hours ",
				"($cpu percent seconds)\n";
			}

		# CPU usage
		$load = int(&sum_usage_over_period(
			\@allusage, $start, $end, 'load'));
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
			\@allusage, $start, $end, 'disk');
		if ($disk) {
			$gbh = sprintf("%.2f",
				($disk / (3600*1024*1024*1024)));
			print "    Disk limit over period: ",
				$gbh," GB hours ($disk byte seconds)\n";
			}

		# Disk used
		$space = &sum_usage_over_period(
			\@allusage, $start, $end, 'space');
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
	}
elsif ($nameonly) {
	# Just logins
	foreach $o (@owners) {
		print $o->{'name'},"\n";
		}
	}
else {
	# Just summary
	$fmt = "%-20.20s %-20.20s %-38.38s\n";
	printf $fmt, "Login", "Real name", "Systems";
	printf $fmt, ("-" x 20), ("-" x 20), ("-" x 38);
	foreach $o (@owners) {
		%canservers = map { $_, 1 }
			split(/\s+/, $o->{'acl'}->{'servers'});
		@users = grep { $canservers{$_->{'id'}} } @allservers;
		printf $fmt, $o->{'name'}, $o->{'real'},
			     join(" ", map { $_->{'host'} } @users);
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists some or all systems owners.\n";
print "\n";
print "cloudmin list-owners [--multiline | --name-only]\n";
print "                     [--name username]*\n";
print "                     [--last-period | --period-ago N]\n";
exit(1);
}

