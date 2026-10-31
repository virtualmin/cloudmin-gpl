# Image catalogue

`images.json` lists bundled cloud disks. Custom catalogue entries can also
provide installer ISOs. Each release has only the architectures its vendor
publishes. Keep existing IDs stable so saved selections and jobs continue to
refer to the same release.

The Image Catalogue tab lists supplied and custom images together, with a
Bundled/Custom source column. Custom images use the same manifest format in
`image-catalogue.json` in Webmin's module configuration directory. That file
also stores disabled image keys; the packaged `images.json` stays unchanged.
Custom entries use IDs starting with `custom-`. Each row represents one image
architecture. Enabled entries for the host's architecture appear in Add Images,
grouped as Recommended, Supported or Older. Lists containing only bundled entries
are labelled Official cloud images; custom entries are marked individually.
The download note explains the HTTPS and checksum checks and links to Image Catalogue,
where administrators can inspect the source URLs. Each image has one badge
showing its estimated download size and support date, when known. The list is
filtered by host architecture and omits architecture labels, minimum disk
capacity and selection counts.
Module updates preserve the custom catalogue.

The catalogue table includes download size by default. Module Configuration's
Image catalogue columns setting lets you choose which columns to show.
The image link is always shown; other columns can be hidden. The `catalogue_columns`
setting stores column IDs in display order. Missing or invalid settings use all
columns, including download size.

Each architecture may include `download_size_bytes`, the downloadable file's size
in bytes. This differs from `min_disk_bytes`, the virtual machine's minimum disk capacity.
Stored sizes are estimates because publishers can replace files behind `latest`
URLs. The selector shows the estimated total for checked images and says when
some sizes are unknown.

Image Manager refreshes stale sizes asynchronously, with at most three requests
at once. It uses verified HTTPS headers, following redirects and falling back to
a one-byte range request if HEAD is unsupported or omits the size. No image is
imported during these checks. Results are cached by URL under the module's
variable directory for one day; unsuccessful checks retain the previous estimate
and wait an hour before retrying. Read-only sessions use existing estimates.
The downloader continues to use the actual response size for transfer progress
and checks available storage independently of these estimates.

Support dates describe the vendor or community maintenance included with the
release, including Debian LTS. They do not include optional extended-support
subscriptions. Every bundled fixed release has a support date. Rolling releases
show Rolling updates because they have no fixed deadline. Custom entries without
a date show Support date unknown; `older` alone does not mean support has ended.
The selector moves releases with a past support date into Older. The download
size and support text share the same status color.
Sources for support dates include [AlmaLinux release notes](https://wiki.almalinux.org/release-notes/),
[CentOS downloads](https://www.centos.org/download/),
[Debian releases](https://www.debian.org/releases/),
[Rocky Linux's release guide](https://wiki.rockylinux.org/rocky/version/),
[Ubuntu's security maintenance schedule](https://ubuntu.com/security/esm),
[Alpine's release branches](https://alpinelinux.org/releases/),
[Fedora 43's schedule](https://fedorapeople.org/groups/schedule/f-43/f-43-key-tasks.html),
[Fedora 44's schedule](https://fedorapeople.org/groups/schedule/f-44/f-44-key-tasks.html), and
[openSUSE Leap's lifecycle](https://news.opensuse.org/2025/09/03/leap-16-doubles-support/).
Fedora dates follow the provisional release schedules. Leap 16.0's planned
October 2027 end follows its October 2025 release and 24-month support policy.
`end_of_life_planned` marks these dates in the tooltip. Month-only commitments
use the month's last day. Alpine's date covers its main repository; community
packages are supported until the next stable release.

Use official HTTPS image and checksum URLs. Supported formats are standalone
QCOW2 and raw disk images, and installer ISOs (`format: "iso"`). Compressed
archives are not supported. ISO imports verify the checksum without inspecting
the operating system or disk layout. Prefer a vendor's
stable release alias when its checksum includes that filename. Fedora and
Alpine use pinned builds; update their image and checksum URLs together when
refreshing the catalogue. Do not add development or end-of-life releases as
recommended downloads.

Tumbleweed is currently offered only on x86-64. Its ARM64 checksum URL
returned 404 during the 2026-10-12 source check. Verify a published ARM64
image and its checksum before adding that download again.

Run `prove t/catalogue-edit.t t/image-catalog.t t/images.t` after editing. On the
Cloudmin debug virtual machine, `perl t/live/check-image-catalogue.pl` checks
the bundled cloud disks' live checksum entries and disk headers through the Webmin downloader without importing
the disks. This is a source-availability check, not a guest boot test. Use
`python3 t/live/check-images.py --extra-catalogue` for real batch imports and
cleanup of representative new distributions.

For installer ISOs, `t/live/check-iso-install.pl` checks imports, virtual machine creation,
media changes and snapshot restore. By default it uses nonbootable test media.
Supply an Alpine virt ISO as its second argument to also install an OS and
verify a boot with the ISO ejected. Verify the ISO against the vendor's
checksum before running the test. See [installer compatibility and test results](../docs/machine_creation_api.md#installer-compatibility).
Other installers need equivalent installation and disk-boot checks for each
claimed architecture and firmware combination.

## Older images

Before adding an older release, create a guest from its ARM64 image and test
boot, login, networking and disk growth. A passing ARM64 release may also be
offered on AMD64 after checking the corresponding vendor image,
checksum entry, disk header, and firmware metadata. Record AMD64 compatibility as inferred
unless that image was also boot-tested.

Debian 11 and Ubuntu 20.04 passed the ARM64 checks and qualify as older entries: regular-user DHCP and root static `/32` networking, password and SSH-key login, sudo, cloud-init, disk growth and source-image preservation. Their AMD64 URLs, checksum entries and QCOW2 headers were checked, and the published manifests include BIOS and UEFI bootloaders; AMD64 boot compatibility remains inferred, not boot-tested.

Ubuntu 18.04 failed root password login, and openSUSE Leap 15.6 failed static networking; their regular-user DHCP checks passed. CentOS Stream 8 and CentOS 8 provided no address or SSH within the test window and did not reach the root/static check. CentOS 7 remains unqualified because its ARM64 kernel requires 64 KiB pages that the test CPU cannot run. These releases stay out of the catalogue until they pass; the failures do not establish whether they work on other hosts.

Compatibility does not imply ongoing vendor support. These entries remain older releases; Ubuntu extended security coverage requires a separate entitlement where applicable.

### Testing candidates

Run these fixtures only on a disposable Linux Cloudmin host with working KVM,
Webmin installed, and the default libvirt storage pool and NAT
network. Copy the `t/live` helpers together. Keep the candidate manifest outside
the installed catalogue until the tests pass.

1. Run `perl t/live/check-image-catalogue.pl /absolute/path/candidates.json`
   to check the candidate URLs, checksum entries, and disk headers.
2. Run `perl t/live/import-candidate.pl /absolute/path/candidates.json IMAGE_ID /absolute/path/job.json`.
   The record contains the imported job ID, including when the import fails.
3. Run `python3 t/live/check_machine_create.py --image-id JOB_ID --form --both`.
4. Run `python3 t/live/check_machine_create.py --image-id JOB_ID --form --both --root --static`.
5. Run `perl t/live/image-volume.pl cleanup JOB_ID`, including after a failed check.

Run creation fixtures sequentially: they share a temporary Webmin account and
the static test address `192.168.122.250`. The fixture refuses that address if
it is already leased. Confirm it is also unused by any manually configured
guest before running the static test. Keep failure results and leave failed
candidates out of the supplied catalogue.
