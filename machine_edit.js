/* Apply the server's resource limits to the existing Webmin size widgets. */
// cloudminVmEditInit() binds ranges once per widget and rendered edit form.
window.cloudminVmEditInit = () => {
    const form = document.getElementById('vm-edit-form');
    // A deferred asset can arrive after navigation has removed the editor.
    if (!form) return;
    for (const input of form.querySelectorAll('[data-vm-max]')) {
        // Read-only widgets submit their preserved value through hidden fields.
        if (input.disabled) continue;
        // Repeated initialization must not add another unit-change listener.
        if (input.dataset.vmLimitsReady) continue;
        input.dataset.vmLimitsReady = '1';
        const units = form.elements[input.name + '_units'];
        // update() translates byte limits whenever the selected unit changes.
        const update = () => {
            const multiplier = units ? Number(units.value) : 1;
            input.type = 'number';
            input.min = Number(input.dataset.vmMin) / multiplier;
            input.max = Number(input.dataset.vmMax) / multiplier;
            input.step = units ? 1048576 / multiplier : 1;
        };
        update();
        if (units) {
            // Byte widgets need unit conversion; CPU fields are already counts.
            units.addEventListener('change', update);
            // Enhanced selects can change the unit through a synthetic jQuery event.
            if (window.jQuery) window.jQuery(units).on('change.cloudminVmEdit', event => {
                // Native changes were handled above;
                // only bridge synthetic ones.
                if (!event.originalEvent) update();
            });
        }
    }
    // Keep allocation ranges within the chosen saved maximum, including unit changes.
    if (!form.dataset.rangesReady) {
        // Bind once while allowing future edits to either value or size unit.
        form.dataset.rangesReady = '1';
        // ranges() caps allocations at the smaller host and selected maximum.
        const ranges = () => {
            for (const [name, maximum] of [['cpus', 'cpu_limit'], ['memory_mib', 'memory_limit_mib']]) {
                const input = form.querySelector('[name="' + name + '"]');
                const limit = form.querySelector('[name="' + maximum + '"]');
                const units = form.querySelector('[name="' + name + '_units"]');
                const limitUnits = form.querySelector('[name="' + maximum + '_units"]');
                // Fixed layouts submit hidden values and
                // need no editable range.
                if (!input || input.disabled || !limit) continue;
                const bytes = Number(limit.value) * (limitUnits ? Number(limitUnits.value) : 1);
                input.max = Math.min(Number(input.dataset.vmMax), bytes) / (units ? Number(units.value) : 1);
            }
        };
        form.addEventListener('input', ranges);
        form.addEventListener('change', ranges);
        // Theme unit controls can notify the form only through jQuery.
        if (window.jQuery) window.jQuery(form).on('change.cloudminVmRanges', event => {
            // Avoid recalculating twice for a bubbled native change event.
            if (!event.originalEvent) ranges();
        });
        ranges();
    }
};
// Initialize after parsing or deferred loading, as the status updater does.
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', window.cloudminVmEditInit, { once: true });
// Deferred theme assets initialize the already parsed form immediately.
else window.cloudminVmEditInit();
