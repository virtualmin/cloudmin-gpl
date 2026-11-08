#!/usr/bin/perl
# check-image-locks.pl
# Exercises Webmin locking, diffs and forked imports on a disposable Linux VM.
use strict;
use FindBin;
use Cwd qw(abs_path);
my $webmin_root;
use warnings;
no warnings 'once';
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find qw(find);
use POSIX qw(WNOHANG);
use Test::More;

BEGIN
{
$webmin_root = abs_path("$FindBin::Bin/../../..");
die "Run only on a disposable Linux VM as root\n"
	unless $^O eq 'linux' && $< == 0;
$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
$ENV{'WEBMIN_VAR'} = '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir("$webmin_root/server-manager") || die $!;
$0 = "$webmin_root/server-manager/check-image-locks.pl";
}
use lib "$FindBin::Bin/../../..";
require './server-manager-lib.pl';
require Sys::Virt;
$| = 1;

{
	package GatedImageWorker;

	# run(self, task, request, [options...]) gates processing to inspect
	# real locks. Named options are forwarded unchanged to the
	# fixture's run callback.
	sub run
	{
	return $_[0]->{'run'}->(@_[1 .. $#_]);
	}
	}

my $tmp = tempdir('/tmp/cloudmin-lock-test-XXXXXX', CLEANUP => 1);
my $jobs = get_image_jobs();
$jobs->{'directory'} = "$tmp/jobs";
make_path($jobs->{'directory'}, "$tmp/logs", { mode => 0700 });

# Load the filesystem API before overriding Webmin's process-wide log settings.
foreign_require('mount', 'mount-lib.pl');

# Enable real action/file logging only in this process, under its private
# tempdir. These settings are never written to Webmin's configuration.
local $ENV{'WEBMIN_VAR'} = "$tmp/logs";
local $WebminCore::webmin_logfile = "$tmp/actions.log";
local %WebminCore::gconfig = %WebminCore::gconfig;
$WebminCore::gconfig{$_} = 0 for qw(logclear logrotate logemail logsyslog);
$WebminCore::gconfig{$_} = '' for qw(logusers logmodules action_script_dir);
$WebminCore::gconfig{$_} = 1 for qw(log logfiles logfullfiles);

my $conn = Sys::Virt->new(uri => 'qemu:///system');
my $pool = $conn->get_storage_pool_by_name('default');
my $request = { source => 'url', format => 'raw', slug => 'lock-test',
		name => 'Webmin lock fixture', pool => $pool->get_uuid_string(),
		pool_name => 'default',
		url => 'https://fixture.invalid/image.raw' };
my (@records, %workers);

# wait_until(callback, message) Polls callback() until true, raising message
# after 30 seconds without progress.
sub wait_until
{
my ($code, $message) = @_;
my $deadline = time() + 30;
while (!$code->()) {
	die "$message\n" if (time() >= $deadline);
	select(undef, undef, undef, 0.05);
	}
}

# finish_worker(pid) Reaps a fixture worker before checking its final state
# or deleting its files.
sub finish_worker
{
my ($pid) = @_;
wait_until(sub { waitpid($pid, WNOHANG) == $pid }, 'Worker did not finish');
delete($workers{$pid});
is($?, 0, 'worker exits cleanly');
}

my $ok = eval {
	# A read-only view on a fresh host must not initialize
	# the private job store.
	my ($page, $page_data) = ( '', undef );
	{
		no warnings 'redefine';
		local $main::readonly_mode_cache = 1;
		local $main::module_var_directory = "$tmp/read-only";
		local $ENV{'REQUEST_METHOD'} = 'GET';
		local $ENV{'QUERY_STRING'} = '';
		# Capture page data without theme functions
		# that require MiniServ.
		local *main::ui_print_header = sub { };
		local *main::ui_print_footer = sub { };
		local *main::show_images_page =
			sub { $page_data = $_[0]; return '';
				};
		open(my $output, '>', \$page) || die $!;
		local *STDOUT = $output;
		do './images.cgi';
		die $@ if ($@);
		}
	is_deeply($page_data->{'jobs'}, [ ],
		  'fresh read-only image page loads an empty inventory');
	ok(!$page_data->{'token'}, 'read-only page issues no write token');
	ok(!-e "$tmp/read-only",
	   'read-only page creates no job store or signing key');

	my $token = $jobs->form_token('cloudmin-lock-test');
	ok(!exists($main::orig_file_data{"$tmp/jobs/form-key"}),
	   'signing key is excluded from full-file logging');

	# Gate data processing to observe locks reliably; check-workers.pl
	# exercises the real sandbox separately, including cancellation of its
	# descendants. The binary payload is a private fixture; libvirt
	# receives its actual bytes.
	for my $cancel ( 0, 1 ) {
		my $gate = "$tmp/release-$cancel";
		my $entered = "$tmp/entered-$cancel";
		# run(task, request, options...) waits until the parent
		# has checked the locks.
		$jobs->{'worker'} = bless({ run => sub {
			my ($task, $request, %opts) = @_;
			open(my $ready, '>', $entered) || die $!;
			close($ready);
			wait_until(sub { -e $gate },
				   'Download gate was not released');
			# Publish deterministic bytes and phases after the
			# parent releases the gate.
			$opts{'progress'}->({ type => 'progress',
					      phase => 'downloading', mode => 2,
					      value => 1024**2 });
			open(my $out, '>', $opts{'output'}) || die $!;
			binmode($out);
			print($out "\0" x (1024 * 1024)) || die $!;
			close($out) || die $!;
			$opts{'progress'}->({ type => 'progress',
					      phase => 'verifying',
					      bytes => 1024**2 });
			return { format => 'raw', 'virtual-size' => 1024**2,
				 bytes => 1024**2, verified => '' };
			} }, 'GatedImageWorker');
		# Verify real Webmin locks survive both worker
		# startup and parent cleanup.
		my $job = $jobs->create('cloudmin-lock-test', $token, $request,
					"$cancel");
		push(@records, $job);
		my $id = $job->{'id'};
		my $pid = $jobs->start($id);
		$workers{$pid} = 1;
		wait_until(sub { -e $entered },
			   'Worker did not start its download');
		is(test_lock("$tmp/jobs/$id.json"), $pid,
		   'metadata lock reports the worker PID');
		is(test_lock("$tmp/jobs/$id.part"), $pid,
		   'binary lock reports the worker PID');
		cleanup_tempnames();
		is(test_lock("$tmp/jobs/$id.json"), $pid,
		   'parent exit cleanup preserves the worker lock');

		# A repeated POST must return the record without
		# waiting for this worker.
		{
			local $SIG{'ALRM'} =
				sub {
					die "Repeated submission waited for the worker\n" };
			alarm(5);
			my $repeated = $jobs->create('cloudmin-lock-test',
						     $token, $request,
						     "$cancel");
			alarm(0);
			is($repeated->{'id'}, $id,
			   'repeated submission returns the locked job');
			}

		# A second worker must finish promptly without
		# entering the import.
		my $duplicate = $jobs->start($id);
		$workers{$duplicate} = 1;
		finish_worker($duplicate);
		is(test_lock("$tmp/jobs/$id.json"), $pid,
		   'duplicate worker preserves the original lock');
		# Request deletion while the original worker
		# still owns the job lock.
		if ($cancel) {
			is($jobs->remove($id), 0,
			   'deletion defers to the lock-holding worker');
			ok(-e "$tmp/jobs/$id.cancel",
			   'deferred deletion requests cancellation');
			}
		open(my $release, '>', $gate) || die $!;
		close($release);
		finish_worker($pid);
		my $completed = $jobs->get($id);
		is($completed->{'state'}, $cancel ? 'deleted' : 'ready',
		   $cancel
			   ? 'worker completes cancellation'
			   : 'worker completes the real import');
		ok(!test_lock("$tmp/jobs/$id.json") &&
		   !test_lock("$tmp/jobs/$id.part"),
		   'worker releases both locks');
		ok(!-e "$tmp/jobs/$id.part", 'worker removes staging data');
		# Successful imports must reach libvirt and remain removable.
		if (!$cancel) {
			ok($pool->get_volume_by_name($job->{'volume'}),
			   'libvirt contains the imported fixture');
			ok($jobs->remove($id),
			   'completed fixture can be deleted');
			}
		}

	# Failed uploads must unlock before another request
	# retries or deletes them.
	my $upload = $jobs->create('cloudmin-lock-test', $token,
				   { %$request, source => 'upload' },
				   'short-upload');
	push(@records, $upload);
	my $body = 'short';
	open(my $input, '<', \$body) || die $!;
	ok(!eval { $jobs->receive($upload->{'id'}, 'cloudmin-lock-test', $input,
				  100); 1 },
	   'short upload fails');
	like($@, qr/interrupted/, 'short upload preserves its failure');
	ok(!test_lock("$tmp/jobs/$upload->{id}.json"),
	   'upload failure releases the metadata lock');
	ok(!test_lock("$tmp/jobs/$upload->{id}.part"),
	   'upload failure releases the binary lock');
	ok($jobs->remove($upload->{'id'}), 'failed upload can be deleted');

	# Inspect only this fixture's private action log and diff files.
	open(my $log, '<', "$tmp/actions.log") || die "Action log missing: $!";
	my $actions = do { local $/; <$log> };
	close($log);
	like($actions, qr/ server-manager \S+ "create" "image"/,
	     'creation is logged under the Cloudmin module');
	like($actions, qr/"import" "image".*state='ready'/,
	     'successful import reaches the action log');
	like($actions, qr/"upload" "image".*state='failed'/,
	     'failed upload reaches the action log');
	like($actions, qr/"delete" "image"/,
	     'deletion reaches the Webmin action log');
	my @logged_files;
	find(sub { push(@logged_files, $File::Find::name) if (-f $_) },
	     "$tmp/logs");
	ok(@logged_files, 'Webmin writes metadata diff and full-file records');
	my @private_files;
	foreach my $file (@logged_files) {
		open(my $record, '<', $file) || die $!;
		my $header = <$record>;
		close($record);
		push(@private_files, $file)
			if (($header || '') =~ /(?:form-key|\.part)\b/);
		}
	is_deeply(\@private_files, [ ],
		  'binary data and signing key are not logged');
	1;
	};
my $error = $@;

# Clean up only the workers and volumes created by this fixture, even on error.
foreach my $pid (keys %workers) {
	kill('TERM', $pid);
	waitpid($pid, 0);
	}
foreach my $job (@records) {
	my $volume = eval { $pool->get_volume_by_name($job->{'volume'}) };
	$volume->delete(0) if ($volume);
	}
die $error if (!$ok);
done_testing();
