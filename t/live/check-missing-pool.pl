#!/usr/bin/perl
# Check image removal after an actual libvirt storage pool is undefined.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
BEGIN {
	$webmin_root = abs_path("$FindBin::Bin/../../..");
	die "Disposable Linux VM as root only\n" unless $^O eq 'linux' &&
		$< == 0;
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir("$webmin_root/server-manager") || die $!;
	$0 = "$webmin_root/server-manager/check-missing-pool.pl";
	}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
require Sys::Virt;

# Keep fixture records and files separate from the user's image library.
my $work = tempdir('cloudmin-missing-pool-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $images = get_image_jobs();
$images->{'directory'} = "$work/jobs";
make_dir($images->{'directory'}, 0700, 1) || die $!;
my $conn = Sys::Virt->new(uri => 'qemu:///system');
my $name = 'cloudmin-pool-check-'.substr(Cloudmin::Images::generate_id(), 0, 12);
my $pool = $conn->define_storage_pool("<pool type='dir'><name>$name</name>".
	"<target><path>$work</path></target></pool>");
my $ok = eval {
	my $uuid = $pool->get_uuid_string();
	$pool->create();
	# Record imports while their destination exists, then remove the pool.
	my @cases = (['retained', 0], ['link', 0], ['absent', 1]);
	for my $case (@cases) {
		my $job = $images->create('fixture',
			$images->form_token('fixture'),
			{ source => 'upload', format => 'qcow2', pool => $uuid,
			  name => $case->[0] });
		@$job{qw(state volume_path)} = ('ready', "$work/$case->[0]");
		$images->save($job->{'id'}, $job);
		push(@$case, $job->{'id'});
		}
	# An undefined pool must not imply that files left on disk are gone.
	$pool->destroy();
	$pool->undefine();
	$pool = undef;
	write_file_contents("$work/retained", 'fixture image');
	symlink("$work/absent", "$work/link") || die $!;
	for my $case (@cases) {
		my ($file, $removed, $id) = @$case;
		my $result = eval { $images->remove($id); 1 };
		is($result ? 1 : 0, $removed,
			"$file uses actual libvirt missing-pool behavior");
		is($images->get($id)->{'state'},
			$removed ? 'deleted' : 'ready',
			"$file retains metadata until the file is absent");
		}
	ok(-f "$work/retained", 'existing image remains untouched');
	ok(-l "$work/link", 'dangling link remains untouched');
	1;
	};
my $error = $@;
# Never leave the fixture pool defined when an assertion setup fails.
eval { $pool->destroy() if ($pool->is_active()); $pool->undefine() } if ($pool);
die $error if (!$ok);
done_testing();
