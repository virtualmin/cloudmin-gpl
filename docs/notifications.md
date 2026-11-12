# Notifications

Cloudmin sends email, chat and push messages or webhooks for resource use, guest problems, monitoring failures and failed jobs. Each rule sets what to watch, when to alert and where to send messages.

You need host and management access to change rules or destinations. Users assigned to a guest can read that guest's events.

Test messages check delivery to an enabled destination without triggering a rule. Tests use the same retry rules as alerts.

Email uses Webmin's sender and mail settings. Messages describe the condition, reading, threshold and alert state, with a link back to Cloudmin. Links use Webmin's configured email URL, or its hostname and listening port. Message wording uses the module's language strings.

Generic webhooks send the event as JSON. Slack, Discord, Teams Workflows, ntfy, Telegram, Pushover and Gotify receive readable messages in their own formats.

All HTTP delivery checks HTTPS certificates, rejects redirects and requires HTTPS for bearer tokens. Slack, Discord and Teams URLs also require HTTPS. Saved tokens and private chat URLs are visible to authorized editors, but omitted from configuration listings. Saving an empty bearer token removes it. Telegram requires a bot token. Pushover and Gotify require application tokens. Gotify requires HTTPS. Pushover user and group keys are also hidden from configuration listings.

Use an incoming webhook URL for Slack or Discord. Discord requests wait for message creation before accepting success. For Teams, create a workflow with the Teams webhook trigger and access set to anyone, then use its signed URL. For ntfy, use the topic URL, with a bearer token if required. Slack and Discord messages are shortened to their text limits. ntfy messages are limited to 4096 UTF-8 bytes. All methods support test messages and delivery history.

Telegram uses a chat ID and a bot token from [BotFather](https://t.me/BotFather). Start the bot for a private chat. Add it to a group with permission to send messages, or to a channel with permission to post. Use a numeric chat ID, including its minus sign, or an `@username` for a public supergroup or channel.

To find an ID, send a command to the bot and read `message.chat.id` from its [getUpdates response](https://core.telegram.org/bots/api#getupdates). In a group, address the command to the bot, such as `/start@your_bot`. For a channel, read `channel_post.chat.id` after posting a message. If the bot already uses a webhook, read its incoming updates instead.

Telegram messages are plain text, limited to 4096 characters, with link previews disabled. Delivery needs both an HTTP success and Telegram's `ok: true` response. Rejections and rate limits use the normal retry schedule. Forum topics, automatic chat discovery and custom Bot API servers are not supported.

[Pushover](https://pushover.net/api) needs a user or group key and an application API token from your Pushover account. Both are private, case-sensitive keys containing 30 letters and digits. Messages use normal priority. Titles are shortened to 250 characters and message text to 1024 characters. Delivery requires an HTTP success and `status: 1` in the response.

Pushover HTTP 4xx responses, including quota-exhaustion 429 responses, and valid API rejection statuses stop delivery immediately. Correct the destination or restore its quota before retrying from History or with `retry-notification`. Network failures, server errors and unreadable responses still retry automatically.

[Gotify](https://gotify.net/docs/pushmsg) needs your server's HTTPS URL and an application token, not a client token. Include any reverse-proxy path in the server URL, but omit `/message`, query strings and fragments. Cloudmin appends `/message` and sends the token in the `X-Gotify-Key` header. Messages use plain text and priority 5. The server certificate must be trusted by the Cloudmin host. Delivery requires an HTTP success and a positive message ID in the response.

## Rules and delivery

Checks run as a background job every 60 seconds by default. The `notifications_interval` module setting accepts 10 to 3600 seconds. Slow checks or deliveries can delay the next run.

Resource and guest status rules alert after a problem lasts for five minutes by default. For example, a CPU rule with a 90% threshold needs readings of 90% or higher across checks for five minutes. Each rule's `duration` sets this wait in minutes. Setting it to `0` alerts on the first matching check, subject to the minimum gap between alerts.

By default, each rule also waits at least five minutes between new alerts for the same host, guest or device. This gap starts from the last alert or reminder. Set it in minutes with `cooldown`. Both waits must finish before a new alert is sent.

Numeric rules can alert at or above a threshold, or at or below it. Usage uses percent, free memory and space use GiB, and network and disk rates use MiB/s. Host load uses the one-, five- or fifteen-minute load average. Free memory is total memory minus reported usage. Rates come from the collector's measured change per second, rather than lifetime counters.

Recovery requires the reading to pass the threshold in the opposite direction by two percentage points for usage, or 2% of the threshold for other measurements. A high-usage rule at 90% clears at 88% or lower. A low-free-space rule at 10 GiB clears at 10.2 GiB or higher. High-usage thresholds at or below 2% clear only at zero. A zero threshold clears when its comparison stops matching.

Missing readings restart the wait for a new threshold alert and pause checks for an ongoing problem. They do not count as recovery. Guests that leave an all-guests rule, and guest filesystems or pools that are no longer reported, are dropped from the current conditions once no alert or cooldown remains. Explicitly selected guests and host mount points remain paused while their readings are unavailable. Dedicated collector and pool conditions report monitoring problems separately.

CPU, memory, load, transfer rates, guest status, guest filesystem and storage pool checks need resource collection enabled. They use its latest readings, so checking more often does not collect new data. Saving statistics history is optional. Host filesystem checks and job failures work even when collection is disabled.

Collector health rules report when no fresh snapshot is available for three collection intervals, followed by the rule's duration. They create one host incident per rule, not one alert per guest. Deliberately disabling collection pauses these rules. Pool inactivity rules use a separate inventory of active and inactive pools, refreshed about once a minute. A failed or stale inventory read cannot establish inactivity.

Guest power rules detect guests that are not running. Agent rules detect an unavailable agent while a guest is running. Retries after failed agent checks can be an hour apart, so detecting recovery can take that long. Results older than 65 minutes pause the rule until another agent check completes.

Planned stops made in Cloudmin pause checks until the guest runs again. If the guest is still running when checked after two minutes, checks resume. Reboots allow ten minutes to recover. Unfinished guest jobs, such as backups, snapshots and disk changes, also pause checks. So do failed jobs that still require recovery. Stops made outside Cloudmin may trigger alerts.

Filesystem rules check mounted filesystems. A host path must be a mount point, such as `/` or `/boot`. A blank host path means `/`. Other directories get no readings, so their rules never alert. A blank guest path checks every reported filesystem. A blank pool name checks every active storage pool for usage or free space, or every known pool for inactivity. Problems are tracked separately for each device.

Job failure rules report new failures, including scheduled backups. These alerts skip the duration and cooldown waits. They have no reminders or recovery messages. Errors while preparing scheduled backups or removing old backups are recorded for the host. A failed backup may create both a guest job event and a host schedule event.

An ongoing resource or guest problem produces one alert. Reminders are off by default. When enabled, they repeat while the problem continues and readings are available. Recovery messages are on by default and always use notice severity. Alerts and reminders use the rule's severity. Each enabled destination gets its own copy and delivery result.

Failed deliveries retry with increasing delays, up to six attempts in total, except for permanent Pushover rejections. Messages more than a day overdue expire. Successful email delivery means the receiving server accepted the message, not that it reached an inbox. If the receiver accepts a message but its response is lost, Cloudmin may send it again. Webhook receivers can use `(instance, id)` or the `Idempotency-Key` header to avoid processing the same alert more than once.

Cloudmin keeps rules, alert state and unsent messages across restarts in the private `notifications/notifications.sqlite` database. It is separate from resource history and its disk budget. Events older than 30 days are removed once none of their deliveries are pending.

Disabling a rule or destination cancels its pending deliveries. Saving or re-enabling a rule starts its waiting period again. Saving also cancels deliveries queued under the old settings. Deleting a rule stops tracking its conditions and cancels its pending deliveries. Event history remains. A delivery already in progress may still finish.

A powered-off host or stopped Webmin service cannot send alerts. Detecting either requires another monitoring system.

## Muting alerts

Muting pauses alert delivery for one guest or for the host and all guests. Muting all alerts also covers guests added later. Mutes stay active until you unmute them, including after restarts.

Unmuting all alerts leaves separately muted guests muted. Unmuting one guest does not override a mute for all alerts.

Checks and history continue. Pending deliveries are marked muted and will not be sent later. Destination tests still send. A delivery already in progress may finish.

After unmuting, a problem still present at the next fresh check sends one new alert, even when reminders are disabled. A problem that has recovered stays quiet. A missing reading leaves the check paused.

You need host and management access to mute or unmute alerts. Changes are blocked in read-only mode. Users assigned to a guest can see its mute status and events.

## Command line

Save this destination in `target.json` with file permissions `0600`, so only its owner can read or write it:

```json
{"name":"Operations","type":"email","address":"ops@example.com","enabled":1}
```

```sh
cloudmin save-notification-target --file target.json
cloudmin get-notification-config --json
cloudmin test-notification-target --id TARGET_ID
```

Save this rule in `rule.json`. Replace `TARGET_ID` with the destination ID returned above:

```json
{
  "name": "Host memory pressure",
  "metric": "memory",
  "scope": "host",
  "threshold": 90,
  "duration": 5,
  "reminder": 0,
  "recovery": 1,
  "severity": "warning",
  "targets": ["TARGET_ID"],
  "enabled": 1
}
```

```sh
cloudmin save-notification-rule --file rule.json
cloudmin get-notifications --json
cloudmin get-notifications --id GUEST_UUID --cursor 0 --limit 100 --json
cloudmin delete-notification-rule --id RULE_ID
cloudmin delete-notification-target --id TARGET_ID
```

To switch a rule or destination on or off without resending its settings, use `set-notification-rule-enabled` or `set-notification-target-enabled`:

```sh
cloudmin set-notification-rule-enabled --id RULE_ID --enabled no
cloudmin set-notification-target-enabled --id TARGET_ID --enabled yes
```

To update a rule or destination, include its existing `id` and the full settings you want to save. Keep any optional values you still need. Omitting `secret` keeps its saved token only if the type and address stay the same. An empty `secret` removes a bearer token, but is rejected for Telegram, Pushover and Gotify.

Use these commands to mute or unmute one guest or all alerts:

```sh
cloudmin mute-notifications --id GUEST_UUID
cloudmin unmute-notifications --id GUEST_UUID
cloudmin mute-notifications --id all
cloudmin unmute-notifications --id all
```

Use `--file -` to read JSON from standard input. Remove a destination from all its rules before deleting it.

## API

These actions use version 1 of the authenticated API. `notifications` returns events and the latest status of each monitored condition. An optional guest `id` limits both to that guest. The `limit` sets how many events to return, from 1 to 500, with a default of 100.

Without a cursor, the API returns the latest events. Set `cursor=0` to start with the oldest retained event. Pass the returned cursor to read the next batch. Event IDs increase but may have gaps.

`notification_config` returns saved rules, destinations without tokens or private chat URLs, and the last background job status. Each destination's `last_delivery` shows the current result of its last recorded attempt. If that attempt record is unavailable, it uses the newest retained delivery record. The optional `at` field gives the attempt time. Records without a finished attempt have no time. `last_delivery` is null when no delivery record remains.

Changes require POST, host and management access, and a signed `token` obtained from `options`. Changes are blocked in read-only mode.

| Action | Fields |
| --- | --- |
| `save_notification_target` | `target` object |
| `set_notification_target_enabled` | `object` target ID and `enabled` flag |
| `save_notification_rule` | `rule` object and optional new `target` object |
| `set_notification_rule_enabled` | `object` rule ID and `enabled` flag |
| `delete_notification_target` | `object` target ID |
| `delete_notification_rule` | `object` rule ID |
| `test_notification_target` | `object` target ID |
| `retry_notification` | `object` event ID |
| `mute_notifications` | Guest UUID or `all` in `id` |
| `unmute_notifications` | Guest UUID or `all` in `id` |

`notifications` returns `muted` and `all_muted` as 0 or 1. For guest history, `muted` reports only that guest's own mute. For combined history, it reports the global mute. `all_muted` always reports the global mute. A guest is muted if either value is 1.

Events marked muted have a `silenced` field set to `guest` or `all`. Deliveries with state `muted` cannot be retried or sent later.

Passing a `target` object with `save_notification_rule` creates a destination for that rule instead of using `rule.targets`. Both are saved together. If either is invalid, neither is saved. The new target must not have an `id`. Use `save_notification_target` to update an existing destination.

The `metric` sets what to watch:

| Metrics | Units | Default threshold |
| --- | --- | --- |
| `cpu`, `memory`, `filesystem`, `pool` | Percent | 90 |
| `memory_free`, `filesystem_free`, `pool_free` | GiB | 1 |
| `load_1`, `load_5`, `load_15` | Load average | 1 |
| `network_receive`, `network_transmit`, `disk_read`, `disk_write` | MiB/s | 100 |
| `guest_down`, `guest_agent`, `pool_inactive`, `collector_stale` | Status | None |
| `job_failed` | Event | None |

Numeric rules accept `comparison: "ge"` for at or above, or `"le"` for at or below. Free memory and space metrics default to `le`; other numeric metrics default to `ge`. The `severity` can be `notice`, `warning` or `error`. The `device` identifies a mount point or a pool name or UUID.

Destination `type` accepts `email`, `webhook`, `slack`, `discord`, `teams`, `ntfy`, `telegram`, `pushover` or `gotify`. The `address` is the mailbox, webhook URL, ntfy topic URL, Telegram chat ID, Pushover user or group key, or Gotify server URL. Telegram stores its required bot token in `secret`.

Numeric chat IDs must fit Telegram's 52-bit range; usernames accept `@` followed by 4 to 32 letters, digits or underscores. Slack, Discord and Teams URLs may include signed query fields; generic webhook, ntfy and Gotify URLs may not.

Configuration responses replace private Slack, Discord and Teams addresses with `address_host` and `has_private_address: 1`. Pushover responses omit the recipient key and set `has_private_address: 1`. Supply the full private address when updating these destinations.

Pushover and Gotify store their required application token in `secret`. Omitting `secret` keeps it only when the destination type and address are unchanged. These methods reject an empty token or `clear_secret: 1`.

The `scope` sets which machines to monitor and defaults to `host`. It also accepts `guests`, one guest UUID or an array of one or more guest UUIDs. An array monitors only those guests and tracks their problems separately. `guests` includes guests added later. Only job failure rules accept `all`, which covers the host and all guests. Pool, load and collector-health rules require `host`. Guest power and agent rules require guests.

Generic webhook messages include `version`, `instance`, `id`, `host`, `owner`, `subject`, `label`, `rule`, `name`, `metric`, `threshold`, `comparison`, `unit`, `duration`, `value`, `phase`, `severity` and `created`. The `unit` is `%`, `GiB`, `MiB/s` or empty. The `duration` is the rule's wait in minutes, and is null for job failure and test events. The `phase` is `firing`, `reminder`, `resolved`, `failed` or `test`. Times are Unix timestamps in seconds. Measurements may be null, and so is the `unit` of a test event.

Guest history leaves out destinations and delivery results. Neither webhook messages nor API responses include raw guest agent or job errors.
