use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use Time::HiRes qw(time);
require "$Bin/../lib/Cloudmin/Probe.pm";

is_deeply(Cloudmin::Probe::run(sub { { name => 'Čačak 日本' } }, 1),
	  { name => 'Čačak 日本' }, 'probe pipe preserves Unicode');
is_deeply(Cloudmin::Probe::run(sub { die 'Fixture failure' }, 1),
	  { error => 1 }, 'probe exceptions stay local');
# A child that ignores TERM must still be reaped within the probe deadline.
my $start = time();
is_deeply(Cloudmin::Probe::run(sub {
	$SIG{'TERM'} = 'IGNORE';
	sleep(30);
	return { };
	}, 0.1), { error => 1 }, 'a stuck probe is stopped by its supervisor');
cmp_ok(time() - $start, '<', 2, 'native-call timeout has bounded cleanup');
is_deeply(Cloudmin::Probe::run(sub { { responding => 1 } }, 1),
	  { responding => 1 }, 'the next probe succeeds after a timeout');
done_testing();
