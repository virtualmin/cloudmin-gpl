use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
our (@shows, @commands, $stop_status);

# Replace process calls before loading Worker; no host systemctl is executed.

BEGIN
{
*CORE::GLOBAL::readpipe = sub {
	push(@commands, $_[0]);
	die "Unexpected state query\n" if (!@shows);
	my ($state, $status) = @{shift(@shows)};
	$? = $status;
	return $state;
	};
*CORE::GLOBAL::system = sub { push(@commands, [ @_ ]);
	return $stop_status; };
}
require "$Bin/../lib/Cloudmin/Worker.pm";
my $runner = Cloudmin::Worker->new();
for my $case (
	[ 'already collected', [ [ "not-found\n", 0 ] ], 0, 1, 1 ],
	[ 'ordinary stop', [ [ "loaded\n", 0 ] ], 0, 1, 2 ],
	[ 'collected during stop', [ [ "loaded\n", 0 ], [ "not-found\n", 0 ] ],
	  256, 1,
	  3 ],
	[ 'still loaded after failed stop', [ [ "loaded\n", 0 ], [ "loaded\n",
								   0 ] ],
	  256, 0, 3 ],
	[ 'failed state query', [ [ "\n", 256 ] ], 0, 0, 1 ],
	[ 'failed recheck', [ [ "loaded\n", 0 ], [ "not-found\n", 256 ] ], 256,
	  0, 3 ],
) {
	my ($name, $states, $status, $expected, $calls) = @$case;
	@shows = @$states;
	@commands = ();
	$stop_status = $status;
	my $ok = eval { $runner->stop('a' x 32); 1 };
	is($ok ? 1 : 0, $expected, $name);
	is(scalar(@commands), $calls,
	   "$name uses a bounded number of service calls");
	like($@, qr/Cannot (?:check|stop) image worker service/,
	     "$name retains the cleanup failure") if (!$expected);
	}
done_testing();
