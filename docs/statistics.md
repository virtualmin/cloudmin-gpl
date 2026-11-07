# Resource statistics

The statistics pages in the menu show history for the selected VM or the host. Guest history needs permission to view that VM. Host history needs host-administrator access. Charts refresh every 10 seconds while visible.

Choose a recent period or a custom range in 15-minute steps. Charts show current readings and period peaks. CPU charts also show the period's average. Disk reads and received network traffic appear above zero, with writes and sent traffic below. Missing readings appear as gaps.

Guest pages include filesystem usage from the guest agent. Host pages add load averages, active storage pool usage and running guests' CPU and memory allocations beside the host's capacity. Pool readings refresh once a minute. When pools share a filesystem, its space counts once in the period's total change.

Cloudmin GPL and Pro use the same collector and local history store. The module installer enables `cloudmin-statistics.service` unless resource statistics are disabled. The service samples all libvirt guests in one bulk call, even when no browser is open. The status server reads the collector's private cache of latest readings. SSH, address and application health checks remain separate.

The service uses Webmin's existing Perl SQLite dependencies. It requires a local `qemu:///system` connection and Linux `/proc` and `/sys`. A systemd watchdog restarts a collector stuck in a native call. A single worker checks guest filesystems with a timeout for each call. Failed checks use increasing retry delays. Guest-agent calls do not block bulk collection.

## Configuration and storage

Collection is enabled by default. Disabling it in Module Configuration stops the service, prevents startup at boot and hides both statistics menu links. Saved history and VM power controls stay available. Enabling it starts collection again. These changes apply when saved and survive upgrades.

Disabling history recording keeps live readings. Sampling intervals, retention, uplinks and the disk budget can be set separately. The collector reads these settings on its next sampling tick.

The module's private state directory contains `metrics.sqlite` and its SQLite WAL files, separate from the job database. Only the collector writes history. HTTP handlers use short, read-only database connections. The live cache is in the private `/run/cloudmin-statistics` runtime directory, so a full history filesystem does not prevent live readings from being published.

Default retention:

| Interval | Retention | Entities |
| --- | --- | --- |
| 10 seconds | 24 hours | Host, VMs and devices |
| 1 minute | 7 days | Host, VMs and devices |
| 5 minutes | 30 days | Host, VMs and devices |
| 1 hour | 365 days | Host and VMs |

The default disk budget is 1024 MiB. Retention settings are maximum ages. A busy host can reach its budget sooner, causing older detailed readings to be removed first. Keep the database on a local filesystem. SQLite WAL requires local storage.

The `statistics-host-id` file in the module configuration directory contains a random UUID. Recreating the database leaves this host ID unchanged but gives the new database a separate generation UUID. When cloning a host installation, give the clone a new statistics host ID before collecting data. Connect must detect duplicate host IDs during enrollment so it does not merge data from different hosts.

The SMBIOS UUID, when available, is exported as `hardware_uuid` for inventory only. It may be absent or duplicated and must never replace `host_id`.

## Meaning of the measurements

A disk is identified by the VM UUID and target slot, such as `vda`. Replacing the volume keeps the slot's history but resets the counters used to calculate rates. A NIC is identified by the VM UUID and MAC address. Libvirt interface indexes and changing `vnet` names are only lookup keys. Lifecycle and device events reset rate baselines. Periodic XML checks also catch changes made outside Cloudmin.

Guest CPU wait uses libvirt's per-vCPU `delay` counters to measure time spent waiting in the host's run queue. Like CPU usage, it is reported as a percentage of the guest's assigned CPU time. Where `delay` is missing, the older `wait` counter is used. That counter needs cgroup v1 and reads zero on hosts without it. These readings can help identify guests competing for host CPU time.

Rates use elapsed time from a monotonic clock, which is unaffected by wall-clock adjustments. Missing or decreasing counters, lifecycle changes and long gaps leave rates unknown rather than zero. A delayed collection tick still records current gauges, with a limit on how much time they represent. Allocated memory and balloon-reported used memory have separate coverage. Filesystem readings expire independently.

Host network totals use physical ports or bonds without counting both layers. Automatic selection includes physical interfaces such as Wi-Fi and replaces bond members with their bond. It excludes guest tap/vnet devices. Explicit uplinks must not include both an interface and its lower devices. A bridge's own counters may omit forwarded traffic. Select the ports carrying the traffic you want to measure. Host disk I/O counts physical whole devices without adding their partitions and logical layers again.

Each metric summary carries `sum`, `duration`, `min`, `max` and `count`. Gauge sums are the reading multiplied by valid seconds. Counter sums are increments, and their min/max values are interval rates. To calculate an average, divide `sum` by `duration`. To merge summaries, add their sums and durations rather than averaging their averages.

An interval crossing a summary boundary is split proportionally because counters do not reveal exactly when the activity occurred. Fractional counts describe these split observations. Coverage is tracked separately for each metric. These estimates are for monitoring, not billing.

## Read API

Both operations use the existing authenticated version-one `api.cgi` API and allow GET. VM queries require view permission for that exact UUID. Host queries and exports require host-administrator access. Permissions are checked before reading history, devices or events.

`action=statistics` accepts:

| Field | Meaning |
| --- | --- |
| `id` | `host` or a VM UUID. Defaults to `host`. |
| `from`, `to` | Unix timestamps in seconds. Defaults to the last hour, with a maximum span of 366 days. |
| `points` | Maximum output points, 60–1200. Default 600. |
| `entity` | Optional device ID returned by a previous authorized query |

The result contains metric units, available entities, selected resolution, timestamped values, per-metric coverage, peaks, recent events, collector availability and latest live readings. Missing values are JSON null. The browser loads Webmin's shared uPlot assets once and uses the same Cloudmin chart helper in all themes.

Device choices come from retained history in the requested period, including removed devices. The browser shows the Device selector only when that period contains multiple disks or multiple network interfaces.

Chart values for counter metrics are rates per second in the metric's base unit. Exported counter sums are increments over their valid duration.

## Future Connect synchronization

`action=statistics_export` exports completed summaries. Set `step` to 60, 300 or 3600 seconds, and `limit` to 1–1000 rows. The defaults are 60 seconds and 500 rows. Pass the returned `cursor` to resume. It identifies the database generation, summary interval and sequence number. Retry the same cursor after connection loss. Save rows and their returned cursor in one controller transaction to keep them in sync.

Identify each exported summary by `(host_id, generation, entity, step, t)`. Completed numeric summaries do not change. Entity names reflect their current display names. The response includes `more`, `available_from` and `retention_gap`. A cursor from another database generation requires a new synchronization session. A retention gap means some summaries have expired. Request a coarser interval for that missing time range. Never add overlapping resolutions together.

Connect should pull limited batches using its existing authenticated host connection. Keep one-minute data briefly at the controller and merge summaries for longer retention. A fleet of 10,000 VMs generates 14.4 million VM summary rows per day at one-minute intervals, before device detail. Choosing the controller database and retention requires a separate fleet benchmark.

This feature provides the host API for future Connect synchronization. It does not add a Connect server, an unauthenticated metrics endpoint or outbound transfers from hosts. The local SQLite design has not been validated as a central fleet database.

## Validation

`prove t/statistics.t` tests weighted summaries, independent validity, boundary splitting, counter resets, delayed ticks, device replacement, retention cursors and database recreation. The API tests cover authorization before reads. Live validation should check all themes, collection off, recording off, service restart, unavailable guest agents and continuing VM status when history cannot be written. Synthetic storage benchmarks measure history costs without creating thousands of guests.
