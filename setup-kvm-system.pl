#!/usr/local/bin/perl

=head1 setup-kvm-system.pl

Configures a physical system as a KVM host.

This command installs and configures the packages needed for hosting KVM
virtual machines on a physical system. It is primarily designed to be called
from the Cloudmin installer, but can be used from the shell as well.

=head1 Example usage

  cloudmin setup-kvm-system --host kvmhost.home
Setting up KVM host system ..
    Checking system status ..
    .. done

    Installing required commands ..
    .. done

    Turning off AppArmor ..
    .. not installed

    Installing KVM packages ..
    .. done

    Enabling CGroups ..
    .. not needed, as this system is running systemd

    Creating loopback device files ..
    .. done

    Setting up br0 network bridge ..
    .. done

.. setup complete! You can now add this system as a KVM host.

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
$0 = "$pwd/setup-kvm-system.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";
@OLDARGV = @ARGV;

# Parse command line
while(@ARGV > 0) {
	my $a = shift(@ARGV);
	if ($a eq "--host") {
		$host = shift(@ARGV);
		}
	elsif ($a eq "--qemu") {
		$qemu = 1;
		}
	elsif ($a eq "--multiline") {
		$multiline = 1;
		}
	else {
		&usage("Unknown parameter $a");
		}
	}

# Get the server and check parameters
$host || &usage("Missing --host parameter");
$server = &find_one_managed_server($host);
$server || &usage("No system with hostname $host exists");
&can_action_usage(undef, "global");

# Install as KVM host
&set_all_text_print();
&$first_print($text{'kvminstall_doing'});
&$indent_print();
$ok = &install_kvm_host_software($server, $qemu);
&$outdent_print();

# Evaluate the output
if ($ok) {
	&$second_print($ok == 2 ? $text{'kvminstall_reboot'}
				: $text{'kvminstall_done'});
	&cloudmin_api_log(\@OLDARGV);
	}
else {
	&$second_print($text{'kvminstall_failed'});
	exit(1);
	}

sub usage
{
print "$_[0]\n\n" if ($_[0]);
print "Configures a physical system as a KVM host.\n";
print "\n";
print "cloudmin setup-kvm-system --host name\n";
print "                         [--qemu]\n";
exit(1);
}


