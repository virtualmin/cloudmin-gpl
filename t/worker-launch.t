use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
require "$Bin/../lib/Cloudmin/Worker.pm";

{
	package LaunchFixture;
	our @ISA = ('Cloudmin::Worker');

	# command(self, task, id, [limit]) runs a protocol
	# fixture without systemd.
	sub command
	{
	return @{$_[0]->{'command'}};
	}
	}

my $tmp = tempdir('cloudmin-launch-XXXXXX', DIR => '/tmp', CLEANUP => 1);
open(my $script, '>', "$tmp/worker.pl") or die $!;
print { $script } <<'PERL';
use strict;
use warnings;
use JSON::PP qw(encode_json);
my ($work, $mode) = @ARGV;
open(my $events, '>>', "$work/events") or die $!;
print {$events} encode_json({ type => 'identity', uid => 1001, euid => 1001 }), "\n";
# An explicit worker error must survive even after the time limit.
if ($mode eq 'error') {
	print {$events} encode_json({ type => 'error', message => 'Fixture task error' }), "\n";
}
# A successful protocol result must not be mistaken for a timeout.
elsif ($mode eq 'success') {
	print {$events} encode_json({ type => 'result', data => { done => 1 } }), "\n";
}
# Launcher stderr must remain available when no worker result was written.
elsif ($mode eq 'diagnostic') {
	print STDERR "Fixture launcher error\n";
}
close($events) or die $!;
exit($mode eq 'success' ? 0 : 7);
PERL
close($script) or die $!;

# A late exit alone cannot distinguish a timeout from another silent failure.
for my $case ( [ 'silent', 2 ], [ 'silent', 181 ], [ 'error', 181 ],
	       [ 'diagnostic', 181 ], [ 'success', 181 ] ) {
	my ($mode, $elapsed) = @$case;
	my $work = "$tmp/$mode-$elapsed";
	mkdir($work) or die $!;
	my $runner = LaunchFixture->new();
	$runner->{'command'} = [ $^X, "$tmp/worker.pl", $work, $mode ];
	my $clock_reads = 0;
	no warnings qw(redefine once);
	local *Cloudmin::Worker::path = sub { $work };
	local *Cloudmin::Worker::time =
		sub { return 100 + ($clock_reads++ ? $elapsed : 0); };
	my $result = eval { $runner->launch('inspect', 'a' x 32) };
	my $error = $@;
	# A complete successful result takes precedence over elapsed time.
	if ($mode eq 'success') {
		is_deeply($result, { done => 1 },
			  'elapsed time does not invalidate a successful task');
		is($error, '', 'successful task has no error');
		}
	# Keep diagnostics, or report elapsed time without guessing the cause.
	else {
		ok(!$result, "$mode task fails after $elapsed seconds");
		my $expected = $mode eq 'error'
			? 'Fixture task error'
			: $mode eq 'diagnostic'
				? 'Fixture launcher error'
				: "Image worker failed without an error message after $elapsed seconds (time limit: 180 seconds)";
		like($error, qr/\A\Q$expected\E\n+\z/,
		     "$mode keeps the available failure details");
		unlike($error, qr/timed out/,
		       'elapsed time is not used to diagnose a timeout');
		}
	}
done_testing();
