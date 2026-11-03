# Virtual machine API

The UI, `cloudmin`, `api.cgi` and `api.pl` call `call_vm_api(1, action, input)`.
Webmin authentication and module access apply to HTTP requests. Changes require
POST and a signed `token` returned by `options`. Send a JSON object or form fields;
responses are JSON with `version: 1` and either `result` or `error`. Check the
response's `error` field: Webmin's CGI server returns HTTP 200 for JSON responses.
HTTP clients must also pass Webmin's referer check: send a `Referer` from the
same Webmin origin, or use its supported `User-Agent: Webmin` API convention.

Cloudmin module ACLs also apply. Delegated users can call `options` and use
permitted power and password reset actions on their assigned virtual machine UUIDs. Their `options` response
lists the `power`, `force`, `console`, `terminal` and `password` grants under `permissions`.
It includes a token when any of these grants is enabled and Webmin is not in
read-only mode. Host resources are omitted.

`power` allows `start`, `shutdown`, `reboot`, `suspend`, `resume` and `autostart`;
`force` allows `force_off` and `reset`; `password` allows `reset_password`. The `machines` action lists only guests the caller may view. Other API actions, including `power_cycle`
and job history, require a host administrator. Graphical consoles and SSH
terminals have separate endpoints and permission checks. Tokens belong to the
authenticated user and do not grant permissions.

Host administrators can view, cancel or recover other administrators' jobs.
Read-only administrators can view progress but cannot change jobs. New requests
and repeated submissions remain tied to the user who submitted them.

On Pro hosts, license restrictions also apply to new changes. License management, inventory, accepted jobs, job recovery and network rollback remain available. See [License management](licensing.md) for grace periods and the actions below.

Actions:

| Action | Input | Result |
| --- | --- | --- |
| `license` | None | Public host license status; never the key |
| `check_license` | `token` | Rechecked license status, including any restriction |
| `change_license` | `token`, `serial`, `license_key` | Validates and saves a replacement license |
| `deregister_license` | `token`, `confirm=1` | Removes this host's saved license and repository credentials |
| `machines` | Optional `id` (UUID or exact name) | Visible virtual machines sorted by name, or one matching record |
| `options` | None | Current images, storage, networks and capabilities; form token for users with write access |
| `review` | Creation settings | Validated settings without creating a virtual machine |
| `create` | Creation settings | Job ID, state and progress; repeating the same request with its token and optional `attempt` returns the existing job |
| `status` | `job` | Job status, including jobs started by other administrators |
| `list` | None | All owners' recent jobs and unfinished work |
| `cancel` | `job` | Request cancellation at the next safe point |
| `cancel_cleanup` | `job`, `confirm=1` | Cancel an unfinished creation and remove its owned resources, including a guest already in software setup |
| `recover` | `job` | Check existing resources or retry failed cleanup |
| `discard` | `job` | Abandon the remaining changes of a failed settings update after checking the original hardware definition and removing unused new disks; completed disk growth is kept |
| `start` | `id` (virtual machine UUID) | Request startup of a stopped virtual machine |
| `shutdown` | `id` (virtual machine UUID) | Request a clean guest shutdown |
| `reboot` | `id` (virtual machine UUID) | Request a guest reboot |
| `suspend` | `id` (virtual machine UUID) | Pause a running guest, keeping its memory and devices |
| `resume` | `id` (virtual machine UUID) | Continue a paused guest |
| `reset` | `id` (virtual machine UUID), `confirm` (`1`) | Reset virtual hardware immediately; unsaved data can be lost |
| `reset_password` | `id` (virtual machine UUID), `username`, `password` | Set an existing account password on a running guest with a responding agent |
| `power_cycle` | `id` (virtual machine UUID) | Job: wait for a clean shutdown, then start with the saved settings; never force power off |
| `force_off` | `id` (virtual machine UUID), `confirm` (`1`) | Immediately power off an active virtual machine, including a paused guest or one stuck shutting down |
| `autostart` | `id` (virtual machine UUID), `enabled` (`0` or `1`) | Save whether a persistent virtual machine starts at host boot |
| `snapshots` | Optional `id` (virtual machine UUID) | Snapshot history and revision for one virtual machine, or host inventory |
| `snapshot_create` | `id`, `revision`, `label`, optional `description`, `mode`, `shutdown`, `restart` | Queued snapshot job; `mode` defaults to `prepared`. `shutdown=1` permits a clean shutdown if the agent is unavailable; `restart=1` starts the virtual machine after success. Explicit `unprepared` remains available to API clients |
| `snapshot_restore` | `id`, `revision`, `snapshot`, `confirm` (`1`), optional `shutdown`, `restart` | Queued restore job; a running virtual machine requires `shutdown=1`. It stays stopped unless `restart=1` |
| `snapshot_delete` | `id`, `revision`, `snapshot`, `confirm` (`1`) | Queued deletion; file layers are merged and saved LVM volumes are removed |

### Machine inventory

`machines` allows GET and needs no token. With no `id`, it returns an array sorted by name. With an exact name or UUID, it returns one record. Missing and inaccessible guests return the same error. Ambiguous names require a UUID.

Records contain `id` (UUID), `name`, `state` (`running`, `stopped` or `paused`), `cpus`, `memory_mib`, total writable `disk_gib`, `addresses` and a boolean `autostart`. A missing disk measurement is `null`. When known, `template` and `plan` contain their names and `created` contains the creation Unix timestamp. Private domain XML, credentials and job requests are excluded.

### Host bridge removal

Host administrators can remove an unused, persistent bridge with one Ethernet
port. The bridge's current IP addresses, routes and DNS move to that port.
NetworkManager, Netplan and Debian ifupdown are supported. Attached virtual
machines (including stopped guests), dependent virtual networks, VLANs and
macvlans block removal. These checks cover both the bridge and its Ethernet port.
Active virtual machine jobs, another pending bridge change and unsupported host configurations
also block removal.

| Action | Input | Result |
| --- | --- | --- |
| `bridges` | None | Host bridge inventory, excluding libvirt-managed NAT and routed bridges |
| `bridge_remove_review` | `name`, `token` | Destination Ethernet interface, addresses, timeout and `revision` |
| `bridge_remove` | `name`, `revision`, `token` | Public transaction state, including its `id` |
| `bridge_status` | Optional transaction `id` | Current public state, or `null` if there is no transaction; rejects an ID that does not match |
| `bridge_confirm` | `id`, `token` | Keeps the new settings after checking host connectivity |
| `bridge_rollback` | `id`, `token` | Requests recovery in an independent worker |

`bridges` and `bridge_status` allow GET. The other bridge actions require POST and
a signed token; read-only users cannot submit them. The root CLI supplies the token. Bridge creation is currently available through the web interface only.

Use the same client address for review and submission. The revision check rejects
settings changed since review. Responses omit private configuration backups.

```sh
cloudmin list-bridges
cloudmin remove-bridge --name br0 --review
cloudmin remove-bridge --name br0
cloudmin get-bridge-status --id TRANSACTION_ID
cloudmin confirm-bridge --id TRANSACTION_ID
```

Reconnect using the host address if needed. Wait for `state: "confirm"`, then
confirm as the user who started removal. The confirmation timer starts when the
change is submitted and includes time spent applying it. Without confirmation,
Cloudmin restores the bridge and its saved configuration. `bridge_rollback`
requests this recovery immediately. Other administrators may recover expired or failed
transactions. A confirmed removal cannot be undone with `bridge_rollback`.

### Host storage

Storage reads require host administrator access. Reviews and changes also require manage access, a signed `token` and a session with read-only mode disabled. HTTP clients must use POST for reviews and changes. The `storage` action allows GET without a token. The root CLI supplies the token automatically. All storage actions finish before returning a result.

| Action | Input | Result |
| --- | --- | --- |
| `storage` | None | Active and inactive pools, volume ownership, revisions, storage totals and unregistered groups in `lvm_groups`; group discovery errors appear in `lvm_group_error` |
| `register_pool` | `name`, `type` (`dir` or `logical`), `path` or `group`, optional `autostart` (`0` or `1`), `token` | Newly registered pool |
| `pool_start`, `pool_stop` | `id`, `revision`, `token` | Updated directory pool |
| `pool_autostart` | `id`, `revision`, `enabled` (`0` or `1`), `token` | Updated directory pool |
| `volume_review` | `pool`, `volume`, `token` | Volume identity, `usage.owners`, `usage.reason` and a deletion `revision` when allowed |
| `delete_volume` | `pool`, `volume`, `revision`, `confirm=1`, `token` | Deleted volume record |
| `pool_review` | `id`, optional `stop` (`0` or `1`), `token` | Pool identity, `stop_required`, `usage.owners`, `usage.reason` and current `revision` |
| `unregister_pool` | `id`, `revision`, `confirm=1`, optional `stop` (`0` or `1`), `token` | Removed registration record; its data remains intact |

Identify pools by their UUID from `storage` and volumes by their exact name within the pool. The CLI also accepts a pool name if it identifies exactly one pool, including LVM-thin destinations such as `guests/thin`.

LVM registration uses an existing volume group. It does not create a group or format disks. The raw API disables startup with the host unless `autostart=1` is supplied. The CLI command `create-pool` enables it by default; use `--no-autostart` to disable it.

Before deleting a volume or unregistering a pool, request a review. Send the returned `revision` with `confirm=1` in the removal request. Reviews report references and any reason removal is blocked without changing storage. Cloudmin repeats the checks under the host lock before making changes. References from running or stopped guests, saved states, snapshots, imported images and dependent disks block removal. Pending operations and references that cannot be checked also block it.

Unregistration removes a saved directory or parent LVM pool definition from libvirt. It preserves files, logical volumes, volume groups and thin pools. LVM-thin destinations cannot be unregistered separately. The `pool_start`, `pool_stop` and `pool_autostart` actions support directory pools only.

To unregister an active pool, send `stop=1` to both `pool_review` and `unregister_pool`. The default is `0`, which requires an inactive pool. Changing this choice or the volume group's identity invalidates the review. For LVM, stopping deactivates every logical volume in the group, including thin volumes. Host mounts, swap, open volumes and other block devices using those volumes prevent the stop. Register the group again to use it in Cloudmin.

If the volume group no longer exists, its inactive registration can still be removed after checking for references. Cloudmin must be able to read the LVM inventory and confirm that the group is absent. An active pool or a failed inventory read still blocks removal.

A failed stop keeps the registration. If stopping succeeds but removing the registration fails, the error reports that the pool is stopped. Request a new review before retrying.

```sh
cloudmin list-pools --json
cloudmin list-volume-groups
cloudmin create-pool --name guests --group guests
cloudmin list-volumes --pool guests/thin
cloudmin delete-volume --pool guests/thin --volume leftover --review
cloudmin delete-volume --pool guests/thin --volume leftover --yes
cloudmin create-pool --name extra --path /var/lib/libvirt/extra
cloudmin stop-pool --pool extra
cloudmin unregister-pool --pool extra --review
cloudmin unregister-pool --pool extra --yes
cloudmin unregister-pool --pool guests --stop --review
cloudmin unregister-pool --pool guests --stop --yes
```

### Snapshot revisions

Snapshot changes use the `revision` returned by the `snapshots` request for that virtual machine.
Read-only inventory omits the revision needed for changes and does not probe
guest-agent preparation. Snapshot changes use the same signed tokens, ownership,
conflict checks, progress and retry rules as other virtual machine operations.
A snapshot saves all writable disks and libvirt's hardware configuration. It excludes memory, firmware variables and external
services. Snapshots support private managed raw/QCOW2 files and LVM disks, with up to 20 snapshots per virtual machine. A snapshot cannot mix file and LVM disks.

Live LVM snapshots briefly pause the guest and require a disk cache mode of `none`, `directsync` or `writethrough`. Restoring copies data back to the original logical volumes while the guest is stopped. The host needs temporary space under `/var/tmp` for the largest disk's full capacity plus 256 MiB.

Libvirt support and permission errors are reported
at the failing job step; host versions are not used to predict failure because
distributions may backport fixes. An operation with an uncertain or partial
result keeps the affected resources reserved for recovery.
Snapshots created outside Cloudmin remain visible but cannot be changed here.
Inventory includes `allocation` in bytes for saved external disk files, or null
when unavailable. It counts allocated filesystem blocks, excludes shared backing
files, and does not estimate the space that deletion would free.
Each snapshot's `state` comes from libvirt's saved metadata. The restore form
defaults to starting afterward for `running`, `blocked`, or `disk-snapshot`
states, and leaving it stopped otherwise. Users can override this choice;
API restores still require explicit `restart=1` to start afterward.
For a running virtual machine, `preparation_available` reports whether the guest-agent probe
currently succeeds. Creating a prepared snapshot checks again and requires libvirt
to freeze the filesystems successfully. Shutdown consent never causes downtime
when the agent is available at submission. A requested shutdown waits up to two
minutes for normal guest shutdown and never forces the virtual machine off. Startup runs only
after the snapshot operation succeeds; recovery retries a failed startup without
repeating the disk operation.
See [snapshot help](../help/snapshots.html) for preparation and restore behavior.

`reset_password` runs synchronously and returns `id`, `name` and `action` after the agent accepts the change. It requires the separate `password` grant or host administrator access, plus a signed token. It refuses stopped guests and unavailable agents. Passwords are neither logged nor kept in job records; failed calls do not return raw agent errors. This changes only the guest account password, not SSH authentication settings. Send the password in the POST body or CLI standard input, never in a URL or command argument.

Lifecycle actions return `id`, `name` and `action` after libvirt accepts the
request. Shutdown and reboot finish asynchronously. These controls apply to
the host's virtual machines and require a Webmin user with write access to Cloudmin.
The overview uses the same API and records changes in Webmin's action log.

Use `force_off` only when a clean shutdown cannot complete. It does not delete
disk files, but unsaved data will be lost and guest filesystems may be damaged.
Virtual machine details and the editor's shutdown waiting page open a confirmation before
submitting this action.

The optional `attempt` is a 32-character lowercase hexadecimal identifier.
Together with the signed `token`, it identifies a job. Omitting it preserves the
original API behavior. Repeating that pair returns the existing job,
including a finished job, without rerunning it. Password drafts are also scoped
to this pair.

Browser forms generate attempt IDs on submission and POST to `submission.cgi`
with `token`, `kind=vm`, `operation`, `proposed` and the previous `attempt` (empty
on first submission). The response contains the selected `attempt`, or `error`.
After a failed or cancelled job finishes cleanup, the server records one new
attempt. Concurrent retries and retries after a lost response return that same
attempt. Active and successful jobs keep their IDs; partly completed operations
require recovery. This check creates no virtual machine and stores no
provisioning credentials.

Once the virtual machine is created, resubmitting creation cannot restart failed
or cancelled software setup. Check the existing guest's setup status.

Image forms use `kind=image`, newline-separated catalogue IDs in `selection`
(empty for a custom import), and `image_attempts`, a JSON object mapping each
selection to its attempt ID. Submit the returned map with the image form.
Successful images in a batch keep their original imports; only failed imports retry.

Resubmitting an existing creation attempt keeps its original settings.
Changing the virtual machine name, image or installation source requires a new
attempt after failure and cleanup, or a fresh form for a separate creation request.

`options.presets` lists saved `template` and `plan` entries and their default IDs.
Pass `template` and/or `plan` to `review` or `create` to fill omitted settings.
Explicit fields take precedence, including empty values and zero, except that
`require_fqdn=0` cannot disable an enabled template hostname requirement. API calls do
not automatically select the UI's default template or plan. Submit passwords,
virtual machine names, hostnames and static guest addresses separately. Presets
do not store passwords, license credentials or individual guest identities.

Template and plan editors accept repeated saves from an earlier form, including
one restored with browser Back. The latest submission replaces the displayed
settings. Template sections preserve the current settings in other sections.
Preset saves, copies and list actions do not require a revision value.

Bundled templates include Default Template and four Virtualmin variants:
GPL and Pro, each with Apache or Nginx. The Virtualmin templates use full
installation by default; minimal installation remains available.
Default Plan supplies 2 CPUs, 2 GiB of memory and a 20 GiB disk. On a one-CPU
host, the unedited Default Plan uses 1 CPU. Both lists always have a default.
Unset template settings inherit Default Template; an explicitly empty package
list skips package installation. An explicit ISO source omits inherited guest
software setup.

Templates expose **Require fully qualified hostname** under **Basic settings**.
The setting is `require_fqdn`, with `1` requiring a hostname such as
`host.example.com` and `0` allowing short names. An unset value inherits Default
Template, which initially allows short names. Virtualmin always requires a
qualified hostname, regardless of this setting or the template name. Supply it
in `name` or override it with `hostname`. Validation checks the format, not DNS.
The rule is kept in the submitted request and does not apply to ISO installers.

The template editor makes package inheritance explicit: **Use Default Template**
omits `packages`, **None** saves an empty string, and **Listed packages** saves a
nonempty list. Default Template offers only the latter two choices. Saving other
software options preserves the selected package source.

Default Template and Default Plan cannot be deleted. Other templates can be
deleted only when no existing virtual machine or pending creation uses them.
Deletion checks share the creation submission lock. Guests retain their template
ID in domain metadata. Deleted bundled templates remain excluded from the
available choices.
Supplied descriptions are cleared when a template's name or settings change;
custom descriptions are retained. Each supplied description is translated as a
complete message.

Built-in Virtualmin template names update on save to match the edition, web server
and PostgreSQL option, without mentioning installation size. Duplicate automatic
names receive a numeric suffix. A manually changed name or a copy's chosen name
stays fixed. Default Template is never automatically renamed.

Guest setup accepts `packages` (up to 200 whitespace-separated package
names, at most 8,192 characters), `before_script` and `after_script` (up to 16,384
characters each). Package names cannot be options, URLs, paths or wildcards.

Custom scripts require Cloudmin Pro through the UI, JSON API and CLI. Cloudmin GPL can install guest packages and either Virtualmin edition; Virtualmin Pro still needs its own license.

In GPL, set `*_mode=none` to clear a script. Creation rejects inherited active scripts before allocating resources. After Pro is removed, templates remain readable: you can keep their scripts unchanged while editing other settings, or explicitly clear them.

Each script also accepts a `_mode` field (`none`, `file` or `inline`) and a
`_path` field for an absolute path on the Cloudmin host. For example, use
`before_script_mode=file` with `before_script_path=/srv/scripts/prepare.sh`.
Without a mode, a supplied path selects `file`, a script body selects `inline`,
and neither selects `none`. Only the selected source is used. File reads follow
the Webmin user's global file access permissions and configured Unix user.
Files must be regular UTF-8 text files of at most 16 KiB. Templates save paths;
creation reads their contents before submitting the job. Workers use the saved contents.
If `_mode` is omitted, an explicit body or path overrides the template's script source.

The guest uses apt-get, dnf or zypper and its configured repositories;
Cloudmin does not translate package names between distributions or upgrade
unrelated packages. An unsupported package manager fails the package step.

Guest setup requires a cloud image with systemd, `start=1` and managed virtual
machine SSH keys. For guests using DHCP or a static IPv4 address, requests with
software setup check host IPv4 forwarding and the selected libvirt NAT or routed
network's rules before downloading images or creating disks. Missing rules stop
submission with an error. The check
supports nftables and iptables. It does not test guest DNS, repository access,
other firewall policies, host bridges or IPv6-only networking. Creation without
software setup skips it.

Host Overview shows the same checks, even when healthy host details are hidden.
Host administrators can use **Restore network rules** after virtual machine
operations and pending bridge changes finish. It restarts the active libvirt
network daemon, enables IPv4 forwarding if needed and checks the rules again.
Networks and guests keep running. Recovery restores the active rules without
changing the saved firewall configuration. A later firewall reload can remove
libvirt's rules again.

After cloud-init finishes, it runs the preparation script,
installs packages and optional Virtualmin, then runs the final setup script.
Scripts run as root using `/bin/sh -e` with no interactive input.
They receive `CLOUDMIN_VM_UUID`, `CLOUDMIN_HOSTNAME` and `CLOUDMIN_GUEST_USER`.
They can explicitly change users, for example with
`runuser -u "$CLOUDMIN_GUEST_USER" -- command`. No scripts execute on the host.
Do not embed passwords or license credentials in reusable scripts.

Virtualmin options are `software` (`none`, `virtualmin-gpl`, `virtualmin-pro`),
`virtualmin_bundle` (`LAMP` or `LEMP`), `virtualmin_type` (`full` or `mini`),
`virtualmin_postgres` (`0` or `1`), `virtualmin_ssl` (`0` or `1`) and
`webmin_register` (`0` or `1`). Defaults are LAMP, full installation, no PostgreSQL,
hostname certificates enabled and Servers Index registration enabled. Supply
`virtualmin_serial` and `virtualmin_key` on each Pro `create` request. These
credentials never appear in presets, review responses, public jobs or seeds.

When **Enable Virtualmin installation?** is disabled in Module Configuration (`virtualmin_enabled=0`), `review` and `create` reject requests to install Virtualmin. Templates that select Virtualmin directly or inherit it from Default Template are also blocked, even if the request overrides `software`. Re-enable the setting to use them.

This setting does not affect package installation or setup scripts. Jobs submitted before it changed keep their settings.

Set `webmin_register` to `1` in a template or creation request to add the guest to the host's Webmin Servers Index after installation. Registration saves the initial guest username and password in the host's protected Servers Index configuration. The setup job deletes its copy of the password when setup ends. Cloudmin excludes its changes to these login files from file-change and undo logs. Without a saved password, Servers Index asks for the guest login and remembers it for the browser session.

Only the host's `root` Webmin login can register guests or open Cloudmin's Webmin tab. Servers Index permissions still apply. Requests by other users force `webmin_register` to `0` and retain no proxy password.

The `software_webmin` phase registers Webmin after installation. A registration failure leaves the job complete with a `webmin_warning`. Retry by choosing **Open embedded Webmin** on **Remote Access → Webmin**.

With registration enabled, `software_url` points to the guest's Webmin tab on the host. By default, it offers direct HTTPS in a new tab or an embedded proxy for fully trusted guests. The proxy also works behind NAT; direct access requires the browser to reach the guest. Without registration, `software_url` points directly to the guest's HTTPS address.

Virtualmin also requires a fresh supported cloud image, a fully qualified hostname
and Internet access. Supply it in `name` or override it with `hostname`.
Full installation requires at least 2048 MiB of memory; minimal requires 1024 MiB.
Both require a 20 GiB disk. The creation job adds `software_boot` and the applicable
`software_before`, `software_packages`, `software_download`, `software_install`
and `software_after` phases.

When creation reaches software setup, `vm_created=1` and `can_cancel=1`.
The creation reservation is released, so power controls, edits, snapshots and
deletion remain available. Cancellation stops the
guest setup service and keeps the virtual machine and its disks; it does not undo
installed software. If the guest cannot be reached, Cloudmin reports that stopping
setup could not be confirmed. Powering off or deleting the guest ends monitoring.
Cancellation marks the current software phase `cancelled` and supplies an
explanation in `error`. Deleting the guest also cancels setup and clears
`vm_created`; an inventory lookup failure remains an error, not a deletion.
Successful Virtualmin jobs include `software_url`.

Active Jobs buttons submit signed POST requests without a confirmation page. **Cancel and clean up** requests removal of an unfinished creation, including a guest already in software setup. Cleanup runs in the background and removes the guest, disks recorded by its job, firmware variables, managed SSH key and temporary files.

Cleanup reserves the guest before requesting cancellation and waits for its worker. It refuses changed disks, snapshots or concurrent operations and keeps shared source images. Failed cleanup remains visible for retry. This action cannot delete a completed creation.

Exited Linux workers that remain as zombie processes do not hold job locks indefinitely. Recovery releases only a lock still owned by that exited process. Cancellation never signals a process based only on an old PID.

Reopening a job monitors the existing installation without running it again.
Failed or interrupted scripts are never repeated automatically. The complete
sequence has a two-hour time limit inside the guest.
Virtualmin's configuration wizard remains available after installation.

Script, package and installer failures leave details in
`/var/lib/cloudmin-install/install.log` inside the guest. Errors during initial
guest setup can occur before this log exists; check cloud-init's status and logs
for those errors.

Once submitted, a job uses its resolved settings. Editing or deleting its template
or plan does not change that job. Reusing its token and attempt ID with the original
preset IDs returns the existing job. Changing either preset ID requires a new attempt
after failure and cleanup, or a fresh token for a separate creation request.

Creation settings: `install_source` (`cloud`, the default, or `iso`), `name`,
`image` (Image Manager job ID or `catalogue:<id>`), `pool` (pool UUID), `cpus`, `memory_mib`,
`disk_gib`, `network` (key from `options`), `start`, and `autostart`.
Cloud images also use `username` and `ssh_keys` (one public key per line),
as described below.

`options.catalogue_images` lists enabled images for the host architecture, with
IDs such as `catalogue:rocky-linux-10` and a `downloaded` flag. The built-in Default
Template selects this Rocky Linux 10 cloud image. `options.images` retains ready
imports for clients using image job IDs.

A catalogue selection saves its download metadata at submission. Before disk
allocation, the worker reuses a verified matching import or downloads into the
selected file pool. For an LVM destination, the download uses an available file
pool instead. Creations targeting the same asset and cache pool share an active import;
ready images can be reused across pools. The `image` phase reports `image_progress`
with `name`, `state`, `bytes`, `total` and `cached` (whether a ready image was reused). Other guests can continue disk operations while it downloads.
The original catalogue ID stays in the request so repeated submissions match the same job;
the source volume is checked again before disk allocation. Download failure stops
creation without allocating guest resources. Cancelling a creation does not cancel
its shared import; Image Manager controls that import separately. Cached images
are not automatically refreshed when a publisher replaces a file at the same URL.

With `install_source=iso`, `image` must identify an ISO import or catalogue entry. Creation
allocates an empty system disk of at least 1 GiB, using QCOW2 for file pools or raw for LVM.
It mounts the shared ISO in the read-only CD/DVD drive and boots from that drive before the system disk.
Use **Remote Access → Graphical console** to install the OS, then eject the ISO or set the system
disk as the first boot device.

ISO installs skip cloud-init and managed SSH keys. Account, hostname and guest
IP-address settings are left to the installer; Cloudmin ignores those inputs.
`network` still chooses the libvirt network or host bridge for the virtual machine.
Creating a virtual machine from an ISO does not require xorriso or ssh-keygen.

Cloudmin does not inspect custom ISO contents. Choose media matching the host's
CPU architecture and the selected firmware. Known catalogue architecture and
firmware constraints still apply.

### Installer compatibility

Installers need drivers for the generated virtual hardware: a virtio system
disk, a virtio-scsi CD/DVD drive, and virtio network and graphics devices.
Linux and BSD compatibility depends on the specific release, architecture
and firmware; accepting an ISO does not establish that it will install or boot.
A complete OS installation followed by a boot with the ISO ejected is required
before qualifying an installer.

On 2026-10-11, Alpine 3.24.2 virt ARM64 passed a full installation on the Rocky
Linux 10.2 ARM64 Cloudmin test host under UTM. The guest used UEFI, one CPU,
512 MiB of memory and a 2 GiB system disk. The test verified the vendor SHA-256
checksum, imported the ISO through Cloudmin, installed through the serial
console, ejected the ISO through the virtual machine API, and cold-booted the installed
system. It confirmed an ext4 root filesystem on `/dev/vda2`, then exercised
media changes and snapshot restore. All fixture resources were removed.
This does not verify other installers, x86-64, BIOS, or graphical installer UI.

To repeat this on a disposable Cloudmin host, download an Alpine virt ISO for
that host's architecture and verify its vendor checksum, then run:

```sh
perl t/live/check-iso-install.pl /usr/libexec/webmin/server-manager /absolute/path/alpine-virt.iso
```

The test needs Python 3, virsh, an active libvirt network with DHCP and internet
access, and the `t/live/iso-alpine-console.py` helper beside it. It creates and
removes its own guest and storage pool. Without the ISO argument, it runs the
faster lifecycle check with nonbootable test media.

### Cloud-image account settings

The following account settings apply to `install_source=cloud`.

`auth_type` selects `keys` (default), `password`, or `both`. Supply `ssh_keys` for
key authentication and `password` for password authentication. `username` may
be `root`; other initial users get sudo access. Password authentication enables console and SSH login.

The web form submits directly to `create`; `review` is an optional API validation
call and does not add a step to the web form. The web form's default authentication
method comes from the selected template and is initially password authentication.

Review stores a password hash privately. It can be reused for one day with the
same token, attempt ID (if supplied), Webmin user and initial username. Subsequent review or create calls
with that same identity can omit `password`. Changing the username requires a new password.
For automatic Servers Index login, include `password` in the `create` request;
the saved hash cannot be used to sign in.
Responses never contain passwords or hashes; review reports `password_set`.
The hash is removed from the job record when creation finishes, but remains in
the guest's cloud-init seed to initialize the account on first boot.

Memory and disk values may include decimals. Without unit selectors, `memory_mib`
uses MiB and `disk_gib` uses GiB. The optional `memory_mib_units` and `disk_gib_units`
fields override these units with a byte multiplier: 1, 1024, 1048576, 1073741824,
1099511627776, or 1125899906842624. Memory must resolve to whole MiB; disk sizes
round up to a 512-byte sector. Review returns normalized MiB and GiB values.

New guests reserve a CPU maximum of twice the requested count, capped at the host's logical CPU count. Only the requested CPUs start online in QEMU. Q35 and ARM virt guests also receive 16 PCIe root ports, shared by initial devices and later additions. These definitions do not allocate extra CPUs or memory to the guest.

The read-only SCSI CD/DVD drive holds the selected installer ISO. For cloud images, it starts empty.

The initial memory maximum equals the requested allocation. Live balloon adjustment can reduce that allocation or restore it up to the maximum. A higher maximum can be saved while running and takes effect after a full shutdown and start. DIMM hotplug, `<maxMemory>` and its NUMA setup are not used in this implementation.

Optional settings: `firmware` (`auto`, `efi`, `bios`), `hostname`, `description`,
`mac`, `address_mode` (`dhcp` or `static`), `ipv4`, `ipv6` (CIDR notation),
`gateway4`, `gateway6`, and `dns` (space- or comma-separated server addresses).

Known guest limitation: Rocky Linux 10 with cloud-init 24.4 leaves automatic addressing enabled for an omitted IP family in a static configuration. An IPv6-only request can acquire IPv4 through DHCP; an IPv4-only request can acquire IPv6 through router advertisements. This affects both creation and prepared cloning. Dual-stack static settings passed live tests.

Cloud-image compatibility is checked during review, submission and again before creation.
Catalogue metadata must identify cloud-init support and a matching CPU architecture.
Missing metadata triggers read-only disk inspection with libguestfs. The host needs
its Perl bindings (`perl-Sys-Guestfs` on Rocky/AlmaLinux, `libguestfs-perl` on
Debian/Ubuntu) and `YAML::XS`. Inspection runs in an unprivileged
worker and an isolated appliance, without booting the image or mounting guest
filesystems on the host. See [worker isolation](workers.md) for host requirements.
It requires one Linux installation, a matching architecture, cloud-init files,
and no cloud-init disable marker or masked first-boot service. Explicit configuration
must allow the NoCloud datasource and cloud-init networking. These checks cannot
guarantee that every custom first-boot configuration will work. Inspection errors
block creation; a client-supplied `image_compatible` flag cannot bypass validation.

## Command line

Run `cloudmin` as root on the Cloudmin Linux host. Webmin installs `/usr/sbin/cloudmin` when installing or upgrading the module. `perl cli.pl` also works from the module directory.

```sh
cloudmin list-systems
cloudmin list-images --json
cloudmin create-system --name guest.example.com --template "Default Template" --plan "Default Plan" --auth-type password --password-file /root/guest-password --review
cloudmin get-job --job JOB_ID
cloudmin help create-system
```

Lists use tables by default. Use `--multiline` for details, `--name-only` or `--id-only` for one identifier per line, or `--json` for a JSON object with `command`, `status` and `data` fields. The `data` field holds the API result. JSON failures contain `error` instead of `data`. Success exits 0, API or validation failures exit 1, and usage errors exit 2.

Commands wait for jobs by default and print phase changes to standard error. `--no-wait` returns the job ID immediately. JSON mode omits progress messages and returns the final record, or the initial record with `--no-wait`. A waiting timeout leaves the worker running. Power commands wait for the requested host state, except `reboot-system` and `reset-system`, which return when the request is accepted. They do not wait for guest software to become ready.

Use `--name` or `--id` to select one machine. Image, pool, network, template and plan options accept IDs or unambiguous names. Commands that require confirmation show `--yes` in their syntax. Hardware, snapshot, clone and capture commands read the current revision before submission and reject conflicting changes.

Passwords and license credentials come from regular files, or `-` for standard input; only one option can read standard input. One final newline is removed. `create-system` starts the guest by default; use `--no-start` to leave it stopped. Preparation and final setup scripts require Cloudmin Pro.

`cloudmin help COMMAND` explains the command, its options and examples. `cloudmin COMMAND --help` shows a short description and syntax. `perl cli.pl --docs` generates the full reference as one Markdown document from the command table and `lib/Cloudmin/CLI/commands.pod`; `perl cli.pl --docs-dir DIRECTORY` writes the website's overview page and one page per command into a Hugo section.

The raw API remains available for requests supplied as JSON. This example uses the Debian/Ubuntu Webmin path; on Rocky/AlmaLinux, use `/usr/libexec/webmin`:

```sh
perl /usr/share/webmin/server-manager/api.pl create < request.json
```

`cloudmin api create < request.json` is equivalent. The raw API returns a JSON object with `version` and `result` fields. Reuse the same request, token and attempt ID when retrying a job submission. Named commands generate a new token for each change, so check the job before repeating a command that timed out. Guest login options such as `--ssh-key` accept public keys only.

The SQLite journal is under the module's `vm-jobs` data directory. Webmin locks
serialize writes and resource allocation. Each job records the resources it
plans to create before changing libvirt. Recovery uses these records to identify
the job's resources and remove unfinished work.
Recovery runs when a user with write access visits the overview, the virtual
machine job pages or a creation progress page. There is no service that performs
recovery without a visit yet. Creations are serialized from their final capacity
and address checks through startup. A lock timeout is recorded as a job failure;
it does not leave the job silently queued.

Required host packages include Sys::Virt, DBI, DBD::SQLite, XML::LibXML and the
libvirt network service. Cloud-image provisioning also needs xorriso and OpenSSH
client tools. Libvirt 8.6 or later is required for the persistent UEFI loader
(`stateless='no'`); firmware feature selection itself was introduced earlier.
Libvirt validates the generated XML
when the guest is defined. Creation supports the local
`qemu:///system` connection, native x86-64/ARM64 guests, cloud images or installer ISOs, and
active file, LVM or LVM-thin pools. Boot tests cover ARM64 under UTM and
Debian 13 and Ubuntu 26.04 guests on a physical Ubuntu x86-64 host.
The full host and architecture matrix still needs testing before release.

## Managing existing virtual machines

The guest menu links to **Edit Virtual Machine**, with Resources, Disks and Network
interfaces tabs. Click Save to apply changes from all tabs. The shared action bar
has Save and Start or Shut down on the left and Delete on the right. Start uses saved settings. Running guests can edit supported resource and boot fields. After saving, a banner shows changes that need a full shutdown and start, with running and saved values while they differ. The shutdown waiting page reopens the editor with fresh settings once the guest stops. Delete opens the
disk selection and confirmation page. These use the same API and CLI as creation.

The editor waits for saves and redirects back to the selected tab. Errors use Webmin's normal error page; successful deletion returns to the overview. Jobs continue if the browser disconnects while waiting.

Management requires a persistent KVM virtual machine on `qemu:///system`. Resolve managed memory saves first. Existing snapshots and backup checkpoints allow resource, description, boot and network edits, as well as ISO insertion and ejection.

Adding or removing drives, resizing disks, or deleting individual disk files requires removing snapshots and checkpoints first. Deleting the whole virtual machine handles the selected file disk chains and removes snapshot and checkpoint metadata automatically. LVM snapshots must be deleted first. These checks also run when a queued job starts.

Restoring a snapshot restores its saved hardware configuration along with its disks. Deleting a snapshot preserves later hardware edits.

Cloudmin checks the power state again at execution, so starting or stopping between submission and execution selects the appropriate path. It never shuts down a guest implicitly for a hardware edit.

Running guests support CPU count changes within their defined maximum, memory balloon adjustment from 256 MiB to their defined memory size, disk and interface attach/detach, disk growth, ISO media changes, and interface link, bandwidth or network-source changes. Libvirt and the guest must support each operation. A guest may need to bring a newly added CPU online; its CPU count inside the operating system can differ from the number assigned by libvirt. Memory changes require a working virtio balloon driver. Resource maximums, boot order and boot menu changes are saved for the next full shutdown and start. CPU counts outside the running limits, and memory allocations above the running maximum or without a virtio balloon, are also saved for next start. MAC addresses and interface models remain offline settings. Disk shrinking, format conversion and guest-image editing are not live operations.

For an older guest without spare PCIe ports, shut down once and select **Add CPU slots, spare device ports and an empty CD/DVD drive**. This preserves the current allocation while adding expansion capacity. CPU and memory maximums can also be saved while running for the next start. The running editor reports its actual live limits, which can differ from a configuration edited externally for the next boot.

A defined CPU maximum does not guarantee live CPU support for that machine type. If libvirt reports that CPU hotplug is unsupported, change the count while stopped. `settings.live_limits.min_cpus` reports the minimum count allowed by the running guest's non-removable CPUs. A lower count is saved for the next full shutdown and start; CPUs added while running can still be removed when libvirt and the guest support it.

Read `settings` with `id` (the virtual machine UUID) to obtain its saved configuration,
`revision`, disks, interfaces, storage pools and networks. `attachable_volumes` contains unused writable disk choices; `images` contains ready imports that can be cloned. Disk records include a display `role` when Cloudmin recognizes the original system or cloud-init disk. No XML or console
password is returned. Each change requires the current `revision` and a signed
`token` from `options`. A stale revision is rejected. Keep the same token and
optional attempt ID when resubmitting an operation. Changed input requires
a new attempt after failure and cleanup, or a new token for a separate operation.

| Action | Additional input | Behavior |
| --- | --- | --- |
| `update` | `cpus`, `memory_mib`, optional `cpu_limit`, `memory_limit_mib`, `enable_live`, `description`, `boot`, `bootmenu`, `changes` | Applies resource and hardware edits in one job. Known next-start resource and boot changes are saved while running; hardware expansion still requires a stopped guest |
| `add_disk` | `pool`, plus `disk_gib` or `image` | Creates and attaches an empty disk or an independent clone of the imported image. File pools use QCOW2; LVM pools use raw. With `image`, omitted `disk_gib` keeps its original capacity; shrinking is rejected |
| `attach_disk` | `pool`, `volume` | Attaches an existing, unused raw/QCOW2 volume |
| `detach_disk` | `target`, such as `vdc` | Detaches the disk and keeps its data |
| `delete_disk` | `target` | Detaches and permanently deletes one managed disk while keeping the virtual machine; the editor confirms with a Delete button, and this action cannot be included in `update.changes` |
| `grow_disk` | `target`, `disk_gib` | Grows to the specified total capacity; never shrinks |
| `add_interface` | `network`, optional `mac` | Adds a virtio NIC; generates a MAC if omitted |
| `update_interface` | `mac`, optional `network`, `link` (`up`/`down`), `inbound_kib`, `outbound_kib` | Changes the source network/bridge, link state or average bandwidth limits in KiB/s; zero removes a limit. Live source switching depends on the libvirt network backend |
| `remove_interface` | `mac` | Removes the selected NIC |
| `change_media` | `target`, `pool`, `volume` | Inserts a managed ISO into an existing CD/DVD drive; an empty `volume` ejects it without removing the drive |
| `delete` | `confirm_name`, optional `disks`, `shutdown`, `history_revision` | Removes the virtual machine and only the selected disk targets; `shutdown=1` allows stopping it according to the disk selection |

New disk filenames include the virtual machine name, disk role and a unique job identifier. Existing files are not renamed. Libvirt domain XML remains the source of disk attachment information.

`settings.running` contains the running CPU count, memory allocation, maximums and boot settings. `settings.pending` contains only differences, with `running` and `saved` values for each field; it is empty while stopped. These are comparisons with libvirt, not a separate queue. The editor and details page group these differences in a persistent banner; the overview shows a Power cycle pending badge. Power cycle now submits a `power_cycle` job and waits up to two minutes for shutdown. If shutdown times out, the job fails without starting or forcing off the guest; a delayed shutdown may still finish. Unchanged saved fields remain pending when another setting is edited. A guest reboot or hard reset does not guarantee that saved hardware changes take effect: shut down fully, then start.

API changes return jobs, followed through `status` or the progress page. Management jobs include `scope`: `live`, `config`, or `offline-required`. `config` includes changes saved for next start while the guest runs. `deferred_fields` lists the groups saved for next start (`cpus`, `memory`, `boot`); a mixed live/deferred job reports `scope=live` and a nonempty list. Failed native live calls remain failures and are not silently saved for later. The initial value describes submission; the worker updates it after checking the current power state. `offline-required` jobs fail before writes with a shutdown explanation if the guest is still active. The root
CLI accepts the same fields and supplies a token if omitted. For example:

```sh
cloudmin get-system --id VM_UUID
cloudmin modify-system --id VM_UUID --cpus 2 --memory 4G
```

`boot` is `disk:TARGET` or `nic:MAC`; it makes that device first and replaces the
previous boot order. An omitted or empty value preserves the order. `bootmenu`
is `0` or `1`; omitting it preserves the saved value. Firmware and machine type are preserved. Existing CPU topology, pinning and NUMA settings are preserved. CPU counts can change within the existing maximum without rewriting the topology. Fields tied to individual CPU settings or memory devices, and maximums tied to custom layouts, remain read-only; `settings.resource_locks` identifies them. Unrelated edits remain available. Memory and disk fields accept
the unit selectors documented above.

`update` accepts up to 128 hardware edits in `changes`. Each entry contains an
`action` from the disk or interface operations above, except `delete_disk`, and its additional fields.
For example, `"changes":[{"action":"grow_disk","target":"vda","disk_gib":20},
{"action":"add_interface","network":"network:NETWORK_UUID"}]` grows a disk and
adds a NIC in the same job as the resource edits. A device may be changed only
once in the list. Unchanged sizes and network selections are skipped.

The whole request is validated before writes. Offline edits perform storage work followed by one saved definition. Live edits use the native libvirt calls and record each step. Detach first requests live removal, waits up to 30 seconds for the device to disappear from live XML, then updates the saved definition. A timeout leaves the saved attachment unchanged and retains the job for recovery: the guest may still complete removal later. File disks can grow while running through `block_resize`, which changes the image's persistent capacity. LVM disks require shutdown before growth.

Calls that support both live and saved settings use both flags, but libvirt does not guarantee that these writes are atomic. If the live change succeeds and saving fails, recovery checks the observed state and retries only the missing part. It refuses unrelated configuration changes. Disk growth cannot be rolled back; if a later step
fails, Active Jobs retains the plan for recovery and blocks further virtual machine changes.
After a failed live change, resuming or stopping the guest remains available so it can acknowledge the change or recovery can finish its saved settings. These controls remain blocked while the worker is active.
Use **Retry recovery** in Active Jobs to retry the operation. For a failed settings update, **Keep disk growth and discard remaining changes** can release the reservation after verifying that the original hardware definition is unchanged and removing any unused disks allocated by the job. Completed disk growth is kept.

Deleting an individual disk uses a separate confirmed request. Cloudmin first saves the definition without that disk, then deletes its storage volume. If deletion is interrupted, Active Jobs can finish it after checking that the volume's identity is unchanged and it remains unused.

Disk operations support active directory, filesystem, NFS, LVM and LVM-thin pools. LVM disks use raw format, and each thin pool is a separate destination. Imported
images, disks referenced by other virtual machines, and backing files used by other managed
volumes are protected. Libvirt XML identifies dependencies; references outside
libvirt's inventory are not discoverable. Disk growth does not expand guest
partitions or filesystems. Changing NICs does not rewrite the guest's network
configuration or cloud-init seed.

The editor's Delete button confirms the selected disks without asking for the virtual machine name. API and CLI callers supply the exact name in `confirm_name`. Pass `shutdown=1` to permit stopping a running virtual machine; otherwise it must already be stopped. When any writable disk is kept, Cloudmin waits up to two minutes for a clean shutdown. When every writable disk is selected for deletion, it powers off immediately. Keeping read-only media, such as a cloud-init seed or ISO, does not require a clean shutdown. Both live and saved disk attachments are checked. A failed or timed-out stop leaves the definition and disks intact; a delayed clean shutdown may still finish. Configuration and disk ownership are checked again after stopping.

`disks` is an array of attached target
names, or a comma-separated string for form clients. Omitting it keeps every
disk, including the cloud-init seed. Deleting a selected disk also removes its private snapshot layers and branches. Layers needed by kept disks, other guests, other storage volumes or imported images remain. The plan records file identities and deletes child layers before their backing files, so recovery can finish an interrupted deletion without expanding its scope.

Libvirt removes the virtual machine's snapshot and backup checkpoint metadata when undefining it. Kept disks retain their complete chains, but the deleted virtual machine's snapshot list is no longer available. Snapshot and checkpoint changes are checked before stopping and before undefining the virtual machine. Clients can pass `settings.history_revision` as `history_revision` with `delete` to detect history changes since opening the form; the editor does this automatically. Active disk jobs and interrupted snapshot merges must finish first.

Selected volumes are checked before undefining the virtual machine and again before removal. Libvirt removes the UEFI variable store; Cloudmin removes its managed guest SSH keys. The confirmation page lists
attached disks and leaves deletion unchecked by default.

Creation, snapshots and management serialize disk work separately from the short host reservation lock. Power controls for unrelated virtual machines remain available. An unfinished
management job blocks further edits and power changes for that virtual machine. Cancellation
is allowed before its first write. If a change is interrupted after starting,
use **Active Jobs → Retry recovery**. For a failed creation, recovery removes unfinished resources. Recovery checks the saved
operation marker, volume identity or target capacity before continuing. A
refused edit releases the virtual machine once unchanged state is confirmed. A new disk
whose attachment was refused is removed only after its identity and lack of
users are verified. Recovery does not roll back disk growth or restore deleted
data. If a new disk was allocated but the worker died before recording its
identity, the job reports its path for
manual inspection instead of adopting an unrecorded file.

## Full virtual machine cloning

Host administrators can call `clone_options` with `{ "id": "source-uuid" }` to obtain the source revision, resources and available templates, plans, storage and networks. Submit `clone` with that `id`, `revision`, a new `name`, and the normal form `token` and `attempt`. The root CLI supplies a token when omitted:

```sh
cloudmin clone-system --id SOURCE-UUID --new-name copy.example.com --mode prepared --username cloudmin --auth-type keys --ssh-keys-file /root/guest-public-keys --no-start
```

Both clone modes require libguestfs, its Perl bindings, bsdtar and exactly one Linux installation that libguestfs can inspect. The worker changes only independent disk copies, with networking disabled.

`clone_mode` defaults to `prepared`. This mode also requires YAML::XS 0.69 or later, enabled cloud-init and one network interface. It prepares a new guest identity before boot. `unchanged` requires `confirm_unchanged: 1`, `start: 0` and `autostart: 0`. It keeps guest settings and leaves the copy stopped, but still resets the host ID and removes copied Virtualmin Pro credentials.

`template` supplies access, network and boot defaults, including `require_fqdn`. Installation media and software setup settings are ignored. `plan` supplies resources. Without these selections, Cloudmin uses the source's CPU, memory, first-disk size, pool and network. The usual credential, hostname, static-address and size fields can override defaults. Disks cannot shrink. `host_ssh_key` controls managed SSH access for prepared clones and defaults to the module setting.

For a running source, the guest agent freezes filesystem writes while Cloudmin takes a temporary snapshot. File disks use external overlays. LVM disks keep writes on the original volumes; Cloudmin briefly pauses the guest to create native snapshots and copies those. Set `shutdown: 1` to shut the source down cleanly and restart it after copying instead. This is required for sources that mix file and LVM disks.

`nvram_mode` defaults to `fresh` for a running source. Libvirt creates new UEFI variables without copying the source's firmware boot entries. A stopped source or `shutdown: 1` defaults to `copy`. Selecting `copy` for a running source requires `shutdown: 1`.

`clone_options` returns `tpm: 1` for a supported libvirt-managed software TPM 2.0 guest. A running source requires `shutdown: 1`. If it has UEFI variables, use `nvram_mode: "copy"`. Cloudmin copies the TPM state to the clone's own libvirt directory before restarting the source.

Encrypted or custom TPM storage, physical TPMs and externally managed TPMs are not supported. Both clone modes reject encrypted root disks that libguestfs cannot inspect. Keep a recovery key for encrypted disks in case changed hardware or guest settings prevent automatic unlocking.

The source UUID and destination name remain reserved until completion or successful cleanup. Use the existing `status`, `cancel` and `recover` actions. Interrupted jobs restore the source and remove incomplete copies. Cleanup failures keep the reservations.

File and standard LVM pools must have room for full disk capacities and temporary snapshots. Thin pools allocate space as data is copied. LVM processing also needs temporary space on the host; free-space checks use each disk's full capacity even when the copy is sparse. Writable disks must be private raw or QCOW2 files, or managed LVM volumes. The result has no backing files.

Both clone modes replace Virtualmin Pro credentials in the license file and repository authentication files with `CLONE_REQUIRES_LICENSE`. They also clear cached license status before the clone can boot. `confirm_license: 1` acknowledges this. Pro packages and repository channels stay in place. Add a separate Pro license or downgrade manually to GPL to restore repository updates.

Virtualmin on the source must support `change_licence()` offline mode. Otherwise, cloning fails before defining the new virtual machine. Cloudmin checks the source's creation journal and the copied guest's installed Pro directory to determine its edition. The template name does not affect this check.

In `prepared` mode, Cloudmin updates Virtualmin's management hostname and Postfix hostname references, replaces management TLS keys and certificates, and removes certificate renewal settings for the source hostname. Hosted domain names, data and certificates remain unchanged. Review application settings that use the source IP address before serving traffic from the clone; Cloudmin does not rewrite them.

The private worker filesystem also needs space for the full disk capacities, QCOW2 metadata and appliance work. Prepared outputs receive a separate read-only format and capacity check before being imported into the destination volumes.

Live tests are in `t/live`:

- `check-clones.py` checks identity, boot, multiple disks, source preservation, cancellation and recovery.
- `check-clone-tpm.py` tests TPM-bound LUKS unlocking in the source and clones after reboot, and confirms that a fresh TPM cannot unlock a copy.
- `check-clone-tpm-failures.pl` checks TPM cleanup after failure, cancellation and an interrupted worker.
- `check-clone-access.py` checks HTTP permissions and form validation.
- `check-clone-storage.pl` checks independent raw/QCOW2 disk copies.
- `check-clone-pools.py` checks filesystem and NFS pools on a disposable test virtual machine.

Run these only on authorized test hosts. `check-clones.py --virtualmin` installs GPL in its disposable guest; `--virtualmin-hostname` also checks a management hostname domain and a hosted website. Fixtures remove their own guests, storage and jobs after successful cleanup. Failed source recovery retains the fixtures for inspection.

`t/live/check-clone-networks.py IMAGE` boots clones across temporary NAT, routed, isolated and private bridged networks. It checks DHCP, static dual-stack and single-family addressing, `/32` and `/128` gateway routes, DNS, traffic, reboot persistence and unchanged source disks. It also checks that prepared clones reject multiple NICs and unchanged copies retain their network settings and stay stopped. The fixture leaves physical interfaces alone and restores forwarding settings during cleanup. `--keep-on-failure` retains failed fixtures for diagnosis.

## Backups and restore

The virtual machine API also runs full backup, inspection and restore jobs. See [Full virtual machine backups](backups.md) for request fields, CLI examples and which guest settings are preserved.
