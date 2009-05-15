#!/usr/local/bin/perl

=head1 list-owners.pl

Lists some or all Cloudmin system owners

By default, this command outputs a table of all Cloudmin system owners. To switch
to a more complete and parsable format, use the C<--multiline> flag, or to
get a list of just logins use C<--name-only>. To limit the listing to just
some owners, use the C<--name> flag followed by a owner's login. This can be
given more than once.

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
	elsif ($a eq "--name") {
		push(@onames, shift(@ARGV));
		}
	elsif ($a eq "--name-only") {
		$nameonly = 1;
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
exit(1);
}

