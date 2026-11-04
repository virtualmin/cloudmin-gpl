/* Apply the server's resource limits to the existing Webmin size widgets. */
// cloudminVmEditInit() links hardware fields to their form and binds ranges.
window.cloudminVmEditInit = () => {
    const form = document.getElementById('vm-edit-form');
    const editor = document.getElementById('vm-editor');
    // A deferred asset can arrive after navigation has removed the editor.
    if (!form || !editor) return;
    // All hardware panes submit together; Access has separate, signed forms.
    for (const field of editor.querySelectorAll('[data-vm-edit-fields] input, [data-vm-edit-fields] select, [data-vm-edit-fields] textarea')) {
        field.setAttribute('form', 'vm-edit-form');
    }
    // Keep the outer tab selection with hardware saves, not the Access forms.
    // The tab input sits outside every form; themes without it change nothing.
    [...editor.querySelectorAll('input[name="vm_edit_tabs"]')].find(input => !input.form)?.setAttribute('form', 'vm-edit-form');
    // Access actions have their own buttons. Watch the theme's tab visibility.
    const access = editor.querySelector('#att_access, #div_access');
    const actions = document.getElementById('vm-edit-actions');
    // Bind once when the theme exposes an Access pane and hardware actions.
    if (access && actions && !access.dataset.actionsReady) {
        access.dataset.actionsReady = '1';
        // update() shows hardware actions only while Access is hidden.
        const update = () => { actions.hidden = getComputedStyle(access).display !== 'none'; };
        new MutationObserver(update).observe(access, { attributes: true, attributeFilter: ['class', 'style'] });
        update();
    }
    for (const input of editor.querySelectorAll('[data-vm-max]')) {
        // Read-only widgets submit their preserved value through hidden fields.
        if (input.disabled) continue;
        // Repeated initialization must not add another unit-change listener.
        if (input.dataset.vmLimitsReady) continue;
        input.dataset.vmLimitsReady = '1';
        const units = form.elements[input.name + '_units'];
        // update([normalize]) refreshes bounds and commits whole-MiB values.
        // normalize defaults to false, leaving text untouched while typing.
        const update = (normalize = false) => {
            const multiplier = units ? Number(units.value) : 1;
            input.type = 'number';
            const minimum = Number(input.dataset.vmMin) / multiplier;
            input.min = minimum;
            input.max = Number(input.dataset.vmMax) / multiplier;
            // GiB uses tenths; smaller memory units step by 128 MiB.
            // CPU counts always step by one.
            input.step = units ? (multiplier >= 1073741824 ? 0.1 : 134217728 / multiplier) : 1;
            let value = input.value === '' ? minimum : Number(input.value);
            // MiB and smaller units must represent whole MiB. Normalize only
            // on commit or unit changes, so typing does not move the caret.
            if (units && multiplier <= 1048576 && Number.isFinite(value)) {
                value = Math.round(value * multiplier / 1048576) * 1048576 / multiplier;
                // Keep an empty field empty so the user can enter a new value.
                if (normalize && input.value !== '') input.value = value;
            }
            // Anchor steps to finite memory values so manual entries such as
            // 1.25 GiB remain valid; smaller units use the whole-MiB grid.
            if (units && Number.isFinite(value)) {
                const base = value - Math.floor((value - minimum) / input.step + 1e-8) * input.step;
                input.min = Math.max(minimum, Number(base.toPrecision(12)));
            }
        };
        update(true);
        // Only memory fields need unit conversion and rounding listeners.
        if (units) {
            // Revalidate typed values immediately; commit rounding on change.
            units.addEventListener('change', () => update(true));
            input.addEventListener('input', () => update());
            input.addEventListener('change', () => update(true));
            // Themes can notify value and unit changes through jQuery only.
            if (window.jQuery) {
                window.jQuery(units).on('change.cloudminVmEdit', event => {
                    // Native changes already reached the listener above.
                    if (!event.originalEvent) update(true);
                });
                window.jQuery(input).on('input.cloudminVmEdit change.cloudminVmEdit', event => {
                    // Handle synthetic events without repeating native ones.
                    if (!event.originalEvent) update(event.type === 'change');
                });
            }
        }
    }
    // Keep allocation ranges within the chosen maximum across unit changes.
    if (!form.dataset.rangesReady) {
        // Bind once while allowing future edits to either value or size unit.
        form.dataset.rangesReady = '1';
        // ranges() caps allocations at the smaller host and selected maximum.
        const ranges = () => {
            for (const [name, maximum] of [['cpus', 'cpu_limit'], ['memory_mib', 'memory_limit_mib']]) {
                const input = editor.querySelector('[name="' + name + '"]');
                const limit = editor.querySelector('[name="' + maximum + '"]');
                const units = editor.querySelector('[name="' + name + '_units"]');
                const limitUnits = editor.querySelector('[name="' + maximum + '_units"]');
                // Fixed layouts submit hidden values without editable ranges.
                if (!input || input.disabled || !limit) continue;
                const bytes = Number(limit.value) * (limitUnits ? Number(limitUnits.value) : 1);
                input.max = Math.min(Number(input.dataset.vmMax), bytes) / (units ? Number(units.value) : 1);
            }
        };
        // Form-associated fields bubble to their editor, not the empty form.
        editor.addEventListener('input', ranges);
        editor.addEventListener('change', ranges);
        // Some theme unit controls notify the editor only through jQuery.
        if (window.jQuery) window.jQuery(editor).on('input.cloudminVmRanges change.cloudminVmRanges', event => {
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
