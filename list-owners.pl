#!/usr/local/bin/perl
# Lists some or all system owners

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/list-owners.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@allservers = &list_managed_servers();

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--multiline") {
		$multi = 1;
		}
	elsif ($a eq "--owner") {
		push(@onames, shift(@ARGV));
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

# Print them
if ($multi) {
	# Full details
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
		%actions = map { $_, 1 } split(/\s+/, $o->{'acl'}->{'actions'});
		print "    Allowed actions: ",
		    join(" ", grep { $actions{$_} } &list_owner_actions()),"\n";
		}
	}
else {
	# Just summary
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Lists some or all systems owners.\n";
print "\n";
print "usage: list-owners.pl [--multiline]\n";
print "                      [--owner username]*\n";
exit(1);
}

