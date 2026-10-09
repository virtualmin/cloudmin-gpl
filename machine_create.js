/* Keep installer media and cloud-init provisioning choices separate. */
(() => {
// Re-evaluated assets reuse the document's bindings during theme navigation.
if (window.cloudminVmCreateInit) {
    window.cloudminVmCreateInit();
    return;
}
const forms = new WeakMap();
// cloudminVmCreateInit() binds the current creation form once.
window.cloudminVmCreateInit = () => {
    const form = document.getElementById('vm-create-form');
    // Deferred assets may arrive after navigation removed the creation form.
    if (!form) return;
    // Reuse live bindings, but bind again for cached HTML clones without
    // listeners.
    if (forms.has(form)) {
        forms.get(form)();
        return;
    }
    const fields = form.elements;
    // Keep all media in inert markup so a cached clone retains filtered options.
    let inventory = form.querySelector('template[data-vm-images]');
    // Capture the original choices before filtering the visible selector.
    if (!inventory) {
        inventory = document.createElement('template');
        inventory.dataset.vmImages = '1';
        inventory.content.append(fields.image.cloneNode(true));
        form.append(inventory);
    }
    const images = Array.from(inventory.content.firstElementChild.cloneNode(true).options);
    // Remember headings before source switching moves options between groups.
    const imageGroups = new Map(images.map(option => [option,
        option.parentElement?.tagName === 'OPTGROUP' ? option.parentElement.label : '']));
    const selections = {};
    let previousSource;
    // Read preset JSON as text to preserve inline script indentation.
    const presets = JSON.parse(form.querySelector('script[data-vm-presets]')?.textContent || '{}');
    // Plans set resources; templates exclude machine names and secrets.
    const planFields = ['cpus', 'memory_mib', 'disk_gib'];
    const templateFields = ['image', 'install_source', 'pool', 'network', 'username',
        'auth_type', 'ssh_keys', 'address_mode', 'gateway4', 'gateway6', 'dns',
        'firmware', 'start', 'autostart', 'software', 'virtualmin_bundle',
        'virtualmin_type', 'virtualmin_postgres', 'virtualmin_ssl', 'webmin_register',
        'packages', 'before_script', 'before_script_mode', 'before_script_path',
        'after_script', 'after_script_mode', 'after_script_path'];
    let applying = false;

    // setField(name, value) handles ordinary inputs and Webmin radio groups.
    const setField = (name, value) => {
        const field = fields[name];
        // Some source-specific fields are absent from minimal creation forms.
        if (!field) return;
        // Keep removed resources visible; the server will reject them on submit.
        if (field.tagName === 'SELECT' && value &&
            !Array.from(field.options).some(option => option.value === String(value))) {
            field.add(new Option(String(value), String(value)));
        }
        field.value = String(value);
    };
    // selected([field]) returns the chosen option, or undefined for no selection.
    const selected = field => field?.options
        ? Array.from(field.options).find(option => option.value === field.value) : undefined;
    // fill(template, ...values) replaces $1, $2 and so on in a translated label.
    const fill = (template, ...values) => String(template || '')
        .replace(/\$(\d)/g, (_, index) => values[index - 1] ?? '');
    // size(value, units) formats a quantity and its byte multiplier for a chip.
    const size = (value, units) => {
        let amount = Number(value || 0) * Number(units || 1);
        const names = ['bytes', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
        let index = 0;
        while (amount >= 1024 && index < names.length - 1) {
            amount /= 1024;
            index++;
        }
        // Round only the displayed summary, leaving the submitted value intact.
        return (Number.isInteger(amount) ? amount : amount.toFixed(2).replace(/\.?0+$/, '')) + ' ' + names[index];
    };
    // chip(name, text) updates a named summary chip and hides empty labels.
    const chip = (name, text) => {
        const node = form.querySelector('[data-vm-chip="' + name + '"]');
        // Skip chips absent from this form.
        if (!node) return;
        node.hidden = !text;
        (node.querySelector?.('.ui_chip_text') || node).textContent = text;
    };
    // summary() shows current form values, including manual edits to presets.
    const summary = () => {
        const labels = presets.labels || {};
        const installer = fields.install_source.value === 'iso';
        const image = selected(fields.image);
        chip('image', image?.text || '');
        // Show a download notice for an uncached catalogue image.
        chip('download', image?.dataset?.vmDownload || '');
        chip('resources', fill(labels.resources, fields.cpus?.value || '',
            size(fields.memory_mib?.value, fields.memory_mib_units?.value),
            size(fields.disk_gib?.value, fields.disk_gib_units?.value)));
        // Replace the network's forwarding mode with guest addressing in the chip.
        const network = (selected(fields.network)?.text || '').replace(/\s*\([^)]*\)\s*$/, '');
        chip('network', network && !installer ? fill(labels.network, network,
            fields.address_mode?.value === 'static' ? labels.static : labels.dhcp) : network);
        const software = installer ? 'none' : fields.software?.value || 'none';
        let setup = labels.none;
        if (software === 'virtualmin-gpl' || software === 'virtualmin-pro') {
            // Name the edition and web server the way templates are named.
            setup = fill(labels.virtualmin, software === 'virtualmin-pro' ? labels.pro : labels.gpl,
                fields.virtualmin_bundle?.value === 'LEMP' ? labels.nginx : labels.apache);
            // Mention PostgreSQL only when it is included in the installation.
            if (fields.virtualmin_postgres?.value === '1') setup = fill(labels.postgres, setup);
        }
        else if (!installer) {
            // Saved scripts remain identifiable even after Pro is removed.
            const scripts = ['before_script', 'after_script'].some(name =>
                (fields[name + '_mode']?.value || 'none') !== 'none' &&
                ((fields[name]?.value || '').trim() || (fields[name + '_path']?.value || '').trim()));
            // Scripts use the general setup label, with or without packages.
            if (scripts) setup = labels.setup;
            // Package-only setup gets its own label; otherwise keep None.
            else if ((fields.packages?.value || '').trim()) setup = labels.packages || labels.setup;
        }
        chip('software', setup);
        const note = form.querySelector('[data-vm-template-note]');
        // Update the template description only on forms that display it.
        if (note) {
            const id = fields.template?.value;
            const entry = presets.template?.entries?.find(candidate => candidate.id === id);
            let text = presets.descriptions?.[id] || '';
            // Hide repeated text only when the module setting requests it.
            if (note.dataset.vmTemplateNote === '1' && entry &&
                text.toLowerCase() === String(entry.name || '').toLowerCase()) text = '';
            const description = note.querySelector?.('[data-vm-template-desc]');
            // Replace the text without removing the note's icon or container.
            if (description) description.textContent = text;
            note.hidden = !text;
        }
    };

    // update() filters media and enables only fields used by the chosen source.
    const update = () => {
        const source = fields.install_source.value;
        const installer = source === 'iso';
        // Save the outgoing choice only after the form has a known source.
        if (previousSource) selections[previousSource] = fields.image.value;
        if (previousSource !== source) {
            // Restore the last image chosen for this source.
            const choices = images.filter(option => option.dataset.vmImageSource === source);
            const selected = selections[source] || fields.image.value;
            const children = [], groups = new Map();
            for (const option of choices) {
                const label = imageGroups.get(option);
                if (!label) {
                    // Keep ungrouped image choices outside distribution headings.
                    children.push(option);
                    continue;
                }
                if (!groups.has(label)) {
                    // Create only headings with images for the selected source.
                    const group = document.createElement('optgroup');
                    group.label = label;
                    groups.set(label, group);
                    children.push(group);
                }
                groups.get(label).append(option);
            }
            fields.image.replaceChildren(...children);
            // Fall back to the first image if the saved choice is unavailable.
            fields.image.value = choices.some(option => option.value === selected)
                ? selected : choices[0]?.value || '';
            previousSource = source;
        }
        // Hidden cloud-init fields must also be excluded from ISO submissions.
        for (const group of form.querySelectorAll('[data-vm-cloud-init]')) {
            group.hidden = installer;
            for (const field of group.querySelectorAll('input, select, textarea')) {
                field.disabled = installer;
            }
        }
        // Enable only the credentials used by the authentication method.
        const keys = !installer && fields.auth_type.value !== 'password';
        const password = !installer && fields.auth_type.value !== 'keys';
        form.querySelector('#vm_keys_row').hidden = !keys;
        form.querySelector('#vm_password_row').hidden = !password;
        fields.ssh_keys.disabled = !keys;
        fields.password.disabled = !password;
        // Submit static addresses only when cloud-init is set up to use them.
        for (const name of ['ipv4', 'gateway4', 'ipv6', 'gateway6', 'dns']) {
            fields[name].disabled = installer || fields.address_mode.value !== 'static';
        }
        // Pro license inputs belong to this submission, never a saved preset.
        for (const row of form.querySelectorAll('[data-vm-license]')) {
            const enabled = !installer && fields.software?.value === 'virtualmin-pro';
            row.hidden = !enabled;
            for (const field of row.querySelectorAll('input')) {
                field.disabled = !enabled;
                // Clear license inputs when leaving Pro.
                if (!enabled) field.value = '';
            }
        }
        // Use the hostname checkbox for cloud images; ISOs ignore this input.
        const separate = !installer && (fields.hostname_set ? fields.hostname_set.checked : true);
        const hostnameRow = form.querySelector('#vm_hostname_row');
        // Follow the checkbox when the form provides a separate hostname row.
        if (hostnameRow) hostnameRow.hidden = !separate;
        // Omit hidden hostnames so the server uses the virtual machine name.
        if (fields.hostname) fields.hostname.disabled = !separate;
        window.cloudminSoftwareUpdate?.(form);
        // Show source guidance and block submission without usable media.
        for (const note of form.querySelectorAll('[data-vm-installer]')) note.hidden = !installer;
        const empty = !fields.image.options.length;
        for (const note of form.querySelectorAll('[data-vm-source-empty]')) note.hidden = !empty;
        for (const button of form.querySelectorAll('[type="submit"]')) button.disabled = empty;
        summary();
    };
    // changed(event) applies a preset only when its selector changes.
    const changed = event => {
        const kind = event?.target?.name;
        // Ignore synthetic selector events raised while applying a preset.
        if (!applying && ['template', 'plan'].includes(kind)) {
            const record = presets[kind]?.entries.find(entry => entry.id === fields[kind].value);
            if (record) {
                // Fill missing values from the base preset of this kind.
                applying = true;
                const names = kind === 'plan' ? planFields : templateFields;
                const values = { ...presets.defaults, ...record.settings };
                // Infer the selector for templates saved with pasted scripts alone.
                for (const script of ['before_script', 'after_script']) {
                    values[script + '_mode'] ||= values[script + '_path'] ? 'file'
                        : values[script] ? 'inline' : 'none';
                }
                // Use larger units for readable sizes without rounding allocations.
                if (kind === 'plan') {
                    for (const [name, base] of [['memory_mib', 1024 ** 2], ['disk_gib', 1024 ** 3]]) {
                        let value = Number(values[name] || 0), units = base;
                        // Whole and quarter units keep values such as 2 or 1.5 GiB short.
                        while (value >= 1024 && value % 256 === 0 && units < 1024 ** 4) {
                            value /= 1024;
                            units *= 1024;
                        }
                        values[name] = value;
                        setField(name + '_units', units);
                    }
                }
                for (const name of names.filter(name => name !== 'image')) setField(name, values[name] ?? '');
                update();
                // Source switching replaces image options, so choose the image last.
                if (kind === 'template') {
                    // Match the chosen source; a template without media uses its first image.
                    const choice = images.find(option => option.value === values.image);
                    setField('image', choice && choice.dataset.vmImageSource !== fields.install_source.value
                        ? fields.image.options[0]?.value || '' : values.image || fields.image.options[0]?.value || '');
                }
                // Notify only changed controls. Enhanced unit selectors can
                // reset when their initial selection gets a change event.
                const changedNames = kind === 'plan'
                    ? [...names, 'memory_mib_units', 'disk_gib_units'] : names;
                for (const name of changedNames) {
                    const field = fields[name];
                    // Radio groups do not expose dispatchEvent().
                    if (field?.dispatchEvent) field.dispatchEvent(new Event('change', { bubbles: true }));
                }
                applying = false;
            }
        }
        update();
    };
    form.addEventListener('change', changed);
    // input(event) refreshes allocation and package summaries while typing.
    form.addEventListener('input', event => {
        // Other fields update the summary through their change handler.
        if (['cpus', 'memory_mib', 'disk_gib', 'packages'].includes(event?.target?.name)) summary();
    });
    // Enhanced selects can send synthetic jQuery changes.
    if (window.jQuery) window.jQuery(form).on('change.cloudminVmCreate', event => {
        // Native events already reached the form's change handler.
        if (!event.originalEvent) changed(event);
    });
    forms.set(form, update);
    update();
};
// Browsers restore saved controls after pageshow without firing change events.
window.addEventListener('pageshow', () => setTimeout(window.cloudminVmCreateInit, 0));
// Themes that replace content without a document load re-run initialization.
if (typeof theme === 'object' && theme?.api?.event?.on?.page?.afterReplace) theme.api.event.on.page.afterReplace(window.cloudminVmCreateInit);
// Wait for the form when this asset loads before the document is ready.
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', window.cloudminVmCreateInit, { once: true });
// Deferred theme navigation can load the asset after DOMContentLoaded.
else window.cloudminVmCreateInit();
})();
