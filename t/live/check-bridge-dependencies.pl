#!/usr/bin/perl
# Run with unshare --net on a Linux test host. Only private links are changed.
use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use Test::More;

BEGIN
{
# Creating kernel links requires root in a Linux test environment.
die "Linux test host as root only\n" unless $^O eq 'linux' && $< == 0;
# Refuse the host namespace before loading any network fixture code.
die "A private network namespace is required\n"
	if (readlink('/proc/self/ns/net') eq readlink('/proc/1/ns/net'));
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$FindBin::Bin/../..") || die $!;
$0 = abs_path("$FindBin::Bin/../../network-worker.pl");
}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
my $host = get_host_network();
my $links = $host->ip_json('link', 'show');
# Even another private namespace may contain unrelated test interfaces.
die "An empty network namespace is required\n"
	if (@$links != 1 || $links->[0]->{'ifname'} ne 'lo');
# A dummy stands in for Ethernet; dependency refusal precedes port validation.
$host->command([ 'ip', 'link', 'add', 'cmtestbr', 'type', 'bridge' ]);
$host->command([ 'ip', 'link', 'add', 'cmport', 'type', 'dummy' ]);
$host->command([ 'ip', 'link', 'set', 'cmport', 'master', 'cmtestbr' ]);

# Real iproute2 output must identify children of the bridge and its dummy port.
foreach my $parent ( 'cmtestbr', 'cmport' ) {
	# Linux cannot attach macvlan and a bridge to the same Ethernet port.
	foreach my $kind ($parent eq 'cmport'
		? ('vlan')
		: ( 'vlan', 'macvlan' )) {
		my @options = $kind eq 'vlan'
			? ( 'id', '100' )
			: ( 'mode', 'bridge' );
		$host->command([ 'ip', 'link', 'add', 'link', $parent,
				 'name',
				 'cmchild', 'type', $kind, @options ]);
		my ($child) = grep { $_->{'name'} eq 'cmchild' }
			      @{$host->inventory()->{'interfaces'}};
		is($child->{'parent'}, $parent,
		   "$kind reports its real parent $parent");
		ok(!eval { $host->prepare_remove('cmtestbr'); 1 },
		   "$kind blocks removal during review");
		like($@, qr/Other host interfaces depend/,
		     'refusal identifies the dependency');
		$host->command([ 'ip', 'link', 'delete', 'cmchild' ]);
		}
	}
# Remove only fixture devices and verify that the namespace is empty again.
$host->command([ 'ip', 'link', 'delete', 'cmtestbr' ]);
$host->command([ 'ip', 'link', 'delete', 'cmport' ]);
is(scalar(@{$host->ip_json('link', 'show')}), 1, 'fixture links cleaned up');
done_testing();
