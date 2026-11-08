use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;

BEGIN
{
die "Disposable Linux guest as root only\n" if $^O ne 'linux' || $< != 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir($ARGV[0]) || die $!;
$0 = "$ARGV[0]/network-worker.pl";
}
require './server-manager-lib.pl';
require './cloudmin-network-lib.pl';
{
	package DHCPFixture;
	our @ISA = ('Cloudmin::HostNetwork');

	# inventory(self) admits only the fixture veth as a
	# physical port substitute.
	sub inventory
	{
	my $self = shift;
	my $inventory = $self->SUPER::inventory();
	$_->{'candidate'} =
		1 foreach grep { $_->{'name'} eq $self->{'fixture'} }
		@{$inventory->{'interfaces'}};
	return $inventory;
	}

	# unit(self, action, arguments...) leaves host-wide
	# recovery services alone.
	sub unit
	{
	}
	package DHCPFixtureLock;

	# lock(self, name, callback) runs against the fixture's private journal.
	sub lock
	{
	$_[2]->()
	}
	}
my (undef, $source, $bridge, $mode) = @ARGV;
my $directory = tempdir('/var/tmp/cloudmin-dhcp-state.XXXXXX', CLEANUP => 1);
my $host = DHCPFixture->new(directory => $directory, fixture => $source,
			    jobs => bless({ }, 'DHCPFixtureLock'));
my $plan = $host->prepare($bridge, $source);
ok(@{$plan->{'addresses'}}, "$mode acquired an IPv4 lease");
my $id = $plan->{'dhcp4_client_id'};
like($id, $mode eq 'none'
	? qr/^none$/
	: $mode eq 'duid' ? qr/^ff:/ : $mode eq 'stable' ? qr/^00:/ : qr/^01:/,
     "$mode captures the expected client ID type");
$plan->{'bridge_uuid'} =
	WebminCore::read_file_contents('/proc/sys/kernel/random/uuid');
chomp($plan->{'bridge_uuid'});
$plan->{'state'} = 'armed';
$plan->{'deadline'} = time() + 180;
$host->write_state($plan);
my $ok = eval {
	$host->apply();
	$host->check_connection($plan);
	pass("$mode bridge retains the original address");
	is($host->nm_dhcp4_identity($bridge), $id,
	   "$mode bridge sends the same DHCP client ID");
	$host->command([ 'nmcli', '--wait', '30', 'connection', 'down',
			 $plan->{'bridge_uuid'} ]);
	$host->command([ 'nmcli', 'connection', 'reload' ]);
	# Start the controller; its autoconnect-ports setting
	# starts the port once.
	$host->command([ 'nmcli', '--wait', '30', 'connection', 'up',
			 $plan->{'bridge_uuid'} ]);
	$host->wait_for_connection($plan);
	is($host->nm_dhcp4_identity($bridge), $id,
	   "$mode identity survives profile reload and reactivation");
	1;
	};
my $error = $@;
# Always restore the Ethernet profile, even if apply or reactivation failed.
$host->rollback();
$host->check_connection($plan, 1);
pass("$mode rollback restores the source address");
is($host->nm_dhcp4_identity($source), $id,
   "$mode rollback restores the source identity");
is(WebminCore::read_file_contents($plan->{'saved'}->{'file'}),
   $plan->{'files'}->{$plan->{'saved'}->{'file'}}->{'content'},
   "$mode rollback restores the exact original profile");
die $error if !$ok;
done_testing();
