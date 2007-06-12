#!/usr/local/bin/perl
# Lists some or all managed servers

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
			}
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
print "usage: list-systems.pl [--multiline]\n";
print "                       [--all-hosts] | [--host name]*\n";
print "                       [--group name]*\n";
local $types = join("|", @server_management_types);
print "                       [--type $types]*\n";
print "                       [--os oscode]*\n";
exit(1);
}

