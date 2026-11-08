use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use MIME::Base64 qw(encode_base64);
use WebminCore qw(convert_from_json);
require "$Bin/../lib/Cloudmin/Libvirt.pm";
require "$Bin/../lib/Cloudmin/Images.pm";
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/VMs.pm";

# Public fixture bytes contain no private key or usable test credentials.
my $key = 'ssh-ed25519 '.
	  encode_base64(pack('N', 11).'ssh-ed25519'.pack('N',
							 32).('A' x 32), '').
	  ' fixture';
my $options = {
	capabilities => { architecture => 'aarch64', machine => 'virt',
			  emulator => '/usr/bin/qemu',
			  cpus => 4, memory_kib => 4 * 1024**2, free_memory =>
									3 * 1024**3,
			  efi => 1, firmware => [ 'efi' ] },
	images => [ { id => 'a' x 32, name => 'Test image',
		      architecture => 'aarch64', cloud_init => 1,
		      firmware => 'uefi', virtual_size => 3 * 1024**3,
		      min_disk_bytes => 5 * 1024**3,
		      pool => 'source-pool', volume => 'base.qcow2',
		      volume_key => '/images/base.qcow2',
		      volume_path => '/images/base.qcow2', format =>
								   'qcow2' } ],
	pools => [ { id => 'pool', name => 'default',
		     available => 40 * 1024**3 } ],
	networks => [ { key => 'network:nat', name => 'default',
			type => 'network', source => 'default', dhcp => 1 } ],
	domains => [ ],
};
my $input = { name => 'My server', image => 'a' x 32, pool => 'pool',
	      network => 'network:nat',
	      cpus => 2, memory_mib => 1024, disk_gib => 10,
	      username => 'cloudmin',
	      ssh_keys => $key,
	      firmware => 'auto', address_mode => 'dhcp', start => 1,
	      autostart => 1 };
my $service = Cloudmin::VMs->new();

# Host policy rejects explicit installer requests from any caller.
{
	my $plain = Cloudmin::VMs->new(virtualmin_enabled => 0);
	foreach my $software ( 'virtualmin-gpl', 'virtualmin-pro' ) {
		my $request = { %$input, software => $software,
				virtualmin_type => 'full', webmin_register => 1,
				packages => 'jq' };
		my %original = %$request;
		# No inventory is supplied: policy must fail
		# before probing the host.
		ok(!eval { $plain->prepare($request); 1 },
		   "$software is refused when disabled");
		is($@,
		   "Virtualmin installation is disabled in Module Configuration. ".
		   "Re-enable it to install Virtualmin.\n",
		   'rejection explains how to enable installation');
		is_deeply($request, \%original,
			  'rejection preserves the submitted options');
		}
	ok(eval { $plain->prepare($input, $options); 1 },
	   'plain creation remains available');
	# Isolate host checks so independent package setup is still exercised.
	no warnings qw(redefine once);
	# setup_agent_error() reports no missing host tools for this fixture.
	local *Cloudmin::Libvirt::setup_agent_error = sub { undef };
	# check(network) skips host firewall probing in this
	# preparation-only test.
	local *Cloudmin::NetworkPreflight::check = sub { };
	my $request =
		$plain->prepare({ %$input, software => 'none',
				  packages => 'jq' },
				$options);
	is($request->{'packages'}, 'jq',
	   'package installation remains available');
	is($request->{'software'}, 'none',
	   'packages cannot reactivate Virtualmin');
	# Explicitly enabling the setting restores both installer editions.
	$plain->{'virtualmin_enabled'} = 1;
	foreach my $software ( 'virtualmin-gpl', 'virtualmin-pro' ) {
		my $request = $plain->prepare({ %$input, software => $software,
						name => 'guest.example.test',
						memory_mib => 2048,
						disk_gib => 20 }, $options);
		is($request->{'software'}, $software,
		   "$software is available after re-enabling");
		}
	}

# Host tools are required only when this request includes guest software setup.
{
	no warnings qw(redefine once);
	# setup_agent_error() simulates missing tools without changing the host.
	local *Cloudmin::Libvirt::setup_agent_error =
		sub { 'Guest software setup requires virsh and timeout' };
	ok(!eval { $service->prepare({ %$input, packages => 'jq' },
				     $options); 1 },
	   'missing identity tools refuse setup before allocation');
	like($@, qr/requires virsh and timeout/,
	     'missing host dependency is explained');
	ok(eval { $service->prepare($input, $options); 1 },
	   'plain creation needs no guest identity tools');
	}

# Both UI and API preparation reject broken networking before allocation.
{
	no warnings qw(redefine once);
	local *Cloudmin::Libvirt::setup_agent_error = sub { undef };
	my $checked;
	local *Cloudmin::NetworkPreflight::check = sub {
		$checked = $_[0];
		die "Network default is missing IPv4 NAT rules\n";
		};
	ok(!eval { $service->prepare({ %$input, packages => 'jq' },
				     $options); 1 },
	   'network preflight blocks guest software before allocation');
	like($@, qr/missing IPv4 NAT rules/,
	     'submission reports the network failure');
	is($checked, $options->{'networks'}->[0],
	   'checks the selected host network record');
	$checked = undef;
	ok(eval { $service->prepare($input, $options); 1 },
	   'plain creation still works offline');
	ok(!$checked, 'plain creation does not check software networking');
	ok(eval { $service->prepare({ %$input, packages => 'jq', address_mode =>
									 'static',
				      ipv6 => '2001:db8::10/64',
				      gateway6 => '2001:db8::1' },
				    $options); 1 },
	   'IPv6-only guests do not require IPv4 rules');
	}

# Missing import metadata is matched by asset URL, not just a
# shared catalogue ID.
{
	package MetadataCatalogue;

	# list_entries(self) Supplies ARM and x86 assets with
	# the same catalogue ID.
	sub list_entries
	{
	return [
		{ id => 'example', architecture => 'aarch64',
		  url => 'https://example.test/arm.qcow2', format =>
								   'qcow2' },
		{ id => 'example', architecture => 'x86_64',
		  url => 'https://example.test/x86.qcow2', format =>
								   'qcow2' },
	];
	}
	package main;
	my $metadata_service = Cloudmin::VMs->new(catalogue => bless({ },
								     'MetadataCatalogue'));
	my $legacy = { source => 'download', slug => 'example',
		       format => 'qcow2',
		       url => 'https://example.test/x86.qcow2' };
	is($metadata_service->image_metadata($legacy)->{'architecture'},
	   'x86_64',
	   'legacy import inherits the architecture of its exact asset');
	$legacy->{'url'} = 'https://example.test/unrecognized.qcow2';
	ok(!$metadata_service->image_metadata($legacy)->{'architecture'},
	   'unrecognized legacy asset needs inspection instead of a host-architecture guess');
	$legacy->{'architecture'} = 'aarch64';
	is($metadata_service->image_metadata($legacy)->{'architecture'},
	   'aarch64',
	   'recorded import metadata is preserved');
	}

# Catalogue selections validate before download and preserve retry identity.
{
	my $entry =
		{ %{$options->{'images'}->[0]},
		  id => 'catalogue:rocky-linux-10',
		  catalogue_id => 'rocky-linux-10',
		  name => 'Rocky Linux 10',
		  url => 'https://example.test/rocky.qcow2',
		  checksum_url => 'https://example.test/CHECKSUM',
		  checksum_algorithm => 'sha256',
		  download_size_bytes => 1024**3 };
	delete(@$entry{qw(pool volume volume_key volume_path)});
	my $inventory = { %$options, images => [ ],
			  catalogue_images => [ $entry ] };
	my $selection = { %$input, image => $entry->{'id'} };
	my $pending = $service->prepare($selection, $inventory);
	is($pending->{'image'}, $entry->{'id'},
	   'catalogue identity remains in the submitted request');
	is($pending->{'image_download'}->{'url'}, $entry->{'url'},
	   'the validated download URL is captured');
	is($pending->{'image_download'}->{'pool'}, 'pool',
	   'download uses the selected destination pool');
	ok(!$pending->{'source_image'}->{'volume_key'},
	   'undownloaded choice does not invent a source volume');
	ok(!eval { $service->prepare($selection, $options); 1 },
	   'removed catalogue choice cannot be submitted');
	# An uncached source needs additional space alongside the guest disk.
	my $low_space =
		{ %$inventory, pools =>
				       [ { %{$options->{'pools'}->[0]},
				available => 11 * 1024**3 } ] };
	ok(!eval { $service->prepare($selection, $low_space); 1 },
	   'submission reserves room for the source download too');
	# Reuse a verified source across pools without changing
	# submission identity.
	my $ready = { %{$options->{'images'}->[0]},
		      %{$pending->{'image_download'}}, id => 'b' x 32, pool =>
									       'another-pool' };
	$inventory->{'images'} = [ $ready ];
	my $cached = $service->prepare($selection, $inventory);
	is($cached->{'image'}, $entry->{'id'},
	   'cache reuse does not change idempotency inputs');
	is($cached->{'source_image'}->{'id'}, 'b' x 32,
	   'cached source may be in another pool');
	is($cached->{'source_image'}->{'volume_key'}, '/images/base.qcow2',
	   'cached volume identity is retained');
	# A verified disk's actual size takes precedence over
	# catalogue estimates.
	$ready->{'virtual_size'} = 15 * 1024**3;
	ok(!eval { $service->prepare($selection, $inventory); 1 },
	   'actual downloaded capacity overrides catalogue estimates');
	}

# Only trusted image records can request offline preparation for each new guest.
{
	my $image =
		{ %{$options->{'images'}->[0]}, prepared_vm => 1, virtualmin =>
									  'pro' };
	my $captured = { %$options, images => [ $image ] };
	my $request =
		$service->prepare({ %$input, hostname => 'new.example.test' },
				  $captured);
	ok($request->{'source_image'}->{'prepared_vm'},
	   'captured image retains per-VM preparation flag');
	ok($request->{'require_fqdn'},
	   'captured Virtualmin requires a qualified hostname');
	ok(!eval { $service->prepare($input, $captured); 1 },
	   'short hostname rejected before copying captured Virtualmin');
	ok(!$service->prepare({ %$input, prepared_vm => 1 },
			      $options)->{'source_image'}->{'prepared_vm'},
	   'public input cannot mark an ordinary image as a prepared VM');
	}
my $r = $service->prepare($input, $options);
is($r->{'hostname'}, 'my-server', 'a VM name does not need to be an FQDN');
my $fqdn_error =
	"The selected template requires a fully qualified hostname, such as host.example.com. ".
	"Use it as the virtual machine name, or set the guest hostname separately.\n";
# Custom template rules apply without Virtualmin or any guest software setup.
for my $name ( 'short', 'short.' ) {
	ok(!eval { $service->prepare({ %$input, name => $name,
				       require_fqdn => 1 },
				     $options); 1 },
	   'a required qualified hostname cannot be replaced by a short VM name');
	is($@, $fqdn_error,
	   'template validation explains both hostname choices');
	}
for my $identity ( { name => 'guest.example.test' },
		   { name => 'short', hostname => 'other.example.test' } ) {
	my $request =
		$service->prepare({ %$input, %$identity, require_fqdn => 1 },
				  $options);
	is($request->{'hostname'}, $identity->{'hostname'} ||
	   $identity->{'name'},
	   'custom template accepts either hostname source');
	is($request->{'require_fqdn'}, 1,
	   'durable request retains the hostname requirement');
	}
is($service->prepare({ %$input, require_fqdn => 0 }, $options)->{'hostname'},
   'my-server',
   'a template allowing short names keeps ordinary creation unchanged');
for my $invalid ( 'yes', 2, [ ] ) {
	ok(!eval { $service->prepare({ %$input, require_fqdn => $invalid },
				     $options); 1 },
	   'invalid hostname requirement is rejected');
	}
# Virtualmin accepts a qualified VM name or a separate
# hostname before allocation.
{
	no warnings qw(redefine once);
	# setup_agent_error() isolates hostname validation from
	# installed host tools.
	local *Cloudmin::Libvirt::setup_agent_error = sub { undef };
	for my $software ( 'virtualmin-gpl', 'virtualmin-pro' ) {
		my $setup =
			{ %$input, software => $software, require_fqdn => 0,
			  memory_mib => 2048,
			  disk_gib => 20, name => 'guest.example.test' };
		is($service->prepare($setup, $options)->{'hostname'},
		   'guest.example.test',
		   "$software uses a qualified VM name when no hostname is supplied");
		is($service->prepare({ %$setup, hostname => '' },
				     $options)->{'hostname'},
		   'guest.example.test',
		   "$software also accepts a blank separate hostname");
		$setup->{'name'} = 'short';
		ok(!eval { $service->prepare($setup, $options); 1 },
		   "$software refuses a short hostname before allocation");
		is($@, $fqdn_error,
		   "$software explains both ways to supply a qualified hostname");
		is($service->prepare({ %$setup, hostname =>
							'other.example.test' },
				     $options)->{'hostname'},
		   'other.example.test',
		   "$software accepts a separate hostname with a short VM name");
		}
	}
# Names may use separators that hostname labels cannot start or end with.
is($service->prepare({ %$input, name => 'web.' }, $options)->{'hostname'},
   'web',
   'a trailing dot in the name does not reach the derived hostname');
is($service->prepare({ %$input, name => 'My..Server-' },
		     $options)->{'hostname'}, 'my.server',
   'repeated dots and trailing dashes are dropped from the derived hostname');
is($service->prepare({ %$input, name => 'My._--.Server' },
		     $options)->{'hostname'}, 'my.server',
   'a separator-only label is omitted from the derived hostname');
ok(!eval { $service->prepare({ %$input, hostname => 'bad_host.' }, $options);
	1 },
   'an explicit hostname is still validated');
is($r->{'firmware'}, 'efi', 'host and image select UEFI automatically');
like($r->{'mac'}, qr/^52:54:00:/, 'a fresh libvirt MAC is assigned');
is($r->{'source_image'}->{'volume_key'}, '/images/base.qcow2',
   'source identity is retained');

# Every unit in Webmin's size widget must represent the same disk capacity.
for my $power (0 .. 5) {
	my $units = int(1024**$power);
	my $value = sprintf('%.20f', 12.5 * 1024**3 / $units);
	$value =~ s/0+$//;
	$value =~ s/\.$//;
	my $sized = $service->prepare({ %$input, memory_mib => 1.5,
					memory_mib_units => 1024**3,
					disk_gib => $value,
					disk_gib_units => $units },
				      $options);
	is($sized->{'memory_mib'}, 1536, 'GiB memory converts to MiB');
	is($sized->{'disk_gib'} * 1024**3, 12.5 * 1024**3,
	   "disk multiplier $units converts exactly");
	is($service->prepare($sized, $options)->{'disk_gib'},
	   $sized->{'disk_gib'},
	   'normalized sizes remain stable during worker preflight');
	}
# Decimal GiB round once to stored MiB and survive worker preflight.
for my $case ( [ 1.1, 1126 ], [ 1.2, 1229 ], [ 1.25, 1280 ] ) {
	my $sized = $service->prepare({ %$input, memory_mib => $case->[0],
					memory_mib_units => 1024**3 },
				      $options);
	is($sized->{'memory_mib'}, $case->[1],
	   'decimal GiB round to nearest MiB');
	is($service->prepare($sized, $options)->{'memory_mib'}, $case->[1],
	   'normalized memory remains stable during preflight');
	}
my $odd_size = $service->prepare({ %$input, disk_gib => 10 * 1024**3 + 1,
				   disk_gib_units => 1 }, $options);
is($odd_size->{'disk_gib'} * 1024**3, 10 * 1024**3 + 512,
   'disk capacity rounds up to a whole sector');
is($service->prepare($odd_size, $options)->{'disk_gib'},
   $odd_size->{'disk_gib'},
   'sector rounding does not grow the disk again during preflight');

# CPU errors include the range displayed by the creation form.
for my $cpus ( 0, 5, 1.5 ) {
	ok(!eval { $service->prepare({ %$input, cpus => $cpus }, $options); 1 },
	   'invalid CPU count rejected before allocation');
	like($@, qr/whole CPU count from 1 to 4/,
	     'CPU validation states the allowed range');
	}

# Reject realistic invalid requests before any job or volume is created.
for my $bad (
	{ name => '<invalid>' }, { cpus => 5 }, { memory_mib => 4096 },
	{ disk_gib => 4 },
	{ disk_gib => 50 }, { pool => 'gone' }, { image => 'gone' },
	{ network => 'gone' },
	{ memory_mib => 4, memory_mib_units => 1024**3 },
	{ memory_mib => 1024.5, memory_mib_units => 1024**2 },
	{ memory_mib_units => 1000 }, { memory_mib_units => '' },
	{ disk_gib => 1, disk_gib_units => 1024**4 }, { disk_gib_units => -1 },
	{ disk_gib => 'NaN' }, { disk_gib => '1e300' }, { disk_gib => '-10' },
	{ username => 'sshd' }, { ssh_keys => '-----BEGIN PRIVATE KEY-----' },
	{ ssh_keys => 'command="id" '.$key },
	{ ssh_keys => 'ssh-ed25519 AAAA' },
	{ firmware => 'bios' }, { mac => 'ff:ff:ff:ff:ff:ff' },
	{ address_mode => 'static', ipv4 => '192.0.2.1/33' },
	{ address_mode => 'static', ipv6 => '2001:db8::1/129' },
	{ address_mode => 'static', ipv4 => '192.0.2.1/24',
	  gateway6 => '2001:db8::1' },
) {
	ok(!eval { $service->prepare({ %$input, %$bad }, $options); 1 },
	   'invalid request rejected: '.join(',', keys %$bad));
	}
my $occupied = { %$options,
		 domains => [ { name => 'My server', macs => [ ] } ] };
ok(!eval { $service->prepare($input, $occupied); 1 },
   'duplicate name is rejected');
$occupied = { %$options,
	      domains => [ { name => 'another', macs => [ $r->{'mac'} ] } ] };
ok(!eval { $service->prepare({ %$input, mac => $r->{'mac'} }, $occupied); 1 },
   'duplicate MAC is rejected');
my $custom = { %$options,
	       images => [ { %{$options->{'images'}->[0]},
		       architecture => undef,
		cloud_init => undef } ] };
{
	no warnings 'redefine';
	my $calls = 0;
	my $detected = { architecture => 'aarch64', cloud_init => 1 };
	local *Cloudmin::VMs::inspect_custom_image = sub { $calls++;
		return $detected; };
	ok($service->prepare($input, $options),
	   'known catalogue image needs no confirmation');
	is($calls, 0, 'known metadata avoids disk inspection');
	ok($service->prepare($input, $custom),
	   'custom image is checked automatically');
	is($calls, 1, 'unknown metadata triggers inspection');
	$detected = { architecture => 'x86_64', cloud_init => 1 };
	ok(!eval { $service->prepare({ %$input, image_compatible => 1 },
				     $custom); 1 },
	   'old confirmation input cannot override a detected architecture mismatch');
	like($@, qr/architecture does not match/,
	     'architecture mismatch is explained');
	$detected = { architecture => 'aarch64', cloud_init => 0 };
	ok(!eval { $service->prepare($input, $custom); 1 },
	   'custom image without cloud-init is rejected');
	my $unsupported = { %$options,
			    images => [ { %{$options->{'images'}->[0]},
				   cloud_init => 0 } ] };
	ok(!eval { $service->prepare({ %$input, image_compatible => 1 },
				     $unsupported); 1 },
	   'known lack of cloud-init cannot be overridden');
	$unsupported = { %$options,
			 images => [ { %{$options->{'images'}->[0]},
			architecture => 'x86_64' } ] };
	ok(!eval { $service->prepare($input, $unsupported); 1 },
	   'preflight independently checks architecture even if the selector was bypassed');
	local *Cloudmin::VMs::inspect_custom_image =
		sub { die "Inspection unavailable\n"; };
	ok(!eval { $service->prepare($input, $custom); 1 },
	   'inspection failure blocks unknown images');
	like($@, qr/Inspection unavailable/, 'inspection failure is retained');
	}

# A successful inspection is recorded on the image so it is not repeated.
{
	package PersistingImages;

	# path(self, id, suffix) Returns a fixed lock identity for the fixture.
	sub path
	{
	return 'image-lock';
	}

	# with_lock(self, path, nodiff, callback) Runs the callback
	# without Webmin locks.
	sub with_lock
	{
	return $_[3]->();
	}

	# get(self, id) - Returns a copy of the stored image record.
	sub get
	{
	return { %{$_[0]->{'job'}} };
	}

	# save(self, id, record) - Stores the record as the import job would.
	sub save
	{
	$_[0]->{'job'} = { %{$_[2]} };
	}
	package main;
	no warnings qw(redefine once);
	local *Cloudmin::Worker::run = sub {
		my (undef, undef, undef, %opts) = @_;
		$opts{'started'}->('b' x 32);
		return { architecture => 'aarch64', cloud_init => 1 };
		};
	my $store = bless({ job => { id => 'a' x 32, state => 'ready',
				     volume_key => '/images/base.qcow2' } },
			  'PersistingImages');
	my $detected = Cloudmin::VMs->new(images =>
						  $store)->inspect_custom_image({ id => 'a' x 32,
										  volume_key => '/images/base.qcow2',
										  volume_path => '/images/base.qcow2', format =>
															       'qcow2' });
	is($detected->{'architecture'}, 'aarch64',
	   'inspection returns the detected architecture');
	is($store->{'job'}->{'architecture'}, 'aarch64',
	   'the detected architecture is saved with the image');
	ok($store->{'job'}->{'cloud_init'},
	   'detected cloud-init support is saved with the image');
	ok(!exists($store->{'job'}->{'worker'}),
	   'the sandbox reference is cleared after inspection');
	}

# Cloud-init must carry static /32 and IPv6 routes without
# modifying guest disks.
$r = $service->prepare({ %$input, address_mode => 'static',
			 ipv4 => '192.0.2.10/32',
			 gateway4 => '192.0.2.1', ipv6 => '2001:0db8::10/64',
			 gateway6 => '2001:db8::1',
			 dns => '192.0.2.53, 2001:db8::53' }, $options);
is($r->{'ipv6'}, '2001:db8::10/64', 'IPv6 addresses use a canonical spelling');
# Volume names remain safe and distinct while identifying their VM and role.
is(Cloudmin::VMs::disk_volume_name('Alma VM', 'system', 'a' x 32),
   'cloudmin-Alma-VM-system-'.('a' x 32).'.qcow2',
   'system volume includes readable VM name');
unlike(Cloudmin::VMs::disk_volume_name('../../unsafe / vm', 'data', 'b' x 32),
       qr{[/ ]}, 'foreign VM names cannot introduce directories');
like(Cloudmin::VMs::disk_volume_name('VM', 'seed', 'c' x 32), qr/\.iso$/,
     'provisioning media keeps its ISO extension');
my $seed = Cloudmin::VMs::seed_data($r, 'fixture-uuid');
# Check encoded types directly; decoding alone can hide boolean coercion.
like($seed->{'user-data'}, qr/"disable_root"\s*:\s*true\b/,
     'Webmin encoder retains JSON true rather than a numeric or string value');
like($seed->{'user-data'}, qr/"preserve_hostname"\s*:\s*false\b/,
     'Webmin encoder retains JSON false');
my $network = convert_from_json($seed->{'network-config'});
my $nic = $network->{'ethernets'}->{'eth0'};
is_deeply($nic->{'addresses'}, [ '192.0.2.10/32', '2001:db8::10/64' ],
	  'both address families reach cloud-init');
is_deeply($nic->{'routes'}, [
	{ to => '192.0.2.1/32' }, { to => '0.0.0.0/0', via => '192.0.2.1' },
	{ to => '2001:db8::1/128' }, { to => '::/0', via => '2001:db8::1' },
], 'direct gateway routes support both families without Netplan-only options');
is($nic->{'match'}->{'macaddress'}, $r->{'mac'},
   'networking matches the allocated MAC');
ok(!exists($nic->{'set-name'}),
   'networking preserves the image interface name');
my $user_data = $seed->{'user-data'};
$user_data =~ s/^#cloud-config\n//;
my $user = convert_from_json($user_data);
ok(!exists($user->{'users'}->[0]->{'groups'}),
   'no supplementary groups omits the field instead of an invalid empty list');
ok(!$user->{'ssh_pwauth'} && $user->{'disable_root'},
   'initial access disables password and direct root login');
is($user->{'users'}->[0]->{'ssh_authorized_keys'}->[0], $key,
   'public key is preserved');

# Plain and software-enabled guests both need the agent, without duplicates.
for my $software ( 'none', 'virtualmin-gpl' ) {
	my $seed =
		Cloudmin::VMs::seed_data({ %$r, software => $software },
					 'fixture');
	$seed->{'user-data'} =~ s/^#cloud-config\n//;
	my $config = convert_from_json($seed->{'user-data'});
	is_deeply($config->{'packages'}, [ 'qemu-guest-agent' ],
		  "$software installs the guest agent once");
	like($config->{'runcmd'}->[0]->[2], qr/exec systemctl start/,
	     "$software starts the agent before optional software setup");
	ok($software ne 'none' || !exists($config->{'write_files'}),
	   'plain guests need no software helper or guest RPC policy changes');
	}

# Passwords are supplied through a trusted hash, with root an explicit choice.
my $hash = '$6$rounds=500000$'.('a' x 16).'$'.('b' x 86);
for my $name (qw(root cloudmin)) {
	for my $auth (qw(password both)) {
		my $request = $service->prepare({ %$input, username => $name,
						  auth_type => $auth },
						$options,
						$hash);
		my $data = Cloudmin::VMs::seed_data($request, 'fixture');
		$data->{'user-data'} =~ s/^#cloud-config\n//;
		my $config = convert_from_json($data->{'user-data'});
		ok($config->{'ssh_pwauth'} &&
		   !$config->{'users'}->[0]->{'lock_passwd'},
		   "$auth unlocks $name password login");
		is($config->{'users'}->[0]->{'hashed_passwd'}, $hash,
		   'cloud-init receives the hash');
		ok(!$config->{'chpasswd'}->{'expire'},
		   'initial password does not require an interactive change');
		is(!!$config->{'disable_root'}, $name ne 'root',
		   'root access follows the selected username');
		is(!!$config->{'users'}->[0]->{'ssh_authorized_keys'},
		   $auth eq 'both', 'keys are present only when selected');
		like($config->{'write_files'}->[0]->{'content'},
		     qr/PermitRootLogin yes/,
		     'root SSH policy allows passwords')
			if ($name eq 'root');
		is($service->prepare($request, $options,
				     $hash)->{'password_hash'}, $hash,
		   'worker revalidation preserves the trusted hash');
		}
	}
ok(!eval { $service->prepare({ %$input, auth_type => 'password',
			       password_hash => $hash }, $options); 1 },
   'public input cannot inject a precomputed hash');
ok(!eval { $service->prepare({ %$input, auth_type => 'both', ssh_keys => '' },
			     $options, $hash); 1 },
   'both requires a key as well as a password');
ok(!exists($service->prepare({ %$input, username => 'root' }, $options,
			     $hash)->{'password_hash'}),
   'key-only root login never retains a stale password');

# Installer media is mounted, never inspected or cloned into the system disk.
{
	# Missing cloud-init tools and DHCP must not prevent
	# manual guest installation.
	my $iso_options = { %$options,
			    cloud_init_error => 'No cloud-init tools',
			    images =>
				    [ { id => 'c' x 32, name => 'Installer',
					format => 'iso',
					virtual_size => 8 * 1024**3,
					pool => 'source-pool',
					volume => 'setup.iso',
					volume_key => '/images/setup.iso',
					volume_path => '/images/setup.iso' } ],
			    networks => [ { %{$options->{'networks'}->[0]},
				   dhcp => 0 } ] };
	# Hidden cloud fields are deliberately stale and the ISO
	# exceeds the disk size.
	my $iso_input = { %$input, install_source => 'iso', image => 'c' x 32,
			  disk_gib => 2, auth_type => 'password',
			  username => '',
			  ssh_keys => '',
			  hostname => '', address_mode => 'static',
			  ipv4 => 'ignored' };
	no warnings 'redefine';
	# inspect_custom_image(self, image) must never parse
	# installer media as a disk.
	local *Cloudmin::VMs::inspect_custom_image =
		sub { die 'ISO inspection attempted'; };
	my $install = $service->prepare($iso_input, $iso_options);
	is($service->prepare({ %$iso_input, require_fqdn => 1 },
			     $iso_options)->{'hostname'}, '',
	   'ISO installers configure their own hostname even when the template requires one');
	is($install->{'address_mode'}, 'manual',
	   'installer configures guest networking');
	is($install->{'ipv4'}, '', 'hidden static values are discarded');
	is($install->{'username'}, '', 'installer needs no cloud account');
	ok(!exists($install->{'password_hash'}),
	   'installer needs no password hash');
	is($install->{'disk_gib'}, 2,
	   'empty disk minimum is independent of ISO size');
	is_deeply($service->prepare($install, $iso_options), $install,
		  'installer request remains stable during worker preflight');
	# Reject mismatched sources and undersized disks despite
	# skipping inspection.
	for my $bad ( { install_source => 'other' },
		      { install_source => 'cloud' },
		      { disk_gib => .5 } ) {
		ok(!eval { $service->prepare({ %$iso_input, %$bad },
					     $iso_options); 1 },
		   'invalid installer settings are refused');
		}
	ok(!eval { $service->prepare({ %$input, install_source => 'iso' },
				     $options); 1 },
	   'cloud disk cannot masquerade as installer media');
	# Both native machine families must boot the shared ISO
	# before the empty disk.
	for my $arch ( 'aarch64', 'x86_64' ) {
		my $xml =
			Cloudmin::VMs::domain_xml({ %$install,
						    architecture => $arch,
						    machine => $arch eq 'aarch64'
							    ? 'virt'
							    : 'q35' },
						  '11111111-2222-4333-8444-555555555555',
						  'b' x 32,
						  '/images/system.qcow2', undef,
						  'fixture');
		my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
		is($doc->findvalue('/domain/os/boot[1]/@dev'), 'cdrom',
		   "$arch boots installer first");
		is($doc->findvalue('/domain/os/boot[2]/@dev'), 'hd',
		   'system disk is the fallback');
		# Neither architecture should receive the cloud-init
		# seed normally at vdb.
		is(0 + $doc->findvalue('count(/domain/devices/disk)'), 2,
		   'only system disk and CD/DVD drive');
		is(
			$doc->findvalue(
				'/domain/devices/disk[@device="cdrom"]/source/@file'),
			'/images/setup.iso',
			'drive references the imported ISO');
		ok(
			$doc->exists(
				'/domain/devices/disk[@device="cdrom"]/readonly'),
			'ISO is read-only');
		ok(!$doc->exists('/domain/devices/disk[target/@dev="vdb"]'),
		   'no cloud-init disk');
		}
	}

# Libvirt gets escaped XML, a private console and two independent disk paths.
my $xml =
	Cloudmin::VMs::domain_xml({ %$r, description => '<script> & test',
				    template => 'a' x 32 },
				  '11111111-2222-4333-8444-555555555555',
				  'b' x 32,
				  '/images/a&b.qcow2',
				  '/images/seed.iso', 'fixture');
like($xml, qr/&lt;script&gt; &amp; test/, 'description is XML-escaped');
like($xml, qr/a&amp;b\.qcow2/, 'disk paths are XML-escaped');
like($xml, qr/<readonly\/>/, 'cloud-init media is read-only');
like($xml, qr/<loader stateless="no"\/>/,
     'UEFI requires persistent variables instead of stateless firmware');
like($xml, qr/listen="127\.0\.0\.1"/,
     'console never listens on a public interface');
like($xml, qr/<cloudmin:job>/,
     'domain carries its creation job ownership marker');
is(Cloudmin::Libvirt::extract_metadata($xml)->{'template'}, 'a' x 32,
   'domain retains its template ID for usage checks after job history changes');
unlike($xml, qr{/images/base\.qcow2},
       'domain never boots directly from the reusable image');
# The virt board needs USB input devices for its console; PC types have PS/2.
like($xml, qr{<input type="keyboard" bus="usb"/>},
     'ARM64 guests get a USB keyboard for the console');
like($xml, qr{<controller type="usb" model="qemu-xhci"},
     'ARM64 guests get a USB controller');
like($xml, qr{<gic/>},
     'GIC version follows the host instead of a fixed version');
my $pc = Cloudmin::VMs::domain_xml({ %$r, architecture => 'x86_64',
				     machine => 'q35' },
				   '11111111-2222-4333-8444-555555555555',
				   'b' x 32, '/images/disk.qcow2',
				   '/images/seed.iso', 'fixture');
unlike($pc, qr{bus="usb"},
       'PC guests rely on their built-in PS/2 input devices');
like($pc, qr{<apic/>}, 'PC guests use the x86 feature set');
like($pc, qr/<loader stateless="no"\/>/,
     'PC UEFI guests also require persistent variables');
my $bios = Cloudmin::VMs::domain_xml({ %$r, architecture => 'x86_64',
				       machine => 'q35', firmware => 'bios' },
				     '11111111-2222-4333-8444-555555555555',
				     'b' x 32, '/images/disk.qcow2',
				     '/images/seed.iso', 'fixture');
unlike($bios, qr/<loader|<firmware|firmware='efi'/,
       'BIOS guests do not request UEFI or persistent variables');
# Headroom reserves slots without increasing the initial allocation.
my $doc = Cloudmin::Libvirt::parse_xml_document($pc);
is(0 + $doc->findvalue('/domain/vcpu'), 4,
   'CPU ceiling doubles the requested count within host capacity');
is(0 + $doc->findvalue('/domain/vcpu/@current'), 2,
   'initial CPU count remains unchanged');
is(0 + $doc->findvalue('/domain/memory'), 1024,
   'memory allocation remains unchanged');
is(
	scalar(
		$doc->findnodes(
			'/domain/devices/controller[@model="pcie-root-port"]')->size()), 16,
	'creation reserves PCIe ports for initial and later devices');
ok($doc->findnodes('/domain/devices/disk[@device="cdrom"]/readonly'),
   'rescue drive is read-only');
ok(!$doc->findnodes('/domain/devices/disk[@device="cdrom"]/source'),
   'rescue drive starts empty');
# Applying expansion to an already prepared definition must be idempotent.
Cloudmin::VMs::add_hardware_headroom($doc, 4);
is($doc->findnodes('/domain/devices/disk[@device="cdrom"]')->size(), 1,
   'repeated expansion keeps one rescue drive');
is(
	$doc->findnodes(
		'/domain/devices/controller[@model="pcie-root-port"]')->size(),
	16,
	'repeated expansion does not duplicate ports');
done_testing();
