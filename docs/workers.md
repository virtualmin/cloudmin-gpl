# Privilege separation

Cloudmin CGI scripts run as root, like other Webmin modules. They use normal
Webmin initialization, authentication and permission checks. Image and
provisioning tools run without root privileges, even when the administrator
logs into Webmin as root. Systemd assigns each task a temporary user ID and
releases it when the task stops. No permanent user account is created.

Tool workers start fresh Perl processes without inheriting Webmin's memory,
environment, open files or libvirt connections. Interactive relays also start
fresh, but receive the authorized sockets described below.

## What runs without root

| Task | Work | Network |
| --- | --- | --- |
| Image | HTTPS download or staged upload, checksum verification when supplied, and qemu-img inspection | Allowed |
| Host image | Read a host file, verify a supplied checksum and inspect its disk format | Isolated |
| Size | HTTPS image-size lookup | Allowed |
| Inspection | qemu-img and read-only disk inspection through libguestfs | Isolated |
| Clone preparation | Writable libguestfs preparation of independent copied disks | Isolated |
| Keys | OpenSSH public-key validation and virtual machine login key generation | Isolated |
| Seed | cloud-init files and ISO generation | Isolated |
| Software | SSH to one newly created guest with a pinned host key | Allowed |

Each task gets a private directory. It has no Linux capabilities and cannot gain
privileges through setuid programs. Host files are read-only outside the task's
private directories. Home directories and Webmin data are hidden, and host
libvirt, D-Bus and systemd control sockets are unavailable. User lookup and DNS
resolver files remain available. Inspection and clone preparation receive access to `/dev/kvm`
and read-only kernel modules to build their appliances; they cannot load modules.
The controller copies the host's running kernel into the private worker
directory so the worker can read it without changing the original's permissions.
The matching modules must still be installed. Supermin uses these files to build
the small Linux appliance that inspects or prepares the disk. The kernel copy is removed
with the worker's other files.
Inside libguestfs workers, stock `bsdtar` supplies supermin's `tar` command.
Some GNU tar builds use `openat2`, which the worker's systemd SUID protection
blocks. Using bsdtar avoids that failure and keeps the worker restrictions.
The host's `tar` is unchanged.

Webmin still authenticates users and receives raw HTTP upload bytes as root.
Cloudmin's root request process checks permissions and backend inputs. It starts
background job processes that also run as root to write job and audit records and
change libvirt resources. These jobs use non-root workers for the image and
provisioning tasks above. Webmin's configuration pages and Cloudmin's CLI also
run as root.

The root job process copies staged uploads into the worker directory before any
disk parsing. Host-file imports open the source under the worker UID instead:
a private host file cannot be exposed by asking root to import it as a raw image.
The worker must be able to traverse its parent directories and read the file.
Home, Webmin and libvirt directories remain hidden. Fixed read-only mounts expose
host `/tmp` and `/var/tmp` without sharing the worker's own temporary directory.

A tool worker receives only the data needed for its task. Seed generation
receives a guest password hash when password login is selected. Download and
size-lookup tasks receive Webmin's outgoing proxy settings, including proxy
credentials when configured, through their private request files. These settings
are not saved in job records or progress output.

Worker responses contain JSON data with a size limit. The root process accepts
task results only, not requests to run commands, choose destination paths or
change libvirt resources. It stops the service and its descendants before taking
the expected output file. It rejects links and non-regular files, validates image
metadata, and makes the returned file root-owned and private before import.
Libvirt manages virtual machine execution, storage and networking through `qemu:///system`.

## Guest software installation

The software worker receives the guest's managed SSH key and, for Pro, the
creation request's license credentials through its private task directory.
Credentials go over SSH stdin only after the guest's host key is verified; they
never appear in command arguments or the seed. The guest generates its normal
SSH host keys during cloud-init. No private host key is placed on the seed disk
or sent to the controller. After SSH setup, the guest publishes its public RSA
key and virtual machine UUID in `/var/log/qemu-ga/cloudmin-identity.json`.
Cloudmin reads this file through the domain's libvirt guest-agent channel and
saves the verified public key before making any SSH connection. Reconnection
uses that saved key, rather than trusting a key reported over the network.

This lookup uses `virsh qemu-agent-command`, because Sys::Virt does not expose
that libvirt API. Libvirt describes direct guest-agent commands as
[unsupported](https://wiki.libvirt.org/Qemu_guest_agent.html#usage), because
changes made behind its back can disrupt its own operations. Cloudmin's identity
lookup opens only the public identity file in read-only mode and uses
`guest-file-open`, `guest-file-read` and `guest-file-close`. It attempts to close
every opened handle even if reading or validation fails; an agent disconnect
can prevent the close from succeeding.

Each command has a short timeout, reads are limited to 4 KiB,
and guest identity discovery stops after 15 minutes. Creation checks for `virsh`
and `timeout` before allocating a guest with software setup. Libvirt reports
agent failures through stderr and a nonzero exit status. Cloudmin classifies
those diagnostics in the C locale. Host command errors and unsupported RPCs
fail immediately. A disconnected or busy agent, a missing identity file, a read
handle lost during restart, or pending cloud-init policy changes are retried
until the discovery deadline. The final attempt reports any remaining file or
policy error. If the agent is still unavailable, the job reports that it could
not verify the guest's host key within 15 minutes.

When software setup is selected, cloud-init installs and starts
`qemu-guest-agent` so Cloudmin can discover guest addresses on bridged networks.
Configured static addresses are also tried directly, with the same pinned
host-key check.

Guest preparation enables `guest-file-open`, `guest-file-read` and
`guest-file-close` in existing agent RPC filters, retaining the other
restrictions. It does not enable `guest-exec` or `guest-file-write`. Preparation
restarts the installed agent service, including SUSE's service names. If it
generates a missing RSA host key, it reloads the SSH service before publishing
that key. The public identity record uses the agent log directory's standard
SELinux label. Preparation restores that label when SELinux is active; no policy
booleans or rules are changed.

The host monitor and standalone guest helper use Perl. During cloud-init, a shell
bootstrap installs Perl, Time::HiRes, JSON::PP, HTTP::Tiny, URI and the TLS modules
from the guest's distribution repositories, including on EL8. The guest does not
need Webmin or CPAN. If the helper cannot load at the first SSH connection, the
monitor waits up to 15 minutes for cloud-init before checking again. Missing
dependencies then end the job with a prerequisite error.

Inside the guest, a root helper waits for cloud-init and starts a separate
systemd service. It runs the preparation script, installs packages, optionally runs
the official Virtualmin installer, then runs the final setup script. Cloudmin GPL
supports package installation without Virtualmin. Custom preparation and final
setup scripts require Cloudmin Pro. Scripts selected from host files are read under
the submitting user's Webmin file permissions before job submission; workers use
the saved contents. Host workers never execute template scripts. Scripts use
`/bin/sh -e` with no interactive input. They should not contain reusable secrets.

The guest service survives an SSH disconnect. Reconnection reads its saved
status without replaying installation. Each step is recorded before execution;
a failed or interrupted step is never repeated automatically. The service has a
two-hour deadline for the whole sequence. The controller allows extra time for
boot and reconnection. Missing prerequisites and failed initial guest setup end
the job; temporary SSH connection failures are retried until the saved deadline.
Software failure preserves the virtual machine.

Software setup holds no virtual machine reservation. Administrators can edit,
stop or delete the guest while it runs. Cancelling setup stops the guest service
over verified SSH without rolling back the virtual machine or installed software.
Deleting the virtual machine ends setup as cancelled. Progress and the action log
distinguish cancellation from successful installation and setup failure.
If the guest cannot be reached, Cloudmin reports that cancellation could not be
confirmed.

The controller erases its temporary license copy once the guest accepts the
request. The guest removes the request and downloaded installer after use,
including service timeout cleanup. Virtualmin retains its installed license
configuration. The software worker sends only known status fields to Cloudmin.
Script, package and installer output stays in the private
guest log at `/var/lib/cloudmin-install/install.log`. It redacts the supplied
serial and key and is limited to approximately 4 MiB across all steps. Errors
during initial guest setup can occur before this log exists.

## Interactive relays

The console and terminal CGIs keep Webmin's normal root identity, session checks
and permission checks. A root supervisor prepares each authorized connection,
starts a systemd service and removes its proxy route when the service exits.
The supervisor does not parse WebSocket, VNC or SSH traffic.

Both browser relays run as fresh, unprivileged processes. They receive a private
session credential and an already-bound listener. The console also receives one
libvirt-authorized display socket, with no libvirt management connection. It has
its own network namespace, no capabilities and no access to Webmin data or host
control sockets. The terminal relay runs inside the existing SSH sandbox and
starts the PTY worker only after the browser's session has been verified.

`relay-sockets.py` passes the sockets over a private Unix socket using Python's
standard library. Its non-root receiver then starts the Perl relay with those
sockets. This avoids systemd's restrictions on passing the browser and display
sockets as standard input and output. Session keys travel through systemd
credentials, never command arguments. The console supervisor releases its
libvirt management connection after opening the display socket.

For serial consoles, the root supervisor holds the exclusive libvirt stream and reads the guest's private serial log. It sends a four-byte, big-endian replay length, up to 64 KiB of history, then live output from the same log cursor. The relay forwards these bytes unchanged. The browser suppresses terminal replies during replay so old queries cannot send input to the guest. Guests without managed logging send a zero replay length followed by live PTY output. Log files are not available for HTTP download.

Abandoned listeners expire after one minute. Connected sessions have an
eight-hour limit; disconnecting stops the service and its descendants. Startup
must reach the relay's readiness check before the CGI returns a connection URL.
A failed service does not fall back to a root relay.

`SIGTERM` stops the supervisor through its cleanup path. `SIGKILL` cannot run that
cleanup: an already-started relay keeps its disconnect and lifetime limits,
but its proxy route remains until Webmin's periodic WebSocket cleanup removes
it after the listener closes.

## Networking privileges

Host-file, inspection, key and seed tasks run in private network namespaces,
with no access to the host's IP network. Image and image-size tasks use the host
network for HTTPS requests. The image task also processes uploads, so upload
checks have the same network access. These tasks have no Linux capabilities and
cannot change the host's network configuration. Their network access is not
restricted to HTTPS by the sandbox; the download code enforces HTTPS and
validates URLs.

Host bridges, guest interfaces, routes and firewall rules require privileges
to change the host's network. Cloudmin validates network choices in its root
process. Libvirt manages virtual networks and connects guests to them or to
existing bridges. Cloudmin uses Webmin's network backends for host bridge
conversion, with saved configuration and automatic recovery. Tool workers cannot
change host networking or connect to the services' control sockets.

Cloudmin does not need `passt` or `slirp4netns` for its current networking. These
tools provide unprivileged guest connections, not host bridge management.

References: [Linux network capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html),
[libvirt daemon modes](https://libvirt.org/daemons.html#operating-modes),
[libvirt passt networking](https://libvirt.org/formatdomain.html#userspace-connection-using-passt).

## CGI requests

The CGI loads Webmin through `init_config()` and calls Cloudmin's backend
functions directly. User-requested changes require POST, write access and a valid
user-bound form token. Backend functions validate storage, catalogue and virtual machine inputs.
Job ownership and audit identity come from the authenticated Webmin user.

Tool workers and interactive relays run in isolated processes. CGI scripts,
the CLI, status collector, controller jobs and relay supervisors run as root.

## Read-only viewers

Webmin's read-only mode vetoes its file and command helpers, but does not block
direct libvirt calls, SQLite writes or ordinary Perl file operations. Cloudmin
checks write access before accepting a mutation, even when a token is supplied.
Read-only pages issue no form tokens or console and terminal connections.

Keep these page-load paths read-only:

* Job recovery returns before starting work for a read-only viewer.
* Image sizes use cached values; only writable viewers can refresh them.
* Missing image, size-cache and virtual machine job directories mean an empty inventory.
* Network inventory uses the safe flag for read-only `ip` commands.

SQLite job reads do not create a missing database. They open an existing database
read-write so SQLite can recover a hot journal after an interrupted transaction.
This repairs the store; it does not resume virtual machine jobs or accept new work.

The shared status collector must write its own state and remove its proxy route,
regardless of who first opens a page. Its startup code temporarily lifts Webmin's
read-only veto, and the dedicated process keeps that permission through cleanup.
It authenticates every subscribing session and rechecks access while connected.
Enabling balloon statistics on an existing guest requires a connected writable
subscriber. Read-only viewers can read reports already enabled on the guest.

## Requirements and limits

The host needs systemd 247 or later, `systemd-run`, and `nss-systemd` user lookup.
On the supported Rocky Linux 10 and AlmaLinux 10 hosts, user lookup is supplied
by `systemd-libs`; Debian 13 and Ubuntu 26.04 use `libnss-systemd`.
Interactive relays also require Python 3, `Net::WebSocket::Server` and Webmin's
Terminal module. SSH terminals additionally need the OpenSSH client.
Tool dependencies include qemu-img, OpenSSH client tools, xorriso and bsdtar
(`libarchive-tools` on Debian and Ubuntu); custom-image
inspection also needs libguestfs, its Perl bindings, YAML::XS, the running kernel
and its modules, and the `kvm` group. Missing tools or failed isolation cause an error,
without a privileged fallback.

Image tasks have a one-hour deadline. Closing a page does not cancel its
background job. Inspection is limited to three minutes, seed generation to one
minute, key validation to 30 seconds, and size lookup to 20 seconds. Services
limit process count, memory and individual file size.
The maximum imported image file size is configurable in Cloudmin's module
settings. By default, imports use available space instead of a fixed size cap.
The controller checks temporary storage and the destination pool, then bounds
each image worker by that budget and its own filesystem's free space. Space
checks leave a 256 MiB reserve. Browser uploads use the same configured cap.
These limits do not provide a per-task disk quota. Reflink or sparse copies are
used where supported; uploads and inspection can need an additional temporary
copy on the worker filesystem.

## Installation readiness

After packages and services are configured, `cloudmin-install.sh` calls
Cloudmin-Config's Readiness plugin. It boots this same isolated KVM appliance
with a disposable 64 KiB disk. The inspection service has a three-minute timeout
and a 2 GiB memory limit. The appliance and private task files are cleaned up
after success or failure. This is an installation check, not a periodic task.

A failed boot stops installation and preserves the worker error in the
installation log. Cloudmin does not enable `its=off`, `pci=nomsi`, or software
emulation to make the check pass. Installation can succeed on Ubuntu if the
appliance boots normally, including after a kernel or hypervisor fix. This check
verifies appliance boot; ordinary virtual machine workloads still need testing.

Boot failure has been reproduced with Ubuntu kernel 7.0.0-34 under ARM64
Apple/UTM nested virtualization. On a physical AMD x86-64 host, Ubuntu 26.04.1
with that kernel boots the appliance and ordinary Debian and Ubuntu guests
without interrupt workarounds. Physical ARM64 remains untested. The installer
suggests a tested Rocky Linux 10 or Debian 13 host for the affected UTM
environment, or retesting after kernel or hypervisor updates. It does not
identify every appliance failure as this issue.

## Cancellation and recovery

Cancelling a task stops its entire service, including external tools and their
children. Cloudmin removes private inputs and outputs after success or failure
and reports cleanup errors. Image and virtual machine job records retain the service identifier
while it is active so recovery can stop an abandoned worker. Root-owned leases
also let later requests clean up state left by a crashed root process after two
hours. Services still have their own deadlines if the process that started them
disappears.

State lives under `/var/lib/private/cloudmin-workers`. The links under
`/var/lib/cloudmin-workers` are created by systemd. No persistent user account or
libvirt management-group membership is added.

## Tests

Run `prove t/` from the module directory for local policy, validation and job tests. The tests find Webmin in a sibling source checkout or in the parent directory of an installed module. Set `WEBMIN_ROOT` to test against another Webmin tree. Running `prove *.t` from the `t` directory also works.

When run as root, the worker-task test checks that workers reject root, then drops to `nobody` before processing fixtures. To run the whole suite as `nobody` on an installed Debian host:

```sh
cd /usr/share/webmin/server-manager
runuser -u nobody -- prove t/
```

On a disposable Cloudmin host, `t/live/check-workers.pl` checks actual UIDs, denied access,
cross-task isolation, hostile output, cancellation, deadlines, descendant
cleanup, checksums, SSH keys and seed generation. The image, inspection and virtual machine
creation fixtures exercise the full import and provisioning paths through
Webmin and libvirt. `t/live/check-cgi.py` checks ordinary root CGI execution,
authentication, POST and token checks, catalogue changes and read-only access.
`t/live/check-readonly.py` checks fresh stores, denied mutations with missing or
foreign tokens, concurrent read-only and writable sessions, and collector startup
and idle cleanup. It requires an idle job queue and closed browser sessions;
existing job and size-cache stores are moved aside and restored after the test.
The creation test also checks that libvirt runs the guest's QEMU process without
root. `t/live/check-theme-hooks.py` checks guest navigation through Webmin's
theme hooks, including SPA navigation. It also checks how the LVM module finds
a guest's host through Cloudmin. These live tests must not run on a production host.

`t/live/check-access.py` creates two diskless guests and temporary accounts. It
submits permissions through Webmin Users and checks that the saved grants and guest
assignments reload correctly. It also checks separate action permissions, token
misuse, denied host operations, filtered live status and revocation of virtual machine and
console access. Denied requests must leave guest state, job files and cache files
unchanged. Test accounts and guests are removed afterward. Queuing background
jobs and recovering unfinished jobs require a host administrator.

`t/relay.t` compares the relay's session-key check with Webmin's xterm helper.
`t/console.t` checks setup failures and route cleanup without requiring systemd.
On a disposable host, `t/live/check-relay-startup.pl` checks failed service startup,
and `t/live/check-console.py` checks VNC, relay privileges, abandoned startup,
dead browser expiry and cleanup after a relay crash. Browser checks also pause
JavaScript to verify that protocol pings keep idle serial sessions connected.
Its `--protocol-only` option skips Chromium checks.

`t/serial-log.t` checks replay limits, rotation, private files and virtual machine creation, startup and removal. `t/serial-console-browser.mjs` checks replay with real xterm, including suppression of replies to old terminal queries. On an x86-64 Linux test host, `t/live/check-serial-history.py` boots a diskless guest with a real login prompt and checks replay, native rotation and both navigation layouts. It needs a static BusyBox, agetty, cpio and Chromium. It removes its guest, accounts and recordings afterward.

`t/live/check-console-relay.py` checks partial writes under backpressure and
verifies that keepalive frames never reach the guest as input.
The terminal fixtures use `t/live/terminal_client.py` to check real SSH login,
resizing, large transfers, privilege isolation and cleanup.

## Clone preparation

`clone_prepare` mounts only independent disk copies in its private directory. Like the inspection task, it has KVM access and a private copy of the host kernel. Networking is disabled, and guest commands run inside the appliance. The temporary filesystem must have room for all disk capacities, metadata and appliance work.

Prepared mode clears the copied machine ID, SSH host keys, DHCP leases and cloud-init state before boot. The mode that keeps guest settings leaves these intact and creates a stopped virtual machine with autostart disabled. Both modes reset `/etc/hostid`, replace copied Virtualmin Pro credentials, and require exactly one Linux installation that libguestfs can inspect.

Pro credential replacement uses Virtualmin's offline API without license validation, downloads or repository setup. If replacement fails, Cloudmin does not define or start the clone.

The privileged controller reserves the source UUID and destination name and copies disks through libvirt. After copying, it merges temporary file overlays, removes temporary LVM snapshots, or restarts the source after a requested shutdown. Failed source cleanup keeps both reservations for recovery. After guest preparation, the controller accepts output files only when the worker service and appliance have stopped. A separate read-only task checks them before import.

## Backup archives and transfers

`backup_archive` uses Python 3's streaming tar reader in a network-isolated worker. It accepts only the disk, firmware, key and XML files listed in the manifest, with size limits and matching checksums. Extraction uses fixed filenames and rejects links and paths from the archive. The controller takes ownership of output files only after the worker stops. Each disk is checked separately before restore imports it.

`backup_transfer` runs SFTP and cloud clients with network access but without Webmin configuration, libvirt sockets or guest storage. Only the selected archive, credential files and matching SSH known-host entries enter its private directory. Credentials are supplied through private files, provider configuration or environment variables. Native SSH rejects unknown and changed host keys; cloud API connections require certificate verification. The job records each worker ID so cancellation and cleanup can stop it.

`backup_host_key` scans a destination's public SSH keys without credentials, with a 30-second limit. The controller compares them with existing SSH trust or an approved replacement. Unknown servers and changed keys require an administrator to confirm the displayed fingerprints. Scanning alone never saves trust.

See [Full virtual machine backups](backups.md) for archive contents, destinations, restore behavior and live tests.

### Setup-script edition boundary

`pro/SetupScripts.pm` validates custom scripts and reads host files using Webmin's file permissions. `pro/guest-scripts.pl` executes the scripts inside the guest. It is included in the cloud-init seed only when custom scripts are selected, and the common guest helper refuses to run scripts without it.

Host software jobs check that Pro is still installed before starting or resuming a worker. If Pro has been removed, recovery fails instead of launching saved scripts. Package installation and the official Virtualmin installer remain available in Cloudmin GPL.
