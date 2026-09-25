use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;
use Cloudmin::Libvirt;
use Cloudmin::VMStartup;

{
	package StartupTracker;
	our @ISA = ('Cloudmin::VMStartup');
	# identity(self, domain) models both host reboots and QEMU generations.
	sub identity { return ($_[0]->{'boot'} || 'boot').':'.$_[1]->get_id(); }
	package StartupDomain;
	# get_uuid_string(self) gives the fixture a stable storage key.
	sub get_uuid_string { return '11111111-2222-3333-4444-555555555555'; }
	# get_id(self) changes with each successful cold start.
	sub get_id { return $_[0]->{'generation'} || 0; }
	# has_managed_save_image(self, flags) distinguishes resume from cold boot.
	sub has_managed_save_image { return $_[0]->{'managed_save'}; }
	# get_xml_description(self, flags) supplies the saved balloon target.
	sub get_xml_description {
		return '<domain><vcpu>2</vcpu><memory unit="MiB">1024</memory>'.
			'<currentMemory unit="MiB">950</currentMemory><devices>'.
			'<memballoon model="virtio"/></devices></domain>';
	}
	# create(self) either starts a new QEMU generation or refuses the request.
	sub create { die "Start refused\n" if ($_[0]->{'fail'}); $_[0]->{'generation'}++; }
	package StartupAdapter;
	our @ISA = ('Cloudmin::Libvirt');
	# find_domain(self, id) resolves this fixture without a native connection.
	sub find_domain { return $_[0]->{'domain'}; }
}

my $directory = tempdir(CLEANUP => 1);
my $tracker = StartupTracker->new($directory);
my $domain = bless({}, 'StartupDomain');
my $adapter = StartupAdapter->new(startup => $tracker);
$adapter->{'domain'} = $domain;
my $id = $domain->get_uuid_string();
my $running = { memory_mib => 1024, cpu_limit => 2 };
my $saved = { memory_mib => 950, cpu_limit => 2 };
no warnings 'redefine';
local *Cloudmin::Libvirt::log_call = sub {};

# No startup record means genuine XML differences retain their ordinary meaning.
ok($adapter->pending_domain_settings($domain, $running, $saved)->{'memory_mib'},
	'untracked memory difference remains pending');
ok($adapter->start_domain($id), 'cold start succeeds');
is_deeply($adapter->pending_domain_settings($domain, $running, $saved), {},
	'boot-time maximum is not reported as a pending memory change');
is((stat("$directory/$id"))[2] & 0777, 0600, 'startup record is private');

# CGI requests and the status collector use independent adapter instances.
$adapter->{'startup'} = StartupTracker->new($directory);
is_deeply($adapter->pending_domain_settings($domain, $running, $saved), {},
	'another request recognizes the same cold start');
is_deeply($adapter->pending_domain_settings($domain, $running, {%$saved, cpu_limit => 4}),
	{cpu_limit => {running => 2, saved => 4}}, 'real CPU differences remain pending during boot');

# Reaching the target retires the exception, even if no warning is visible.
is_deeply($adapter->pending_domain_settings($domain, $saved, $saved), {}, 'settled memory matches');
ok(!-e "$directory/$id", 'settled startup record is removed');
ok($adapter->pending_domain_settings($domain, $running, $saved)->{'memory_mib'},
	'a later live-only memory change remains visible');

# Editing the target also retires the exception; reverting does not revive it.
$adapter->start_domain($id);
ok($adapter->pending_domain_settings($domain, $running, {%$saved, memory_mib => 900})->{'memory_mib'},
	'a newly saved target is still pending during startup');
ok($adapter->pending_domain_settings($domain, $running, $saved)->{'memory_mib'},
	'old startup target cannot hide a later change');

# A different QEMU run or host boot cannot inherit an earlier startup record.
$adapter->start_domain($id);
$domain->{'generation'}++;
ok($adapter->pending_domain_settings($domain, $running, $saved)->{'memory_mib'},
	'a different QEMU run cannot inherit the exception');
$domain->{'generation'}--;
$adapter->{'startup'}->{'boot'} = 'new-host-boot';
ok($adapter->pending_domain_settings($domain, $running, $saved)->{'memory_mib'},
	'a reused domain ID after host reboot cannot inherit the exception');

# Failed starts and managed-save restores never claim saved memory was applied.
unlink("$directory/$id");
$domain->{'fail'} = 1;
ok(!eval { $adapter->start_domain($id); 1 }, 'failed start still propagates');
ok(!-e "$directory/$id", 'failed start records no target');
delete $domain->{'fail'};
$domain->{'managed_save'} = 1;
$adapter->start_domain($id);
ok(!-e "$directory/$id", 'managed-save resume records no cold-start target');
ok($adapter->pending_domain_settings($domain, $running, $saved)->{'memory_mib'},
	'restored memory still shows its saved difference');

# Corrupt cache data cannot suppress a real warning or break inventory.
open(my $bad, '>', "$directory/$id") or die $!;
print $bad 'invalid'; close($bad);
ok($adapter->pending_domain_settings($domain, $running, $saved)->{'memory_mib'},
	'unreadable startup record falls back to XML');

done_testing();
