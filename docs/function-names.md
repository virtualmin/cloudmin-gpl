# Function names and external callers

The naming reference is the original
[Cloudmin GPL source at d0a42b7d](https://github.com/virtualmin/cloudmin-gpl/tree/d0a42b7d8b6f1c11c2e2795f38716a2636f9e4ed),
the upstream HEAD checked on September 30, 2026. Cloudmin 10 uses its naming
conventions where they describe the new implementation accurately:

- `get_*` returns a record, value, service object or page data.
- `list_*` returns a collection.
- `check_*` checks a condition; its comment specifies the return value or error.
- `show_*` builds UI output. The comment says whether it returns or prints HTML.
- `describe_*` and `nice_*` format labels and readable values.
- `parse_*`, `build_*`, `generate_*` and `complete_*` describe their operation.

For example, `vm_new_password` became `generate_random_password`, reusing the
original name. `terminal_command` became `build_terminal_command`, since its
result includes the isolated service launcher as well as SSH. Libvirt methods
keep the term `domain`; they operate on libvirt objects, rather than Cloudmin 9
server records. Constructors and ordinary object operations such as `new`,
`run`, `save` and `find` keep their existing names.

Existing public names such as `list_managed_servers`, `get_managed_server`,
`get_server_mac`, `check_server_status`, `can_action` and `get_parent_server`
remain unchanged. Shared names do not imply complete Cloudmin 9 API
compatibility: signatures, return values and supported features are documented
by each function. The naming change preserves current behavior, including
argument order, returned fields, form parameters and stored configuration.

## External caller audit

The local Webmin, Virtualmin GPL, Virtualmin Pro and theme sources were checked
for `server-manager`, qualified `server_manager::` calls and dynamic dispatch.
No external caller found in that audit uses a renamed helper.

| Caller | Cloudmin interface | Current status |
| --- | --- | --- |
| Webmin frame navigation and default guest settings | `can_action`, `list_available_managed_servers_sorted`, `%access` | Retained |
| Webmin menu loading and action logs | `list_webmin_menu`, `parse_webmin_log` | Retained |
| SPA theme guest navigation | `list_managed_servers`, `list_available_managed_servers_sorted` | Retained |
| Webmin login mode and system information | `%access`, module metadata | Retained |
| Webmin LVM device usage | `list_managed_servers`, `get_parent_server`, `type_kvm_list_disk_devices` | Reports attached block devices and their LVM aliases |
| Virtualmin GPL IP allocation | `list_managed_servers`, `get_server_ip`, `get_server_ip6` | Address helpers load libvirt addresses on demand and separate IPv4 from IPv6 |
| Virtualmin GPL system information and SPA theme version display | Optional `get_module_version_and_type` | Absent; callers check whether it exists |
| Webmin frame dashboard extensions | Optional `list_plugin_sections` | Absent; caller checks whether it exists |
| Virtualmin remote provisioning | `/server-manager/remote.cgi` | Intentionally dropped; a new API and client integration are planned for Virtualmin Connect |
| Virtualmin Pro additions | No direct Cloudmin references | Uses the shared GPL integration |

Cloudmin calls Webmin's `theme_select_server` and `theme_post_save_server` hooks
through its selection and save helpers. The hook names and guest record fields
stay the same, so existing themes keep working with Cloudmin 10.
Cloudmin ships its console client, layout and noVNC library. Its consoles work
in all themes. Themes can add terminal font preferences,
shortcuts and saved console zoom. Virtualmin's shared JSON and new-feature libraries also
contain Cloudmin-specific branches, but the new module does not load those
libraries.

## Existing integration gaps

These require behavior changes beyond function renaming:

- Webmin LVM's legacy running-state check expects `down`, rather than
  libvirt's `shutoff`. It conservatively treats attached disks of stopped
  guests as in use too.
- The optional version helper and plugin sections are skipped when absent.
  Virtualmin's system-information function omits its Cloudmin version row;
  the SPA theme has a separate fallback.
- Virtualmin provisioning through the Cloudmin 9 `remote.cgi` protocol is
  intentionally not implemented. A replacement API and Virtualmin client
  integration are planned for Virtualmin Connect. See the design document,
  section 10.
