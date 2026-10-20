use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use Test::More;
use File::Temp qw(tempdir);
require "$Bin/../lib/Cloudmin/Images.pm";

# No system queries or writes outside a private temporary directory are needed.
my $gib = 1024**3;
my $reserve = 256 * 1024**2;
for my $value (undef, '', '0') {
	is(Cloudmin::Images::import_limit_bytes($value), 0,
		'missing or zero configuration defaults to available space');
}
is(Cloudmin::Images::import_limit_bytes(32), 32 * $gib,
	'configured GiB are converted to bytes without the former 8 GiB cap');
for my $value (-1, '1.5', 'infinity', '10 GiB', "32\n", {}, '8388608') {
	ok(!eval { Cloudmin::Images::import_limit_bytes($value); 1 },
		'invalid configuration cannot disable the limit');
}

my $dir = tempdir(CLEANUP => 1);
my $space = 64 * $gib;
my $pool_space = 64 * $gib;
my $jobs = Cloudmin::Images->new(directory => $dir,
	disk_free => sub { $space });
is($jobs->staging_limit(), $space - $reserve,
	'available-space default allows images larger than 8 GiB');
$jobs->{'max_bytes'} = 32 * $gib;
is($jobs->staging_limit(), 32 * $gib, 'administrator cap can lower the budget');
$space = 2 * $gib;
is($jobs->staging_limit(), $space - $reserve, 'available space still overrides a larger cap');

{
	no warnings qw(redefine once);
	local *Cloudmin::Images::get = sub { {state => 'waiting', pool => 'fixture'} };
	local *Cloudmin::Images::import_pool = sub { bless({}, 'LimitPool') };
	local *LimitPool::get_info = sub { {available => $pool_space} };
	local *Cloudmin::Images::with_job_lock = sub { $_[3]->({state => 'waiting', pool => 'fixture'}) };
	local *Cloudmin::Images::receive_locked = sub { 1 };
	local *Cloudmin::Images::start = sub { 'accepted' };
	# Reach upload validation without receiving gigabytes or contacting libvirt.
	$space = 64 * $gib;
	is($jobs->receive('fixture', 'owner', undef, 9 * $gib), 'accepted',
		'upload above 8 GiB passes when configured and physical budgets allow it');
	$jobs->{'max_bytes'} = 8 * $gib;
	ok(!eval { $jobs->receive('fixture', 'owner', undef, 9 * $gib); 1 },
		'upload cannot bypass the configured cap');
	like($@, qr/configured maximum/, 'configured cap failure is explicit');
	$jobs->{'max_bytes'} = 0;
	$pool_space = $gib;
	ok(!eval { $jobs->receive('fixture', 'owner', undef, 2 * $gib); 1 },
		'insufficient destination space rejects upload before reading its body');
	like($@, qr/storage pool/, 'destination shortage is identified');
	$pool_space = undef;
	ok(!eval { $jobs->receive('fixture', 'owner', undef, $gib); 1 },
		'unknown destination capacity fails closed');
	$pool_space = 64 * $gib;
	$space = $gib;
	ok(!eval { $jobs->receive('fixture', 'owner', undef, 2 * $gib); 1 },
		'insufficient staging space rejects upload before reading its body');
	like($@, qr/stage this upload/, 'staging shortage is identified');
}

# Exercise Webmin's configuration parser without initializing the application.
our (%in, %text);
$text{'config_image_max_error'} = 'Invalid import limit';
$INC{'server-manager-lib.pl'} = 1;
require "$Bin/../config_info.pl";
# error(message) exposes Webmin validation failures as test exceptions.
sub error { die $_[0] }
%in = (image_max_size_def => 1, image_max_size => 'invalid');
is(parse_image_max_size(), 0, 'available-space selection ignores the unused textbox');
%in = (image_max_size_def => 0, image_max_size => ' 32 ');
is(parse_image_max_size(), 32, 'configuration saves a valid whole-GiB cap');
for my $value ('', '0', '-2', '1.5', '8388608') {
	$in{'image_max_size'} = $value;
	ok(!eval { parse_image_max_size(); 1 }, 'invalid explicit cap is not saved');
}
done_testing();
