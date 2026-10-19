use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use File::Temp qw(tempdir);
use File::Find qw(find);
use Test::More;
our $module_root_directory = "$Bin/..";
require "$module_root_directory/server-manager-lib-funcs.pl";
require "$module_root_directory/cloudmin-webmin-lib.pl";

# Load the native save/delete bodies without initializing the workstation's Webmin.
open(my $source, '<', "$CloudminTest::webmin_root/servers/servers-lib.pl") or die $!;
my $native = do { local $/; <$source> };
close($source);
for my $name (qw(save_server delete_server)) {
	my ($body) = $native =~ /^(sub \Q$name\E\n\{\n.*?^\})/ms;
	die "Missing native $name\n" if (!$body);
	eval "package servers; use WebminCore; our \$module_config_directory; $body; 1" or die $@;
	}

# All native filesystem and logging operations stay inside this temporary directory.
my $dir = tempdir(CLEANUP => 1);
local $servers::module_config_directory = $dir;
local $main::readonly_mode_cache = 0;
local $WebminCore::var_directory;
my $record = {id => '123456789012345', host => 'fixture.invalid', ip => '192.0.2.1', port => 10000,
	user => 'fixture', pass => 'synthetic-login-secret'};
my $file = "$dir/$record->{'id'}.serv";
my $backquote = \&WebminCore::backquote_command;
no warnings 'redefine';
# backquote_command(command, ...) delegates to the native helper after making
# this fixture's diff scratch file readable by an unprivileged test process.
local *WebminCore::backquote_command = sub {
	# Native code creates this scratch file for root, without owner read bits.
	chmod(0600, "$file.webminorig") if ($> != 0 && -f "$file.webminorig");
	return $backquote->(@_);
	};

# Exercise both forms of Actions Log storage separately and together.
for my $logging ([1, 0], [0, 1], [1, 1]) {
	local %WebminCore::gconfig = (lockmode => 0, log => 1,
		logfiles => $logging->[0], logfullfiles => $logging->[1]);
	local @main::locked_file_diff;
	local %main::orig_file_data;
	local %main::orig_file_type;
	# The unprotected native API must capture this synthetic password first.
	servers::save_server($record);
	servers::delete_server($record->{'id'});
	ok(@main::locked_file_diff || keys(%main::orig_file_data), 'control proves native file capture is enabled');
	like(join('', map { $_->{'data'} || '' } @main::locked_file_diff).
		join('', map { $_ || '' } values %main::orig_file_data),
		qr/synthetic-login-secret/, 'unprotected native writes expose the synthetic secret');
	@main::locked_file_diff = ({object => "$dir/unrelated", data => 'keep this audit'});
	%main::orig_file_data = ("$dir/unrelated" => 'keep this undo');
	%main::orig_file_type = ("$dir/unrelated" => 0);

	# Creation, later IP changes and deletion all use the same no-diff wrapper.
	for my $operation (qw(create update delete)) {
		$record->{'ip'} = $operation eq 'update' ? '192.0.2.2' : '192.0.2.1';
		vm_webmin_server_change($record, sub {
			# Use the native logged deletion path as well as the normal save path.
			if ($operation eq 'delete') {
				servers::delete_server($record->{'id'});
				}
			# Exercise the same audit isolation when saving a replacement
			# record.
			else {
				servers::save_server($record);
				}
			});
		is_deeply(\@main::locked_file_diff, [{object => "$dir/unrelated", data => 'keep this audit'}],
			"$operation excludes login diffs without suppressing other audits");
		is_deeply(\%main::orig_file_data, {"$dir/unrelated" => 'keep this undo'},
			"$operation excludes login undo copies without suppressing other files");
		ok(!test_lock($file), "$operation releases the native lock");
		# Confirm that avoiding audit copies has not skipped the actual operation.
		if ($operation eq 'delete') {
			ok(!-e $file, 'native deletion removes the saved login');
			}
		else {
			# Saves must retain both the login and private filesystem permissions.
			my %saved;
			read_file($file, \%saved);
			is($saved{'pass'}, $record->{'pass'}, 'native configuration retains the saved login');
			is($saved{'ip'}, $record->{'ip'}, 'native configuration retains the correct destination');
			is((stat($file))[2] & 0777, 0600, 'native login permissions stay private');
			}
		}
	# Errors release the lock and preserve the caller's exception.
	ok(!eval { vm_webmin_server_change($record, sub { die "Save failed\n"; }); 1 },
		'native errors propagate');
	like($@, qr/^Save failed/, 'failure retains its cause');
	ok(!test_lock($file), 'failure releases its lock');

	# Flush through the real Actions Log writer into an isolated audit directory.
	my $audit = "$dir/audit-".join('-', @$logging);
	mkdir($audit) or die $!;
	local $ENV{'WEBMIN_VAR'} = $audit;
	local $WebminCore::webmin_logfile = "$audit/actions.log";
	webmin_log('fixture', 'server', $record->{'id'}, {}, 'server-manager');
	my $logged = '';
	find({no_chdir => 1, wanted => sub {
		# Read only artifacts created by this test's audit writer.
		$logged .= read_file_contents($File::Find::name) if (-f $File::Find::name);
		}}, $audit);
	like($logged, qr/"fixture"/, 'the action itself is still recorded');
	unlike($logged, qr/synthetic-login-secret|\Q$file\E/, 'written audit files contain no login file or secret');
	like($logged, qr/keep this audit/, 'unrelated file diffs are still written') if ($logging->[0]);
	like($logged, qr/keep this undo/, 'unrelated undo copies are still written') if ($logging->[1]);
	}
done_testing();
