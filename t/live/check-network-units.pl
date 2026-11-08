#!/usr/bin/perl
# check-network-units.pl module-root
# Exercises the real systemd API with private unit names and a harmless worker.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Test::More;
use Time::HiRes qw(sleep);

# Only the selected Linux test host may create these temporary systemd units.
die "Run on the Linux test host as root\n" unless ($^O eq 'linux' && $< == 0);
my ($module) = @ARGV;
die "Pass the installed Cloudmin module directory\n"
	unless ($module && -d $module);
$ENV{'WEBMIN_CONFIG'} ||= '/etc/webmin';
$ENV{'WEBMIN_VAR'} ||= '/var/webmin';
$ENV{'REMOTE_USER'} = 'root';
chdir($module) or die $!;
$0 = "$module/network-worker.pl";
require './server-manager-lib.pl';
require "$module/lib/Cloudmin/HostNetwork.pm";
our $error_must_die = 1;

{
	package UnitHost;
	our @ISA = ('Cloudmin::HostNetwork');

	# unit(self, method, name, [data]) isolates names and references while
	# preserving the production systemd calls and rendered directives.

	sub unit
	{
	my ($self, $method, $name, @args) = @_;
	$name =~ s/^cloudmin-network-/$self->{'prefix'}-/;
	if ($method eq 'create_system_unit') {
		# Isolate timer targets and failure dependencies too.
		$args[0] =~ s/cloudmin-network-/$self->{'prefix'}-/g;
		}
	return $self->SUPER::unit($method, $name, @args);
	}
	}

# All worker output and templates live outside the real network journal.
my $dir = tempdir('cloudmin-unit-test.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $prefix = 'cloudmin-unit-test-'.time().'-'.$$;
my @names = qw(boot.service rollback.service rollback.timer apply.service);
foreach my $name (@names) {
	copy("$module/cloudmin-network-$name.in",
	     "$dir/cloudmin-network-$name.in") or die $!;
	}
my $host = UnitHost->new(module => $dir, directory => "$dir/state",
			prefix => $prefix);
open(my $worker, '>', "$dir/network-worker.pl") or die $!;
print {$worker} <<'WORKER';
use strict;
use warnings;
use FindBin qw($Bin);
my ($action) = @ARGV;
die "Invalid fixture action\n"
	unless ($action =~ /\A(?:apply|rollback|boot)\z/);
open(my $log, '>>', "$Bin/actions") or die $!;
print {$log} "$action\n" or die $!;
close($log) or die $!;
exit($action eq 'apply' && -e "$Bin/fail-apply" ? 1 : 0);
WORKER
close($worker) or die $!;

# fixture_property(name, key) reads one systemd property from a fixture unit.

sub fixture_property
{
my ($name, $key) = @_;
my $value = $host->command([ 'systemctl', 'show', "$prefix-$name",
			    "--property=$key", '--value' ]);
chomp($value);
return $value;
}

# fixture_actions() reads only the harmless worker's execution log.

sub fixture_actions
{
return WebminCore::read_file_contents("$dir/actions") || '';
}

# fixture_wait(callback) allows bounded time for asynchronous systemd jobs.

sub fixture_wait
{
my ($check) = @_;
my $until = time() + 20;
while (time() < $until) {
	return 1 if ($check->());
	sleep(0.1);
	}
return 0;
}

# Let ordinary termination unwind through fixture cleanup.
local $SIG{'TERM'} = sub { die "Fixture terminated\n" };
local $SIG{'INT'} = sub { die "Fixture interrupted\n" };
my $ok = eval {
	# The same installation path must create and arm all four fixture units.
	$host->install_guards({ deadline => time() + 120 });
	foreach my $name (@names) {
		is(fixture_property($name, 'LoadState'), 'loaded',
		   "$name loads in systemd");
		}
	is(fixture_property('boot.service', 'UnitFileState'), 'enabled',
	   'boot recovery is enabled');
	is(fixture_property('rollback.timer', 'ActiveState'), 'active',
	   'rollback timer is armed');
	$host->command([ 'systemd-analyze', 'verify',
			map { "/etc/systemd/system/$prefix-$_" } @names ]);
	pass('systemd accepts all rendered unit definitions');
	$host->unit('stop_unit', 'cloudmin-network-rollback.timer');

	# Boot and apply must pass their actions to the configured worker.
	$host->unit('start_unit', 'cloudmin-network-boot.service');
	$host->unit('start_unit', 'cloudmin-network-apply.service');
	is(fixture_actions(), "boot\napply\n",
	   'boot and apply execute the expected actions');
	is(fixture_property('boot.service', 'Result'), 'success',
	   'boot worker succeeds');
	is(fixture_property('apply.service', 'Result'), 'success',
	   'apply worker succeeds');

	# Timer expiry must start rollback automatically.
	$host->install_guards({ deadline => time() + 5 });
	ok(fixture_wait(sub { fixture_actions() =~ /rollback\n/ }),
	   'timer expiry runs the rollback worker');
	$host->unit('stop_unit', 'cloudmin-network-rollback.timer');
	ok(fixture_wait(sub {
		fixture_property('rollback.service',
				 'ActiveState') eq 'inactive'
		}),
	   'timed rollback completes');
	is(fixture_property('rollback.service', 'Result'), 'success',
	   'timed rollback succeeds');

	# A failing apply must invoke its OnFailure dependency without a timer.
	open(my $fail, '>', "$dir/fail-apply") or die $!;
	close($fail) or die $!;
	ok(!eval {
		$host->unit('start_unit', 'cloudmin-network-apply.service'); 1
		},
	   'apply failure is returned by the Webmin systemd API');
	ok(fixture_wait(sub {
		fixture_actions() eq "boot\napply\nrollback\napply\nrollback\n"
		}),
	   'apply failure automatically runs rollback');

	# Disarming recovery must stop the timer and disable boot recovery.
	$host->install_guards({ deadline => time() + 120 });
	my $record = { };
	$host->disarm_guards($record);
	ok(!$record->{'error'}, 'disarming reports no errors');
	is(fixture_property('rollback.timer', 'ActiveState'), 'inactive',
	   'disarming stops the timer');
	is(fixture_property('boot.service', 'UnitFileState'), 'disabled',
	   'disarming disables boot recovery');
	1;
	};
my $error = $@;

# Remove fixture units before deleting the worker, even after failures.
foreach my $name (
	qw(rollback.timer apply.service rollback.service boot.service)) {
	eval { $host->unit('stop_unit', "cloudmin-network-$name"); };
	}
eval { $host->unit('disable_unit', 'cloudmin-network-boot.service'); };
my @cleanup_errors;
foreach my $name (@names) {
	my $unit = "$prefix-$name";
	eval { $host->command([ 'systemctl', 'reset-failed', $unit ], 1, 1); };
	my $file = "/etc/systemd/system/$unit";
	if (-e $file) {
		# Delete only files under this fixture's unique prefix.
		my $removed = eval {
			$host->unit('delete_system_unit', $unit, $file); 1
			};
		push(@cleanup_errors, $@) if (!$removed);
		}
	}
die join('', @cleanup_errors) if (@cleanup_errors);
die $error if (!$ok);
foreach my $name (@names) {
	ok(!-e "/etc/systemd/system/$prefix-$name",
	   "$name is removed after testing");
	}
done_testing();
