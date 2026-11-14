use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
use MIME::Base64 ();
use Digest::SHA qw(sha256_hex);
require "$Bin/../lib/Cloudmin/VMs.pm";
require "$Bin/../cloudmin-webmin-lib.pl";

# Keep guest identity, credentials and native server records entirely in memory.
our ($module_root_directory, $module_config_directory, $remote_user);
$remote_user = 'root';
$module_root_directory = "$Bin/..";
$module_config_directory = '/fixture';
$servers::module_config_directory = '/fixture/servers';
require "$module_root_directory/cloudmin-lib.pl";
my $uuid = '11111111-2222-4333-8444-555555555555';
my $job =
	{ id => 'a' x 32, request =>
				  { uuid => $uuid, software => 'virtualmin-gpl',
				    webmin_register => 1,
				    name => 'fixture',
				    hostname => 'fixture.example.test',
				    username => 'cloudmin',
				    webmin_password => 'fixture-initial-password' },
	  resources => { ssh_host_public => 'ssh-rsa Zml4dHVyZQ==' } };
my $vm = { uuid => $uuid, active => 1, cloudmin => { job => $job->{'id'} },
	   addresses => [ { address => '192.0.2.5' } ], interfaces =>
								[ { mac => '52:54:00:12:34:56' } ] };
my @host_addresses;
my (%servers, @calls, %locked);
my ($module_grant, $view_grant, $manage_grant, $server_grant, $readonly) =
	( 1, 1, 1, 1, 0 );

# pem(bytes, [with_key]) builds a PEM file whose certificate holds these bytes.
# with_key defaults to false. When true, prepend a dummy private key block.
sub pem
{
my ($bytes, $with_key) = @_;
return ($with_key
		? "-----BEGIN PRIVATE KEY-----\n".
		  MIME::Base64::encode_base64('fixture-private-key').
		  "-----END PRIVATE KEY-----\n"
		: '').
       "-----BEGIN CERTIFICATE-----\n".MIME::Base64::encode_base64($bytes).
       "-----END CERTIFICATE-----\n";
}

# Model the files returned by the guest agent, including a combined key file.
our %guest_files =
	( '/etc/webmin/miniserv.conf' =>
		  "port=10000\nssl=1\nkeyfile=/etc/webmin/miniserv.pem\n",
	  '/etc/webmin/miniserv.pem' => pem('first certificate', 1) );
my $first_pin = sha256_hex('first certificate');
my ($agent_down, @reads);

{
	no warnings qw(redefine once);
	# foreign_available(module) models the caller's native module grant.
	*main::foreign_available = sub { $module_grant };
	# foreign_check(module) keeps Servers Index installed in every case.
	*main::foreign_check = sub { 1 };
	# foreign_require(module, file) uses the in-memory stubs below.
	*main::foreign_require = sub { };
	# is_readonly_mode() supplies the current fixture restriction.
	*main::is_readonly_mode = sub { $readonly };
	# can_access(action, uuid) allows only the fixture guest.
	*main::can_access =
		sub { $_[0] eq 'view' && $_[1] eq $uuid && $view_grant };
	# require_access(action) rejects missing management or read-only access.
	*main::require_access =
		sub { die "Denied\n" if (!$manage_grant || $readonly); };
	# get_libvirt([writable]) returns the fake guest lookup
	# without opening libvirt.
	*main::get_libvirt = sub { bless { }, 'WebminAdapter' };
	# get_webprefix() exercises installations behind a path prefix.
	*main::get_webprefix = sub { '/prefix' };
	# lock_data_file(path) detects recursive locking of the same guest.
	*main::lock_data_file =
		sub { die "Already locked\n" if ($locked{$_[0]}++); };
	# unlock_data_file(path) records release so error paths can be checked.
	*main::unlock_data_file = sub { delete($locked{$_[0]}); };
	# list_servers() returns only synthetic native records.
	*servers::list_servers = sub { values %servers };
	# get_server(id) supports native ID reservation without touching disk.
	*servers::get_server = sub { $servers{$_[0]} };
	# save_server(record) copies the record and counts writes.
	*servers::save_server =
		sub { $servers{$_[0]->{'id'}} = { %{$_[0]} }; push(@calls,
								   'save'); };
	# delete_server(id) removes an in-memory record and counts deletes.
	*servers::delete_server =
		sub { delete($servers{$_[0]}); push(@calls, 'delete'); };
	# can_use_server(record) supplies the separate per-server grant.
	*servers::can_use_server = sub { $server_grant };
	%servers::access = ( add => 1, edit => 1, links => 1 );
	# get_domain(self, uuid) lets production code verify creation ownership.
	*WebminAdapter::get_domain = sub { $vm };
	# find_domain(self, uuid) supplies the domain for
	# independent lease discovery.
	*WebminAdapter::find_domain = sub { $vm };
	# get_domain_addresses(self, domain, record, [skip_agent])
	# returns host evidence.
	*WebminAdapter::get_domain_addresses = sub {
		# Agent data must never serve as independent
		# confirmation of its own report.
		die "Guest agent must be skipped\n" if (!$_[3]);
		return \@host_addresses;
		};
	# read_guest_file(self, uuid, path, [limit]) returns a fixture file,
	# undef while the agent is down, or dies for a missing file.
	# The optional limit is ignored by this stub.
	*WebminAdapter::read_guest_file = sub {
		push(@reads, $_[2]);
		# Model an unavailable agent without a file-specific error.
		return undef if ($agent_down);
		# A missing file must not prevent trying other certificates.
		die "Guest identity lookup failed\n"
			if (!exists($guest_files{$_[2]}));
		return $guest_files{$_[2]};
		};
	# server_ssl_fingerprints(record) splits fixture pins. Its presence lets
	# Cloudmin detect proxy support. These tests do not model TLS.
	*servers::server_ssl_fingerprints =
		sub { split(/,/, $_[0]->{'sslfingerprint'} || '') };

	}

# Both the module grant and guest visibility are required before proxy access.
ok(can_vm_webmin($uuid), 'authorized user sees Webmin');
# Native wildcard grants cannot turn a delegated account into the host root.
{
	local $remote_user = 'fixture';
	ok(!can_vm_webmin($uuid), 'non-root administrators cannot see Webmin');
	ok(!eval { register_vm_webmin($job); 1 },
	   'non-root administrators cannot register logins');
	ok(!eval { vm_webmin_url($vm); 1 },
	   'non-root administrators cannot obtain the proxy URL');
	ok(!eval { vm_webmin_direct_url($vm); 1 },
	   'direct access retains the root-only tab gate');
	is_deeply(\@calls, [ ], 'root-only refusals perform no server writes');
	}
for my $grant ( \$module_grant, \$view_grant ) {
	$$grant = 0;
	ok(!can_vm_webmin($uuid), 'missing grant hides Webmin');
	$$grant = 1;
	}
$readonly = 1;
# A visible guest still cannot expose an interactive login to a read-only user.
ok(!can_vm_webmin($uuid),
   'read-only users cannot reach an interactive guest admin login');
$readonly = 0;
$manage_grant = 0;
ok(!eval { register_vm_webmin($job); 1 },
   'viewers cannot create stored logins');
is_deeply(\@calls, [ ], 'denial happens before credential creation');
$manage_grant = 1;

# Direct links need no registration and never include a saved login.
is(vm_webmin_direct_url($vm), 'https://192.0.2.5:10000/',
   'unregistered guest gets its own HTTPS address');
is_deeply(\@calls, [ ], 'direct link creates no native entry');
{
	local $vm->{'addresses'} = [ { address => '2001:db8::5' } ];
	is(vm_webmin_direct_url($vm), 'https://[2001:db8::5]:10000/',
	   'direct IPv6 URL brackets the address');
	}
{
	local $vm->{'addresses'} =
		[ { address => '192.0.2.5/servers/link.cgi/1/' } ];
	ok(!eval { vm_webmin_direct_url($vm); 1 },
	   'malformed address cannot become a URL');
	}

# Missing credentials use the native prompt, without storing a guest password.
my $password = delete($job->{'request'}->{'webmin_password'});
my ($prompt, $occupied);
{
	# A seven-digit PID must still produce an ID supported by older themes.
	local $$ = 2522527;
	no warnings 'redefine';
	# get_server(id) simulates a manual entry occupying the first candidate.
	local *servers::get_server = sub {
		if (!defined($occupied)) {
			# Force a collision without depending on the current timestamp.
			$occupied = $_[0];
			$servers{$occupied} = { id => $occupied,
					       host => 'manual.example.test' };
			}
		return $servers{$_[0]};
		};
	$prompt = register_vm_webmin($job);
	}
like($prompt->{'id'}, qr/\A\d{8,16}\z/,
     'large process IDs stay within the older theme limit');
is(substr($occupied, -7), '2522527', 'the full process ID is retained');
is($prompt->{'id'}, $occupied + 1, 'an occupied ID is skipped');
is($servers{$occupied}->{'host'}, 'manual.example.test',
   'ID reservation preserves the existing server');
delete($servers{$occupied});
is($prompt->{'autouser'}, 1,
   'passwordless guests use Servers Index login prompt');
ok(!exists($prompt->{'user'}) && !exists($prompt->{'pass'}),
   'prompt has no stored credentials');
is_deeply(\%locked, { }, 'registration releases the lock');
remove_vm_webmin($uuid, $job->{'id'});
# Reject malformed credentials before publishing any native record.
$job->{'request'}->{'webmin_password'} = "invalid\npassword";
ok(!eval { register_vm_webmin($job); 1 },
   'malformed supplied passwords are rejected');
is(scalar(keys %servers), 0, 'invalid credentials publish no server');
$job->{'request'}->{'webmin_password'} = $password;
# A guest whose certificate cannot be read gets no entry and no saved login.
my $pem_file = '/etc/webmin/miniserv.pem';
# Each broken() callback removes one prerequisite for learning a certificate.
for my $broken ( sub { $agent_down = 1 },
		 sub { delete($guest_files{'/etc/webmin/miniserv.conf'}) },
		 sub { $guest_files{$pem_file} = 'no certificate' } ) {
	# Isolate each failure and check that no server record is saved.
	local %guest_files = %guest_files;
	$broken->();
	ok(!eval { register_vm_webmin($job); 1 },
	   'registration needs a certificate read through the guest agent');
	like($@, qr/guest agent/, 'the failure names the guest agent');
	is(scalar(keys %servers), 0, 'an unverified guest publishes no server');
	$agent_down = 0;
	}
# Reuse the creation login exactly once and retain later administrator edits.
@calls = ();
my $server = register_vm_webmin($job, '192.0.2.5');
is($server->{'sslfingerprint'}, $first_pin,
   'registration saves the fingerprint of the guest certificate');
unlike(convert_to_json($servers{$server->{'id'}}), qr/private-key|PRIVATE KEY/i,
       'key material from the certificate file is not saved');
is($server->{'user'}, 'cloudmin',
   'registration uses the initial guest username');
is($server->{'pass'}, $password,
   'registration reuses the supplied initial password');
is($server->{'cloudmin_job'}, $job->{'id'},
   'registration records its creation owner');
is_deeply(\@calls, [ 'save' ],
	  'registration saves only a native Servers Index entry');
is(register_vm_webmin($job)->{'pass'}, $password,
   'repeat registration preserves the existing login');
is_deeply(\@calls, [ 'save' ],
	  'repeat registration does not create a duplicate');
# Direct links reuse only the registered port and a currently reported IP.
is(vm_webmin_direct_url($vm), 'https://192.0.2.5:10000/',
   'registered direct link contains no credentials or proxy path');
{
	local $servers{$server->{'id'}}->{'port'} = 12345;
	local $vm->{'addresses'} =
		[ { address => '192.0.2.8' }, { address => '192.0.2.5' } ];
	is(vm_webmin_direct_url($vm), 'https://192.0.2.5:12345/',
	   'direct link preserves a usable saved IP and custom port');
	}
{
	local $servers{$server->{'id'}}->{'port'} = '10000/servers/';
	ok(!eval { vm_webmin_direct_url($vm); 1 },
	   'invalid registered port is rejected');
	}
{
	$server_grant = 0;
	ok(!eval { vm_webmin_direct_url($vm); 1 },
	   'direct link retains native per-server permission');
	$server_grant = 1;
	}
# Public progress exposes the access route, never the private login fields.
my $public = get_public_vm_job({ %$job, state => 'complete',
				 resources => { } });
unlike(convert_to_json($public), qr/fixture-initial-password|webmin_password/,
       'public job does not expose the saved login');
like($public->{'software_url'}, qr/^remote_access.cgi.*tab=webmin$/,
     'completion links to the host proxy view');

# Permission to add a server never grants access to an
# existing restricted server.
$server_grant = 0;
ok(!eval { register_vm_webmin($job); 1 },
   'existing native server ACL is honored');
ok(!eval { vm_webmin_url($vm); 1 },
   'proxy access honors the native server ACL');
$server_grant = 1;
@reads = ();
is(vm_webmin_url($vm), '/prefix/servers/link.cgi/'.$server->{'id'}.'/',
   'URL uses the native proxy and Webmin prefix');
is_deeply(\@reads, [ ], 'checking the setup does not contact the guest agent');

# Opening refreshes pins from the agent. An unchanged pin needs no write.
my $proxy_url = '/prefix/servers/link.cgi/'.$server->{'id'}.'/';
# saved() reads the current fixture server's stored fingerprints.
my $saved = sub { vm_webmin_server($uuid)->{'sslfingerprint'} };
my $pin_writes = scalar(@calls);
is(vm_webmin_url($vm, undef, undef, 1), $proxy_url,
   'an unchanged certificate opens the proxy');
is(scalar(@calls), $pin_writes, 'an unchanged certificate is not saved again');
{
	# An older proxy would connect without checking the saved fingerprint.
	no warnings 'once';
	local *servers::server_ssl_fingerprints;
	ok(!eval { vm_webmin_url($vm, undef, undef, 1); 1 },
	   'a proxy that cannot check certificates is not opened');
	like($@, qr/Update Webmin/, 'the refusal asks for a Webmin update');
	ok(vm_webmin_url($vm), 'the setup check itself needs no proxy support');
	}
{
	# A saved fingerprint cannot secure a connection with SSL disabled.
	local $servers{$server->{'id'}}->{'ssl'} = 0;
	ok(!eval { vm_webmin_url($vm, undef, undef, 1); 1 },
	   'a connection without SSL is not opened');
	}
# A changed guest certificate can update the pin only with edit permissions.
$guest_files{'/etc/webmin/miniserv.pem'} = pem('second certificate', 1);
my $second_pin = sha256_hex('second certificate');
{
	# Native server permissions apply even when Cloudmin allows management.
	local $servers::access{'edit'} = 0;
	ok(!eval { vm_webmin_url($vm, undef, undef, 1); 1 },
	   'saving a changed certificate needs native edit permission');
	}
# Cloudmin management permission is also required to save a renewed pin.
$manage_grant = 0;
ok(!eval { vm_webmin_url($vm, undef, undef, 1); 1 },
   'saving a changed certificate needs management access');
$manage_grant = 1;
is($saved->(), $first_pin, 'refused updates leave the saved fingerprint');
# With both grants restored, refresh the pin exactly once.
is(vm_webmin_url($vm, undef, undef, 1), $proxy_url,
   'a changed certificate opens once verified');
is($saved->(), $second_pin, 'the changed certificate replaces the saved one');
is(scalar(@calls), $pin_writes + 1, 'the change is saved exactly once');
# Webmin can present its default certificate, or one saved for the name or
# address the proxy connects to. Other domains' certificates do not apply.
{
	local %guest_files = ( %guest_files,
		'/etc/webmin/miniserv.conf' =>
			"keyfile=/etc/webmin/miniserv.pem\n".
			"certfile=/etc/webmin/host.cert\n".
			"ipkey_a.test,fixture.test=/etc/webmin/sni.key\n".
			"ipcert_a.test,fixture.test=/etc/webmin/sni.cert\n".
			"ipkey_192.0.2.9=/etc/webmin/combined.pem\n".
			"ipkey_*.test=/etc/webmin/missing.pem\n".
			"ipkey_192.0.2.9,alias.test=relative.pem\n".
			"ipkey_other.test,192.0.2.10=/etc/webmin/other.pem\n",
		'/etc/webmin/host.cert' => pem('host certificate'),
		'/etc/webmin/sni.cert' => pem('name certificate'),
		'/etc/webmin/combined.pem' => pem('address certificate', 1),
		'/etc/webmin/other.pem' => pem('other certificate', 1) );
	# Check which certificates are accepted and which guest paths are read.
	@reads = ();
	is_deeply([ sort(vm_webmin_fingerprints($uuid, 'fixture.test',
						 '192.0.2.9')) ],
		  [ sort(map { sha256_hex($_) } 'host certificate',
			 'name certificate', 'address certificate') ],
		  'certificates for this name and address are returned');
	ok(grep({ /missing/ } @reads),
	   'a wildcard entry for the name is tried');
	ok(!grep({ /\.key\z|relative|other/ } @reads),
	   'keys, relative paths and other domains are never read');
	}
# An unavailable agent leaves the saved pin in force without another write.
$agent_down = 1;
$pin_writes = scalar(@calls);
is(vm_webmin_url($vm, undef, undef, 1), $proxy_url,
   'a saved fingerprint still opens the proxy without the agent');
is(scalar(@calls), $pin_writes, 'nothing is saved without the agent');
{
	# Without either an agent response or a saved pin, opening must fail.
	local $servers{$server->{'id'}}->{'sslfingerprint'};
	ok(!eval { vm_webmin_url($vm, undef, undef, 1); 1 },
	   'a guest never verified is not opened without the agent');
	like($@, qr/open Webmin directly/,
	     'the refusal offers the direct link');
	}
$agent_down = 0;
{
	# An older entry gains a pin when the agent can supply its certificate.
	local $servers{$server->{'id'}}->{'sslfingerprint'};
	is(vm_webmin_url($vm, undef, undef, 1), $proxy_url,
	   'an earlier entry opens after its first verification');
	is($saved->(), $second_pin, 'the earlier entry gains a fingerprint');
	}
# An address change requires approval before credentials go to the new target.
$vm->{'addresses'} = [ { address => '192.0.2.6' } ];
my %change;
my $writes = scalar(@calls);
is(vm_webmin_direct_url($vm), 'https://192.0.2.6:10000/',
   'direct link uses the current guest address without changing registration');
ok(!vm_webmin_url($vm, \%change),
   'changed address does not expose a proxy URL');
is(vm_webmin_server($uuid)->{'ip'}, '192.0.2.5',
   'viewing a change preserves the saved destination');
is(scalar(@calls), $writes, 'viewing a change performs no native writes');
is_deeply(\%change,
	  { old => '192.0.2.5', new => '192.0.2.6', source => 'unverified' },
	  'warning distinguishes agent data from host evidence');

# Only the guest's saved static IP or a lease for its MAC supports the report.
for my $entry (
	{ source => 'lease', mac => '52:54:00:12:34:56', expected => 'lease' },
	{ source => 'lease', mac => '52:54:00:aa:bb:cc', expected =>
								 'unverified' },
	{ source => 'agent', mac => '52:54:00:12:34:56', expected =>
								 'unverified' },
	{ source => 'arp', mac => '52:54:00:12:34:56', expected =>
							       'unverified' } ) {
	@host_addresses = ({ %$entry,
			     address => '192.0.2.6' });
	vm_webmin_url($vm, \%change);
	is($change{'source'}, $entry->{'expected'},
	   'host evidence checks source and MAC');
	}
@host_addresses = ();
$vm->{'cloudmin'}->{'ipv4'} = '192.0.2.6/24';
vm_webmin_url($vm, \%change);
is($change{'source'}, 'static',
   'saved static configuration is checked without address_mode metadata');
delete($vm->{'cloudmin'}->{'ipv4'});

# Confirmations bind both addresses so changed reports or
# other edits need review.
for my $approval ( { old => '192.0.2.4', new => '192.0.2.6' },
		   { old => '192.0.2.5', new => '192.0.2.7' } ) {
	ok(!vm_webmin_url($vm, \%change, $approval),
	   'stale confirmation does not connect');
	is(vm_webmin_server($uuid)->{'ip'}, '192.0.2.5',
	   'stale confirmation cannot change the entry');
	}
my $approval = { old => '192.0.2.5', new => '192.0.2.6' };
{
	local $servers::access{'edit'} = 0;
	ok(!eval { vm_webmin_url($vm, \%change, $approval); 1 },
	   'address acceptance needs native edit permission');
	}
ok(vm_webmin_url($vm, \%change, $approval),
   'accepted current address opens the proxy');
is_deeply(\%change, { }, 'accepted address clears the warning');
is(vm_webmin_server($uuid)->{'ip'}, '192.0.2.6',
   'accepted change updates the native entry');
$vm->{'active'} = 0;
ok(!eval { vm_webmin_url($vm); 1 }, 'stopped guests cannot open a stale login');
ok(!eval { vm_webmin_direct_url($vm); 1 },
   'stopped guests have no direct connection action');
$vm->{'active'} = 1;
# UUID reuse cannot adopt another creation's saved login.
delete($vm->{'cloudmin'}->{'job'});
ok(!vm_webmin_url($vm), 'unmanaged guest cannot adopt an earlier registration');
$vm->{'cloudmin'}->{'job'} = 'b' x 32;
ok(!vm_webmin_url($vm), 'reused UUID cannot adopt an earlier creation login');
ok(!eval { register_vm_webmin($job); 1 },
   'registration rechecks the original creation identity');

# Removal requires matching guest and creation IDs.
$servers{'manual'} = { id => 'manual', host => 'manual.example.test' };
remove_vm_webmin($uuid, 'b' x 32);
ok(vm_webmin_server($uuid),
   'different creation cannot remove the original entry');
remove_vm_webmin($uuid, $job->{'id'});
ok(!vm_webmin_server($uuid),
   'virtual machine deletion removes its owned entry');
ok($servers{'manual'}, 'manual Servers Index entries remain untouched');
# A later explicit connection without the original password uses the prompt.
$vm->{'cloudmin'}->{'job'} = $job->{'id'};
$vm->{'addresses'} = [ { address => '192.0.2.5' } ];
delete($job->{'request'}->{'webmin_password'});
my $manual = register_vm_webmin($job);
is($manual->{'autouser'}, 1, 'older guests use the same native login prompt');
ok(!exists($manual->{'pass'}),
   'explicit connection does not need a Cloudmin password form');
is_deeply(\%locked, { }, 'all paths release their locks');
done_testing();
