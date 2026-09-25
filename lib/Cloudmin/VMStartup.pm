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

1;
