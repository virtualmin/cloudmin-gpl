/* Update saved-change summaries without touching unsaved form inputs. */
// cloudminPendingUpdate(vm)
// Refreshes saved differences; null means unavailable.
window.cloudminPendingUpdate = vm => {
    const banner = document.querySelector('[data-vm-pending-banner]');
    // Console views update their badges through machine_status.js without
    // a banner.
    if (!banner) return;
    const action = document.querySelector('#vm-power-cycle-form');
    // Missing inventory must not enable a power operation or clear a warning.
    if (action) {
        // Hide the editor's whole button cluster, including its spacing.
        const container = action.closest('.ui_form_grouped_cluster') || action;
        container.hidden =
            !vm ||
            !['running', 'blocked'].includes(vm.state) ||
            vm.pending == null ||
            !Object.keys(vm.pending).length;
        // Let the wrapper control visibility after the initial render.
        if (container !== action) action.hidden = false;
    }
    const config = JSON.parse(banner.dataset.pendingConfig);
    // Failed XML comparisons preserve the last known warning until fresh data.
    if (vm?.pending == null) return;
    const count = Object.keys(vm.pending).length;
    banner.hidden = !count;
    banner.querySelector('[data-pending-title]').textContent =
        count === 1 ? config.one : config.many.replace('$1', count);
    // Matching definitions hide the entire summary, including stale row text.
    if (!count) return;
    // format(field, value) renders public resource, boot and network settings.
    const format = (field, value) => {
        // Memory arrives in MiB and is shown in MiB or GiB.
        if (field.includes('memory'))
            return value >= 1024
                ? (value / 1024).toLocaleString(undefined, {
                      maximumFractionDigits: 2
                  }) + ' GiB'
                : value + ' MiB';
        // Match the form's translated values for the boot-menu flag.
        if (field === 'bootmenu') return value ? config.yes : config.no;
        // Show stable identities and attachment names instead of host
        // tap names.
        if (field === 'networks')
            return (
                value
                    .map(
                        item =>
                            `${item.mac}: ${config.boot_labels.kinds[item.type]} ${item.source}`
                    )
                    .join(', ') || config.none
            );
        // Boot entries can name a device class or a particular attachment.
        if (field === 'boot')
            return (
                value
                    .map(item => {
                        // Live roles follow external attachment changes without
                        // stale filenames.
                        const labels = config.boot_labels;
                        const kind = item.device || 'disk',
                            target = item.target;
                        const roles = vm.disk_roles || labels.disks;
                        const name =
                            kind === 'disk' && target
                                ? labels.roles[roles[target] || 'disk'] ||
                                  labels.roles.disk
                                : labels.kinds[kind] || kind;
                        return name + (target ? ` (${target})` : '');
                    })
                    .join(' → ') || config.boot_default
            );
        return String(value);
    };
    // Rows already exist for each public field;
    // update only values and visibility.
    for (const row of banner.querySelectorAll('[data-pending-field]')) {
        const field = row.dataset.pendingField,
            entry = vm.pending[field];
        row.hidden = !entry;
        // Callback replacements preserve literal dollar signs in device labels.
        if (entry)
            row.querySelector('[data-pending-values]').textContent =
                config.values
                    .replace('$1', () => format(field, entry.running))
                    .replace('$2', () => format(field, entry.saved));
    }
};
