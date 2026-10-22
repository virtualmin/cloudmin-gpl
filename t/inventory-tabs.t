use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
use File::Temp qw(tempdir);
# Load real preference and permission helpers with a temporary data directory.
our (%config, %text, %access, %in);
our $remote_user = 'fixture';
our $root_directory = $CloudminTest::webmin_root;
our $module_root_directory = "$Bin/..";
our $module_var_directory = tempdir(CLEANUP => 1);
require "$Bin/../cloudmin-access-lib.pl";
require "$Bin/../cloudmin-tab-lib.pl";
my $readonly = 0;
# is_readonly_mode() lets each case change permissions without host setup.
{ no warnings 'redefine'; *is_readonly_mode = sub { $readonly }; }

# Real file helpers exercise per-user persistence and default precedence.
is(inventory_tab('images'), 'images', 'images defaults to imported images');
is(inventory_tab('networks'), 'net_overview', 'networking defaults to overview');
is(inventory_tab('storage'), 'storage_overview', 'storage defaults to overview');
# Writing one page's choice must preserve the other pages in the same file.
save_inventory_tab('images', 'catalogue');
save_inventory_tab('storage', 'storage_volumes');
save_inventory_tab('networks', 'net_bridges');
is(inventory_tab('images'), 'catalogue', 'saved image tab reopens');
is(inventory_tab('networks'), 'net_bridges', 'saved network tab reopens');
is(inventory_tab('storage'), 'storage_volumes', 'saved storage tab reopens');
# Explicit links take precedence over the saved choice.
is(inventory_tab('images', 'add'), 'add', 'explicit link overrides memory');
is(inventory_tab('images', 'bad'), 'images', 'invalid link uses the default');
my $file = "$module_var_directory/inventory-tabs-fixture";
is((stat($file))[2] & 0777, 0600, 'preference file is private');
# Each login has an escaped filename and independent choices.
{
	local $remote_user = 'second/user';
	is(inventory_tab('images'), 'images', 'another user has separate preferences');
	save_inventory_tab('images', 'add');
	ok(-f "$module_var_directory/inventory-tabs-second%2Fuser", 'username is one escaped path component');
}
is(inventory_tab('images'), 'catalogue', 'other user cannot change this account');
# Turning memory off affects reads and writes without erasing previous choices.
{
	local $config{'images_remember'} = 0;
	is(inventory_tab('images'), 'images', 'disabled memory uses default');
	save_inventory_tab('images', 'add');
	is(inventory_tab('images', 'catalogue'), 'catalogue', 'explicit links work with memory disabled');
	is(inventory_tab_script('images', 'token'), '', 'disabled memory has no browser writer');
}
is(inventory_tab('images'), 'catalogue', 'disabled memory does not erase existing choices');
# Pages without a write token must not initialize the browser's save handler.
is(inventory_tab_script('images', ''), '', 'read-only page has no preference writer');
like(inventory_tab_script('images', 'token'), qr/data-inventory-tabs=/, 'writable page initializes memory');

# Invalid requests and revoked grants cannot alter saved preferences.
for my $input (['bad', 'catalogue'], ['images', 'storage_volumes'], ['images', "add\ninjected=1"]) {
	ok(!eval { save_inventory_tab(@$input); 1 }, 'invalid page or tab rejected');
}
# Read-only mode permits navigation reads while blocking preference writes.
$readonly = 1;
is(inventory_tab('images'), 'catalogue', 'read-only viewers can read their saved choice');
ok(!eval { save_inventory_tab('images', 'add'); 1 }, 'read-only mode rejects writes');
$readonly = 0;
# Host inventory preferences are unavailable to delegated guest administrators.
{
	local %access = (admin => 0, vms => '');
	ok(!eval { inventory_tab('images'); 1 }, 'delegated users cannot read host preferences');
	ok(!eval { save_inventory_tab('images', 'add'); 1 }, 'delegated users cannot write host preferences');
}

# Failed and nested locks preserve state and never release another caller's lock.
my $before = read_file_contents($file);
mkdir("$file.lock") or die $!;
ok(!eval { save_inventory_tab('images', 'add'); 1 }, 'lock acquisition failure is reported');
is(read_file_contents($file), $before, 'failed lock preserves all preferences');
rmdir("$file.lock") or die $!;
# A nested call must neither borrow nor release the lock held by its caller.
lock_file($file) or die 'Cannot lock fixture';
ok(!eval { save_inventory_tab('images', 'add'); 1 }, 'nested lock does not authorize a write');
ok(-f "$file.lock", 'nested request leaves original lock held');
unlock_file($file);
# Native Webmin write errors must throw and release the newly acquired lock.
rename($file, "$file.saved") or die $!;
mkdir($file) or die $!;
ok(!eval { save_inventory_tab('images', 'add'); 1 }, 'native write error is catchable');
ok(!-e "$file.lock", 'write error releases the acquired lock');
rmdir($file) or die $!;
rename("$file.saved", $file) or die $!;

# The actual endpoint rejects unsigned requests before saving any preference.
{
	package TabTokenFixture;
	# check_token(self, user, token) validates the fixture's signed requests.
	sub check_token { die "Bad token\n" if (($_[2] || '') ne 'signed'); }
}
$INC{'./server-manager-lib.pl'} = 1;
# endpoint(method, fields) captures the real CGI response with isolated inputs.
sub endpoint
{
	my ($method, $fields) = @_;
	# Supply request metadata and fields without reading workstation stdin.
	local $ENV{'REQUEST_METHOD'} = $method;
	local $ENV{'CONTENT_LENGTH'} = 64;
	local %in = %$fields;
	# Capture output and suppress expected rejection warnings.
	my ($output, $reply);
	open(my $out, '>', \$output) or die $!;
	local *STDOUT = $out;
	local $SIG{'__WARN__'} = sub { };
	no warnings qw(redefine once);
	# ReadParse() leaves the isolated request fields supplied above intact.
	local *main::ReadParse = sub { };
	# error(message) turns CGI rejection into an exception captured by do.
	local *main::error = sub { die $_[0] };
	# get_image_jobs() supplies token verification without a job store.
	local *main::get_image_jobs = sub { bless({}, 'TabTokenFixture') };
	# print_json(reply, [options...]) captures the response as a hash.
	local *main::print_json = sub { $reply = $_[0] };
	# Run the real handler and return its result or fatal rejection.
	do "$Bin/../save_inventory_tab.cgi";
	return ($reply, $@);
}
# GET and bad-token POST requests must leave the prior choice unchanged.
my %fields = (page => 'images', tab => 'add', token => 'signed');
my ($reply, $error) = endpoint('GET', \%fields);
like($error, qr/signed POST/, 'GET cannot save a preference');
($reply) = endpoint('POST', {%fields, token => 'invalid'});
is($reply->{'saved'}, 0, 'invalid token is rejected');
is(inventory_tab('images'), 'catalogue', 'unsigned requests leave saved tab alone');
# A valid signed POST saves only the current login's selected page.
($reply) = endpoint('POST', \%fields);
is($reply->{'saved'}, 1, 'signed POST saves a preference');
is(inventory_tab('images'), 'add', 'signed endpoint uses the current user');
done_testing();
