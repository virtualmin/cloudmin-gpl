// Exercise template access and package choices without host configuration changes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// fixture(auth, inherited, [readonly]) models a template's access section.
function fixture(auth, inherited, readonly = false) {
    const listeners = {};
    const row = { hidden: false, hasAttribute: () => readonly };
    const form = { dataset: { defaultAuth: inherited },
        elements: { auth_type: { value: auth }, ssh_keys: { value: 'saved key', disabled: readonly } },
        querySelector: () => row,
        addEventListener: (event, handler) => { listeners[event] = handler; } };
    const context = { window: { jQuery: () => ({ on: (event, handler) => { listeners.theme = handler; } }) },
        document: { readyState: 'complete', querySelectorAll: () => [form] } };
    vm.runInNewContext(fs.readFileSync('machine_template.js', 'utf8'), context);
    return { form, row, listeners, context };
}

// Password-only access hides keys on initial display and on both event paths.
const f = fixture('password', 'keys');
assert.equal(f.row.hidden, true);
assert.equal(f.form.elements.ssh_keys.disabled, true);
for (const auth of ['keys', 'both', 'password', '']) {
    f.form.elements.auth_type.value = auth;
    f.listeners.change();
    assert.equal(f.row.hidden, auth === 'password');
    assert.equal(f.form.elements.ssh_keys.disabled, auth === 'password');
    f.listeners.theme();
    assert.equal(f.row.hidden, auth === 'password');
    assert.equal(f.form.elements.ssh_keys.value, 'saved key');
}
// Inheritance follows Default Template, including its password-only setting.
const inherited = fixture('', 'password');
assert.equal(inherited.row.hidden, true);
// Changing visibility must not grant write access to a read-only viewer.
const readonly = fixture('keys', 'password', true);
assert.equal(readonly.row.hidden, false);
assert.equal(readonly.form.elements.ssh_keys.disabled, true);
readonly.form.elements.auth_type.value = 'both';
readonly.listeners.theme();
assert.equal(readonly.form.elements.ssh_keys.disabled, true);
// Reinitialization must leave one set of event handlers on the form.
const update = f.listeners.change;
f.context.window.cloudminTemplateAccessInit();
assert.equal(f.listeners.change, update);
console.log('Template authentication visibility passed');

// packageFixture(mode, [readonly]) runs the software controls on a template form.
function packageFixture(mode, readonly = false) {
    const listeners = {};
    const panel = { hidden: false };
    const group = { querySelector: () => panel, hasAttribute: () => readonly };
    const form = { dataset: {}, elements: {
        software: { value: 'virtualmin-gpl' }, packages_mode: { value: mode },
        packages: { value: 'curl jq', disabled: readonly }
    }, querySelectorAll: selector => selector === '[data-vm-packages]' ? [group] : [],
        addEventListener: (event, handler) => { listeners[event] = handler; } };
    const context = { window: { jQuery: () => ({ on: (event, handler) => { listeners.theme = handler; } }) },
        document: { readyState: 'complete', querySelectorAll: () => [{ form }] } };
    vm.runInNewContext(fs.readFileSync('machine_software.js', 'utf8'), context);
    return { form, panel, listeners, context };
}

// Native and theme changes show only the selected custom package list.
for (const initial of ['inherit', 'none', 'list']) {
    const packages = packageFixture(initial);
    assert.equal(packages.panel.hidden, initial !== 'list');
    assert.equal(packages.form.elements.packages.disabled, initial !== 'list');
    for (const mode of ['list', 'none', 'inherit', 'list']) {
        packages.form.elements.packages_mode.value = mode;
        for (const handler of [packages.listeners.change, packages.listeners.theme]) {
            handler();
            assert.equal(packages.panel.hidden, mode !== 'list');
            assert.equal(packages.form.elements.packages.disabled, mode !== 'list');
            assert.equal(packages.form.elements.packages.value, 'curl jq');
        }
    }
    // Reopening an initialized form must not duplicate its event handlers.
    const update = packages.listeners.change;
    packages.context.window.cloudminSoftwareInit();
    assert.equal(packages.listeners.change, update);
}
// Showing a package list never enables edits in read-only mode.
const lockedPackages = packageFixture('list', true);
assert.equal(lockedPackages.panel.hidden, false);
assert.equal(lockedPackages.form.elements.packages.disabled, true);
lockedPackages.listeners.theme();
assert.equal(lockedPackages.form.elements.packages.disabled, true);
console.log('Template package choices passed');
// Hiding Virtualmin must not leave package inheritance controls uninitialized.
const plain = packageFixture('none');
delete plain.form.elements.software;
// Simulate a fresh form without the selector, then change the package mode.
delete plain.form.dataset.softwareReady;
plain.context.window.cloudminSoftwareInit();
plain.form.elements.packages_mode.value = 'list';
plain.listeners.change();
assert.equal(plain.form.elements.packages.disabled, false);
assert.equal(plain.panel.hidden, false);
