#!/usr/local/bin/perl
# Lists domains on some or all managed servers

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-domains.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

# Parse command line
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
	elsif ($a eq "--domain") { push(@dnames, shift(@ARGV)); }
	else {
		&usage();
		}
	}

# Work out who to list domains on
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types);
@servers = sort { $a->{'host'} cmp $b->{'host'} } @servers;
@servers || &usage("No systems specified");

# Get all the domains
foreach $s (@servers) {
	foreach $d (&get_server_domains($s)) {
		push(@serverdoms, [ $s, $d ]);
		}
	}
if (@dnames) {
	# Limit to those requested
	%want = map { $_, 1 } @dnames;
	@serverdoms = grep { $want{$_->[1]->{'dom'}} } @serverdoms;
	}

if ($multi) {
	# Show a block for each domain
	%dmap = map { $_->[0]->{'id'}, $_->[0] } @serverdoms;
	foreach $sd (@serverdoms) {
		($s, $d) = @$sd;
		$info = &get_server_collected($s);
		print "$d->{'dom'}\n";
		print "    ID: $d->{'id'}\n";
		print "    Host system: $s->{'host'}\n";
		print "    Type: ",($d->{'alias'} ? "Alias" :
				    $d->{'parent'} ? "Sub-server" :
						     "Top-level server"),"\n";
		if ($d->{'alias'}) {
			$aliasdom = $dmap{$d->{'alias'}};
			print "    Real domain: $aliasdom->{'dom'}\n";
			}
		elsif ($d->{'parent'}) {
			$parentdom = $dmap{$d->{'parent'}};
			print "    Parent domain: $parentdom->{'dom'}\n";
			}
		print "    Description: $d->{'owner'}\n";
		print "    Username: $d->{'user'}\n";
		print "    Group name: $d->{'group'}\n";
		print "    Mailbox username prefix: $d->{'prefix'}\n";
		print "    Password: $d->{'pass'}\n";
		print "    Home directory: $d->{'home'}\n";
		print "    Contact email: $d->{'emailto'}\n";
		print "    Created on: ",&make_date($d->{'created'}),"\n";
		if ($d->{'creator'}) {
			print "    Created by: $d->{'creator'}\n";
			}
		if ($d->{'disabled'}) {
			$dwhy = $d->{'disabled_reason'} eq 'bw' ?
				  "For exceeding bandwidth limit" :
				$d->{'disabled_why'} ?
				  "Manually ($d->{'disabled_why'})" :
				  "Manually";
			print "    Disabled: $dwhy\n";
			}
		if ($d->{'virt'}) {
			print "    IP address: $d->{'ip'} (Private)\n";
			}
		else {
			print "    IP address: $d->{'ip'} (Shared)\n";
			}
		if ($info) {
			@features = map { $_->{'feature'} }
				        grep { !$_->{'plugin'} }
					@{$info->{'features'}};
			print "    Features: ",
			      join(" ", grep { $d->{$_} } @features),"\n";
			@feature_plugins = map { $_->{'feature'} }
				               grep { $_->{'plugin'} }
					       @{$info->{'features'}};
			if (@feature_plugins) {
				print "    Plugins: ",
				      join(" ", grep { $d->{$_} }
						  @feature_plugins),"\n";
				}
			}
		if ($d->{'quota'} && !$d->{'parent'}) {
			print "    Server quota: ",
			      ($d->{'quota'} ? "$d->{'quota'} blocks"
					     : "Unlimited"),"\n";
			print "    User quota: ",
			      ($d->{'quota'} ? "$d->{'quota'} blocks"
					     : "Unlimited"),"\n";
			}
		if ($d->{'bw_limit'} && !$d->{'parent'}) {
			print "    Bandwidth limit: ",($d->{'bw_limit'} ? &nice_size($d->{'bw_limit'}) : "Unlimited"),"\n";
			if (defined($d->{'bw_usage'})) {
				print "    Bandwidth start: ",&make_date($d->{'bw_start'}*(24*60*60), 1),"\n";
				print "    Bandwidth usage: ",&nice_size($d->{'bw_usage'}),"\n";
				}
			if ($config{'bw_disable'}) {
				print "    Disable if over bandwidth limit: ",
			           ($d->{'bw_no_disable'} ? "No" : "Yes"),"\n";
				}
			}
		if ($d->{'reseller'}) {
			print "    Reseller: $d->{'reseller'}\n";
			}
		}
	}
else {
	# Show one domain per line
	$fmt = "%-25.25s %-25.25s %-28.28s\n";
	printf $fmt, "Domain", "System", "Description";
	printf $fmt, ("-" x 25), ("-" x 25), ("-" x 28);
	foreach $sd (@serverdoms) {
		printf $fmt, $sd->[1]->{'dom'}, $sd->[0]->{'host'},
			     $sd->[1]->{'owner'};
		}
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists domains on some or all managed systems.\n";
print "\n";
print "usage: list-domains.pl [--multiline]\n";
print "                       [--all-hosts] | [--host name]*\n";
print "                       [--group name]*\n";
local $types = join("|", @server_management_types);
print "                       [--type $types]*\n";
print "                       [--os oscode]*\n";
print "                       [--domain name]*\n";
exit(1);
}

