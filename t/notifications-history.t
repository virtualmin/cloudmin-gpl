use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Cloudmin::Notifications;
use File::Temp qw(tempdir);
use Test::More;

# Keep pagination and search fixtures out of the installed notification store.
my $directory = tempdir(CLEANUP => 1);
my $store = Cloudmin::Notifications->new(directory => $directory);
my $guest = '11111111-1111-4111-8111-111111111111';
my $other = '22222222-2222-4222-8222-222222222222';
# An unused store returns page metadata without creating a database.
my $empty = $store->history($guest, undef, 25, { page => 10, search => 'CPU' });
is_deeply([ @{$empty}{qw(page pages total limit)} ], [ 1, 1, 0, 25 ],
	  'an unused store has a single empty page');
ok(!-e "$directory/notifications.sqlite", 'pagination does not create storage');
my @ids;
$store->transaction(sub {
	# callback(db) seeds events, an incident and a private receipt.
	my ($db) = @_;
	# Interleave owners and create enough events to exceed the old
	# 100-row view.
	for my $n (1 .. 150) {
		push @ids, Cloudmin::Notifications::event($db,
			{ id => 'fixture', name => $n == 1
				? 'Oldest unique alert'
				: "Caf\x{e9} CPU 100%_ '$n'",
			  metric => 'cpu', threshold => 90,
			  severity => 'warning', targets => [ ] },
			{ owner => $n % 3 == 0 ? $other : $guest,
			  subject => "cpu-$n", label => 'Guest reading',
			  value => $n },
			$n % 2 ? 'firing' : 'resolved', 1000 + $n);
		}
	# Live incidents remain independent of the historical filter.
	$db->do('INSERT INTO states(rule, subject, record) VALUES (?, ?, ?)',
		undef, 'fixture', 'cpu', Cloudmin::Notifications::encode({
			owner => $guest, name => 'Current problem',
			status => 'active' }));
	# Delivery errors must not affect searchable text, even for
	# host readers.
	$db->do('INSERT INTO deliveries(event, target, state, attempts, due, error)
		VALUES (?, ?, ?, ?, ?, ?)', undef, $ids[0], 'private-target',
		'failed', 1, 0, 'Private delivery phrase');
	});

# Every numbered page is selected newest first but retains ascending API order.
my @seen;
for my $page (1 .. 6) {
	my $data = $store->history(undef, undef, 25, { page => $page });
	is_deeply([ @{$data}{qw(total page pages limit)} ],
		  [ 150, $page, 6, 25 ],
		  "page $page reports the complete count");
	my @expected = @ids[(6 - $page) * 25 .. (7 - $page) * 25 - 1];
	is_deeply([ map { $_->{id} } @{$data->{events}} ], \@expected,
		  "page $page has the expected IDs without gaps or repeats");
	push @seen, map { $_->{id} } @{$data->{events}};
	}
is(scalar(keys %{{ map { $_ => 1 } @seen }}), 150, 'all events are reachable');
is($store->history(undef, undef, 25, { page => 999 })->{page}, 6,
   'out-of-range pages fall back to the last page');
# Guest counts and returned records must enforce the same owner restriction.
my $scoped = $store->history($guest, undef, 25, { page => 4 });
is_deeply([ @{$scoped}{qw(total pages page)} ], [ 100, 4, 4 ],
	  'counts and pages include only the requested guest');
ok(!grep({ $_->{owner} ne $guest || exists($_->{deliveries}) }
	 @{$scoped->{events}}),
   'guest pages omit other guests and delivery details');

# Search runs before paging and reaches older events.
my $found = $store->history(undef, undef, 25,
	{ page => 1, search => 'oldest UNIQUE' });
is($found->{total}, 1, 'search reaches events beyond the latest 100');
is($found->{events}[0]{id}, $ids[0], 'the oldest event is returned');
# Unicode case matching must work before scoped page counts are calculated.
$found = $store->history($guest, undef, 25,
	{ page => 2, search => "CAF\x{c9} cpu 100%_" });
is_deeply([ @{$found}{qw(total pages page)} ], [ 99, 4, 2 ],
	  'Unicode case-insensitive search preserves scoped counts');
# Punctuation is literal, and a filter with no matches has one empty page.
is($store->history(undef, undef, 25, { page => 1, search => '%_' })->{total},
   149, 'SQL wildcard characters are literal search text');
is($store->history(undef, undef, 25,
	{ page => 1, search => q{' OR 1=1 --} })->{total}, 0,
   'SQL-looking input cannot change the query');
is($store->history(undef, undef, 25,
	{ page => 99, search => 'does not exist' })->{page}, 1,
   'no matches return the first empty page');
# Both stored state codes and trusted translations are searchable.
is($store->history(undef, undef, 25,
	{ page => 1, search => 'resolved' })->{total}, 75,
   'search includes event state');
is($store->history(undef, undef, 25,
	{ page => 1, search => 'Recovered',
	  labels => { resolved => 'Recovered' } })->{total}, 75,
   'search includes translated state labels supplied by the caller');
# Delivery errors stay private; unmatched current incidents remain visible.
my $private = $store->history($guest, undef, 25,
	{ page => 1, search => 'Private delivery phrase' });
is($private->{total}, 0, 'search never reveals a guest delivery error');
is($store->history(undef, undef, 25,
	{ page => 1, search => 'Private delivery phrase' })->{total}, 0,
   'host search also excludes private delivery fields');
is(scalar(@{$private->{states}}), 1,
   'current incidents remain visible when historical search has no matches');

# Existing cursor consumers still move forward, with optional search filtering.
my $cursor = $store->history(undef, $ids[39], 10);
is_deeply([ map { $_->{id} } @{$cursor->{events}} ], [ @ids[40 .. 49] ],
	  'cursor batches keep their existing order');
ok(!exists($cursor->{total}), 'cursor reads do not add page metadata');
my $searched = $store->history(undef, 0, 3, { search => 'resolved' });
is_deeply([ map { $_->{id} } @{$searched->{events}} ], [ @ids[1, 3, 5] ],
	  'cursor search returns the next matching events');

# Reject conflicting filters, long searches and invalid page numbers.
for my $case (
	[ 0, { page => 1 } ], [ undef, { page => 0 } ],
	[ undef, { page => -1 } ], [ undef, { page => 1.5 } ],
	[ undef, { page => [ ] } ], [ undef, { search => [ ] } ],
	[ undef, { search => 'x' x 201 } ],
	[ undef, { search => "bad\nvalue" } ],
) {
	ok(!eval { $store->history(undef, $case->[0], 25, $case->[1]); 1 },
	   'invalid history filter rejected');
	}
done_testing();
