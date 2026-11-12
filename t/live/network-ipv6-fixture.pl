use strict;
use warnings;
use File::Temp qw(tempdir);

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
	package IPv6Fixture;
	our @ISA = ('Cloudmin::HostNetwork');

	# A veth endpoint substitutes for Ethernet without touching the
	# management NIC. inventory(self) makes only the owned
	# veth a bridge candidate.
	sub inventory
	{
	my $self = shift;
	my $inv = $self->SUPER::inventory();
	for my $nic (@{$inv->{'interfaces'}}) {
		$nic->{'candidate'} = 1 if $nic->{'name'} eq $self->{'fixture'};
		}
	return $inv;
	}

	# Fixture recovery uses its private journal, with no host-wide service
	# units. unit(self, action, record) omits recovery service
	# changes for this fixture.
	sub unit
	{
	}
	package FixtureLock;

	# lock(self, name, callback) runs this isolated fixture
	# without a host lock.
	sub lock
	{
	$_[2]->()
	}
	}
my (undef, $source, $bridge, $mode) = @ARGV;
my $dir = tempdir('/var/tmp/cloudmin-ipv6-state.XXXXXX', CLEANUP => 1);
my $host = IPv6Fixture->new(directory => $dir, fixture => $source,
			    jobs => bless({ }, 'FixtureLock'));
my $before = $host->ip_json('address', 'show', 'dev', $source);
my $plan = eval { $host->prepare($bridge, $source) };
# Stable-privacy addresses cannot be promised unchanged after conversion. Verify
# preflight refuses the change before writing files or moving addresses.
if ($mode eq 'stable-privacy') {
	die "Stable-privacy conversion was not refused before writes\n"
		if ($plan || $@ !~ /IPv6 addresses that cannot be preserved/);
	die "Preflight wrote a journal\n" if $host->read_state();
	my $after = $host->ip_json('address', 'show', 'dev', $source);
	my @old = map { $_->{'local'} } @{$before->[0]->{'addr_info'}};
	my @new = map { $_->{'local'} } @{$after->[0]->{'addr_info'}};
	die "Preflight changed source addresses\n"
		if join(',', @old) ne join(',', @new);
	print "PASS: stable-privacy is refused before any network change\n";
	exit(0);
	}
die $@ if !$plan;
die "No SLAAC address acquired\n" if !@{$plan->{'addresses'}};
print 'Original addresses: '.join(', ', @{$plan->{'addresses'}})."\n";
$plan->{'bridge_uuid'} =
	WebminCore::read_file_contents('/proc/sys/kernel/random/uuid');
chomp($plan->{'bridge_uuid'});
$plan->{'state'} = 'armed';
$plan->{'deadline'} = time() + 180;
$host->write_state($plan);
my $ok = eval { $host->apply(); 1 };
my $error = $@;
my $live = $host->ip_json('address', 'show', 'dev', $bridge);
print 'Converted addresses: '.join(', ', map { $_->{'local'} }
				   @{$live->[0]->{'addr_info'}})."\n";
print $ok ? "PASS: original SLAAC address retained\n" : "FAILED: $error";
$host->rollback();
$host->check_connection($plan, 1);
print "PASS: rollback restored original source address\n";
die $error if !$ok;
