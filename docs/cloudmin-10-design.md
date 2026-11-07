# Cloudmin 10 design

- Status: Team draft
- Updated: 2026-11-03
- Replaces: the earlier proposal and the team `.docx` draft

## 1. Summary

Cloudmin 10 is a rewrite of Cloudmin around libvirt, the standard Linux
API for managing virtual machines. The first release will support QEMU/KVM only.
The old backend abstraction and direct QEMU process management are not carried
forward.

This document describes the planned release. It includes features that are not
implemented yet; [the delivery plan](#12-delivery-plan-and-status) records current
progress.

The goal:

> Install Cloudmin on a supported Linux system, choose or supply an image, and
> get a safe, manageable KVM virtual machine without manual host setup.

Cloudmin should let people manage virtual machines on their own Linux hosts,
with a straightforward interface and integration with Virtualmin. It should
also be useful on its own.

The rewrite breaks internal compatibility on purpose. It must not break user
data: existing KVM installations get a visible, tested import and rollback
path, and Cloudmin 9 stays available for Xen users while the KVM line matures.

## 2. What we heard

Users asked for reliable migration, easier shared storage and an installer that works on current supported distributions. They also want better monitoring, usable consoles and clear progress during long operations. These priorities guide the KVM-first design and its recovery checks.

## 3. Decisions

1. Libvirt is the only virtual machine management layer. Cloudmin does not build raw QEMU
   command lines or scrape `virsh` output. Reading legacy QEMU processes is
   limited to the migration tool.
2. KVM first. Xen comes later through libvirt's libxl driver, once KVM is
   stable. Cloudmin 9 remains the maintained line for Xen until then.
3. The default path is short: install, pick an image, create a virtual machine. Firmware,
   machine type, VLANs, extra disks and NICs live under advanced settings.
4. Cloudmin GPL and Pro share one core. A separate Pro package adds features on each host. Cloudmin Connect will manage multiple hosts and have its own GPL and Pro editions.
5. Management of Virtualmin servers moves to an optional Webmin module,
   Virtualmin Connect, outside Cloudmin itself. Shared DNS, database, spam and
   virus services become remote-server settings in Virtualmin; Connect
   distributes settings and policy and never proxies traffic.
6. Docker, Podman, LXC, OpenVZ, VServer, Zones, Citrix, EC2, GCE and other
   provider screens are removed from Cloudmin.
7. Existing KVM installations are imported by an explicit tool with a
   report for each virtual machine, followed by cutover and rollback. Never by a package upgrade.
8. The proposed release workflow uses a dedicated `cloudmin-10` branch, promoted
   to `main` after the release gates pass.

## 4. Scope

These are release targets, not a list of currently available features.

| First supported release | After the base is stable | Separate modules or products |
| --- | --- | --- |
| KVM through the libvirt system connection | Xen through libvirt | Containers and Kubernetes |
| Fresh install and repeatable host configuration | Managed iSCSI/SAN and Ceph RBD | Public cloud providers |
| Host checks with actionable errors | Live migration across all storage types | MicroVM or sandbox products |
| Image catalogue, URL, upload, host file, ISO install | Automatic failover and controller HA | Virtualmin pages in the default navigation |
| Create, import, start, stop, reboot, pause, delete, clone, console | Prometheus metrics and external logs | Raw QEMU launch code |
| Snapshots, backups, restore, scheduled snapshots | Declarative fleet deployment, hooks, autoscaling | Mail relay and OS upgrade services |
| Local directory, LVM/LVM-thin, and one tested shared storage path | S3-compatible object storage, hosted databases, load balancers | |
| NAT, bridges, routed, VLAN tags, multiple NICs, static IPv4/IPv6 | | |
| Durable jobs, versioned API and CLI, roles | | |
| Legacy KVM import with rollback | | |
| Documentation and fixtures delivered with each feature | | |

## 5. How it works

```text
Web UI          cloudmin CLI          External clients
   \                 |                      /
              Versioned controller API
                        |
        Roles, inventory, jobs, policy, audit
                        |
              Host-side Cloudmin API
                        |
      libvirt domains, networks, storage pools
                        |
                    QEMU/KVM
```

**Controller.** The Cloudmin backend runs within Webmin and uses its
authentication, navigation and UI widgets. Virtual machine creation, power controls, offline
management, snapshots, clones and backups use a versioned API shared by the UI, CLI and
external clients. Future management operations will follow the same pattern.

SQLite stores persistent virtual machine creation and management jobs (requests,
progress, resource reservations, recovery information, and history) and
short-lived password hashes used during setup. Job records survive
restarts so interrupted work can be recovered or cleaned up.

Resource history uses a separate SQLite database. Collection continues when
no pages are open. Disabling history recording keeps live readings. Collection
can also be disabled entirely. See [resource statistics](statistics.md) for
retention, coverage and the summary export format intended for Connect.

Server configuration, accounts, and permissions keep their existing Webmin
file-based storage. Webmin continues to handle audit logging; its audit log
is not stored in SQLite.

**Host-side Cloudmin API.** Cloudmin Connect will use authenticated Webmin API calls
to manage each host. Each host must check permissions and input before calling
libvirt, and report its API version and supported features. The API will expose
specific management operations, not arbitrary shell commands.

**Privilege separation.** Cloudmin CGI scripts run as root, like other Webmin
modules. They use normal Webmin initialization and check permissions, form tokens
and input before making changes. Downloads, host-file reads, checksum checks,
disk inspection, SSH key validation and cloud-init disk generation run as
separate processes without root privileges. Systemd assigns each task a temporary
user ID and releases it when the task stops. These tasks cannot read Webmin's
credential files or control libvirt. Download and size-lookup tasks receive
configured outgoing proxy settings, including proxy credentials, through private
request files. Background jobs retain root to record progress and make libvirt
changes. Console and terminal relays also run without root. A root supervisor
authorizes each connection and handles cleanup; the relay receives only its
prepared sockets and private credentials. The status collector still runs as
root. See [worker isolation](workers.md) for details and tests.

**Networking.** Cloudmin uses libvirt to manage virtual networks and guest
interfaces, and Webmin's network backends to create host bridges. Its root
process checks permissions and input before applying changes. Task workers
cannot change host networking. Cloudmin does not need `passt` or `slirp4netns`
for its current networking.

**Source of truth.** Libvirt stores the virtual hardware, network and storage
configuration. Standard tools such as `virsh`, virt-manager and Cockpit keep
working. Cloudmin will add ownership, projects, policies and schedules, and
must detect and report changes made outside Cloudmin.

**Jobs.** Image imports, virtual machine creation, offline management, snapshots, clones and
backups run as background jobs with progress and recovery records. Other long operations must follow the same
pattern. Job requirements include bounded logs and retries, resource locks,
duplicate-request protection, cancellation at safe points, and tested recovery
after a restart. Migration and failover must also prevent two hosts from
starting guests with the same writable disks.

**Health signals.** Power state, guest-agent health, SSH reachability and
application health are separate signals, never one ambiguous "up" or "down".

## 6. The user's path

### 6.1 Install

`cloudmin-install` remains the entry point. It configures repositories,
installs the RPM groups defined by `cloudmin-yum-groups` or the DEB core and
KVM meta packages, then runs Cloudmin-Config. Debian 13 and Ubuntu 26.04 use
their stock monolithic daemon until modular packages become available.

Cloudmin-Config already loads KVM, enables the selected libvirt daemons and
prepares a default storage pool when needed. It tests volume creation and
deletion in the standard default pool. It prepares a persistent default NAT
network after checking host routes, and verifies packaged EFI firmware. NAT
does not require changing the host's management interface. The Networking page
provides guided bridge setup with connectivity checks and automatic rollback.

Modular services are preferred when `virtqemud` is installed. Otherwise the
installer enables `libvirtd`. Webmin systemd manages both layouts. The selected
services and sockets are enabled at boot so guests, networks and pools marked
for autostart start automatically. Active monolithic hosts are not migrated
automatically when modular packages are installed.

The installer must end with a readiness report. A failed check must name the
missing capability and explain how to fix it. Required manual steps must be
documented before the installation can be reported as complete.

Relevant improvements from `Virtualmin-Install` are reused: OS detection,
package simulation, repository migration, hooks, modular post-install steps
and installer tests. The base KVM package set contains only the controller,
node, libvirt, QEMU, console, image, storage, network and provisioning
dependencies. DNS, mail and Virtualmin Connect are optional packages.

A physical x86-64 host runs the full test matrix; nested virtualization under UTM on Apple hardware is slower, and some Rocky Linux and Debian guest checks need the physical host.

### 6.2 Get an image

The image flow follows the pattern users already know from `virtualmin-podman`:
browse or search, read the useful details, download with visible progress,
verify, and use the image directly from virtual machine creation.

Current sources are the catalogue, a direct HTTPS URL, a browser upload or a
file already on the host. Installer ISOs are supported. Cloudmin Pro can capture
one Linux virtio system disk from an existing virtual machine as a reusable image. Extra data
disks are rejected. Capture resets machine identity. **Remove login credentials?** defaults to **Yes** and applies to all local accounts. New virtual machines receive their own host IDs and administrator access settings. Accounts, applications, data and other secrets remain, so captured images must stay private. See
[virtual machine image capture](machine_images.md) for the supported flow and API.

The catalogue records stable IDs, names, operating systems, architectures,
disk formats, download sizes, minimum disk capacities, firmware and guest
capabilities, release and support dates, and source URLs. Catalogue downloads
use HTTPS and verify the publisher's SHA-256 or SHA-512 checksum before import.
Existing volumes are never overwritten. Signature verification is planned.
The release needs a catalogue maintainer and an update schedule.

Machine templates save image, storage, network, guest access, software and boot defaults. Resource plans save CPU, memory and system disk size. Both fill the creation form, where administrators can change their values. Editing a preset affects future forms; existing virtual machines and submitted jobs keep their settings.

Presets use Webmin configuration files, host access controls, form tokens, locking and audit logging. Reading presets does not create configuration files.

Both pages appear under System Settings. The template editor uses a section
selector with Previous, Next and Save and Next controls. Resource plans use a
collapsible Basic plan details section. Both use Webmin's standard form widgets.

Cloudmin includes Default Template and four Virtualmin templates: GPL and Pro, each with Apache or Nginx. The Virtualmin templates use full installation by default; minimal installation remains available. Default Plan supplies 2 CPUs, 2 GiB of memory and a 20 GiB disk. On a one-CPU host, the unedited Default Plan uses 1 CPU.

All presets can be edited or copied. Default Template and Default Plan cannot be deleted. Virtualmin and custom templates can be deleted when no existing virtual machine or pending creation uses them. Deleted built-in templates stay removed.

Supplied descriptions explain the shipped settings. Each is translated as a complete message. Changing a template's name or settings clears its supplied description. Custom descriptions are preserved.

Built-in Virtualmin template names update on save to match the edition, web server and PostgreSQL option. Installation size is omitted. Duplicate automatic names receive a numeric suffix. Manually renamed and copied templates keep their custom names. Default Template is never renamed automatically.

The creation form always selects a template and plan; API callers select them explicitly. Creation defaults are edited on these pages. Module Configuration retains display, password generation and managed SSH key preferences. Manual field changes keep the selected preset. Deleting a custom default selects the built-in default again.

The Software section supports guest packages and Virtualmin installation in Cloudmin GPL. Cloudmin Pro adds preparation and final setup scripts, usable with or without Virtualmin.

After cloud-init finishes, setup runs as root inside the guest in this order: preparation script, packages, optional Virtualmin, final setup script. Scripts use `/bin/sh -e` and can switch users for application work. Failed or interrupted setup stops without repeating scripts and keeps the virtual machine.

Each script can be disabled, entered directly or read from a host file. File access follows Webmin's global file permissions and configured Unix user. Templates store paths; creation jobs copy the contents before allocating resources. Scripts run only inside the guest.

The Virtualmin templates run the official installer inside a fresh guest. Options match the website's command builder: Apache or Nginx, full or minimal installation, optional PostgreSQL and a hostname certificate. Pro credentials are supplied for each creation request and kept out of templates and cloud-init seed disks. Installation uses the managed SSH key and verifies the guest's host key.

Progress appears in the creation job while other guests can continue disk operations. Script, package and installer failures report the guest log location; errors during initial guest setup may occur before that log exists.

The built-in Default Template selects Rocky Linux 10 for the host architecture.
Image selectors include enabled catalogue entries before download and existing
imports. Catalogue selections store a release ID; submission captures the exact
asset metadata. A creation worker reuses a verified source or starts or joins an
import in a file pool before allocating guest disks. LVM destinations use a
separate file pool for source images. Downloads expose
byte progress and do not hold the disk-work lock. Cancellation leaves the shared
import running; Image Manager can cancel it separately. Cached assets are reused
without automatically refreshing rolling publisher URLs.

Templates store settings rather than prepared disk images. Clone mode omits installation media and software setup while retaining access, network, boot and qualified-hostname settings. Prepared clones use offline guest preparation and a new cloud-init seed; unchanged copies remain stopped.

### 6.3 Create a virtual machine

One form, based on Virtualmin's Create Virtual Server page:

1. **New virtual machine details** starts open. Enter the name, choose a template and plan, and supply the password or SSH keys required by the login method. Pro templates also ask for the license serial and key.
2. **Image and storage**, **Resources**, **Access**, **Software**, **Network** and **Boot options** contain the editable template and plan settings. They start collapsed by default. Module Configuration controls which start open; selecting a template does not open or close them.
3. Click **Create Virtual Machine**.

The guest hostname defaults to the virtual machine name. A checkbox below the name reveals a separate hostname field. Templates have a **Require fully qualified hostname** option under **Basic settings**; custom templates can enable it independently of their name or software. Virtualmin always requires it. Selecting a template leaves the checkbox unchanged. If the required hostname is missing, validation explains both choices. The rule applies to cloud images, not ISO installers.

A summary below the template and plan selectors shows the image, any required download, CPU, memory, disk size, network, addressing mode and software. It updates when the user changes a preset or edits a field.

Template descriptions are hidden by default on the creation page. **Show template description?** in Module Configuration can display nonempty descriptions either always or only when they differ from the template name, ignoring letter case.

Cloudmin chooses the machine type, UEFI or BIOS, and disk bus from the host and
image settings. Each virtual machine gets a separate writable disk so the source stays reusable.

ISO installation starts with an empty system disk and the ISO in a read-only
CD/DVD drive. Complete setup through **Remote Access → Graphical console**.

Cloud images use cloud-init for account and network setup. Cloudmin does not
mount and rewrite guest filesystems during normal creation. Cloud-init supports
static addressing, including a /32 address with an on-link gateway.

Creation returns a job immediately and shows progress. If it fails, the job
attempts to remove its resources and reports any cleanup failures so they can
be retried. SSH and graphical consoles are available from the guest menu.

### 6.4 Manage it

The UI already provides power controls, autostart settings, live status and
resource usage. Guest password reset uses a responding QEMU Guest Agent on a
running virtual machine, with a separate ACL grant and no password stored in jobs or logs.
Offline management includes CPU, memory and boot settings,
extra disks and network interfaces, disk growth and virtual machine deletion. These use the
same jobs, API and CLI as creation. The UI explains the shutdown requirement
and the filesystem or network work still needed inside the guest.
Administrators will also be able to adopt guests defined outside Cloudmin.

Cloudmin ships the graphical console client, layout and noVNC library, without
noVNC's separate application UI. Both consoles work in all themes. Themes can
add terminal font preferences, shortcuts and saved console zoom.
Webmin checks permissions and a form token, then proxies a session-bound
WebSocket to a VNC connection opened through the libvirt API.
The browser receives neither a VNC password nor a direct QEMU port. This works
with local guests during boot and without guest networking. Closing the page
closes the connection; reconnecting creates a fresh authenticated route.
Virtual machine names do not need to be FQDNs or have DNS records.

### 6.5 Protect it

Disk snapshots are implemented, with creation, restore, deletion, per-machine
history and a host overview. Live snapshots use guest-agent preparation, with
an explicit clean-shutdown fallback or an unprepared snapshot choice.
Full cloning creates independent disk copies in file, LVM and LVM-thin pools. A stopped source is copied directly. For a running source, Cloudmin uses the guest agent to freeze filesystem writes while taking a temporary snapshot. File disks use external overlays, which are merged after copying. LVM disks keep writes on the original volumes; Cloudmin briefly pauses the guest to create native snapshots, then copies and removes those snapshots. The alternative is a clean shutdown, followed by copying and restart. A source with both file and LVM disks requires shutdown. Filesystem freezing does not guarantee database consistency.

Both the source UUID and destination name are reserved. Cancellation and interrupted-job recovery restore the source before releasing either reservation. Full disk capacities and live overlay growth are included in free-space checks. Output disks are checked for backing links before use.

Both clone modes require libguestfs, its Perl bindings, bsdtar and exactly one Linux installation that libguestfs can inspect. Each clone receives a new UUID, MAC addresses, console password and host ID.

Prepared clones also require YAML::XS, enabled cloud-init and one network interface. A libguestfs task with networking disabled clears the copied machine ID, SSH host keys, DHCP leases and cloud-init cache before boot. A new seed supplies cloud-init settings. The mode that keeps guest settings preserves these files, the hostname, addresses and account credentials, and leaves the virtual machine stopped with autostart disabled.

When preparing a new identity, Cloudmin updates Virtualmin's management hostname, Postfix hostname references and management TLS certificate. Hosted domains and their certificates stay unchanged. Application settings that use the source IP address still need review.

Both clone modes replace Pro license and repository credentials with `CLONE_REQUIRES_LICENSE` before boot. They use Virtualmin's offline license API without contacting a server or changing repository channels. The installed Pro files determine whether this is required. The administrator must acknowledge that the clone needs a separate Pro license or a manual downgrade to GPL. The source license stays unchanged.

UEFI variables can be copied from a stopped source. Live cloning defaults to fresh variables, which do not preserve the source's firmware boot entries.

Cloning copies libvirt-managed software TPM 2.0 state after shutdown and preserves any UEFI variables. Encrypted or custom TPM storage, physical TPMs and externally managed TPMs are not supported. Keep a recovery key for encrypted disks in case changed hardware or guest settings prevent automatic unlocking.

Both clone modes require a Linux installation that libguestfs can inspect. Encrypted root disks that it cannot inspect are rejected. Passthrough devices, other external device state, linked copies and cross-host cloning are not supported.

Full backup and restore support managed file, LVM and LVM-thin disks, hourly through yearly schedules, and retention. Backups use cloning's source preparation and recovery but preserve guest identity and license credentials. Restore verifies the archive before confirmation and leaves the restored machine stopped. Local, SSH and cloud destinations use Virtualmin's backup flow and cloud transfer helpers. Public cloud account tests are still pending. See [Full virtual machine backups](backups.md). Scheduled snapshots and autoscaling remain planned.

### 6.6 Move it

Cloudmin Connect GPL will move stopped virtual machines between compatible hosts (cold moves). Cloudmin Connect Pro will add live migration, placement rules, host evacuation and automatic failover. These features belong to Connect, separately from Cloudmin Pro.

Hosts must keep their virtual machines running if the controller is unavailable. Connect will not require a Corosync cluster. Migration will use libvirt and QEMU with shared storage such as NFS, iSCSI/SAN or Ceph RBD, or QEMU block mirroring for local disks. Only tested host and storage combinations will be offered.

A move must prevent the source from starting the same disks again. Before restarting a guest elsewhere, failover must verify that the old host is isolated (fenced).

The design combines storage leases through libvirt/virtlockd/sanlock where supported, a kernel watchdog for host self-fencing, and IPMI/Redfish power control where available. A lease alone is not enough if the old host can still access and start the disks. Connect must refuse failover when it cannot reliably fence the old host.

Failover decisions require a voting majority, using three controllers or two plus a witness. Only the majority may fence a host and restart its guests.

Delivery order is registration and cold moves in Connect GPL, then live migration in Connect Pro, and automatic failover last. Integration with an existing Pacemaker/Corosync cluster may follow later.

### 6.7 Import a legacy installation

The planned importer is a separate tool, never a package side effect. The
following commands describe its intended interface and are not available yet:

1. `cloudmin migrate --scan` reads the old configuration without changing it
   and backs up the legacy controller state.
2. It inventories Servers Index records, flat files, running QEMU processes,
   boot scripts, disks, LVM volumes, iSCSI mappings, bridges, MACs, IPs,
   console settings, schedules, owners and image references.
3. It produces a report for each virtual machine:

| Result | Meaning |
| --- | --- |
| Ready | Cloudmin can import the virtual machine safely. |
| Review | Import is possible, but the administrator must confirm a choice. |
| Blocked | Part of the old configuration cannot be translated safely. |

4. For each ready virtual machine it generates and validates a libvirt definition without
   starting it, stops the old virtual machine, disables only its exact legacy start-up
   entry, defines and starts it through libvirt, runs health checks, and
   commits only when they pass.
5. If anything fails it undefines the new domain and restores the legacy boot
   entry.

The importer preserves UUID where known, name, MACs, disk paths and formats,
boot order, CPU, memory, firmware, network attachments and autostart. It reuses
disks in place when safe. It does not copy old SSH or Webmin passwords. Legacy
parsing lives only in the migration tool, and unsupported QEMU options block
with an explanation. Legacy fixtures are collected throughout development, not
at the end.

## 7. Storage

Storage is a set of named libvirt pools with capabilities, health, free space
and host visibility. Path and volume-group assumptions do not spread through
virtual machine code. Support order:

1. Local directory pools with qcow2 or raw volumes.
2. Registered LVM volume groups and their thin pools. Cloudmin allocates raw
   guest disks, grows them and creates native snapshots. Webmin's Logical
   Volume Management module creates and extends the underlying storage.
3. NFS shared pools, fully tested.
4. Safe adoption of existing iSCSI and SAN volumes.
5. Managed iSCSI/SAN and Ceph RBD.

The planned setup UI will discover candidates, validate every host, and show
which operations a pool supports. Pools differ in their clone, snapshot and
resize support; the UI must explain these limits before an operation starts.

## 8. Networking

Current virtual machine creation supports active libvirt networks, including NAT, and existing
host bridges. It checks for duplicate MACs, duplicate managed addresses and
missing networks before allocating resources. Cloud-init configures DHCP or
static IPv4 and IPv6, including on-link gateway routes.

Offline management can add, change and remove NICs. The Networking page lists
libvirt networks, host bridges, addressing and attached virtual machines. It creates NAT,
routed and isolated networks and protects networks referenced by stopped or
running guests. VLAN configuration remains planned.

Guided host bridge creation uses Webmin's NetworkManager, Netplan and ifupdown
APIs. It reviews the selected Ethernet interface, preserves saved addressing,
and requires confirmation within three minutes. Independent systemd recovery
restores the backed-up configuration after a timeout or an unconfirmed reboot.
Other host and virtual machine changes wait while confirmation is pending. Unsupported
custom interface configurations remain under Webmin Network Configuration.
Anti-spoofing through libvirt network filters remains planned.

## 9. API, CLI and access control

The virtual machine creation, power-control, offline-management, snapshot, clone and backup API
is versioned, uses JSON and shares its implementation with the CLI. Future operations will follow this pattern. A machine-readable
schema and generated API documentation are planned.

Module ACLs support host administrators and users assigned to existing virtual machines by
UUID. Power controls, forced power controls, graphical consoles, SSH terminals
and guest password resets have separate permissions. Webmin read-only mode
blocks these actions. Project ownership, quotas and self-service creation remain planned.
API credentials must be revocable and limited to individual actions. Secrets
must stay out of job logs, process arguments and audit records. Selected old
CLI names may remain as wrappers around the new API.

## 10. Editions

The products have separate purposes:

| Product | Purpose |
| --- | --- |
| Virtualmin GPL / Pro | Websites, domains, users and services on individual servers |
| Cloudmin GPL / Pro | Virtual machines and infrastructure on one compute host |
| Virtualmin Connect | Central management of multiple Virtualmin servers |
| Cloudmin Connect GPL / Pro | Central management of multiple Cloudmin hosts |

`cloudmin-gpl` is the shared host module. `cloudmin-pro` supplies optional features under `server-manager/pro`. Both use the same schemas, API and UI helpers. Pro implementations stay in the separate package; disabled previews may live in GPL. Both Connect products will support GPL hosts without requiring a host Pro license.

### Cloudmin host editions

| GPL | Pro additions |
| --- | --- |
| One compute host, unlimited virtual machines | Custom preparation and final setup scripts |
| Packages and built-in Virtualmin GPL/Pro templates and installation | Image capture from virtual machines |
| Images, clones, snapshots, live backups, schedules, retention and restore | Google Cloud Storage, Azure Blob Storage, B2, Dropbox and Drive backup destinations |
| Local/mounted storage, SSH and S3-compatible backups | Planned: projects, quotas, self-service creation, usage accounting and automation credentials |
| Consoles, SSH terminal, networks, bridges, storage and status | Later: object storage, block storage and load balancers |
| Local CLI and remote API; planned Cloudmin 9 migration | |
| Webmin users assigned to virtual machines, separate action grants and read-only mode | |

Basic access control stays in GPL. Planned tenancy features belong to Pro. Assigning existing virtual machines to Webmin users, including separate permissions for power, forced power, console, SSH and password resets, must never require Pro. Security fixes, data export and restore must remain available without Pro. Cold moves belong to Connect GPL, subject to its action limits below.

GPL shows unavailable Pro features in place, using Virtualmin's disabled controls and plain lock icon with a Pro label. A preview can show a whole form with disabled inputs and submission. The code that implements the feature stays in Pro.

Set **Show Pro features overview?** to **No** in Module Configuration to hide these previews. Saved scripts and unavailable backup destinations remain visible for review. This setting does not change feature access.

Both custom script sources (inline text and host files) require Pro. Creation, template saves, the CLI and JSON API enforce this; workers check again before starting or resuming script work. Guest packages and Virtualmin installation remain available in Cloudmin GPL.

After Pro is removed, saved scripts remain visible but cannot be edited. GPL can keep them unchanged when saving other template settings, or explicitly clear them. Creating a virtual machine from a template with active scripts fails with advice to clear the scripts or install Pro.

### Cloudmin Connect editions

Connect is planned, with separate GPL and Pro packages. These replace the earlier Free/Scale names and the split based only on host and virtual machine counts.

**Connect GPL** will include host registration, fleet inventory and search, central consoles and terminals, cold moves, starting backups and restores on each host, and a basic status and resource view.

It will limit registered hosts and the total virtual machines across the fleet. GPL and Pro hosts will count equally. A controller will count only if it also hosts virtual machines; a dedicated controller will not count. Virtual machines created through a host's own UI will also count toward the fleet total.

Above the limit, Connect will block registering another host and creating or moving virtual machines through Connect. Existing guests will remain visible, monitored and restorable, with an upgrade notice. Operations performed directly on a GPL host will remain unlimited. The limits are undecided and must not be published as final.

**Connect Pro** is planned to add:

1. Automatic failover and controller high availability.
2. Live migration, maintenance-mode evacuation, affinity/anti-affinity and placement policy.
3. Cross-site replication and disaster-recovery plans that can be tested.
4. Single sign-on (SAML/OIDC/LDAP), required two-factor authentication and fleet roles.
5. Tamper-evident Connect audit records, SIEM/syslog export, retention and compliance reports.
6. Central backup schedules and retention, off-site copies and automatic test restores.
7. Alert integrations, trends, capacity planning, utilization and chargeback reports.
8. Fleet API tokens, bulk operations, approval workflows, maintenance windows and a Terraform provider.
9. Shared storage pools and storage migration, overlay networks and security groups.
10. A white-label portal and priority support.

These additions manage multiple hosts. Basic host APIs, Webmin security and action logs stay in GPL. Cold moves, export, restore and security fixes will remain available without Connect Pro, subject to Connect's action limits above.

Cloudmin Pro and Cloudmin Connect Pro will be separate purchases. A Pro host will still count toward Connect's limits. Connect will not unlock host Pro features, and Cloudmin Pro will include no Connect seats or features. Bundle discounts may combine purchases while keeping the licenses separate.

The exact boundary is still a product decision. See the private note "Cloudmin editions and product notes" for the commercial proposals and survey evidence.

### Virtualmin Connect

Cloudmin Services from Cloudmin 9 is not carried forward. Virtualmin Connect
replaces it as a separate, optional Webmin module. Connect can run on the
Cloudmin system, but Cloudmin itself takes no part in what it does.

**Shared services are remote-server settings in Virtualmin.** Each Virtualmin
server talks to a shared service directly, using the service's own account and
protocol: a MySQL or MariaDB login over the database protocol, a spamd or clamd
address, and for DNS a Webmin user on the BIND server that can use only the
BIND module. Virtualmin gains a DNS provider for a BIND server the administrator
runs, built on the remote BIND calls that its slave DNS support already uses.
No system gets root access to another. This replaces the root-level Webmin RPC
access that the Cloudmin 9 master held on every service host.

**Connect handles only what needs a central place.** It pushes those settings
to selected Virtualmin servers at once, enforces per-owner quotas, runs the
cross-server check that stops a subdomain from being created under a domain
owned on another server, and keeps the log of what was provisioned where. It
also keeps the existing server list and links, central monitoring and alerts,
commands and package updates across servers, and file distribution. Managed
servers can link to their Cloudmin virtual machines. Blocking ordinary users
from creating conflicting domains still needs changes in Virtualmin.

Because Connect is a configuration and policy tool rather than a proxy,
customers' DNS and database changes keep working while the Connect system is
down.

**No compatibility with the Cloudmin 9 protocol.** Connect does not implement
the provisioning commands behind `remote.cgi`. Virtualmin's client moves to the
Connect API in the same release and must recognize a Cloudmin 9 master and ask
for an upgrade. A one-time script migrates owners, limits and provisioning
history from a Cloudmin 9 master. Backup-server wiring for fleets comes later.

## 11. Xen and Cloudmin 9

Xen starts only after the KVM release is stable. Libvirt's libxl driver and
`virtxend` let Xen reuse the controller, jobs, roles, API and most of the UI,
but support still needs packaging, capability checks and tests. PV and HVM
guests differ in boot, devices, storage and networking. Each needs fixtures
and compatibility tests before support is promised.

Cloudmin 9 will remain available and maintained for Xen users. Its
end-of-support policy still needs agreement. Installer and critical
compatibility fixes belong on a separate maintenance branch. No date is set
for Xen support in Cloudmin 10.

## 12. Delivery plan and status

| Stage | Content | Status |
| --- | --- | --- |
| 0. Contracts and evidence | Resources, job states, API conventions, host matrix, legacy fixtures, Cloudmin 9 policy | Partly done: resource model and host matrix defined; legacy fixtures and full host qualification pending |
| 1. Installable foundation | Installer, meta-packages, Cloudmin-Config, libvirt adapter, readiness checks | Implemented: installer refresh, RPM groups, NAT, firmware, nftables and readiness checks; clean-install matrix validation pending |
| 2. First complete virtual machine | Image manager; create, start, console, stop, delete | Implemented, including deletion through the UI, API and CLI; full host qualification remains pending |
| 3. Single-host management | Settings, disks, NICs, storage pools, networks, snapshots, clones, backups, audit | Implemented: offline virtual machine settings, disks, NICs, networks, storage pools, disk snapshots, full cloning, full backups, restore, backup schedules and retention; public cloud account tests pending |
| 4. Cloudmin Connect and Pro tenancy | Connect GPL registration and cold moves; Connect Pro fleet capabilities; Cloudmin Pro projects, quotas, self-service and automation credentials | Pending |
| 5. Legacy import and preview | Repeatable migration tests across file, LVM, NFS and adopted block storage; user preview | Pending |
| 6. KVM release, Xen evaluation | Release gates, documentation, then Xen fixtures | Pending |

The proposed workflow uses small commits on `cloudmin-10`, kept installable at each
completed stage. Short design and safety reviews happen at the foundation,
first working guest, Connect, tenancy and migration milestones; a final whole-branch review
precedes the promotion to `main`. The last Cloudmin 9 state is tagged and kept
on a named maintenance branch.

Next steps are the remaining first-release items: clean-install tests across
the supported host matrix, one fully tested shared storage path, VLAN tags and
anti-spoofing filters, scheduled snapshots, adoption of guests defined outside
Cloudmin, the API schema, the catalogue maintenance process, legacy import and
a stable package repository.

## 13. Release gates

Cloudmin 10 ships when all of these are true:

- A supported clean OS reaches a running virtual machine without undocumented shell edits.
- Every installer and configuration step is idempotent and tested.
- A supported legacy KVM virtual machine imports without copying its disk.
- No failed import or migration can leave two startable owners of one disk set.
- Create, backup, restore, clone and migration jobs survive controller restart
  at tested interruption points.
- Unsupported storage, network, firmware and image combinations fail in
  preflight with useful errors.
- The image catalogue has an owner, update schedule, signature process and
  end-of-life policy.
- Unit, libvirt integration and multi-distribution installer tests run
  automatically.
- The API and CLI are documented and covered by compatibility tests.
- Every supported UI workflow is documented on `cloudmin.com`.
- No runtime path constructs raw QEMU launch commands.

## 14. Open decisions

- Final qualification of the host OS and CPU architecture matrix.
- Implementation language and transport for the node service.
- Which shared storage backend is fully managed in the first release.
- Cloudmin 9 maintenance duration and the Xen support statement.
- The Cloudmin 9 migration script for owners, limits and provisioning history.

These do not reopen the core direction: libvirt is the only management layer,
KVM comes first, legacy state is imported explicitly, and unrelated backends
stay outside Cloudmin.

## 15. Main risks

- **Scope growth.** Proxmox parity, cloud services, containers and microVMs can
  delay the reliable KVM base. Keep them out of the first release.
- **Legacy translation.** Arbitrary old QEMU options cannot always be mapped.
  Import must block safely and explain why.
- **Storage semantics.** Snapshot, clone, backup and migration support differs
  by pool. Model capabilities instead of pretending pools are alike.
- **Network changes.** Automatic bridge conversion can disconnect a host. NAT
  is the default; physical changes need rollback.
- **Image maintenance.** A catalogue without an owner and process goes stale.
- **Late review.** A final review cannot replace milestone reviews of security
  boundaries and migration behavior.

## References

- [Cloudmin active users survey and discussion](https://forum.virtualmin.com/t/cloudmin-active-users-survey-and-discussion/137967)
- [libvirt modular daemons](https://libvirt.org/daemons.html)
- [libvirt QEMU/KVM driver](https://libvirt.org/drvqemu.html)
- [libvirt Xen/libxl driver](https://libvirt.org/drvxen.html)
- [libvirt API concepts](https://libvirt.org/api.html)
- [Proxmox VE feature baseline](https://www.proxmox.com/en/products/proxmox-virtual-environment/features)
