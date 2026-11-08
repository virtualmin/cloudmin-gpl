use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use CloudminTest;
use Test::More;
use WebminCore qw(convert_to_json);
use MIME::Base64 qw(encode_base64);
use Cloudmin::Libvirt;

my $uuid = '11111111-2222-4333-8444-555555555555';
my $public = 'ssh-rsa Zml4dHVyZQ== guest';
my $adapter = Cloudmin::Libvirt->new(readonly => 0);
my (@calls, $reply, $open_error, $read_error);
{
	no warnings 'redefine';
	# setup_agent_command(self, uuid, command, [arguments], [final_attempt])
	# Simulates open/read failures while recording handle cleanup.
	local *Cloudmin::Libvirt::setup_agent_command = sub {
		my ($self, $id, $command, $args) = @_;
		push(@calls, [ $id, $command, $args ]);
		return $open_error ? undef : { return => 7 }
			if ($command eq 'guest-file-open');
		return $read_error ? undef : $reply
			if ($command eq 'guest-file-read');
		return { return => { } };
		};

	# A trusted public identity is read once and its
	# handle is always closed.
	my $json = convert_to_json({ uuid => $uuid, key => $public });
	$reply =
		{ return =>
			  { count => length($json),
			    'buf-b64' => encode_base64($json) } };
	is($adapter->get_setup_host_key($uuid), $public,
	   'public host key comes from the domain agent');
	is_deeply([ map { $_->[1] } @calls ],
		  [ qw(guest-file-open guest-file-read guest-file-close) ],
		  'agent handles are closed after reading');
	is_deeply($calls[0]->[2],
		  { path => '/var/log/qemu-ga/cloudmin-identity.json',
		    mode => 'r' },
		  'only the fixed public identity file is opened read-only');
	is_deeply($calls[1]->[2], { handle => 7, count => 4096 },
		  'public identity read is bounded');

	# Startup and transport loss are retryable without
	# leaking agent handles.
	$open_error = 1;
	@calls = ();
	is($adapter->get_setup_host_key($uuid), undef,
	   'unavailable agent is a boot condition');
	is(scalar(@calls), 1, 'no handle is closed when opening failed');
	$open_error = 0;
	$read_error = 1;
	@calls = ();
	is($adapter->get_setup_host_key($uuid), undef,
	   'agent restart during read is retryable');
	is($calls[-1]->[1], 'guest-file-close',
	   'failed reads still close their handles');
	$read_error = 0;

	# Identity mismatches, truncation and extra known_hosts lines
	# are permanent errors.
	for my $bad ( { uuid => 'different', key => $public },
		      { uuid => $uuid,
			key => "$public\nother ssh-rsa AAAA" } ) {
		my $bytes = convert_to_json($bad);
		$reply =
			{ return =>
				  { count => length($bytes), 'buf-b64' =>
								     encode_base64($bytes) } };
		@calls = ();
		ok(!eval { $adapter->get_setup_host_key($uuid); 1 },
		   'untrusted identity is refused');
		is($calls[-1]->[1], 'guest-file-close',
		   'validation failures close their handles');
		}
	for my $value ( { count => 4096, 'buf-b64' => 'eA==' },
			{ count => 1, 'buf-b64' => encode_base64($json) },
			{ count => 3, 'buf-b64' => '???' } ) {
		$reply = { return => $value };
		ok(!eval { $adapter->get_setup_host_key($uuid); 1 },
		   'oversized, partial or malformed reply refused');
		}
	}

# Exercise CLI and QGA failures without invoking host virtualization tools.
{
	no warnings 'redefine';
	local *Cloudmin::Libvirt::setup_agent_error = sub { '' };
	my ($exit, $stdout, $stderr) = ( 0, '', '' );
	# execute_command(command, stdin, stdout_ref, stderr_ref)
	# returns CLI fixtures.
	local *Cloudmin::Libvirt::execute_command = sub {
		my ($command, $stdin, $out, $err) = @_;
		is($ENV{'LC_ALL'}, 'C',
		   'libvirt error classification uses a fixed locale');
		$$out = $stdout;
		$$err = $stderr;
		return $exit;
		};
	for my $case (
		[ 124 << 8, '' ], [ 137 << 8, '' ],
		[ 256,
		  'error: Guest agent is not responding: QEMU guest agent is not connected' ] ) {
		($exit, $stderr) = @$case;
		is($adapter->get_setup_host_key($uuid), undef,
		   'agent startup or timeout remains retryable');
		}
	# Host failures cannot improve by waiting for guest preparation.
	for my $message ( 'error: Failed to connect socket: Permission denied',
			  'error: QEMU guest agent is not configured',
			  'error: domain is not running',
			  'error: Failed to connect socket: No such file or directory' ) {
		($exit, $stderr) = ( 256, $message );
		ok(!eval { $adapter->get_setup_host_key($uuid); 1 },
		   'permanent virsh failure stops discovery');
		like($@, qr/\Q$message\E/,
		     'virsh diagnostic is retained');
		}

	# Libvirt reports guest errors on stderr with exit 1,
	# not as JSON on stdout.
	for my $case (
		[ 'guest-file-open',
		  "failed to open file '/var/log/qemu-ga/cloudmin-identity.json': No such file or directory" ],
		[ 'guest-file-open',
		  'Command guest-file-open has been disabled: the command is not allowed' ],
		[ 'guest-file-open', 'the command is not allowed' ],
		[ 'guest-file-open',
		  "failed to open file '/var/log/qemu-ga/cloudmin-identity.json': Permission denied" ],
		[ 'guest-file-read', "handle '7' has not been found" ],
		[ 'guest-file-read', 'invalid handle' ] ) {
		my ($command, $description) = @$case;
		($exit, $stdout, $stderr) = ( 256, '',
					      "error: guest agent command failed: unable to execute QEMU agent command '$command': $description\n" );
		my $result;
		ok(eval { $result =
			$adapter->setup_agent_command($uuid, $command); 1 },
		   "guest boot condition is retryable: $description");
		is($result, undef,
		   'retryable guest error returns no identity');
		ok(!eval { $adapter->setup_agent_command($uuid, $command,
							 { },
							 1); 1 },
		   'persistent guest error stops discovery at the deadline');
		like($@, qr/\Q$description\E/,
		     'final attempt retains the guest diagnostic');
		}

	# Unsupported commands and unexpected guest errors are
	# permanent even at boot.
	for my $case ( [ 'guest-file-open',
			 "Command guest-file-open has not been found" ],
		       [ 'guest-file-read',
			 'Command guest-file-read has not been found' ],
		       [ 'guest-file-open', 'Input/output error' ] ) {
		my ($command, $description) = @$case;
		($exit, $stderr) = ( 256,
				     "error: guest agent command failed: unable to execute QEMU agent command '$command': $description" );
		ok(!eval { $adapter->setup_agent_command($uuid,
							 $command); 1 },
		   'permanent guest error fails without a boot wait');
		like($@, qr/\Q$description\E/,
		     'permanent guest diagnostic is retained');
		}

	# Only successful virsh commands provide the JSON response body.
	($exit, $stderr, $stdout) = ( 0, '',
				      convert_to_json({ return => 7 }) );
	is_deeply($adapter->setup_agent_command($uuid, 'guest-file-open'),
		  { return => 7 },
		  'successful virsh response is decoded');
	$stdout = 'not JSON';
	ok(!eval { $adapter->setup_agent_command($uuid, 'guest-file-open'); 1 },
	   'malformed success output is refused');
	}

# Read-only access and malformed identifiers fail before any host command runs.
my $readonly = Cloudmin::Libvirt->new();
ok(!eval { $readonly->get_setup_host_key($uuid); 1 },
   'read-only adapter cannot issue agent file operations');
like($@, qr/write permission/, 'read-only denial is explicit');
ok(!eval { $adapter->get_setup_host_key('name;command'); 1 },
   'agent lookup requires a UUID');
like($@, qr/identifier/, 'invalid identifier fails before launching virsh');
done_testing();
