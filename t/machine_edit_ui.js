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
        elements[name] = {name, value: String(value), dataset: {}, addEventListener() {}};
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
    const window = {jQuery: target => ({on: (name, fn) => { if (target === form) jquery[name] = fn; }})};
    const document = {readyState: 'complete', getElementById: id => id === 'vm-edit-form' ? form : null};
    const context = vm.createContext({window, document});
    vm.runInContext(source, context);
    return {elements, window, handlers,
        // change(name, value, [synthetic]) uses native events unless requested.
        change(name, value, synthetic = false) {
            elements[name].value = value;
            // Theme unit widgets can emit jQuery-only changes.
            if (synthetic) Object.values(jquery).forEach(fn => fn({}));
            // Typing in a normal field invokes the native input listeners.
            else handlers.input.forEach(fn => fn());
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
// Deferred initialization must not multiply input listeners.
const count = f.handlers.input.length;
f.window.cloudminVmEditInit();
assert.equal(f.handlers.input.length, count, 'SPA initialization does not duplicate listeners');
console.log('VM editor resource range checks passed');
