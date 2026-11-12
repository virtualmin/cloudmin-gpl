# Notification authorization, unattended checks and delivery through Webmin.
use strict;
use warnings;
use Encode ();
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW);
use Time::HiRes ();
our (%text, $module_root_directory, $module_var_directory, $module_name, $remote_user,
     $cloudmin_notifications_directory);
require "$module_root_directory/lib/Cloudmin/Notifications.pm";
require "$module_root_directory/lib/Cloudmin/NotificationSignals.pm";
require "$module_root_directory/lib/Cloudmin/NotificationMessages.pm";

# notification_bytes(value) encodes characters for Webmin's byte interfaces.
# Escape the returned text with the appropriate UI helper before displaying it.
sub notification_bytes
{
return Encode::encode('UTF-8', defined($_[0]) ? $_[0] : '');
}

# get_notifications() returns a store in the module's data directory.
# Tests can override the directory to keep their data separate from host data.
sub get_notifications
{
return Cloudmin::Notifications->new(
	directory => $cloudmin_notifications_directory ||
		"$module_var_directory/notifications");
}

# call_notification_api(action, input) dispatches a notification API request.
# input is a request hash. Check host or guest access before reading storage;
# mutations also require management access and a signed token.
sub call_notification_api
{
my ($action, $in) = @_;
my $owner;
if ($action eq 'notifications' && defined($in->{id}) && $in->{id} ne 'host') {
	# Delegated viewers may read only one explicitly authorized guest.
	die "Invalid virtual machine ID\n" if ref($in->{id}) || $in->{id} !~
		/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i;
	$owner = lc($in->{id});
	require_access('view', $owner);
	}
else {
	# Configuration and combined history remain host-only.
	require_access('host');
	}
my $store = get_notifications();
# History reads need no management grant or mutation token.
return $store->history($owner, $in->{cursor}, $in->{limit})
	if $action eq 'notifications';
if ($action eq 'notification_config') {
	# Report worker health alongside the redacted saved settings.
	my $result = $store->configuration();
	$result->{worker} = $store->metadata('worker');
	return $result;
	}
# A signed token alone never grants permission to edit delivery destinations.
die "Notification changes are disabled in read-only mode\n"
	if is_readonly_mode();
require_access('manage');
get_image_jobs()->check_token($remote_user, $in->{token});
my $result;
if ($action eq 'save_notification_target') {
	# Validate the full destination, including address and token changes.
	$result = $store->save_target($in->{target});
	}
elsif ($action eq 'set_notification_target_enabled') {
	# Inline switches preserve the saved address and credential.
	$result = $store->set_target_enabled($in->{object}, $in->{enabled});
	}
elsif ($action eq 'set_notification_rule_enabled') {
	# Start the rule's waiting period again when its enabled state changes.
	$result = $store->set_rule_enabled($in->{object}, $in->{enabled}, time());
	}
elsif ($action eq 'save_notification_rule') {
	# An optional new destination commits with its rule or not at all.
	$result = $store->save_rule($in->{rule}, time(), $in->{target});
	}
elsif ($action =~ /\Adelete_notification_(rule|target)\z/) {
	# Keep referenced destinations until their rules are updated.
	$result = $store->remove($1, $in->{object});
	}
elsif ($action eq 'retry_notification') {
	# Requeue failed receipts without resending successful ones.
	$result = $store->retry($in->{object}, time());
	}
elsif ($action eq 'test_notification_target') {
	# Progress pages wait for delivery; other callers queue the test.
	$result = $store->test_target($in->{object}, time(),
		$in->{immediate} ? \&send_cloudmin_notification : undef);
	}
else {
	# Reject unrecognized mutations rather than logging a false success.
	die "Unknown notification action\n";
	}
# Any change also makes sure the check timer is registered.
ensure_notification_schedule();
# Never log the submitted target, which may contain a token or private URL.
webmin_log($action, 'notification', $result->{id}, { });
return $result;
}

# ensure_notification_schedule([interval]) installs or updates the check timer.
# interval is seconds; omitting it uses the saved setting, default 60. Webmin
# loads the registered file and calls run_cloudmin_notifications().
sub ensure_notification_schedule
{
# Validate a supplied interval like the saved one. Bad values use the default.
my $interval = @_ ? config_number('notifications_interval', $_[0])
	: config_number('notifications_interval');
# callback() updates the timer while holding the schedule lock.
get_vm_jobs()->lock('notification-schedule', sub {
	foreign_require('webmincron');
	my ($cron) = grep { $_->{module} eq $module_name &&
		$_->{func} eq 'run_cloudmin_notifications' }
		webmincron::list_webmin_crons();
	my @calendar = qw(mins hours days months weekdays special);
	# Avoid reloading Webmin when the existing timer already matches.
	return if $cron && ($cron->{interval} || 0) == $interval &&
		!grep { length($cron->{$_} || '') } @calendar;
	# Keep the existing ID and disabled flag when changing the interval.
	my %updated = ( %{$cron || { }}, module => $module_name,
		file => 'server-manager-lib.pl',
		func => 'run_cloudmin_notifications',
		args => [ ], interval => $interval );
	# Calendar fields would also run longer intervals once a minute.
	delete @updated{@calendar};
	webmincron::save_webmin_cron(\%updated);
	});
}

# notification_planned_power(uuid, action) pauses alerts for a guest UUID.
# Call after an accepted shutdown, force_off, suspend, reboot or reset.
# Reboots get ten minutes; an observed stop stays paused until restart.
sub notification_planned_power
{
my ($uuid, $action) = @_;
# Starting, resuming and changing autostart do not need downtime grace.
return unless $action =~ /\A(?:shutdown|force_off|suspend|reboot|reset)\z/;
my $store = get_notifications();
# Power actions must not initialize notification storage on an unused host.
return unless -f "$store->{directory}/notifications.sqlite";
$store->suppress(lc($uuid), $action =~ /\A(?:reboot|reset)\z/
	? time() + 600 : -time());
}

# notification_schedule_failed(id) records a failure for a saved schedule ID.
# Preparation and retention can fail without creating a controller job.
sub notification_schedule_failed
{
my ($id) = @_;
my $store = get_notifications();
# Hosts without saved notifications need no failure history.
return unless -f "$store->{directory}/notifications.sqlite";
# Use a public schedule label, keeping raw backup errors out of messages.
$store->failure(
	'schedule:'.$id.':'.time(), 'host',
	'Backup schedule '.$id.' failed. See the scheduled task result.',
	time());
}

# notification_job_failures(store, jobs, rules) scans up to 500 failed jobs.
# store and jobs are the notification and job stores; rules is an arrayref of
# saved rules. A saved cursor lets the next run continue the scan.
sub notification_job_failures
{
my ($store, $jobs, $rules) = @_;
# Use the oldest enabled job-rule time for the first scan.
my @created = sort { $a <=> $b }
	map { $_->{created} } grep { $_->{enabled} &&
	$_->{metric} eq 'job_failed' } @$rules;
return unless @created;
my $db = $jobs->connect(0);
return unless $db;
my $cursor = $store->metadata('jobs') || [ $created[0], '' ];
# Order by time and ID so jobs with the same timestamp are not skipped.
my $rows = $db->selectall_arrayref("SELECT id, updated, record FROM jobs
	WHERE state = 'failed' AND (updated > ? OR (updated = ? AND id > ?))
	ORDER BY updated, id LIMIT 500", undef, $cursor->[0], $cursor->[0],
	$cursor->[1]);
$db->disconnect();
for my $row (@$rows) {
	# Use the guest resource; a request ID may name a backup.
	my $job = Cloudmin::Notifications::decode($row->[2]);
	my ($uuid) = ($job->{resource} || '') =~ /\Aguest:(.+)\z/;
	$uuid ||= $job->{request}->{uuid} || $job->{request}->{id};
	my $owner = defined($uuid) && $uuid =~
		/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/i
		? lc($uuid) : 'host';
	# Use a public label instead of raw job errors or credentials.
	my $operation = $job->{request}->{operation} || 'Job';
	$operation =~ s/[^a-zA-Z0-9 _-]//g;
	$store->failure(
		'job:'.$row->[0], $owner,
		$operation.' job '.$row->[0].' failed. See the job log.',
		$row->[1]);
	$cursor = [ $row->[1], $row->[0] ];
	}
# Rescan the last two minutes for late job updates; source IDs avoid duplicates.
$cursor = [ time() - 120, '' ] if @$rows < 500;
$store->metadata('jobs', $cursor);
}

# notification_message(event) formats a message using module translations.
# Build its link from Webmin configuration so a request Host cannot alter mail.
sub notification_message
{
my ($event) = @_;
# Hide request headers so the link comes from saved Webmin settings.
local %ENV = %ENV;
delete @ENV{qw(HTTP_HOST SSL_CN HTTPS SERVER_PORT)};
# Guest events link to that guest's history page.
my $cgi = 'notifications.cgi?tab=history';
$cgi .= '&id='.$event->{owner} if ($event->{owner} || '') =~
	/\A[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}\z/;
my $url = get_webmin_email_url('server-manager', $cgi);
return Cloudmin::NotificationMessages::render($event, \%text, $url);
}

# send_cloudmin_notification(target, event) sends mail or a provider webhook.
# target includes private credentials; event is the public event payload. A
# delivery failure throws so the caller can save an error without credentials.
sub send_cloudmin_notification
{
my ($target, $event) = @_;
# Generic JSON delivery does not depend on message or link configuration.
my $message = $target->{type} eq 'webhook' ? { } : notification_message($event);
if ($target->{type} eq 'email') {
	# Reuse Webmin's configured sender and SMTP transport.
	foreign_require('mailboxes');
	local $main::error_must_die = 1;
	mailboxes::send_text_mail(
		mailboxes::get_from_address(), $target->{address},
		undef, Encode::encode(get_charset(), $message->{subject}),
		Encode::encode(get_charset(), $message->{body})) or
		die "Mail delivery was not accepted\n";
	}
else {
	# Never forward credentials through redirects or disable TLS validation.
	require HTTP::Tiny;
	my $request = Cloudmin::NotificationMessages::request(
		$target, $event, $message);
	# These services echo the sent message, including escaped Unicode.
	my $max_size = $target->{type} =~ /\A(?:telegram|gotify)\z/
		? 65536 : 16384;
	my $http = HTTP::Tiny->new(timeout => 8, verify_SSL => 1,
		max_redirect => 0, max_size => $max_size);
	# Transport exceptions can contain a private URL. Return a fixed error
	# instead of passing its credentials into logs or delivery receipts.
	my $result = eval { $http->post($request->{url}, {
		headers => $request->{headers}, content => $request->{content} }) };
	die "Webhook delivery was not accepted\n" unless $result;
	if ($target->{type} eq 'pushover' &&
	    $result->{status} =~ /\A4[0-9]{2}\z/) {
		# Pushover uses 4xx for invalid requests and exhausted quotas.
		# Repeating them can trigger an IP block, even with backoff.
		Cloudmin::Notifications::permanent_failure();
		}
	die "Webhook delivery was not accepted\n" unless $result->{success};
	if ($target->{type} eq 'telegram') {
		# Require explicit acceptance in the JSON reply. Keep provider
		# error descriptions private because they may
		# echo request credentials.
		my $reply = eval {
			JSON::PP->new->utf8->decode($result->{content})
			};
		die "Telegram delivery was not accepted\n" unless
			ref($reply) eq 'HASH' && JSON::PP::is_bool($reply->{ok}) &&
			$reply->{ok};
		}
	elsif ($target->{type} eq 'pushover') {
		# HTTP success alone does not confirm that Pushover accepted it.
		my $reply = eval {
			JSON::PP->new->utf8->decode($result->{content})
			};
		my $status = ref($reply) eq 'HASH' ? $reply->{status} : undef;
		my $valid = defined($status) && !ref($status) &&
			$status =~ /\A-?[0-9]+\z/;
		# A valid rejection is final. An unreadable response may be
		# temporary, so it retains the normal retry policy.
		Cloudmin::Notifications::permanent_failure()
			if $valid && $status ne '1';
		die "Pushover delivery was not accepted\n" unless
			$valid && $status eq '1';
		}
	elsif ($target->{type} eq 'gotify') {
		# Require a saved message ID, not a proxy or login page.
		my $reply = eval {
			JSON::PP->new->utf8->decode($result->{content})
			};
		die "Gotify delivery was not accepted\n" unless
			ref($reply) eq 'HASH' && !ref($reply->{id}) &&
			defined($reply->{id}) &&
			$reply->{id} =~ /\A[1-9][0-9]*\z/;
		}
	# Slack returns plain 'ok' after accepting an incoming webhook.
	die "Slack delivery was not accepted\n" if $target->{type} eq 'slack' &&
		($result->{content} || '') !~ /\A\s*ok\s*\z/;
	}
}

# run_cloudmin_notifications() is the registered Webmin scheduler callback.
# It takes no arguments, checks enabled rules and delivers a bounded batch. The
# worker lock skips overlapping runs; delivery needs no browser session.
sub run_cloudmin_notifications
{
# Scheduling alone must not create storage on an unused host.
my $store = get_notifications();
return unless -f "$store->{directory}/notifications.sqlite";
# A slow transport cannot cause overlapping workers or duplicate evaluations.
sysopen(my $lock, "$store->{directory}/worker.lock",
	O_RDWR | O_CREAT | O_NOFOLLOW, 0600) or
	die "Cannot lock notifications\n";
return unless flock($lock, LOCK_EX | LOCK_NB);
my $rules = $store->configuration()->{rules};
# Freeze settings before field use can change how Perl encodes their types.
# Full records also distinguish edits made within the same second.
my $rule_snapshot = { map {
	$_->{id} => Cloudmin::Notifications::encode($_)
	} @$rules };
my $now = Time::HiRes::time();
my $ok = eval {
	require "$module_root_directory/cloudmin-statistics-lib.pl";
	my $collection_enabled = statistics_enabled();
	# A cache read failure must not prevent the collector-health rule from
	# running. Other resource conditions receive unknown readings.
	my $latest = { };
	if ($collection_enabled) {
		# Report only an error from this read,
		# not one left in $@ earlier.
		my $read = eval { $latest = statistics_latest(); 1 };
		warn "Cloudmin notification collector read failed: $@" unless $read;
		$latest = { } unless ref($latest) eq 'HASH';
		}
	my $previous = $store->metadata('sample') || 0;
	# Faster checks may see the same fresh sample. Leave its incident state
	# alone until a new reading arrives or the cached reading becomes stale.
	my $unchanged = $latest->{checked_at} &&
		$latest->{checked_at} == $previous && !$latest->{stale} &&
		$now >= $latest->{checked_at} &&
		$now - $latest->{checked_at} <= 3 * ($latest->{interval} || 10);
	if (($latest->{checked_at} || 0) <= $previous && !$unchanged) {
		# Old or expired readings cannot extend a measured duration.
		$latest = { };
		}
	elsif (!$unchanged) {
		# Remember new readings before evaluating them.
		$store->metadata('sample', $latest->{checked_at});
		}
	# Tell the collector-health rule whether collection is meant to run.
	$latest = { %$latest, collection_enabled => $collection_enabled ? 1 : 0 };
	# A gap must account for both the check and collection intervals.
	my $interval = config_number('notifications_interval');
	$interval = $latest->{interval}
		if ($latest->{interval} || 0) > $interval;
	my %filesystems;
	# Bound each host filesystem probe, including unavailable disks.
	for my $r (@$rules) {
		next unless $r->{enabled} && $r->{scope} eq 'host' &&
			$r->{metric} =~ /\Afilesystem(?:_free)?\z/ &&
			!exists($filesystems{$r->{device}});
		$filesystems{$r->{device}} = eval {
			# ALRM() aborts a stalled probe;
			# signal arguments are unused.
			local $SIG{ALRM} = sub {
				die "Filesystem probe timed out\n"
				};
			alarm(3);
			foreign_require('mount');
			my @space = mount::disk_space('', notification_bytes($r->{device}));
			alarm(0);
			# Webmin reports free space in KiB. Share this probe
			# between percentage and absolute free-space
			# rules for the same path.
			@space ? { usage => $space[3], free =>
				Cloudmin::NotificationSignals::numeric($space[1])
					? $space[1] / 1024**2 : undef } : undef;
			};
		# A failed probe must not leave its alarm armed for later work.
		alarm(0);
		}
	# Active jobs may explain temporary guest downtime.
	my $jobs = get_vm_jobs();
	my %suppressed;
	# Unfinished guest jobs may stop guests, so their checks pause.
	# Job failure rules report failed jobs.
	for my $job (@{$jobs->list_pending()}) {
		$suppressed{$1} = 1 if ($job->{resource} || '') =~ /^guest:(.+)$/;
		}
	# Evaluate resource readings, then record newly failed jobs separately.
	$store->evaluate(Cloudmin::NotificationSignals::observations(
		$rules, $latest, $now, \%filesystems), $now, \%suppressed,
		{ max_gap => 2.5 * $interval, skip_cached => $unchanged,
		  rule_snapshot => $rule_snapshot });
	notification_job_failures($store, $jobs, $rules);
	1;
	};
# Delivery remains independent of a failed collector, job scan or disk probe.
my $error = $ok
	? ''
	: 'Notification checks failed. Check the Webmin error log.';
warn "Cloudmin notification checks failed: $@" unless $ok;
# Expire overdue receipts and old history before attempting queued sends.
$store->prune(time());
my $delivered = eval {
	$store->deliver(\&send_cloudmin_notification, Time::HiRes::time());
	};
# Publish a safe health summary even when the transport loop failed.
$error ||= 'Notification delivery worker failed.' if $@;
$store->metadata('worker', { checked_at => time(), error => $error,
	deliveries => $delivered || 0 });
close($lock);
}

1;
