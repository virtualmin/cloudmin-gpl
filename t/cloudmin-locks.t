use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore qw(lock_file unlock_file can_lock_file test_lock is_readonly_mode
		  translate_filename);
use File::Temp qw(tempdir);
use Test::More;
our $module_root_directory = "$Bin/..";
require "$module_root_directory/server-manager-lib-funcs.pl";

# Exercise the real Webmin locking API only against this test's temporary files.
my $dir = tempdir(CLEANUP => 1);
local $main::readonly_mode_cache = 0;
local %WebminCore::gconfig = (lockmode => 0);
ok(lock_data_file("$dir/resource", 0, 0, 1), 'ordinary Webmin locking works');
is(test_lock("$dir/resource"), $$, 'the lock belongs to this process');
unlock_data_file("$dir/resource");
ok(!test_lock("$dir/resource"), 'unlock releases the actual Webmin lock');
ok(!grep($_ eq "$dir/resource.lock", @main::temporary_files),
	'unlock removes the stale exit-cleanup entry');

# Excluded paths and read-only mode must fail before writing any lock file.
for my $case ([1, '', 0], [2, "$dir/other", 0], [3, $dir, 0], [0, '', 1]) {
	local @WebminCore::gconfig{qw(lockmode lockdirs)} = @$case[0, 1];
	local $main::readonly_mode_cache = $case->[2];
	ok(!eval { lock_data_file("$dir/denied", 0, 0, 1); 1 },
		'disabled locking is rejected');
	like($@, $case->[2] ? qr/disabled in read-only mode/
		: qr/needs Webmin file locking/,
		'the permission or configuration failure is explained');
	ok(!-e "$dir/denied.lock", 'refused locking leaves no file');
	}
done_testing();
