package Cloudmin::VMStartup;

# Keep a cold start's memory target until the guest balloon reaches it.
use strict;
use warnings;
use Fcntl qw(:flock);
use File::Path qw(make_path);
use WebminCore qw(read_file_contents convert_to_json convert_from_json);

# new(class, directory) stores private startup records shared by CGI and status.
sub new
{
return bless({ directory => $_[1] }, $_[0]);
}

# identity(self, domain) distinguishes a QEMU run, including host reboots.
sub identity
{
my ($self, $domain) = @_;
my $boot = read_file_contents('/proc/sys/kernel/random/boot_id');
die "Host boot identity unavailable\n" if (!$boot);
chomp($boot);
my $id = $domain->get_id();
die "Guest is not running\n" if (!defined($id) || $id < 0);
return "$boot:$id";
}

# record(self, domain, callback) serializes reads and changes for this VM.
# callback(file, identity) runs under the lock; exceptions release it too.
sub record
{
my ($self, $domain, $callback) = @_;
my $uuid = $domain->get_uuid_string();
die "Invalid guest identity\n" if ($uuid !~ /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i);
my $identity = $self->identity($domain);
make_path($self->{'directory'}, {mode => 0700});
my $file = "$self->{directory}/$uuid";
open(my $lock, '>>', "$file.lock") or die "Cannot open startup lock: $!\n";
chmod(0600, "$file.lock");
flock($lock, LOCK_EX) or die "Cannot lock startup record: $!\n";
return $callback->($file, $identity);
}

# remember(self, domain, memory_mib) records only a successful cold start.
sub remember
{
my ($self, $domain, $memory) = @_;
$self->record($domain, sub {
	my ($file, $identity) = @_;
	open(my $out, '>', $file) or die "Cannot save startup memory: $!\n";
	chmod(0600, $file);
	print $out convert_to_json({identity => $identity, memory => $memory}, 0, 1);
	close($out) or die "Cannot save startup memory: $!\n";
	});
}

1;
