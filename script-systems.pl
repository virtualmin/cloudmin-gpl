#!/usr/local/bin/perl

=head1 script-systems.pl

Updates Virtualmin scripts on multiple systems, and displays the results.

This command updates scripts installed by Virtualmin (like Wordpress or
phpMyAdmin) on multiple systems, selected using standard flags like 
C<--host>.

By default, it will attempt to upgrade all scripts for which newer versions
are available axross all domains. However, you can limit it to selected script
types with the C<--script> flag followed by a name like I<wordpress>. Or you
can have the command simply display what it would like to upgrade with the
C<--test> flag.

=head1 Example usage

  cloudmin script-systems --host xennoupdate.home
  Updating scripts on 1 systems ..
  xennoupdate.home: OK example.com/wordpress/4.8

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
$0 = "$pwd/script-systems.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;
&usage_if_cloudmin_replica();

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--all-hosts") { $all = 1; }
	elsif ($a eq "--host") { push(@hosts, shift(@ARGV)); }
	elsif ($a eq "--group") { push(@groups, shift(@ARGV)); }
	elsif ($a eq "--os") { push(@types, shift(@ARGV)); }
	elsif ($a eq "--type") { push(@managers, shift(@ARGV)); }
	elsif ($a eq "--owner") { push(@owners, shift(@ARGV)); }
        elsif ($a eq "--host-on") { push(@hostons, shift(@ARGV)); }
        elsif ($a eq "--status") { push(@statuses, shift(@ARGV)); }
	elsif ($a eq "--script") {
		push(@scriptnames, shift(@ARGV));
		}
	elsif ($a eq "--test") {
		$testmode = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Work out who to update
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "update"); 

# Do the parallel update and print
if ($testmode) {
	print "Finding updated scripts on ",scalar(@servers)," systems ..\n";
	}
else {
	print "Updating scripts on ",scalar(@servers)," systems ..\n";
	}
&obtain_lock_server(\@servers);
&parallel_server_function(\@servers,
	sub { my ($server) = @_;
	      $last_remote_error = undef;
	      &remote_foreign_require($server, "virtual-server",
				      "virtual-server-lib.pl");
	      if ($last_remote_error) {
		print "$server->{'host'}: ERROR $last_remote_error\n";
		return;
	      }

	      # Find scripts to update
	      my $updates = &remote_eval($server, "virtual-server",
			'[ &list_script_upgrades([ &list_domains() ]) ]');
	      if ($last_remote_error) {
		print "$server->{'host'}: ERROR $last_remote_error\n";
		return;
	      }
	      my @wantupdates;
	      if (@scriptnames) {
	        @wantupdates = grep { &indexof($_->{'script'}->{'name'},
					       @scriptnames) >= 0 } @$updates;
		}
	      else {
		@wantupdates = @$updates;
	        }

	      # Apply them
	      if (@wantupdates && !$testmode) {
		my @rv = &update_server_scripts($server, \@wantupdates);
		my @fails = grep { $_->[1] } @rv;
		my @oks = grep { !$_->[1] } @rv;
		if (@fails) {
		  print "$server->{'host'} ERROR ".
			join(" ", map { $_->[1] } @fails)."\n";
		  }
		if (@oks) {
		  print "$server->{'host'} OK ".
			join(" ", map { &nice_script_desc($_->[0]) }
				      @oks)."\n";
		  }
		}
	      elsif (@wantupdates && $testmode) {
		print "$server->{'host'} OK ".
		      join(" ", map { &nice_script_desc($_) }
				    @wantupdates)."\n";
		}
	      else {
		print "$server->{'host'}: NONE\n";
	        }
	      });
&release_lock_server(\@servers);
&cloudmin_api_log(\@OLDARGV);

sub nice_script_desc
{
my ($s) = @_;
return $s->{'dom'}->{'dom'}."/".$s->{'script'}->{'name'}."/".$s->{'ver'};
}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Updates Virtualmin scripts on some or all managed systems.\n";
print "\n";
print "cloudmin script-systems [--all-hosts] | [--host name]*\n";
print "                        [--group name]*\n";
my $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--owner name]*\n";
print "                        [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                        [--host-on name]\n";
print "                        [--os oscode]*\n";
print "                        [--script name]*\n";
print "                        [--test]\n";
exit(1);
}

