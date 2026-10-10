// cloudminSoftwareUpdate(form) shows controls for the selected setup options.
window.cloudminSoftwareUpdate = form => {
    const installer = form.elements.install_source?.value === 'iso';
    const enabled = !installer &&
        ['virtualmin-gpl', 'virtualmin-pro'].includes(form.elements.software?.value);
    // Show Virtualmin options only when installing Virtualmin from a cloud image.
    for (const row of form.querySelectorAll('[data-vm-virtualmin]')) {
        row.hidden = !enabled;
        for (const field of row.querySelectorAll('input, select')) {
            field.disabled = !enabled || row.hasAttribute('data-vm-readonly');
        }
    }
    // Template package lists are editable only when explicitly selected.
    for (const group of form.querySelectorAll('[data-vm-packages]')) {
        const panel = group.querySelector('[data-vm-package-list]');
        panel.hidden = form.elements.packages_mode.value !== 'list';
        form.elements.packages.disabled = installer || panel.hidden || group.hasAttribute('data-vm-readonly');
    }
    // Keep the unused script source out of the page and submitted form data.
    for (const group of form.querySelectorAll('[data-vm-script]')) {
        const mode = form.elements[group.dataset.vmScript + '_mode'].value;
        const disabled = installer || group.hasAttribute('data-vm-readonly');
        // Creation's source switch must not enable Pro preview radio controls.
        for (const field of group.querySelectorAll('input, textarea, button')) field.disabled = disabled;
        for (const panel of group.querySelectorAll('[data-vm-script-source]')) {
            panel.hidden = panel.dataset.vmScriptSource !== mode;
            for (const field of panel.querySelectorAll('input, textarea, button')) {
                field.disabled = disabled || panel.hidden;
            }
        }
    }
};

// cloudminSoftwareInit() binds template and creation forms after navigation.
window.cloudminSoftwareInit = () => {
    // Packages stay present when host policy hides the Virtualmin selector.
    for (const input of document.querySelectorAll('[name="packages"]')) {
        const form = input.form;
        // Theme navigation may initialize the same form more than once.
        if (!form || form.dataset.softwareReady) continue;
        form.dataset.softwareReady = '1';
        // update() reads the current controls after native or theme changes.
        const update = () => window.cloudminSoftwareUpdate(form);
        form.addEventListener('change', update);
        // Enhanced selects also emit synthetic jQuery changes.
        if (window.jQuery) window.jQuery(form).on('change.cloudminSoftware', update);
        update();
    }
};
// Initial loads wait for controls; theme loads can bind them immediately.
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', window.cloudminSoftwareInit, { once: true });
// Theme navigation has already inserted the form before evaluating the script.
else window.cloudminSoftwareInit();
