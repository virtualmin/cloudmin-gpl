#!/usr/local/bin/perl
# Moves a virtual system to another host, by imaging it and copying across
# the image file
# XXX need to update DNS

=head1 move-system.pl

Moves a virtual system from one host to another

This command allows you to transfer a Xen instance or other supported virtual
system from one hosting server to another. It can be useful if the original
host is getting overloaded, and you have brought a new host system online to
take some of the load.

During the move process, the system specified with the C<--host> flag will
generally be temporarily shut down and un-available. All data files will be
copied to the new host (set with the C<--dest> flag), modified as needed,
and then the virtual system restarted.

=head1 Example usage

  XXX

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/move-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
&set_all_text_print();

# Parse command line
while(@ARGV > 0) {
	local $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--dest") {
		$desthost = shift(@ARGV);
		}
	else {
		&usage();
		}
	}

# Check for mandatory args
$host || &usage("Missing --host parameter");
$desthost || &usage("Missing --dest parameter");

# Get the systems
$server = &get_managed_server_by("host", $host);
$dest = &get_managed_server_by("host", $desthost);
$vhost = &get_parent_server($server);
$server->{'id'} eq $dest->{'id'} && &usage("A system cannot be transferred to itself");
$vhost->{'id'} eq $dest->{'id'} && &usage("$dest->{'host'} is already hosting this system");

# Check if supported
$dfunc = "type_".$server->{'manager'}."_desc";
$desc = &$dfunc();
$cfunc = "type_".$server->{'manager'}."_can_move";
defined(&$cfunc) || &usage("Systems of type $desc cannot be moved");
&$cfunc($server, $dest) || &usage("The selected system cannot be moved to the new host");

# Do the transfer
print "Moving $desc system $server->{'host'} from $vhost->{'host'} to $dest->{'host'} ..\n\n";
$err = &move_system($server, $dest);
if ($err) {
	print $err,"\n";
	exit(1);
	}
print ".. all done\n";

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Moves a virtual system from one host to another.\n";
print "\n";
print "usage: move-system.pl --host name\n";
print "                      --dest new-host-system-name\n";
exit(1);
}

