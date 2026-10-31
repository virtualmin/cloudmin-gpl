# Full virtual machine backups

Open **Backups and Restore** from the Cloudmin menu, or choose **Back up virtual machines** from a machine's actions. Each selected machine gets a separate full archive. Its filename includes the guest name, UTC date and job ID.

Manual and scheduled backups share the host's disk-work queue. Only one backup or other queued disk operation runs at a time.

Restore replaces a missing machine with its original identity. It refuses to overwrite an existing name or UUID and leaves the restored machine stopped, with automatic startup disabled. It keeps the hostname, machine ID, host ID, MAC addresses, guest network files, passwords, SSH keys and license files. The restore operation does not deregister Virtualmin Pro or contact its license service. Use cloning to create another machine with a new identity.

## Destinations

Local destinations are private directories, including mounted NFS storage. Cloudmin creates a missing backup directory with private permissions. Mount remote storage before using it as a local destination.

SSH uses SFTP with a password or a private key file on the Cloudmin host. It reuses matching entries from root's `~/.ssh/known_hosts` and `/etc/ssh/ssh_known_hosts`. Unknown servers and changed keys require fingerprint confirmation in the backup or restore form. Cloudmin stores approved replacements privately without changing those SSH files. Scheduled jobs fail until an unknown or changed key is approved. SSH checks the server key on every transfer.

The username appears under **Password** authentication. Switching to a private key keeps that username, or uses `root` when it is blank.

S3 supports custom HTTPS endpoints and a CA certificate file. The isolated worker passes AWS credentials through environment variables to keep them out of command arguments.

Local directories, mounted storage, SSH and S3-compatible storage are available in GPL and Pro. Google Cloud Storage, Azure, Backblaze B2, Dropbox and Google Drive require Cloudmin Pro. Their transfer and OAuth refresh helpers come from Virtualmin and are installed under `server-manager/pro`; Virtualmin itself need not be installed. Forms, API requests, scheduled jobs and transfer workers enforce the same edition limits. GPL can restore an archive downloaded separately to a local directory.

S3 uses `aws`, Azure uses `az`, and B2 uses `b2`, `b2-linux` or `backblaze-b2`. Google and Dropbox need OAuth client credentials and a refresh token. Authorize the application outside Cloudmin, then enter the credentials in the destination settings.

Saved schedule secrets are never sent back to the browser. Leave a field blank to keep its value, enter a replacement to change it, or choose **Clear saved value** to remove it. Required secrets cannot be cleared while that authentication method is selected.

Provider credentials and schedules are stored privately under Webmin's module variable directory. Public job responses and backup lists exclude credentials. Backup, inspection and restore requests require host-administrator access, POST and a signed form token. Global read-only mode blocks changes. Scheduled jobs recheck their owner's current permissions.

## Consistency and recovery

Stopped machines are copied directly. For a running machine, the guest agent briefly freezes its filesystems while Cloudmin takes a snapshot. File disks send new writes to temporary overlays while Cloudmin copies the original disks, then merges the writes back. LVM disks keep writes on the original volumes; Cloudmin briefly pauses the guest to create native snapshots and copies those. A machine with both file and LVM disks must be shut down for backup. Freezing filesystems alone does not guarantee consistent application or database data.

Live UEFI backup checks the firmware variables before the disk snapshot and after copying them. The source and copy must match, and the source file must not change during a read or be replaced. A change fails the backup and triggers source cleanup; retry or choose clean shutdown. Shutdown mode restarts a previously running machine after copying, before compression and transfer.

Copy, archive and transfer steps are recorded in the job store for recovery after an interruption. Cancellation and failure trigger source cleanup before releasing its reservation. If cleanup fails, the job reports it and keeps the source reserved for recovery.

The archive worker reads or writes a tar archive, optionally compressed with gzip. A manifest lists fixed filenames, sizes and SHA-256 checksums. Extraction rejects paths, links, duplicate files and oversized metadata. Separate isolated workers check each disk. Restored disks are independent raw or QCOW2 files, or raw logical volumes in LVM or LVM-thin pools. UEFI variables stay in a file storage pool. The guest's XML definition cannot supply custom QEMU arguments, shared host filesystems, passthrough devices or arbitrary host firmware.

Inspection downloads and verifies the archive before you confirm a restore. Restore checks the archive's checksum again before importing any disk. Its temporary download is removed after restore. Downloads from unused inspections expire after one day; Webmin cron removes them hourly, and opening the backup list also checks for them. A different restore host must support the guest's architecture and firmware and provide the same networks or bridges.

Schedules use Webmin's native cron service and the host's timezone. Hourly, daily, weekly, monthly and yearly schedules may include all machines or a fixed selection. A schedule cannot start another run while its previous run is active. Monthly dates that do not occur are skipped; February 29 runs only in leap years. The form shows only the time fields needed for the selected recurrence.

Retention can be disabled or set in days, weeks, months or years. A week is 7 days, a month is 30 days and a year is 365 days. Deletion runs only after every selected backup succeeds. It removes only that schedule's older archives and keeps the newest successful backup of each machine. Click linked field labels for details.

## Temporary storage

Full backups make several local copies: independent disks in the source pools, inputs for isolated workers, a tar archive, the controller's archive copy and the destination copy. Reflinks and sparse copies can reduce disk use, but plan for the full copies.

Allow roughly four times the copied disks' allocated size on the staging filesystem, plus source-pool copies and the final archive where they use separate filesystems. LVM staging checks use the full disk capacity, even when the temporary copy is sparse. Raw disks and extracted archives can also need their full logical size. Live backups need additional room for temporary snapshots: standard LVM reserves space for a full disk's changes, while thin snapshots share their pool. Cloudmin includes a free-space margin in its checks; other host activity can still consume that space. Compression can use substantial CPU time.

The separate copies keep disk and archive parsing isolated from host storage. Streaming directly from pool copies is a possible future improvement.

## API and CLI

The version 1 virtual machine API accepts `backup`, `backup_inspect` and `restore`. `backups` lists completed archive records. Status, cancellation and recovery use the existing job API. Reuse both the token and attempt value when retrying a request.

As root on the Cloudmin host, use the named commands:

```sh
cloudmin backup-systems --name guest.example.com --dest-mode local --dest-path /srv/backups --shutdown --compression
cloudmin inspect-backup --backup BACKUP_JOB_ID
cloudmin restore-systems --inspection INSPECTION_JOB_ID --pool default --yes
cloudmin list-backups
```

Each backup command selects one machine and waits for its job by default. `--no-wait` returns the job ID immediately. `--json` prints the final job record, or the initial record with `--no-wait`. `cloudmin help backup-systems` explains destination options. Passwords and provider credentials use `--dest-password-file`, `--dest-access-file`, `--dest-secret-file` and the other file options. `--dest-key-file` supplies an SSH private key path on the host. Unknown or changed SSH host keys must first be approved in the backup form.

Replace the example IDs with the 32-character job IDs returned by Cloudmin. Raw `backup`, `backup_inspect` and `restore` requests return a job to poll; the named commands poll it automatically. For an archive outside the local inventory, inspection accepts `target` and `filename` instead of `backup`. The filename must end in `.tar` or `.tar.gz`. For HTTP, send JSON to `api.cgi` with `version`, `action`, `token` and the same operation fields.

## Tests

`t/backups.t` and `t/backup-archive.py` check metadata, XML rewriting, destination validation and malformed archives. `t/backup-schedules.t` checks recurrence and retention controls; `t/backup-ssh.t` checks host-key approval. On authorized Linux test hosts:

- `t/live/check-backups.py IMAGE --network NETWORK` boots an isolated source, backs it up in supported consistency modes, restores it, boots the replacement and checks identity, network, credentials, firmware and secondary-disk data. UEFI is the default, including on x86. Use `--bios` only with a BIOS-capable image such as Ubuntu; RHEL 10 family images require UEFI.
- `t/live/check-backup-jobs.pl` checks scheduling, overlapping-run refusal, retention, cancellation, interrupted-job cleanup, failed transfers, inspection and refusal to restore over an existing virtual machine.
- `t/live/check-backup-nfs.py` runs those checks through a private loopback NFS mount and removes its export afterward. It requires the NFS client and server tools.
- `t/live/check-backup-access.py --browser` checks HTTP permissions, forms, CSRF and destination switching in both navigation layouts.
- `t/live/check-backup-transports.py --moto PATH/TO/moto_server` runs real SFTP transfers with password and key authentication, plus S3-compatible HTTPS transfers against private fixture services. The S3 test includes multipart-sized data. It does not verify a public cloud account.
- `CLOUDMIN_LARGE_ARCHIVE_TEST=1 python3 t/backup-archive.py` also packs and verifies a sparse disk over 8 GiB to check large tar headers. It does not measure large-disk backup performance.

Cloud upload and restore tests with real accounts are still pending; no test accounts are available.
