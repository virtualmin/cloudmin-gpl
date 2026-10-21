// Exercise status refreshes, lost sessions, and theme navigation without a host.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../jobs.js'), 'utf8');

// view() provides just the status region, keeping its replacement count observable.
function view() {
    const content = { hidden: false, writes: 0,
        set innerHTML(value) { this.html = value; this.writes++; } };
    const warning = { hidden: true };
    return { isConnected: true, dataset: { url: '/jobs.cgi?refresh=1' }, content, warning,
        querySelector: selector => selector === '[data-jobs-content]' ? content : warning };
}

// run() verifies the production client with controlled network replies and timers.
async function run() {
    let current = view();
    const requests = [], timers = new Map(), events = {}, observers = [];
    const document = { hidden: false, readyState: 'complete', documentElement: {},
        getElementById: () => current,
        addEventListener: (name, callback) => { events[name] = callback; } };
    const window = { addEventListener: (name, callback) => { events[name] = callback; } };
    const context = vm.createContext({ document, window, AbortController,
        setTimeout: (callback, delay) => { const id = {}; timers.set(id, { callback, delay }); return id; },
        clearTimeout: id => timers.delete(id),
        MutationObserver: class {
            constructor(callback) { observers.push(callback); }
            observe() {}
        },
        fetch: (url, options) => new Promise((resolve, reject) => requests.push({ url, options, resolve, reject }))
    });
    // settled() lets both fetch and response.json promises complete.
    const settled = () => new Promise(resolve => setImmediate(resolve));
    // reply(request, html, revision) supplies a server-rendered snapshot.
    const reply = async (request, html, revision) => {
        request.resolve({ ok: true, json: async () => ({ html, revision }) });
        await settled();
    };
    // tick() runs the sole scheduled refresh after removing its timer.
    const tick = () => {
        assert.equal(timers.size, 1);
        const [id, timer] = [...timers][0];
        timers.delete(id);
        timer.callback();
        return timer.delay;
    };
    vm.runInContext(source, context);
    assert.equal(requests.length, 1);
    vm.runInContext(source, context);
    assert.equal(requests.length, 1, 're-executing the script must not duplicate requests');
    assert.equal(observers.length, 1);
    assert.equal(requests[0].options.cache, 'no-store');
    await reply(requests[0], 'Empty state', 'empty');
    assert.equal(current.content.html, 'Empty state');
    assert.equal(tick(), 2000);
    await reply(requests[1], 'Download 25%', 'quarter');
    assert.equal(current.content.html, 'Download 25%');
    tick();
    await reply(requests[2], 'Different attribute order', 'quarter');
    assert.equal(current.content.writes, 2, 'unchanged jobs keep their existing DOM');
    tick();
    requests[3].resolve({ ok: true, json: async () => { throw new Error('Login page'); } });
    await settled();
    assert.equal(current.warning.hidden, false);
    assert.equal(current.content.hidden, true, 'failed polling must not look like fresh status');
    assert.equal(tick(), 4000);
    await reply(requests[4], 'Download 75%', 'three-quarters');
    assert.equal(current.content.hidden, false);
    assert.equal(current.warning.hidden, true);
    tick();
    const previous = current;
    previous.isConnected = false;
    current = view();
    observers[0]();
    assert.equal(requests[5].options.signal.aborted, true);
    await reply(requests[5], 'Late old reply', 'old');
    assert.equal(current.content.writes, 0, 'old navigation cannot overwrite a new view');
    await reply(requests[6], 'New view', 'new');
    assert.equal(current.content.html, 'New view');
    document.hidden = true;
    events.visibilitychange();
    assert.equal(timers.size, 0, 'background tabs stop polling');
    document.hidden = false;
    events.visibilitychange();
    await reply(requests[7], 'Empty again', 'finished');
    assert.equal(current.content.html, 'Empty again');
    tick();
    current.isConnected = false;
    current = null;
    observers[0]();
    assert.equal(requests[8].options.signal.aborted, true);
    await reply(requests[8], 'Late detached reply', 'detached');
    assert.equal(timers.size, 0, 'leaving the jobs page stops all work');
    console.log('Jobs live progress, empty transitions, failures and navigation: PASS');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
