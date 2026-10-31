# License management

Open **System → Settings → License Manager** to view, check, replace or deregister this host's Cloudmin Pro license. The page is at `server-manager/pro/license.cgi` and requires host administrator access. Read-only users can view the status. GPL does not require a license.

Cloudmin checks the license daily over verified HTTPS at `https://www.virtualmin.com/api/license/client`. It also checks before a new change if the saved result is due for refresh. After renewing a license, use **Recheck License**; you do not need to enter the serial number and key again.

## Saved credentials

Cloudmin validates a replacement license before saving it. Credentials are stored in `/etc/cloudmin-license`. Administrators who can change the license can see its saved key. Read-only views, API responses and audit entries omit the key.

Saving a license also updates existing APT, YUM and Webmin repository credentials, including matching APT authentication entries. Supported hosts are `download.cloudmin.com`, `download.cloudmin.dev`, `rc.download.cloudmin.com`, `rc.download.cloudmin.dev`, `rc.cloudmin.dev`, `cloudmin.virtualmin.com` and `vm2.virtualmin.com`. Other repositories and guest Virtualmin licenses stay unchanged.

The installer does not save license credentials. Add them through License Manager after installing Pro.

## Deregistration

**Deregister License** asks for confirmation, then removes this host's saved license and repository credentials. Pro updates and new changes through Cloudmin require a license again. Existing machines, scheduled backups and accepted jobs keep running.

Deregistration does not cancel your subscription or immediately remove the host from the license server's count.

## Grace periods

- **Expiry:** changes remain available for seven days after the expiry date ends in UTC.
- **Migration:** use on too many hosts allows 21 days to finish a migration or assign separate licenses. This period starts when this host first detects excess use.
- **Failed checks:** a previously verified license remains usable for up to 21 days after the last successful check. An earlier expiry or migration deadline still applies. A missing or invalid cache requires a successful check.

Rechecking does not restart expiry or migration grace. Failed checks do not extend any deadline.

Host counts and allowances come from the license API. Cloudmin displays the machine allowance but does not enforce it as a VM quota.

## When changes are blocked

Cloudmin refuses new VM, storage, network, image, template, backup schedule and module configuration changes through its web interface, API and CLI. Existing guests, networks and storage pools keep running. Guest disks and host startup settings stay unchanged.

Forms and buttons keep their normal permissions. A blocked form submission opens the standard error page with instructions for fixing the license.

Inventory, guest consoles and terminals remain accessible under their existing permissions. Accepted jobs can finish, and scheduled backups and retention continue. Existing jobs can be recovered or cleaned up, and network changes can be rolled back. New backup restores require a valid license or an active grace period.

License Manager remains available to recheck or replace the license. Once the license is valid again, new changes are enabled immediately.

The private cache is tied to the license and host identity. A modified cache, or one from another host or license, requires fresh verification. These checks protect Cloudmin's normal operations; they cannot prevent a host administrator from modifying source code or using libvirt directly.

## API and CLI

`license` returns status without the key, including `allowed`, `state`, `message` and any `deadline`. `check_license` refreshes it. `change_license` accepts `serial` and `license_key`. `deregister_license` requires `confirm=1`.

All license actions require host access. Writes also require a writable session and a form token, plus POST over HTTP. These actions remain available while licensing blocks other changes.

```sh
cloudmin get-license
cloudmin check-license
cloudmin change-license --serial 12345 --key-file /root/cloudmin-key
cloudmin deregister-license --yes
```

Use a private key file, or `--key-file -` to read standard input. The CLI does not accept a key directly in command arguments.

## License API

Checks send an HTTPS POST with three fields: `id` is the host ID, `serial` is the license key, and `product` is `cloudmin`. The key stays out of URLs. Cloudmin verifies the server certificate and does not follow redirects or use a fallback endpoint.

The response format is:

```text
OK YYYY-MM-DD VM_LIMIT BASE_HOSTS USED_HOSTS AUTO_RENEW ALLOWANCE [SUBSCRIPTION_ID] product=cloudmin
EXP YYYY-MM-DD VM_LIMIT BASE_HOSTS USED_HOSTS AUTO_RENEW ALLOWANCE [SUBSCRIPTION_ID] product=cloudmin
```

`N` keeps the base host limit. `D`, `T`, `Q`, `P` and `H` allow at least 2, 3, 4, 5 and 6 hosts respectively. `Y` allows unlimited hosts. A zero machine or base host limit also means unlimited. Automatic renewal is reported as `0` or `1`.

`ERR Invalid host or serial number` rejects the license immediately. Other errors and malformed responses count as failed checks; they leave previously verified terms in place, subject to their deadlines.

The server checks the stored product before accepting a license. Cloudmin requires the `product=cloudmin` response field and discards cached decisions made before product checks were added. A response marked `product=virtualmin` is rejected immediately and cannot use offline grace. Virtualmin licenses cannot activate Cloudmin.

The API returns host counts but not the numeric serial number or the date excess use began.

Deploy the license API with product checks before updating clients. Older responses without the product field cannot validate a license.
