# Virtual machine image capture (Cloudmin Pro)

Choose **Create image** from a guest's action menu or **Create Image** on **Edit Virtual Machine**. Enter an image name and choose a destination pool. Choose whether to remove login credentials. Under **Source preparation**, choose guest-agent preparation to keep the source running, or a clean shutdown before copying.

The Pro extension must be installed under `server-manager/pro`. The shared API rejects capture when it is absent, including direct requests. Host administrator access is required, and read-only sessions cannot submit a capture.

Capture requires libguestfs and its Perl bindings, YAML::XS 0.69 or later, and bsdtar on the host.

## Supported sources

Capture supports one writable Linux system disk using virtio, with working cloud-init and an installation libguestfs can inspect. Cloudmin seed disks are omitted. Additional writable disks, attached installation media and read-only data disks are rejected. The shared clone checks also reject devices whose state cannot be copied, such as TPMs.

Live capture requires a responding guest agent. Cloudmin briefly freezes the filesystems and takes a temporary snapshot. For file disks, it copies the stable disk, then merges the temporary write overlay. For LVM disks, it briefly pauses the guest to create a native snapshot, copies that snapshot, then removes it. Writes stay on the original logical volume. Clean-shutdown capture restarts a source that was initially running. A stopped source stays stopped. New virtual machines use fresh firmware variables; custom firmware settings are not preserved.

Captured images use an active directory, filesystem or NFS pool. Before copying, Cloudmin checks free space for the source disk's full capacity in that pool. Live capture of a file disk also requires that much free space on the source filesystem for writes during copying. The check adds both requirements when they share a filesystem, plus 256 MiB of headroom on each filesystem. Clean shutdown avoids the extra space check for live writes. For an LVM source, snapshot space is checked in its volume group or thin pool instead.

Once copying and snapshot cleanup finish, Cloudmin checks temporary storage before each preparation and inspection stage. The worker that prepares the image needs room for the disk's full capacity; other copies use the actual file size. A later space failure rolls back the unfinished image. Temporary files are removed on completion or rollback.

The captured image keeps the source disk's capacity. Each new virtual machine needs a disk at least that large, even if the source had little data.

## Image contents and identity

The image appears in Image Manager and under **Captured from virtual machines** in the creation and template image selectors. Its checksum column says **Not applicable (local capture)** because it has no publisher checksum. It has no backing link to the source. Existing image deletion and in-use checks apply.

Offline preparation resets cloud-init state, machine identity, SSH host keys, cached leases and the copied hostname. It also removes cloud-init logs, which may contain initial credentials.

**Remove login credentials?** defaults to **Yes**. It removes Linux login password hashes, each account's `.ssh` directory and default Bash, Zsh, sh/KornShell, C-shell and Fish history files. This applies to all local accounts, including root and service accounts. Select **No** to keep these credentials and histories.

Both choices keep accounts, groups, permissions and application data. Services that use removed passwords or SSH keys need new credentials.

Application passwords, credentials and histories in custom locations, and other secrets remain. Keep captured images private and review their contents before sharing them.

When you create a virtual machine, the administrator account selected in the form receives the new access settings, even if the image kept its old credentials.

Copied Virtualmin Pro credentials are always replaced locally with `CLONE_REQUIRES_LICENSE`, using the existing offline clone helper. The appliance has no network access. Each new virtual machine needs its own valid Pro license or a manual downgrade to GPL. The source's license and repositories are unchanged.

Each new virtual machine gets an independent disk, UUID, host ID, hostname and access settings before boot. Capture sets the management hostname to `image.invalid`; creation runs the same helper again to set the final hostname and regenerate the management certificate. Captured Virtualmin installations require a fully qualified hostname.

## Controller API

Use v1 `image_options` with `id` for the source revision and destination choices. Submit `capture_image` with:

- `id`, `revision`: source UUID and revision returned by `image_options`.
- `name`, `pool`: display name and destination pool UUID.
- `clean_credentials`: `1` (default) to remove login credentials and standard shell histories for all local accounts; `0` to preserve them. No source username is required.
- `shutdown`: `0` for the guest agent, `1` for clean shutdown.
- `token`, optional `attempt`: the signed form token and submission attempt ID.

The response is a public virtual machine job. Poll `status` with its `job` ID. On completion, the image has the same ID and is available in `options.images`. Pass that ID as `image` to `create`. Repeated identical submissions return the same job; changed values cannot reuse a submitted attempt. Validation failures allow correction and resubmission with the same CSRF token.

The job reserves the source until capture or rollback finishes. Cancellation restores the source and removes unfinished copies. Interrupted jobs roll back instead of repeating disk writes. Once an image record is published, recovery completes the job without deleting the published volume. Failed cleanup keeps the source reserved for explicit recovery through Active Jobs.
