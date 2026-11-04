'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const handlers = [];
const context = vm.createContext({
    window: {},
    // addEventListener(name, callback) collects the delegated click handler.
    document: {readyState: 'loading', addEventListener(name, callback) {
        assert.equal(name, 'click'); handlers.push(callback);
    }},
    // Event.constructor(type, options) records event type and bubbling.
    Event: class {constructor(type, options) { this.type = type; this.bubbles = options.bubbles; }}
});
const source = fs.readFileSync(require('node:path').join(__dirname, '../ssh-keys.js'), 'utf8');
vm.runInContext(source, context);
// fixture(value) creates a form that may arrive after the script has loaded.
function fixture(value) {
    const input = {value, disabled: false, changes: 0,
        // matches(selector) exposes the textarea lock state.
        matches(selector) { assert.equal(selector, ':disabled'); return this.disabled; },
        // dispatchEvent(event) checks and counts the change notification.
        dispatchEvent(event) {
            assert.equal(event.type, 'change'); assert.equal(event.bubbles, true); this.changes++;
        }};
    // querySelector(selector) resolves only this fixture's textarea.
    const box = {querySelector(selector) { assert.equal(selector, 'textarea[name="ssh_keys"]'); return input; }};
    const entry = {value: 'ssh-rsa BBB second', disabled: false,
        // getAttribute(name) supplies the selected entry public key.
        getAttribute(name) { assert.equal(name, 'data-ssh-key-insert'); return this.value; },
        // closest(selector) binds the entry to its own field wrapper.
        closest(selector) { assert.equal(selector, '[data-ssh-key-input]'); return box; },
        // matches(selector) exposes disabled native and custom entries.
        matches(selector) { assert.equal(selector, ':disabled, [aria-disabled="true"]'); return this.disabled; }};
    return {input, entry};
}
// click(entry) bubbles a click from an entry's label or icon to the document.
function click(entry) {
    // target.closest(selector) returns the entry, or null for unrelated clicks.
    for (const handler of handlers) handler({target: {closest(selector) {
        assert.equal(selector, '[data-ssh-key-insert]'); return entry;
    }}});
}
// A form inserted after script loading receives one key and one change event.
const first = fixture('ssh-ed25519 AAA first');
click(first.entry);
assert.equal(first.input.value, 'ssh-ed25519 AAA first\nssh-rsa BBB second');
assert.equal(first.input.changes, 1);
// A different comment on the same key must not duplicate its identity.
first.entry.value = 'ssh-ed25519 AAA renamed';
click(first.entry);
assert.equal(first.input.value.split('\n').length, 2);
assert.equal(first.input.changes, 1);
// Replacement forms need no script reload or theme-specific initialization.
const replacement = fixture('');
click(replacement.entry);
assert.equal(replacement.input.value, 'ssh-rsa BBB second');
assert.equal(replacement.input.changes, 1);
assert.equal(first.input.changes, 1, 'the old form is untouched');
// Re-evaluating the asset must not accumulate listeners on later navigation.
vm.runInContext(source, context);
assert.equal(handlers.length, 1);
replacement.entry.value = 'ssh-ed25519 CCC third';
click(replacement.entry);
assert.equal(replacement.input.changes, 2);
// Unrelated clicks, disabled menus and locked fields cannot change the input.
click(null);
replacement.entry.value = 'ssh-rsa DDD fourth';
replacement.input.disabled = true;
click(replacement.entry);
replacement.input.disabled = false;
replacement.entry.disabled = true;
click(replacement.entry);
assert.equal(replacement.input.changes, 2);
assert.equal(replacement.input.value, 'ssh-rsa BBB second\nssh-ed25519 CCC third');
console.log('Saved-key insertion, replaced forms, repeated loading and disabled controls passed');
