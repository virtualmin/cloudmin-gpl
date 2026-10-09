// Exercise source switching without a browser or a running Webmin server.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// fixture(options, source, image, [presets]) models the form and its preset JSON.
function fixture(options, source, image, presets = {}) {
    // Model the named controls, including fields disabled in installer mode.
    const elements = {};
    for (const name of ['install_source', 'image', 'auth_type', 'username', 'password', 'ssh_keys',
        'address_mode', 'hostname', 'ipv4', 'gateway4', 'ipv6', 'gateway6', 'dns',
        'software', 'virtualmin_bundle', 'virtualmin_postgres', 'packages',
        'virtualmin_serial', 'virtualmin_key', 'template', 'plan', 'before_script', 'after_script',
        'cpus', 'memory_mib', 'memory_mib_units', 'disk_gib', 'disk_gib_units']) {
        elements[name] = { value: '', disabled: false };
    }
    Object.assign(elements.install_source, { value: source });
    // replaceChildren(...children) models a select's flattened options list.
    Object.assign(elements.image, { value: image, options,
        // cloneNode() retains a separate option list for the inert inventory.
        cloneNode() { return { options: this.options.slice(), cloneNode: this.cloneNode }; },
        replaceChildren(...children) {
            this.children = children;
            this.options = children.flatMap(child => child.tagName === 'OPTGROUP' ? child.children : [child]);
        } });
    elements.auth_type.value = 'password';
    elements.address_mode.value = 'dhcp';
    // The checkbox under the name decides whether the hostname row is open.
    elements.hostname_set = { checked: false, disabled: false };
    // querySelectorAll() returns the cloud-init controls for bulk disabling.
    const cloud = { hidden: false, querySelectorAll: () => Object.entries(elements)
        .filter(([name]) => !['install_source', 'image', 'template', 'plan', 'cpus',
            'memory_mib', 'memory_mib_units', 'disk_gib', 'disk_gib_units'].includes(name))
        .map(([, field]) => field) };
    // A separate hostname is optional even when Virtualmin is selected.
    elements.hostname.required = false;
    const nodes = { '#vm_keys_row': {}, '#vm_password_row': {}, '#vm_hostname_row': {},
        '[data-vm-source-empty]': {}, '[data-vm-installer]': {}, '[type="submit"]': {} };
    nodes['script[data-vm-presets]'] = { tagName: 'SCRIPT', textContent: JSON.stringify(presets) };
    nodes['[data-vm-license]'] = { querySelectorAll: () =>
        [elements.virtualmin_serial, elements.virtualmin_key] };
    // querySelector(selector) returns no text span, exercising the chip fallback.
    for (const chip of ['image', 'download', 'resources', 'network', 'software']) {
        nodes['[data-vm-chip="' + chip + '"]'] = { querySelector: () => null };
    }
    // querySelector(selector) and querySelectorAll(selector) return test nodes.
    // addEventListener(event, callback) records the form's event handlers.
    const listeners = {};
    const form = { dataset: {}, elements,
        // append(node) preserves the inventory template across simulated
        // restores.
        append: node => { nodes['template[data-vm-images]'] = node; },
        querySelector: selector => nodes[selector],
        querySelectorAll: selector => selector === '[data-vm-cloud-init]' ? [cloud] : [nodes[selector]].filter(Boolean),
        addEventListener: (event, callback) => { listeners[event] = callback; } };
    // getElementById() exposes the form to the real script's load-time setup.
    const pageListeners = {}, themeListeners = {}, timers = [];
    const context = { window: {
        addEventListener: (event, callback) => { pageListeners[event] = callback; },
        // on(event, callback) records delegated form events.
        jQuery: () => ({ on(event, callback) { listeners[event] = callback; } })
    }, theme: { api: { event: { on: { page: {
        // afterReplace(callback) records the theme's page replacement hook.
        afterReplace(callback) { themeListeners.afterReplace = callback; }
    } } } } }, Event, setTimeout: callback => timers.push(callback), document: {
        readyState: 'complete', getElementById: () => form,
        // createElement(tag) models persistent templates and rebuilt option
        // groups.
        createElement: tag => tag === 'template' ? { dataset: {}, content: {
            // append(node) retains the select copied into the template
            // fragment.
            append(node) { this.firstElementChild = node; }
        } } : ({ tagName: tag.toUpperCase(), children: [],
            append(option) { this.children.push(option); option.parentElement = this; } })
    } };
    vm.runInNewContext(fs.readFileSync('machine_create.js', 'utf8'), context);
    return { elements, cloud, nodes, update: listeners.change, form, context,
        listeners, pageListeners, themeListeners, timers };
}
// Mixed inventory must retain the selected cloud image and authentication mode.
const options = [ ['cloud-a', 'cloud'], ['cloud-b', 'cloud'], ['setup', 'iso'] ]
    .map(([value, source]) => ({ value, dataset: { vmImageSource: source } }));
const f = fixture(options, 'cloud', 'cloud-b');
assert.equal(f.elements.image.options.length, 2);
assert.equal(f.elements.image.value, 'cloud-b');
assert.equal(f.elements.password.disabled, false);
assert.equal(f.elements.ssh_keys.disabled, true);
assert.equal(f.nodes['#vm_keys_row'].hidden, true);
assert.equal(f.nodes['[data-vm-installer]'].hidden, true);
assert.equal(f.nodes['[data-vm-source-empty]'].hidden, true);
// The hostname input stays hidden and disabled until its checkbox is selected.
assert.equal(f.nodes['#vm_hostname_row'].hidden, true);
assert.equal(f.elements.hostname.disabled, true, 'a hidden hostname is not submitted');
// Installer mode removes cloud choices and prevents hidden provisioning inputs.
f.elements.install_source.value = 'iso';
f.update();
assert.equal(f.elements.image.value, 'setup');
assert.equal(f.cloud.hidden, true);
for (const name of ['username', 'password', 'ssh_keys', 'address_mode', 'hostname', 'ipv4']) {
    assert.equal(f.elements[name].disabled, true, `${name} excluded from installer submission`);
}
// Switching back restores the image and current cloud-init field choices.
f.elements.install_source.value = 'cloud';
f.update();
assert.equal(f.elements.image.value, 'cloud-b', 'cloud choice survives source switching');
f.elements.auth_type.value = 'keys';
f.elements.address_mode.value = 'static';
f.update();
assert.equal(f.elements.password.disabled, true);
assert.equal(f.elements.ssh_keys.disabled, false);
assert.equal(f.elements.ipv4.disabled, false);
// License fields are enabled only for Pro and cleared when Pro is deselected.
f.elements.software.value = 'virtualmin-pro';
f.update({ target: { name: 'software' } });
assert.equal(f.elements.virtualmin_key.disabled, false);
assert.equal(f.nodes['[data-vm-license]'].hidden, false);
f.elements.virtualmin_key.value = 'fixture-license';
f.elements.software.value = 'virtualmin-gpl';
f.update({ target: { name: 'software' } });
assert.equal(f.elements.virtualmin_key.disabled, true);
assert.equal(f.elements.virtualmin_key.value, '');
assert.equal(f.nodes['[data-vm-license]'].hidden, true);
// Virtualmin uses the VM name unless the user asks for a separate hostname.
assert.equal(f.elements.hostname_set.checked, false, 'Virtualmin leaves the hostname checkbox unticked');
assert.equal(f.nodes['#vm_hostname_row'].hidden, true);
assert.equal(f.elements.hostname.disabled, true);
assert.equal(f.elements.hostname.required, false, 'Virtualmin does not require a separate hostname');
// An explicitly opened field stays optional and survives software changes.
f.elements.hostname_set.checked = true;
f.update({ target: { name: 'hostname_set' } });
assert.equal(f.nodes['#vm_hostname_row'].hidden, false);
assert.equal(f.elements.hostname.disabled, false);
assert.equal(f.elements.hostname.required, false, 'a blank separate hostname can use the VM name');
f.elements.software.value = 'none';
f.update({ target: { name: 'software' } });
assert.equal(f.elements.hostname.required, false, 'other software leaves the hostname optional');
assert.equal(f.nodes['#vm_hostname_row'].hidden, false, 'leaving Virtualmin keeps an opened row open');
// Repeated initialization must leave the user's restored selection intact.
f.context.window.cloudminVmCreateInit();
assert.equal(f.elements.image.value, 'cloud-b', 'repeat initialization preserves selection');
// Creation stays blocked until the chosen source has an available image.
const empty = fixture(options.slice(0, 2), 'iso', 'cloud-a');
assert.equal(empty.nodes['[data-vm-source-empty]'].hidden, false);
assert.equal(empty.nodes['[type="submit"]'].disabled, true);
empty.elements.install_source.value = 'cloud';
empty.update();
assert.equal(empty.nodes['[type="submit"]'].disabled, false);
// ISO-only inventory must initialize directly into installer mode.
const iso = fixture(options.slice(2), 'iso', 'setup');
assert.equal(iso.elements.image.value, 'setup');
assert.equal(iso.elements.password.disabled, true);
// Distribution headings survive repeated source switches, without empty groups.
const groupedOptions = [
    ['debian13', 'cloud', 'Debian'], ['debian12', 'cloud', 'Debian'],
    ['debian-iso', 'iso', 'Debian'], ['rocky10', 'cloud', 'Rocky Linux']
].map(([value, source, label]) => ({value, dataset: {vmImageSource: source},
    parentElement: {tagName: 'OPTGROUP', label}}));
const grouped = fixture(groupedOptions, 'cloud', 'rocky10');
assert.deepEqual(Array.from(grouped.elements.image.children, group => group.label), ['Debian', 'Rocky Linux']);
assert.equal(grouped.elements.image.value, 'rocky10');
for (let i = 0; i < 2; i++) {
    grouped.elements.install_source.value = 'iso';
    grouped.update();
    assert.deepEqual(Array.from(grouped.elements.image.children, group => group.label), ['Debian']);
    assert.equal(grouped.elements.image.value, 'debian-iso');
    grouped.elements.install_source.value = 'cloud';
    grouped.update();
    assert.deepEqual(Array.from(grouped.elements.image.children, group => group.label), ['Debian', 'Rocky Linux']);
    assert.deepEqual(Array.from(grouped.elements.image.options, option => option.value), ['debian13', 'debian12', 'rocky10']);
    assert.equal(grouped.elements.image.value, 'rocky10');
}
// Applying a template preserves literal indentation and embedded HTML text.
const script = "cat <<'EOF'\nitems:\n    - 'a  b'\nEOF\necho '</script>'\n";
const templated = fixture(options, 'cloud', 'cloud-a', {
    defaults: { install_source: 'cloud', auth_type: 'password' },
    template: { entries: [{ id: 'script', settings: { before_script: script, after_script: script } }] }
});
templated.elements.template.value = 'script';
templated.update({ target: { name: 'template' } });
assert.equal(templated.elements.before_script.value, script);
assert.equal(templated.elements.after_script.value, script);
// Template switches follow the selected description display mode.
const descriptions = fixture(options, 'cloud', 'cloud-a', {
    template: { entries: [{ id: 'repeated', name: 'Virtualmin GPL with Apache', settings: {} },
        { id: 'custom', name: 'Custom', settings: {} }, { id: 'empty', name: 'Empty', settings: {} }] },
    descriptions: { repeated: 'Virtualmin GPL with Apache', custom: 'My <custom> setup' }
});
const descriptionText = { textContent: '' };
const descriptionNote = { dataset: { vmTemplateNote: '1' }, querySelector: () => descriptionText };
descriptions.nodes['[data-vm-template-note]'] = descriptionNote;
descriptions.elements.template.value = 'repeated';
descriptions.update({ target: { name: 'template' } });
assert.equal(descriptionNote.hidden, true, 'conditional mode hides repeated descriptions');
descriptionNote.dataset.vmTemplateNote = '2';
descriptions.update();
assert.equal(descriptionNote.hidden, false, 'Always show displays repeated descriptions');
assert.equal(descriptionText.textContent, 'Virtualmin GPL with Apache');
descriptions.elements.template.value = 'empty';
descriptions.update({ target: { name: 'template' } });
assert.equal(descriptionNote.hidden, true, 'empty descriptions remain hidden');
descriptionNote.dataset.vmTemplateNote = '1';
descriptions.elements.template.value = 'custom';
descriptions.update({ target: { name: 'template' } });
assert.equal(descriptionNote.hidden, false, 'conditional mode shows a distinct description');
assert.equal(descriptionText.textContent, 'My <custom> setup', 'description is kept as literal text');
// Selecting a template applies its username and authentication settings.
const access = fixture(options, 'cloud', 'cloud-a', {
    defaults: { install_source: 'cloud', auth_type: 'password' },
    template: { entries: [{ id: 'gpl', settings: { username: 'myuser', auth_type: 'keys' } }] }
});
assert.equal(access.nodes['#vm_keys_row'].hidden, true);
assert.equal(access.nodes['[data-vm-installer]'].hidden, true);
access.elements.template.value = 'gpl';
access.update({ target: { name: 'template' } });
assert.equal(access.elements.username.value, 'myuser');
assert.equal(access.elements.auth_type.value, 'keys');
assert.equal(access.nodes['#vm_keys_row'].hidden, false);
assert.equal(access.nodes['#vm_password_row'].hidden, true);

// Selecting a template never opens or closes a section; Module Configuration
// controls which start open, and users can then toggle them.
const opened = [];
const sections = fixture(options, 'cloud', 'cloud-a', {
    defaults: { install_source: 'cloud', auth_type: 'password', address_mode: 'dhcp' },
    template: { entries: [
        { id: 'virtualmin', settings: { software: 'virtualmin-gpl' } },
        { id: 'static', settings: { address_mode: 'static' } }
    ] }
});
for (const name of ['vm_software', 'vm_network']) {
    // contains(className) models closed sections that the script could open.
    sections.nodes['#hiddendiv_' + name] = { classList: { contains: () => true } };
}
// hidden_opener(id) records any unexpected attempt to toggle a section.
sections.context.window.hidden_opener = id => opened.push(id);
for (const template of ['virtualmin', 'static']) {
    sections.elements.template.value = template;
    sections.update({ target: { name: 'template' } });
    assert.deepEqual(opened, [], template + ' template leaves every section as rendered');
}
// Templates must not notify resource controls that belong to the chosen plan.
const resources = fixture(options, 'cloud', 'cloud-a', {
    defaults: { install_source: 'cloud', auth_type: 'password' },
    template: { entries: ['none', 'virtualmin-gpl', 'virtualmin-pro'].map(software =>
        ({ id: software, settings: { software } })) },
    plan: { entries: [
        { id: 'small', settings: { cpus: 1, memory_mib: 512, disk_gib: 10 } },
        { id: 'default', settings: { cpus: 2, memory_mib: 2048, disk_gib: 20 } },
        { id: 'fractional', settings: { cpus: 1, memory_mib: 1536, disk_gib: 1024 } },
        { id: 'precise', settings: { cpus: 1, memory_mib: 1025, disk_gib: 1025 } }
    ] }
});
const allocation = { cpus: '2', memory_mib: '2', memory_mib_units: String(1024 ** 3),
    disk_gib: '20', disk_gib_units: String(1024 ** 3) };
const notified = [];
for (const [name, value] of Object.entries(allocation)) {
    resources.elements[name].value = value;
    resources.elements[name].dispatchEvent = () => notified.push(name);
}
for (const template of ['virtualmin-gpl', 'virtualmin-pro', 'none']) {
    resources.elements.template.value = template;
    resources.update({ target: { name: 'template' } });
    for (const [name, value] of Object.entries(allocation)) {
        assert.equal(resources.elements[name].value, value, `${template} preserves ${name}`);
    }
    assert.deepEqual(notified, [], 'template changes leave resource widgets untouched');
}
// Templates leave a separate hostname under the user's control.
assert.equal(resources.elements.hostname_set.checked, false, 'Virtualmin templates leave the hostname checkbox unticked');
assert.equal(resources.nodes['#vm_hostname_row'].hidden, true);
resources.elements.hostname_set.checked = true;
resources.elements.hostname.value = 'guest.example.test';
resources.elements.template.value = 'virtualmin-gpl';
resources.update({ target: { name: 'template' } });
assert.equal(resources.elements.hostname_set.checked, true, 'template changes preserve an explicit hostname choice');
assert.equal(resources.nodes['#vm_hostname_row'].hidden, false);
assert.equal(resources.elements.hostname.value, 'guest.example.test', 'template changes preserve the entered hostname');
// Plans still update each quantity and its multiplier together.
resources.elements.plan.value = 'small';
resources.update({ target: { name: 'plan' } });
assert.equal(resources.elements.cpus.value, '1');
assert.equal(Number(resources.elements.memory_mib.value) * Number(resources.elements.memory_mib_units.value), 512 * 1024 ** 2);
assert.equal(Number(resources.elements.disk_gib.value) * Number(resources.elements.disk_gib_units.value), 10 * 1024 ** 3);
assert.deepEqual(notified.sort(), Object.keys(allocation).sort());
// Switching plans uses readable units and retains sizes that need smaller units.
for (const [plan, memory, memoryUnit, disk, diskUnit] of [
    ['default', '2', 1024 ** 3, '20', 1024 ** 3],
    ['fractional', '1.5', 1024 ** 3, '1', 1024 ** 4],
    ['precise', '1025', 1024 ** 2, '1025', 1024 ** 3],
    ['small', '512', 1024 ** 2, '10', 1024 ** 3],
    ['default', '2', 1024 ** 3, '20', 1024 ** 3]
]) {
    resources.elements.plan.value = plan;
    resources.update({ target: { name: 'plan' } });
    assert.equal(resources.elements.memory_mib.value, memory, plan + ' memory');
    assert.equal(resources.elements.memory_mib_units.value, String(memoryUnit), plan + ' memory unit');
    assert.equal(resources.elements.disk_gib.value, disk, plan + ' disk');
    assert.equal(resources.elements.disk_gib_units.value, String(diskUnit), plan + ' disk unit');
}
// Summary chips use translated labels with the current form values.
const labels = { resources: '$1 CPU, $2 memory, $3 disk', network: '$1 ($2)', dhcp: 'DHCP', static: 'Static addresses',
    none: 'No extra software', setup: 'Packages and setup scripts', virtualmin: '$1 with $2',
    postgres: '$1 and PostgreSQL', gpl: 'Virtualmin GPL', pro: 'Virtualmin Pro', apache: 'Apache', nginx: 'Nginx' };
const summarized = fixture(options, 'cloud', 'cloud-a', { defaults: {}, labels });
// Render whole allocations in the same units as the size controls.
Object.assign(summarized.elements.cpus, { value: '2' });
Object.assign(summarized.elements.memory_mib, { value: '2' });
Object.assign(summarized.elements.memory_mib_units, { value: String(1024 ** 3) });
Object.assign(summarized.elements.disk_gib, { value: '20' });
Object.assign(summarized.elements.disk_gib_units, { value: String(1024 ** 3) });
summarized.update();
// chips(name) returns the named summary node from this fixture.
const chips = name => summarized.nodes['[data-vm-chip="' + name + '"]'];
assert.equal(chips('resources').textContent, '2 CPU, 2 GiB memory, 20 GiB disk');
assert.equal(chips('software').textContent, 'No extra software');
assert.equal(chips('image').hidden, true, 'an image option without text leaves the chip hidden');
// Manual size edits must appear in the summary without rounding to whole units.
summarized.elements.memory_mib.value = '1.5';
summarized.update();
assert.equal(chips('resources').textContent, '2 CPU, 1.5 GiB memory, 20 GiB disk');
// Show the selected Virtualmin edition, web server and optional PostgreSQL.
summarized.elements.software.value = 'virtualmin-pro';
summarized.elements.virtualmin_bundle.value = 'LEMP';
summarized.update();
assert.equal(chips('software').textContent, 'Virtualmin Pro with Nginx');
summarized.elements.virtualmin_postgres.value = '1';
summarized.update();
assert.equal(chips('software').textContent, 'Virtualmin Pro with Nginx and PostgreSQL');
// Leaving Virtualmin still reports any requested package setup.
summarized.elements.software.value = 'none';
summarized.elements.packages.value = 'tree';
summarized.update();
assert.equal(chips('software').textContent, 'Packages and setup scripts');
// ISO creation skips software setup regardless of the package list.
summarized.elements.install_source.value = 'iso';
summarized.update();
assert.equal(chips('software').textContent, 'No extra software');
console.log('VM creation source switching passed');

// Native history restores control values after pageshow, without change events.
const history = fixture(options, 'cloud', 'cloud-a', {
    defaults: { install_source: 'cloud', auth_type: 'password' },
    template: { entries: ['virtualmin-gpl', 'virtualmin-pro'].map(software =>
        ({ id: software, settings: { software } })) }
});
history.pageListeners.pageshow();
history.elements.template.value = 'virtualmin-pro';
history.elements.software.value = 'virtualmin-pro';
history.elements.cpus.value = '3';
history.elements.virtualmin_serial.value = 'fixture-serial';
history.elements.virtualmin_key.value = 'fixture-key';
history.timers.shift()();
assert.equal(history.nodes['[data-vm-license]'].hidden, false, 'restored Pro shows licenses');
assert.equal(history.elements.virtualmin_key.disabled, false, 'restored Pro enables licenses');
assert.equal(history.elements.virtualmin_key.value, 'fixture-key', 'refresh preserves entered credentials');
assert.equal(history.elements.cpus.value, '3', 'refresh preserves manual resource edits');
const boundChange = history.listeners.change;
vm.runInNewContext(fs.readFileSync('machine_create.js', 'utf8'), history.context);
assert.equal(history.listeners.change, boundChange, 'reloading the asset does not duplicate bindings');

// Cached navigation clones markup and ready flags, but drops native listeners.
const cached = fixture(options, 'cloud', 'cloud-a', {
    defaults: { install_source: 'cloud', auth_type: 'password' },
    template: { entries: ['virtualmin-gpl', 'virtualmin-pro'].map(software =>
        ({ id: software, settings: { software } })) }
});
cached.form.dataset.sourceReady = '1';
cached.elements.template.value = 'virtualmin-pro';
cached.elements.software.value = 'virtualmin-pro';
history.context.document.getElementById = () => cached.form;
history.themeListeners.afterReplace();
assert.equal(cached.nodes['[data-vm-license]'].hidden, false, 'cached Pro form initializes');
cached.elements.template.value = 'virtualmin-gpl';
cached.listeners['change.cloudminVmCreate']({ target: { name: 'template' } });
assert.equal(cached.nodes['[data-vm-license]'].hidden, true, 'cached form can switch to GPL');
assert.equal(cached.elements.virtualmin_key.disabled, true, 'GPL credentials stay out of submissions');
cached.elements.template.value = 'virtualmin-pro';
cached.listeners.change({ target: { name: 'template' } });
assert.equal(cached.nodes['[data-vm-license]'].hidden, false, 'cached form can switch back to Pro');
cached.elements.install_source.value = 'iso';
cached.listeners.change({ target: { name: 'install_source' } });
assert.equal(cached.elements.image.value, 'setup', 'cached form retains filtered ISO choices');
cached.elements.install_source.value = 'cloud';
cached.listeners.change({ target: { name: 'install_source' } });
assert.equal(cached.elements.image.value, 'cloud-a', 'cached form can return to cloud images');
console.log('VM creation history restoration passed');
