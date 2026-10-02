use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Test::More;
require "$Bin/../lib/Cloudmin/Jobs.pm";
require "$Bin/../lib/Cloudmin/VMs.pm";
plan skip_all => 'DBI and DBD::SQLite are required'
	if (!eval { Cloudmin::Jobs::dependencies(); 1 });

{
	package CatalogueFixture;
	our @ISA = ('Cloudmin::VMs');
	# options(self) exposes only completed, present source volumes.
	sub options { return { images => [grep { $_->{'state'} eq 'ready' }
		values %{$_[0]->{'images'}->{'records'}}] }; }
	package DownloadFixture;
	# list(self, [owner], [active]) supplies an existing shared download.
	sub list { return [grep { $_->{'state'} eq 'queued' } values %{$_[0]->{'records'}}]; }
	# form_token(self, owner) supplies an unused fixture token.
	sub form_token { return 'fixture'; }
	# create(self, owner, token, request) counts newly allocated imports.
	sub create {
		my ($self, $owner, $token, $request) = @_;
		$self->{'created'}++;
		return $self->{'records'}->{'a'x32} = { %$request, id => 'a'x32,
			state => 'queued', bytes => 0, total => 100 };
	}
	# get(self, id) returns the import's latest persisted state.
	sub get { return $_[0]->{'records'}->{$_[1]}; }
	# start(self, id) completes or fails without invoking a network worker.
	sub start {
		my ($self, $id) = @_;
		$self->{'started'}++;
		$self->{'before_start'}->() if ($self->{'before_start'});
		$self->{'records'}->{$id} = { %{$self->get($id)},
			state => $self->{'fail'} ? 'failed' : 'ready', error => 'Checksum mismatch',
			bytes => 100, volume => 'base.qcow2', volume_key => '/pool/base.qcow2',
			volume_path => '/pool/base.qcow2', virtual_size => 10*1024**3 };
	}
}

my $root = tempdir(CLEANUP => 1);
my $asset = {source => 'download', slug => 'rocky-linux-10', pool => 'pool',
	name => 'Rocky Linux 10', url => 'https://example.test/rocky.qcow2',
	format => 'qcow2', architecture => 'aarch64', checksum_algorithm => 'sha256'};

# fixture(name) creates private jobs and observable locks without host changes.
sub fixture
{
my ($name) = @_;
my %locks;
my $jobs = Cloudmin::Jobs->new(directory => "$root/$name",
	lock_file => sub { die 'nested lock' if ($locks{$_[0]}); $locks{$_[0]} = 1 },
	unlock_file => sub { delete($locks{$_[0]}); },
	test_lock => sub { $locks{$_[0]} ? $$ : 0 }, log => sub { });
my $images = bless({records => {}, created => 0, started => 0}, 'DownloadFixture');
my $service = CatalogueFixture->new(jobs => $jobs, images => $images);
$jobs->submit('b'x32, 'owner', 'vm:fixture', {
	name => 'fixture', image => 'catalogue:rocky-linux-10', image_download => $asset,
	password_hash => 'fixture-only', virtualmin_key => 'fixture-only' });
return ($jobs, $images, $service, \%locks);
}

# Download preparation holds the guest reservation without blocking disk work.
my ($jobs, $images, $service, $locks) = fixture('download');
$images->{'before_start'} = sub {
	ok($jobs->busy('b'x32), 'creation holds its own worker reservation while downloading');
	ok(!$locks->{"$root/download/vm-work"}, 'download does not hold the disk-work lock');
};
ok($jobs->run_worker('b'x32, sub {
	ok($locks->{"$root/download/vm-work"}, 'disk work is serialized after the download');
	return 1;
}, sub { $service->ensure_image('b'x32); }), 'download preparation succeeds');
is($images->{'created'}, 1, 'one import is allocated');
my $job = $jobs->get('b'x32);
is($job->{'request'}->{'source_image'}->{'volume_key'}, '/pool/base.qcow2', 'resolved volume is persisted');
is($job->{'request'}->{'image'}, 'catalogue:rocky-linux-10', 'original selection remains available for retries');
is($job->{'image_progress'}->{'bytes'}, 100, 'download progress is available to the controller');
is($job->{'events'}->[0]->{'state'}, 'done', 'image phase completes before disk work');
$service->ensure_image('b'x32);
is($images->{'created'}, 1, 'reattaching reuses the completed cache');
is(scalar(@{$jobs->get('b'x32)->{'events'}}), 1, 'reattaching does not duplicate the phase');

# Concurrent creations can share an import instead of allocating another copy.
($jobs, $images, $service) = fixture('shared');
$images->{'records'}->{'c'x32} = {%$asset, id => 'c'x32, state => 'queued'};
$service->ensure_image('b'x32);
is($images->{'created'}, 0, 'another creation joins an existing import');
is($jobs->get('b'x32)->{'image_job'}, 'c'x32, 'shared import identity is recorded');

# Verification failures release the guest name and clear provisioning secrets.
($jobs, $images, $service) = fixture('failed');
$images->{'fail'} = 1;
my $allocated = 0;
ok(!$jobs->run_worker('b'x32, sub { $allocated++ }, sub { $service->ensure_image('b'x32); }),
	'failed download fails creation');
is($allocated, 0, 'no guest resource is allocated after download failure');
$job = $jobs->get('b'x32);
is($job->{'state'}, 'failed', 'failure releases the name reservation');
like($job->{'error'}, qr/Checksum mismatch/, 'verification failure is preserved');
ok(!$job->{'request'}->{'password_hash'} && !$job->{'request'}->{'virtualmin_key'},
	'failed preparation clears provisioning credentials');

# Cancelling one creation must leave the shared source available for others.
($jobs, $images, $service) = fixture('cancelled');
$images->{'before_start'} = sub { $jobs->update('b'x32, sub { $_[0]->{'cancel'} = 1 }); };
$jobs->run_worker('b'x32, sub { $allocated++ }, sub { $service->ensure_image('b'x32); });
is($jobs->get('b'x32)->{'state'}, 'cancelled', 'cancellation before disk work releases the creation');
is($allocated, 0, 'cancelled creation does not allocate guest resources');
is($images->get('a'x32)->{'state'}, 'ready', 'cancellation preserves the reusable shared image');

done_testing();
