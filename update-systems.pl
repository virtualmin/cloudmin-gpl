#!/usr/local/bin/perl

=head1 update-systems.pl

Updates installed packages on multiple systems, and displays the results.

This command updates some or all packages on selected systems, using YUM,
APT, CWS or other supported package management systems. Only systems running
Webmin 1.500 or later or Virtualmin can be updated.

By default, all available updates are installed. However, you can limit this
to just Virtualmin-specific updates with the C<--virtualmin> flag. To select
specific packages, use the C<--package> flag followed by a name like 
I<dovecot>.

=head1 Example usage

  cloudmin update-systems --host xennoupdate.home
  Updating packages on 1 systems ..
  xennoupdate.home: OK spamassassin mod_perl

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
$0 = "$pwd/update-systems.pl";
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
	elsif ($a eq "--virtualmin") {
		$virtonly = 1;
		}
	elsif ($a eq "--package") {
		push(@pkgnames, shift(@ARGV));
		}
	elsif ($a eq "--test") {
		$testmode = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage();
		}
	}

# Work out who to refresh
@servers = &find_managed_servers($all, \@hosts, \@groups, \@managers, \@types, \@owners, \@statuses, \@hostons);
@servers || &usage("No systems specified");
&can_action_usage(\@servers, "update"); 

# Do the parallel update and print
if ($testmode) {
	print "Finding updated packages on ",scalar(@servers)," systems ..\n";
	}
else {
	print "Updating packages on ",scalar(@servers)," systems ..\n";
	}
&obtain_lock_server(\@servers);
&parallel_server_function(\@servers,
	sub { my $info = &get_server_collected($_[0]);
	      my @poss;
	      if (!$virtonly) {
	          @poss = @{$info->{'allposs'}};
	      }
	      @poss = @{$info->{'poss'}} if (!@poss);
	      if (@pkgnames) {
		@poss = grep { &indexof($_->{'name'}, @pkgnames) >= 0 } @poss;
	      }

	      my (@allgot, @allerrs);
	      if ($testmode) {
	          # Assume all would be done
		  push(@allgot, map { $_->{'name'} } @poss);
	          }
	      else {
		  # Do them all at once
		  my ($got, $errs) = &install_multiple_package_updates($_[0],
				[ &sort_package_updates(@poss) ]);
		  push(@allgot, @$got);
		  push(@allerrs, map { s/\r|\n//g; &strip_html_tags($_); } @$errs);
		  }
	      if (@allgot) {
		  if (!$testmode) {
                      &refresh_server_updates($_[0], \@allgot);
	              &check_server_status($_[0]);
	              &save_managed_server($_[0]);
		  }
	          print "$_[0]->{'host'}: OK ".join(" ", @allgot)."\n";
	          }
	      if (@allerrs) {
	          print "$_[0]->{'host'}: ERROR ".join(" ", @allerrs)."\n";
                  }
	      if (!@allgot && !@allerrs) {
	          print "$_[0]->{'host'}: NONE\n"
                  }
	      });
&release_lock_server(\@servers);
&cloudmin_api_log(\@OLDARGV);

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Updates installed packages on some or all managed systems.\n";
print "\n";
print "cloudmin update-systems [--all-hosts] | [--host name]*\n";
print "                        [--group name]*\n";
my $types = join("|", @server_management_types);
print "                        [--type $types]*\n";
print "                        [--os oscode]*\n";
print "                        [--owner name]*\n";
print "                        [--status status-code|\"up\"|\"wm\"|\"bad\"]\n";
print "                        [--host-on name]\n";
print "                        [--os oscode]*\n";
print "                        [--package name]* | [--virtualmin]\n";
exit(1);
}

