use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use Cloudmin::Libvirt;
use Cloudmin::SerialLog;

# Keep all XML, configuration and logs in a temporary directory.
my $dir = tempdir(CLEANUP => 1);
my $uuid = '11111111-2222-3333-4444-555555555555';
my $logs = Cloudmin::SerialLog->new($dir, "$dir/qemu.conf", "$dir/log.conf");
my $path = $logs->path($uuid);
my $xml = "<domain><name>fixture</name><uuid>$uuid</uuid><devices>".
	  '<serial type="pty"><target port="0"/></serial>'.
	  '<console type="pty"><target type="serial" port="0"/></console>'.
	  '<graphics type="vnc" passwd="preserve-me"/></devices></domain>';

# put(path, bytes, [append]) writes only private fixture files.
sub put
{
my ($file, $bytes, $append) = @_;
open(my $out, $append ? '>>' : '>', $file) or die $!;
chmod(0600, $file) or die $!;
print $out $bytes;
close($out) or die $!;
}

# parse(xml) uses the same safe parser as the libvirt adapter.
sub parse
{
Cloudmin::Libvirt::parse_xml_document($_[0]);
}

# Configuration adds only the managed log and remains stable when repeated.
my $configured = $logs->configure($xml);
is(parse($configured)->findvalue('/domain/devices/serial/log/@file'), $path,
   'logging path uses the immutable UUID');
is(parse($configured)->findvalue('/domain/devices/serial/log/@append'), 'off',
   'each cold start discards the previous boot recording');
is(parse($configured)->findvalue('/domain/devices/graphics/@passwd'),
   'preserve-me',
   'other device settings survive configuration');
is($logs->configure($configured), $configured, 'configuration is idempotent');
ok(!$logs->reader($uuid, $xml),
   'unrecorded guests retain their live-only console');
# Custom paths are neither rewritten nor opened as console history.
my $foreign = $configured;
$foreign =~ s/\Q$path\E/\/admin\/serial.log/g;
is($logs->configure($foreign), $foreign,
   'administrator log settings are preserved');
ok(!$logs->reader($uuid, $foreign),
   'arbitrary administrator log paths are never read');
ok(!eval { $logs->path('../guest'); 1 }, 'path traversal is refused');

# A normalized serial console may repeat the backing serial log in its alias.
my $normalized = parse($configured);
my ($console) = $normalized->findnodes('/domain/devices/console');
$console->appendChild(
	($normalized->findnodes('/domain/devices/serial/log'))[0]->cloneNode(
		1));
for my $setting ( 'max_size = 0', 'max_backups = 0' ) {
	put("$dir/log.conf", "$setting\n");
	ok(!parse($logs->configure($normalized->toString()))->exists('//log'),
	   "$setting removes both copies of the managed log");
	}
put("$dir/log.conf", "max_size = 2097152 # native default\nmax_backups = 3\n");
put("$dir/qemu.conf", "stdio_handler = \"file\"\n");
is($logs->configure($xml), $xml,
   'direct QEMU logging is not enabled without rotation');
put("$dir/qemu.conf", "stdio_handler = \"logd\"\n");
ok($logs->bounded(), 'native rotated logging is accepted');

# Capture precisely the last 64 KiB, including the newest rotated file.
put("$path.0", 'a' x 70000);
put($path, "login: tester");
my $reader = $logs->reader($uuid, $configured);
is($reader->history(), ('a' x (65536 - 13)).'login: tester',
   'replay has a strict byte limit');
is($reader->history(), '', 'snapshot is consumed once');
is($reader->read(), '', 'snapshot bytes are not repeated as live output');
put($path, "\r\nhello", 1);
is($reader->read(), "\r\nhello",
   'new bytes follow the snapshot without duplication');

# Follow multiple rotations between polls in chronological order.
rename("$path.0", "$path.1") or die $!;
rename($path, "$path.0") or die $!;
put($path, 'next');
rename("$path.1", "$path.2") or die $!;
rename("$path.0", "$path.1") or die $!;
rename($path, "$path.0") or die $!;
put($path, 'last');
my $followed = join('', map { $reader->read() } 1 .. 5);
is($followed, 'nextlast', 'several rotations do not skip or duplicate bytes');
my $reconnected = $logs->reader($uuid, $configured);
like($reconnected->history(), qr/login: tester\r\nhellonextlast\z/,
     'reconnection includes text typed during the preceding connection');
put($path, '');
ok(!eval { $reader->read(); 1 },
   'unexpected truncation ends replay instead of hiding lost output');
like($@, qr/truncated/, 'truncation explains that reconnection is needed');

# Never follow a link or read an exposed file, even at the expected UUID path.
unlink($path) or die $!;
put("$dir/foreign", 'not console data');
symlink("$dir/foreign", $path) or die $!;
ok(!eval { $logs->reader($uuid, $configured); 1 },
   'symlink history is refused');
ok(!eval { $logs->configure($xml); 1 },
   'unsafe paths are refused before starting recording');
unlink($path) or die $!;
put($path, 'private');
# Correct filenames alone must not allow exposed history to be read.
chmod(0644, $path) or die $!;
ok(!eval { $logs->reader($uuid, $configured); 1 },
   'world-readable history is refused');
chmod(0600, $path) or die $!;
$logs->remove($uuid);
ok(!-e $path && !-e "$path.0" && !-e "$path.2",
   'removal clears the guest and its rotations');
ok(-f "$dir/foreign", 'cleanup preserves unrelated files');

# Exercise the shared creation/start hooks without a host libvirt connection.
{
	package LogDomain;

	# get_uuid_string(self) supplies the immutable fixture identity.
	sub get_uuid_string
	{
	$uuid
	}

	# get_name(self) supplies the name used for duplicate-definition checks.
	sub get_name
	{
	'fixture'
	}

	# is_active(self) exposes the fixture's current power state.
	sub is_active
	{
	$_[0]->{'active'} || 0
	}

	# has_managed_save_image(self, flags) reports a saved guest state.
	sub has_managed_save_image
	{
	$_[0]->{'saved'} || 0
	}

	# get_xml_description(self, flags) records which XML view was requested.
	sub get_xml_description
	{
	push @{$_[0]->{'flags'}},
		$_[1]; $_[0]->{'xml'}
	}

	# create(self) records a single start and changes the fake power state.
	sub create
	{
	$_[0]->{'starts'}++; $_[0]->{'active'} = 1
	}
	package LogConnection;

	# list_all_domains(self) returns only the domain owned by this fixture.
	sub list_all_domains
	{
	$_[0]->{'domain'} ? ($_[0]->{'domain'}) : ()
	}

	# define_domain(self, xml, flags) records the
	# validated persistent update.
	sub define_domain
	{
	my ($self, $xml, $flags) = @_;
	$self->{'defines'}++;
	$self->{'domain'} ||= bless { }, 'LogDomain';
	$self->{'domain'}->{'xml'} = $xml;
	return $self->{'domain'};
	}
	}
# Use the real adapter hooks with a fake connection, not the host hypervisor.
my $connection = bless { }, 'LogConnection';
my $adapter = Cloudmin::Libvirt->new(readonly => 0, serial_log => $logs,
				     connection_factory => sub { $connection });
my $domain = $adapter->define_guest($xml);
ok(parse($domain->{'xml'})->exists('//serial/log'),
   'new guests receive logging before first boot');
$domain->{'xml'} = $xml;
$adapter->start_domain($uuid);
ok(parse($domain->{'xml'})->exists('//serial/log'),
   'cold starts enable logging on existing guests');
ok(grep($_ == 3, @{$domain->{'flags'}}),
   'cold-start update requests secure inactive XML');
is($domain->{'starts'}, 1, 'guest is started once after configuring its log');
# Resuming saved hardware must leave the persistent definition untouched.
$domain->{'xml'} = $xml;
$domain->{'active'} = 0;
$domain->{'saved'} = 1;
my $defines = $connection->{'defines'};
$adapter->start_domain($uuid);
is($connection->{'defines'}, $defines,
   'managed-save resumes do not change saved hardware');
# Cleanup is permitted only after the guest has disappeared from inventory.
put($path, 'keep while defined');
$adapter->removed_guest($uuid);
ok(-e $path, 'cleanup never removes a defined guest recording');
delete $connection->{'domain'};
$adapter->removed_guest($uuid);
ok(!-e $path, 'guest removal invokes serial history cleanup');
done_testing();
