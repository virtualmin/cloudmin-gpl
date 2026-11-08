use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
no warnings 'once';
use File::Path qw(make_path);
require "$Bin/../lib/Cloudmin/TPM.pm";
require "$Bin/../lib/Cloudmin/Clones.pm";

{
	package TPMDomain;

	# get_uuid_string(self) identifies the fixture's
	# managed state directory.

	sub get_uuid_string
	{
	$_[0]->{'uuid'}
	}

	# get_xml_description(self, flags) models live XML and saved XML (flag
	# 2).

	sub get_xml_description
	{
	$_[1] == 2 ? $_[0]->{'xml'} : ($_[0]->{'live_xml'} || $_[0]->{'xml'})
	}

	# is_persistent(self) controls whether the fixture
	# has a saved definition.

	sub is_persistent
	{
	!$_[0]->{'transient'}
	}

	# is_active(self) lets tests model a source restarted after validation.

	sub is_active
	{
	$_[0]->{'active'} || 0
	}
	package TPMAdapter;

	# uri(self) supplies the local system URI required
	# by TPM storage checks.

	sub uri
	{
	'qemu:///system'
	}

	# connect(self) keeps domain enumeration inside this fixture adapter.

	sub connect
	{
	$_[0]
	}

	# list_all_domains(self) exposes fixture guests for shared-state checks.

	sub list_all_domains
	{
	@{$_[0]->{'domains'} || [ ]}
	}

	# find_domain(self, uuid) locates an owner before
	# rollback removes state.

	sub find_domain
	{
	my ($self, $uuid) = @_;
	return (grep { $_->get_uuid_string() eq $uuid }
		$self->list_all_domains())[0]
	}
	}
# Redirect all state operations into a private, automatically removed directory.
my $directory = abs_path(tempdir(CLEANUP => 1));
local $Cloudmin::TPM::DIRECTORY = "$directory/swtpm";
my $uuid = '11111111-1111-4111-8111-111111111111';
my $dest = '22222222-2222-4222-8222-222222222222';
my $id = 'a' x 32;
my $path = Cloudmin::TPM::path($uuid);
make_path($path);

# state(bytes) changes only the private fixture's permanent TPM state.

sub state
{
open(my $fh, '>', "$path/tpm2-00.permall") or die $!;
print($fh $_[0]); close($fh) or die $!;
}
# Resolve a valid source before testing rejection and copying paths.
state ('sealed secret fixture');
my $xml =
	'<domain><devices><tpm model="tpm-crb"><backend type="emulator" version="2.0"/></tpm></devices></domain>';
my $domain = bless({ uuid => $uuid, xml => $xml }, 'TPMDomain');
my $adapter = bless({ domains => [ $domain ] }, 'TPMAdapter');
my $doc = Cloudmin::Libvirt::parse_xml_document($xml);
my $source = Cloudmin::TPM::source($adapter, $domain, $doc);
is($source->{'path'}, $path, 'default emulator state resolved by UUID');
# Source validation must refuse unsupported TPMs without copying any state.
for my $case (
	[ 'type="emulator" version="2.0"', 'type="passthrough" version="2.0"',
	  qr/TPM 2.0 emulator/ ],
	[ 'version="2.0"', 'version="1.2"', qr/TPM 2.0 emulator/ ],
	[ '/>', '><encryption secret="fixture"/></backend>',
	  qr/encrypted or custom/ ],
) {
	my $invalid = $xml; $invalid =~ s/\Q$case->[0]\E/$case->[1]/;
	eval { Cloudmin::TPM::source($adapter, $domain,
				     Cloudmin::Libvirt::parse_xml_document($invalid)); };
	like($@, $case->[2], 'unsupported TPM rejected');
	}
# Custom paths must not redirect copying outside libvirt's managed directory.
my $custom =
	$xml; $custom =~ s{/>}{><source type="dir" path="/other"/></backend>};
eval { Cloudmin::TPM::source($adapter, $domain,
			     Cloudmin::Libvirt::parse_xml_document($custom)); };
like($@, qr/encrypted or custom/, 'custom state directory refused');
# An explicit reference from another domain makes even a managed path unsafe.
my $other =
	bless({ uuid => $dest, xml =>
				       '<domain><devices><tpm><backend><source type="dir" path="'.
				       $path.
				       '"/></backend></tpm></devices></domain>' },
	      'TPMDomain');
push(@{$adapter->{'domains'}}, $other);
eval { Cloudmin::TPM::source($adapter, $domain, $doc); };
like($@, qr/shared/, 'another domain cannot share source TPM state');
# A running guest can retain a path already removed from its saved definition.
$other->{'live_xml'} = $other->{'xml'}; $other->{'xml'} = $xml;
eval { Cloudmin::TPM::source($adapter, $domain, $doc); };
like($@, qr/shared/, 'live-only TPM reference prevents copying');
# Transient guests must be checked without requesting a saved definition.
$other->{'transient'} = 1;
eval { Cloudmin::TPM::source($adapter, $domain, $doc); };
like($@, qr/shared/, 'transient TPM reference prevents copying');
pop(@{$adapter->{'domains'}});
# Empty permanent state must not silently become a fresh TPM in the clone.
state ('');
eval { Cloudmin::TPM::source($adapter, $domain, $doc); };
like($@, qr/empty/, 'empty permanent state refused');
# Reject a linked state file without reading its target.
unlink("$path/tpm2-00.permall");
symlink("$directory/unrelated", "$path/tpm2-00.permall") or die $!;
eval { Cloudmin::TPM::source($adapter, $domain, $doc); };
like($@, qr/Cannot read/, 'symlink state refused');
unlink("$path/tpm2-00.permall"); state ('sealed secret fixture');
# Live state must never be copied, even if the request was queued while off.
$domain->{'active'} = 1;
eval { Cloudmin::TPM::copy($source, $dest, $id, $domain,
			   sub { die 'journal reached'; }); };
like($@, qr/Shut down/, 'live TPM copy refused before journalling');
$domain->{'active'} = 0;
{
	no warnings 'redefine';
	# free_space(path) supplies ample capacity without
	# querying host storage.
	local *Cloudmin::Worker::free_space = sub { 1024**3 };
	# Allocation must be journalled and usable even with the caller's umask
	# 077.
	my $journalled = 0;
	my $mask = umask(0077);
	my $copy =
		Cloudmin::TPM::copy($source, $dest, $id, $domain,
				    sub { $journalled = 1 });
	umask($mask);
	ok($journalled, 'allocation journalled');
	is((stat(File::Basename::dirname($copy)))[2] & 0777, 0711,
	   'swtpm can traverse the clone directory under a private umask');
	# Preserve bytes in an independent inode with private permissions.
	is(Cloudmin::TPM::read_state("$copy/tpm2-00.permall"),
	   'sealed secret fixture', 'TPM state bytes preserved');
	is((stat("$copy/tpm2-00.permall"))[2] & 0777, 0600,
	   'TPM copy remains private');
	isnt((stat("$copy/tpm2-00.permall"))[1],
	     (stat("$path/tpm2-00.permall"))[1], 'copy has its own inode');
	# Neither repeated allocation nor another job may
	# overwrite or remove state.
	eval { Cloudmin::TPM::copy($source, $dest, $id, $domain, sub { }); };
	like($@, qr/already exists/, 'existing state never overwritten');
	eval { Cloudmin::TPM::remove_copy($adapter, $dest, 'b' x 32); };
	like($@, qr/ownership changed/,
	     'foreign job cannot remove copied state');
	# The owning job can roll back repeatedly without changing source state.
	Cloudmin::TPM::remove_copy($adapter, $dest, $id);
	ok(!-d $copy, 'pre-define rollback removes copied state');
	is(Cloudmin::TPM::read_state("$path/tpm2-00.permall"),
	   'sealed secret fixture', 'rollback leaves source intact');
	ok(Cloudmin::TPM::remove_copy($adapter, $dest, $id),
	   'rollback is idempotent');
	# Lost source state leaves a partial allocation that
	# rollback can remove.
	eval { Cloudmin::TPM::copy($source, $dest, $id, $domain,
				   sub { unlink("$path/tpm2-00.permall") }); };
	like($@, qr/Cannot read/, 'lost source state fails after allocation');
	ok(Cloudmin::TPM::remove_copy($adapter, $dest, $id),
	   'partial allocation rolls back');
	}
# Rewrite the clone's ownership while keeping its TPM model, banks and profile.
my $r =
	{ name => 'copy', uuid => $dest, memory_mib => 1024, cpus => 1, mac =>
										'52:54:00:11:22:33',
	  source_xml =>
		  '<domain><name>source</name><uuid>'.$uuid.
		  '</uuid><memory>1024</memory><vcpu>1</vcpu><os><type>hvm</type></os><devices><tpm model="tpm-crb"><backend type="emulator" version="2.0" persistent_state="yes"><source type="dir" path="'.$path.'"/><active_pcr_banks><sha256/></active_pcr_banks><profile name="default-v1"/></backend></tpm></devices></domain>' };
my $copydoc =
	Cloudmin::Libvirt::parse_xml_document(Cloudmin::Clones::domain_xml($r,
									   $id,
									   [ ]));
is($copydoc->findvalue('/domain/devices/tpm/@model'), 'tpm-crb',
   'TPM model retained');
ok($copydoc->exists('/domain/devices/tpm/backend/active_pcr_banks/sha256'),
   'PCR banks retained');
is($copydoc->findvalue('/domain/devices/tpm/backend/profile/@name'),
   'default-v1', 'TPM profile retained');
ok(!$copydoc->exists('/domain/devices/tpm/backend/source'),
   'source state path not reused');
# Clone deletion must discard state even when the source requested retention.
is($copydoc->findvalue('/domain/devices/tpm/backend/@persistent_state'), 'no',
   'libvirt removes clone state on undefine');
done_testing();
