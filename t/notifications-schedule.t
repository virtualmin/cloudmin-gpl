use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use CloudminTest;
use WebminCore;
use Test::More;
no warnings qw(redefine once);
our (%config, $module_root_directory, $module_name);
# Load the scheduler helper. Stubs below replace Webmin cron access.
$module_root_directory = "$Bin/..";
$module_name = 'server-manager';
require "$module_root_directory/cloudmin-config-lib.pl";
require "$module_root_directory/cloudmin-notifications-lib.pl";
my (@crons, @saved);

# ScheduleJobs::lock(self, name, code) runs isolated registration under a stub.
sub ScheduleJobs::lock { $_[2]->(); }
# get_vm_jobs() returns the lock stub without opening host job storage.
local *main::get_vm_jobs = sub { bless { }, 'ScheduleJobs' };
# foreign_require(module) avoids initializing workstation cron configuration.
local *main::foreign_require = sub { };
# list_webmin_crons() reads only the callbacks saved by this fixture.
local *webmincron::list_webmin_crons = sub { @crons };
# save_webmin_cron(cron) retains IDs and
# records writes without a service reload.
local *webmincron::save_webmin_cron = sub {
	my %cron = %{$_[0]};
	$cron{id} ||= '123';
	@crons = ( \%cron );
	push @saved, \%cron;
	};
# Defaults create an interval timer; repeated registration leaves it alone.
ensure_notification_schedule();
is($crons[0]{interval}, 60, 'missing setting defaults to sixty seconds');
ok(!exists($crons[0]{mins}), 'timer has no calendar fallback');
ensure_notification_schedule();
is(scalar(@saved), 1, 'matching schedule does not reload Webmin');
# Rescheduling uses saved settings or an explicit post-save override.
$config{notifications_interval} = 10;
ensure_notification_schedule();
is($crons[0]{interval}, 10, 'saved ten-second interval updates the timer');
is($crons[0]{id}, '123', 'rescheduling preserves the existing timer ID');
ensure_notification_schedule(300);
is($crons[0]{interval}, 300, 'explicit newly saved setting overrides cached config');
# Convert a calendar-based registration in place, clearing its calendar fields.
@crons = ( { id => 'old', module => $module_name,
	func => 'run_cloudmin_notifications', mins => '*', hours => '*',
	days => '*', months => '*', weekdays => '*', special => 'hourly' } );
ensure_notification_schedule(300);
is($crons[0]{id}, 'old', 'calendar schedule converts in place');
is($crons[0]{interval}, 300, 'converted callback uses the configured interval');
ok(!grep(exists($crons[0]{$_}), qw(mins hours days months weekdays special)),
	'calendar fields cannot trigger longer intervals once a minute');
# Hourly checks are allowed; longer manual intervals use the safe default.
ensure_notification_schedule(3600);
is($crons[0]{interval}, 3600, 'hourly checks retain the requested interval');
ok(!grep(exists($crons[0]{$_}), qw(mins hours days months weekdays special)),
	'hourly checks do not acquire calendar triggers');
ensure_notification_schedule(3601);
is($crons[0]{interval}, 60, 'overlong interval falls back to sixty seconds');
# A malformed manual setting falls back to the runtime default.
ensure_notification_schedule('invalid');
is($crons[0]{interval}, 60, 'invalid manual setting falls back to sixty seconds');
# Changes to the interval preserve an explicit scheduler disable flag.
$crons[0]{disabled} = 1;
ensure_notification_schedule(10);
ok($crons[0]{disabled}, 'interval change preserves a disabled scheduled function');
done_testing();
