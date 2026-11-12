use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use Digest::SHA qw(sha256_hex sha512_hex);
use POSIX ();
require "$Bin/../lib/Cloudmin/WorkerTasks.pm";

# Root callers verify the production guard, then drop privilege for this test.
if ($< == 0 || $> == 0) {
	eval { Cloudmin::WorkerTasks::run({ task => 'root-test' }, sub { }); };
	like($@, qr/Image processing must run without root privileges/,
	     'worker dispatch rejects root before handling a request');
	my ($uid, $gid) = (getpwnam('nobody'))[2, 3];
	BAIL_OUT('Root worker tests need an unprivileged nobody account')
		if (!defined($uid) || !defined($gid) || $uid <= 0 || $gid <= 0);
	# Clear supplementary groups before permanently dropping both user IDs.
	$) = "$gid $gid";
	POSIX::setgid($gid) == 0 ||
		BAIL_OUT("Cannot drop test group privileges: $!");
	POSIX::setuid($uid) == 0 ||
		BAIL_OUT("Cannot drop test user privileges: $!");
	my @groups = split(/\s+/, $));
	BAIL_OUT('Worker test retained privileged credentials')
		if ($< != $uid || $> != $uid || $( != $gid ||
		    grep { $_ != $gid } @groups);
	# A root-owned source checkout may no longer be
	# accessible after the drop.
	chdir('/tmp') || BAIL_OUT("Cannot enter temporary directory: $!");
	}

# Only disposable files and mocked external tools are used on the workstation.
my $previous = getcwd();
my $tmp = tempdir(CLEANUP => 1);
chdir($tmp) || die $!;
my $work = getcwd();
my $data = "fixture disk bytes\0\n";
my @events;
my $emit = sub { push(@events, $_[0]); };
my $request = { format => 'qcow2', limit => 1024, sha256 => sha256_hex($data) };
# Downloads receive only the selected transport settings, scoped to this task.
{
	no warnings qw(redefine once);
	local %WebminCore::gconfig = ( fixture => 'controller' );
	local *Cloudmin::HTTP::probe = sub {
		is_deeply(\%WebminCore::gconfig,
			  { http_proxy => 'proxy.example:3128',
			    proxy_user => 'fixture-user',
			    proxy_pass => 'fixture-password' },
			  'worker receives proxy settings without unrelated Webmin configuration');
		return 2048;
		};
	is(Cloudmin::WorkerTasks::run({ task => 'size', url =>
								'https://example.test/disk',
					proxy => { http_proxy => 'proxy.example:3128',
						   proxy_user => 'fixture-user',
						   proxy_pass => 'fixture-password',
						   ignored => 'unrelated' } },
				      $emit)->{bytes},
	   2048, 'proxy settings reach the actual worker dispatch path');
	is_deeply(\%WebminCore::gconfig, { fixture => 'controller' },
		  'worker transport settings do not escape their scope');
	}
{
	no warnings 'redefine';
	local *Cloudmin::WorkerTasks::command = sub {
		is_deeply([ @_ ],
			  [ '/usr/bin/qemu-img', 'info', '--output=json', '-f',
			    'qcow2', 'image' ],
			  'disk tool gets fixed arguments and an explicit format');
		return WebminCore::convert_to_json({ 'virtual-size' => 32768 }, 0, 1);
		};
	Cloudmin::WorkerTasks::write_file('image', $data);
	my $r = Cloudmin::WorkerTasks::image($request, $emit);
	is($r->{'checksum_digest'}, sha256_hex($data),
	   'supplied SHA-256 is computed over the image bytes');
	is($r->{'verified'}, 'sha256',
	   'successful verification names its algorithm');
	is($r->{'bytes'}, length($data), 'result retains the exact file size');
	ok(-f 'output' && !-e 'image',
	   'successful processing produces the fixed output file');
	unlink('output');
	# A large controller budget is valid even when the actual image is tiny.
	Cloudmin::WorkerTasks::write_file('image', $data);
	$r =
		Cloudmin::WorkerTasks::image({ %$request,
					       limit => 32 * 1024**3 },
					     $emit);
	is($r->{'bytes'}, length($data),
	   'worker accepts an import budget above 8 GiB');
	unlink('output');

	# Vendor downloads use absolute worker paths required
	# by Webmin's file API.
	local *Cloudmin::HTTP::download = sub {
		my ($url, $dest, $callback) = @_;
		# Supply a matching publisher manifest through the
		# real checksum parser.
		if ($url =~ /SUMS$/) {
			$$dest = sha512_hex($data)."  disk.qcow2\n";
			$callback->(3, length($$dest));
			}
		# Supply image bytes and progress events
		# separately from the manifest.
		else {
			is($dest, "$work/image",
			   'download destination is inside the private worker directory');
			$callback->(1, 0);
			$callback->(2, length($data));
			Cloudmin::WorkerTasks::write_file($dest, $data);
			$callback->(3, length($data));
			}
		};
	my $vendor = { %$request, sha256 => '',
		       url => 'https://example.test/disk.qcow2',
		       checksum_url => 'https://example.test/SUMS',
		       checksum_algorithm => 'sha512' };
	$r = Cloudmin::WorkerTasks::image($vendor, $emit);
	is($r->{'checksum_digest'}, sha512_hex($data),
	   'vendor SHA-512 is computed and checked');
	is($r->{'verified'}, 'sha512', 'vendor verification retains SHA-512');
	ok(grep({ ($_->{'phase'} || '') eq 'downloading' } @events),
	   'download reports numeric progress');
	unlink('output');
	for my $mode ( 2, 3 ) {
		local *Cloudmin::HTTP::download = sub { $_[2]->($mode, 1025); };
		ok(!eval { Cloudmin::WorkerTasks::image($vendor, $emit); 1 },
		   "oversized download is rejected from callback $mode");
		like($@, qr/exceeds.*staging limit/,
		     'size limit explains the failure');
		}
	local *Cloudmin::HTTP::download = sub {
		my ($url, $dest, $callback) = @_;
		# Announce an oversized manifest to exercise the
		# bounded-download guard.
		if ($url =~ /SUMS$/) { $callback->(3, 1024**2 + 1); }
		# Keep the image itself valid so only the manifest
		# limit causes failure.
		else { Cloudmin::WorkerTasks::write_file($dest, $data); }
		};
	ok(!eval { Cloudmin::WorkerTasks::image($vendor, $emit); 1 },
	   'oversized vendor manifest is rejected');
	like($@, qr/checksum file is too large/,
	     'manifest failure is explicit');
	ok(!eval { Cloudmin::WorkerTasks::image({ %$request,
						  sha256 => '0' x 64 },
						$emit); 1 },
	   'wrong checksum is rejected before disk parsing');
	like($@, qr/checksum mismatch/, 'wrong checksum explains the failure');

	# EOF alone cannot distinguish a complete lengthless
	# response from a broken one.
	for my $case ( [ 0, '', 0 ], [ 0, sha256_hex($data), 1 ],
		       [ 0, '0' x 64, 0 ], [ length($data), '', 1 ] ) {
		my ($length, $digest, $expected) = @$case;
		local *Cloudmin::HTTP::download = sub {
			my ($url, $dest, $callback) = @_;
			# A redirect's length must not stand in for the
			# final response length.
			$callback->(1, 1); $callback->(2, 500);
			$callback->(1, 0); $callback->(2, $length ||
						       undef);
			Cloudmin::WorkerTasks::write_file($dest, $data);
			$callback->(3, length($data));
			};
		my $ok = eval { Cloudmin::WorkerTasks::image({ %$request,
							       url => 'https://example.test/disk.qcow2',
							       sha256 => $digest },
							     $emit); 1 };
		is($ok ? 1 : 0, $expected,
		   'lengthless downloads require a matching checksum');
		like($@, qr/file size|checksum mismatch/,
		     'unsafe download explains why it was refused')
			if (!$expected);
		unlink('output', 'image');
		}
	}

# ISO bytes retain checksum protection without invoking any disk parser.
{
	no warnings 'redefine';
	# command(arguments...) fails if the ISO path invokes a disk utility.
	local *Cloudmin::WorkerTasks::command =
		sub { die 'ISO parser invoked'; };
	# Exercise optional verification, a correct digest and
	# a mismatched digest.
	for my $checksum ( '', sha256_hex($data), '0' x 64 ) {
		Cloudmin::WorkerTasks::write_file('image', $data);
		my $result = eval { Cloudmin::WorkerTasks::image({ %$request,
								   format => 'iso', sha256 => $checksum }, $emit) };
		if ($checksum eq '0' x 64) {
			# A checksum failure must not publish the staged
			# bytes as import output.
			like($@, qr/checksum mismatch/,
			     'ISO with wrong checksum is rejected');
			ok(!-e 'output', 'rejected ISO is not published');
			}
		else {
			# Accepted ISOs retain their type, capacity and
			# verification result.
			is($result->{'format'}, 'iso', 'ISO type is retained');
			is($result->{'virtual-size'}, length($data),
			   'ISO capacity equals file size');
			is($result->{'verified'}, $checksum ? 'sha256' : '',
			   'ISO verification is recorded');
			}
		unlink('image', 'output');
		}
	}

# Reject disk features that could refer to files outside the imported image.
for my $info (
	{ 'virtual-size' => 32768, 'backing-filename' => '/etc/shadow' },
	{ 'virtual-size' => 32768, encrypted => 1 },
	{ 'virtual-size' => 32768,
	  'format-specific' => { data => { 'data-file' => '/etc/shadow' } } },
	{ 'virtual-size' => 0 }, { 'virtual-size' => 17 * 1024**4 },
) {
	no warnings 'redefine';
	local *Cloudmin::WorkerTasks::command = sub { WebminCore::convert_to_json($info, 0, 1) };
	ok(!eval { Cloudmin::WorkerTasks::disk_info('qcow2'); 1 },
	   'unsafe disk metadata is rejected');
	like($@, $info->{'virtual-size'} &&
	     $info->{'virtual-size'} <= 16 * 1024**4
		     ? qr/backing files, external data files or encryption/
		     : qr/Invalid image size/,
	     'the intended metadata validation rejects this fixture');
	}
ok(!eval { Cloudmin::WorkerTasks::disk_info('auto'); 1 },
   'format autodetection is forbidden');
# Managed conversion layers use private names and never rewrite source files.
{
	no warnings 'redefine';
	my @commands;
	local *Cloudmin::WorkerTasks::command = sub {
		push(@commands, [ @_ ]);
		return WebminCore::convert_to_json({ 'virtual-size' => 4096 }, 0, 1)
			if ($_[1] eq 'info');
		return '';
		};
	my $conversion =
		{ task => 'convert', format => 'qcow2', output_format => 'raw',
		  limit => 8192, capacity => 4096, layers => [
			  { name => 'image', format => 'qcow2' },
			  { name => 'layer1', format => 'raw' } ] };
	is(Cloudmin::WorkerTasks::run($conversion, $emit)->{'format'}, 'raw',
	   'managed chain converts to an independent raw disk');
	my ($rebase) = grep { $_->[1] eq 'rebase' } @commands;
	is_deeply($rebase, [ '/usr/bin/qemu-img', 'rebase', '-u', '-f', 'qcow2',
			     '-b', 'layer1', '-F', 'raw', 'image' ],
		  'only the private top layer is relinked');
	local $conversion->{layers}->[1]->{name} = '/etc/shadow';
	ok(!eval { Cloudmin::WorkerTasks::run($conversion, $emit); 1 },
	   'conversion refuses a host path as a staged layer name');
	like($@, qr/Invalid conversion layer/,
	     'bad layer name has a clear error');
	}

chdir($previous) || die $!;
done_testing();
