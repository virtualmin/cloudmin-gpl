use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use WebminCore;
use MIME::Base64 ();
our ($module_root_directory, %access);
$module_root_directory = "$Bin/..";
require "$module_root_directory/cloudmin-lib.pl";

# Guest files are read through bounded agent file operations.
my $uuid = '11111111-2222-4333-8444-555555555555';
my $adapter = Cloudmin::Libvirt->new(readonly => 0);
my (@calls, @replies, $open_error);
{
	no warnings qw(redefine once);
	# setup_agent_command(self, id, command, args, [final]) replays replies.
	# final is omitted for the best-effort close.
	local *Cloudmin::Libvirt::setup_agent_command = sub {
		my ($self, $id, $command, $args, $final) = @_;
		push(@calls, [ $command, $args, $final ]);
		# Opening may fail before a handle exists.
		return $open_error ? undef : { return => 3 }
			if ($command eq 'guest-file-open');
		# Reads consume queued chunks; the remaining
		# close operation succeeds.
		return shift(@replies) if ($command eq 'guest-file-read');
		return { return => { } };
		};
	# chunk(bytes, eof) encodes one agent file-read response.
	my $chunk =
		sub { my ($bytes, $eof) =
			@_; { return =>
				      { count => length($bytes), 'buf-b64' =>
									 MIME::Base64::encode_base64($bytes), eof => $eof } } };
	@replies =
		( $chunk->("root:x:0:0", 0), $chunk->(":root:/root:/bin/bash\n",
						      1) );
	is($adapter->read_guest_file($uuid, '/etc/passwd'),
	   "root:x:0:0:root:/root:/bin/bash\n",
	   'chunks are joined until the agent reports the end');
	is_deeply([ map { $_->[0] } @calls ],
		  [
			  qw(guest-file-open guest-file-read guest-file-read guest-file-close) ], 'handle is closed after reading');
	is($calls[1]->[1]->{'count'}, 8192,
	   'encoded chunks fit the agent reply limit');
	is_deeply($calls[0]->[1], { path => '/etc/passwd', mode => 'r' },
		  'file is opened read-only');
	ok($calls[0]->[2],
	   'open failures are reported at once rather than retried');
	@calls = ();
	# The size limit applies to the combined data, not
	# each individual chunk.
	@replies = ( $chunk->('x' x 20, 0), $chunk->('y' x 20, 1) );
	ok(!eval { $adapter->read_guest_file($uuid, '/etc/passwd', 30); 1 },
	   'oversized files are refused');
	like($@, qr/too large/, 'size limit explained');
	is($calls[-1]->[0], 'guest-file-close',
	   'refused reads still close the handle');
	@calls = ();
	# Truncated payloads still require the already-open handle to be closed.
	@replies =
		({ return =>
			   { count => 5,
			     'buf-b64' => MIME::Base64::encode_base64(
				     'abc') } });
	ok(!eval { $adapter->read_guest_file($uuid, '/etc/passwd'); 1 },
	   'truncated replies are refused');
	is($calls[-1]->[0], 'guest-file-close',
	   'invalid replies close the handle');
	# Tiny successful chunks must not keep a page waiting indefinitely.
	{
		my $clock = 0;
		# time() advances without sleeping so the total
		# deadline is exercised.
		local *Time::HiRes::time = sub { $clock += 4 };
		@calls = ();
		@replies = map { $chunk->('x', 0) } 1 .. 4;
		ok(!eval { $adapter->read_guest_file($uuid,
						     '/etc/passwd'); 1 },
		   'slow short reads cannot extend the whole-file deadline');
		like($@, qr/Guest file read timed out/,
		     'the total read deadline is reported');
		is(scalar(grep { $_->[0] eq 'guest-file-read' } @calls), 2,
		   'no more reads start after the deadline');
		is($calls[-1]->[0], 'guest-file-close',
		   'timed-out reads close the handle');
		}
	# An unavailable agent never returned a handle that could be closed.
	$open_error = 1;
	@calls = ();
	is($adapter->read_guest_file($uuid, '/etc/passwd'), undef,
	   'a disconnected agent yields no file');
	is(scalar(@calls), 1, 'nothing is closed when opening failed');
	}

# Suggestions include UID 0 and ordinary users without known non-login shells.
# This list is a UI convenience; it does not authorize accounts or test logins.
my $passwd =
	join("\n", 'root:x:0:0:root:/root:/bin/bash',
	     'daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin',
	     'sshd:x:107:65534::/run/sshd:/usr/sbin/nologin',
	     'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin',
	     'deploy:x:1001:1001::/home/deploy:/bin/zsh',
	     'cloudmin:x:1000:1000::/home/cloudmin:/bin/bash',
	     'locked:x:1002:1002::/home/locked:/bin/false',
	     'sync:x:4:65534:sync:/bin:/bin/sync',
	     'bad name:x:1003:1003::/home/bad:/bin/sh',
	     'noshell:x:1004:1004::/home/noshell:', 'broken line', '');
is_deeply(login_accounts($passwd, 'cloudmin'),
	  [ qw(cloudmin deploy noshell root) ],
	  'preferred account first, then logins sorted');
is_deeply(login_accounts($passwd), [ qw(cloudmin deploy noshell root) ],
	  'without a preference the list is sorted');
is_deeply(login_accounts($passwd, 'missing'),
	  [ qw(cloudmin deploy noshell root) ],
	  'absent preferences are ignored');
is_deeply(login_accounts(undef), [ ], 'no passwd text gives no accounts');

# Pages get the guest list only for sessions allowed to use the agent channel.
my $vm = { uuid => $uuid, cloudmin => { username => 'cloudmin' } };
{
	no warnings qw(redefine once);
	my ($writable, $reads);
	# get_libvirt(writable) records whether the caller
	# requested write access.
	local *main::get_libvirt = sub { $writable = $_[0]; $adapter };
	# read_guest_file(self, id, path, limit) checks the
	# bounded passwd request.
	local *Cloudmin::Libvirt::read_guest_file =
		sub { my ($self, $id, $path, $limit) = @_;
			++$reads;
			is($path, '/etc/passwd',
			   'account list comes from passwd'); ok(
				   $limit >= 65536,
				   'bounded read'); $passwd };
	%access = ( admin => 1 );
	is_deeply(guest_login_accounts($vm),
		  [ qw(cloudmin deploy noshell root) ],
		  'writable sessions list guest accounts');
	ok($writable, 'agent file reads use the writable adapter');
	# Password and SSH rendering share one lookup without
	# persisting the cache.
	{
		local $main::guest_login_accounts_cache = { };
		my $before = $reads;
		guest_login_accounts($vm);
		guest_login_accounts($vm);
		is($reads - $before, 1,
		   'two Access forms share one account read');
		local %access = ( admin => 0, vms => $uuid, password => 1 );
		is(guest_login_accounts($vm), undef,
		   'cached accounts do not bypass permissions');
		}
	my $before = $reads;
	guest_login_accounts($vm);
	is($reads - $before, 1, 'a later rendering reads fresh accounts');
	is(guest_login_accounts({ %$vm, state => 'shutoff' }), undef,
	   'stopped guests use manual entry');
	is($reads - $before, 1,
	   'stopped guest discovery never calls the agent');
	# read_guest_file(self, id, path, limit) models
	# disabled file operations.
	local *Cloudmin::Libvirt::read_guest_file =
		sub {
			++$reads;
			die "Guest identity lookup failed: file operations disabled\n" };
	is(guest_login_accounts($vm), undef,
	   'blocked file operations fall back quietly');
	{
		local $main::guest_login_accounts_cache = { };
		my $before = $reads;
		guest_login_accounts($vm);
		guest_login_accounts($vm);
		is($reads - $before, 1,
		   'failed discovery is not repeated for the second tab');
		}
	# read_guest_file(self, id, path, limit) models a disconnected agent.
	local *Cloudmin::Libvirt::read_guest_file = sub { undef };
	is(guest_login_accounts($vm), undef,
	   'a disconnected agent falls back quietly');
	# Assignment to a guest does not grant the write-capable agent channel.
	%access = ( admin => 0, vms => $uuid );
	is(guest_login_accounts($vm), undef,
	   'delegated sessions never open the agent channel');
	}
done_testing();
