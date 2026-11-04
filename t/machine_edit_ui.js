// Exercise resource ranges using the production editor script.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../machine_edit.js'), 'utf8');
// fixture() models native inputs and synthetic change events.
function fixture() {
    const elements = {}, handlers = {}, jquery = {};
    const saved = {cpus: 2, cpu_limit: 4, memory_mib: 1024, memory_limit_mib: 1536};
    for (const [name, value] of Object.entries({...saved, memory_mib_units: 1048576, memory_limit_mib_units: 1048576})) {
        elements[name] = {name, value: String(value), dataset: {}, handlers: {},
            // addEventListener(event, fn) captures field listeners for replay.
            addEventListener(event, fn) { (this.handlers[event] ||= []).push(fn); }};
    }
    for (const name of ['cpus', 'cpu_limit', 'memory_mib', 'memory_limit_mib']) {
        elements[name].dataset = {vmMin: name.startsWith('memory') ? 256*1048576 : 1,
            vmMax: name.startsWith('memory') ? 8192*1048576 : 8};
    }
    // Retain listeners so ordinary and synthetic
    // changes can be fired separately.
    const form = {dataset: {}, elements, querySelector: selector => elements[selector.match(/name="([^"]+)"/)[1]],
        querySelectorAll: () => Object.values(elements).filter(input => input.dataset.vmMax),
        addEventListener: (name, fn) => (handlers[name] ||= []).push(fn)};
    // jQuery(target) returns on(name, fn), which stores synthetic listeners
    // separately from native events for the chosen field or editor.
    const window = {jQuery: target => ({on: (name, fn) => {
        (jquery[target.name || 'form'] ||= {})[name] = fn;
    }})};
    const document = {readyState: 'complete', getElementById: id => id === 'vm-edit-form' ? form : null};
    const context = vm.createContext({window, document});
    vm.runInContext(source, context);
    return {elements, window, handlers,
        // change(name, value, [synthetic], [event]) replays native or theme edits.
        // synthetic defaults to false; event defaults to change for units,
        // otherwise input, as when typing into a value field.
        change(name, value, synthetic = false, event = name.endsWith('_units') ? 'change' : 'input') {
            elements[name].value = value;
            // Theme unit widgets can emit jQuery-only changes.
            if (synthetic) {
                for (const target of [name, 'form']) {
                    for (const [events, fn] of Object.entries(jquery[target] || {})) {
                        // Allow jQuery namespaces when matching event types.
                        if (events.split(' ').some(type => type.startsWith(event + '.'))) {
                            fn({type: event});
                        }
                    }
                }
            }
            // Native events reach the field first, then its editor.
            else {
                (elements[name].handlers[event] || []).forEach(fn => fn());
                (handlers[event] || []).forEach(fn => fn());
            }
        }};
}
const f = fixture();
// Allocation ranges track edited maximums and unit conversions.
assert.equal(f.elements.cpus.max, 4, 'CPU range starts at the saved maximum');
assert.equal(f.elements.memory_mib.max, 1536, 'memory range starts at the saved maximum');
f.change('cpu_limit', '6');
assert.equal(f.elements.cpus.max, 6, 'CPU range follows the chosen maximum');
f.change('memory_limit_mib_units', '1073741824', true);
f.change('memory_limit_mib', '2');
assert.equal(f.elements.memory_mib.max, 2048, 'allocation range follows chosen maximum and units');
f.change('cpu_limit', '16');
assert.equal(f.elements.cpus.max, 8, 'CPU range respects the host limit');
f.change('memory_limit_mib', '16');
assert.equal(f.elements.memory_mib.max, 8192, 'memory range respects the host limit');
// Unit changes update both memory spinners without altering CPU steps.
assert.equal(f.elements.cpus.step, 1);
for (const name of ['memory_mib', 'memory_limit_mib']) {
    for (const [units, step, value] of [[1048576, 128, '1024'], [1024, 131072, '1048576'],
        [1073741824, 0.1, '1'], [1099511627776, 0.1, '1']]) {
        f.change(name, value);
        f.change(name + '_units', String(units), true);
        assert.equal(f.elements[name].step, step, name + ' uses the selected unit step');
    }
    // Typing preserves the caret; committing MiB rounds to a whole value.
    f.change(name + '_units', '1048576');
    f.change(name, '1152.6');
    assert.equal(f.elements[name].value, '1152.6', 'typing does not replace the input');
    assert.equal(f.elements[name].min, 257, 'fractional MiB is off the whole-MiB step grid');
    f.change(name, '1152.6', true, 'change');
    assert.equal(Number(f.elements[name].value), 1153, 'theme changes commit whole MiB');
    f.change(name, '1000', true);
    assert.equal(f.elements[name].min, 360, 'theme input revalidates arbitrary whole MiB');
    f.change(name, '2000', false, 'change');
    assert.equal(Number(f.elements[name].value), 2000, 'native changes retain whole MiB');
    f.change(name, '');
    assert.equal(f.elements[name].value, '', 'empty edits remain empty');
    // Changing units must not leave fractional MiB in the input.
    f.change(name + '_units', '1073741824');
    f.change(name, '1152.6');
    f.change(name + '_units', '1048576', true);
    assert.equal(Number(f.elements[name].value), 1153, 'unit changes round whole MiB');
    // Manual GiB fractions remain valid while spinners still use tenths.
    f.change(name + '_units', '1073741824');
    f.change(name, '1.25');
    assert.equal(f.elements[name].min, 0.25, 'quarter GiB stays on a valid step grid');
    f.change(name, '1');
    assert.equal(f.elements[name].min, 0.3, 'whole GiB steps through tenths, not .05 offsets');
}
// Deferred initialization must not multiply input listeners.
const count = f.handlers.input.length;
f.window.cloudminVmEditInit();
assert.equal(f.handlers.input.length, count, 'SPA initialization does not duplicate listeners');
console.log('VM editor resource range checks passed');
