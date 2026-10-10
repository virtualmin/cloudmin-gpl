// Exercise automatic submission and login recovery without opening SSH sockets.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('terminal-connect.js', 'utf8');

// fixture(mode, [results]) supplies page controls and queued server replies.
// mode is auto, attempt or unrelated; replies default to an empty queue.
function fixture(mode, results = []) {
    const timers = new Map();
    let sequence = 0;
    let submissions = 0;
    let redirects = 0;
    let requests = 0;
    const observers = new Set();
    // addEventListener(...args)/removeEventListener(...args) leave cleanup
    // to the test; browser event names and handlers are unused here.
    const window = { addEventListener() {}, removeEventListener() {} };
    let marker, attempt;
    // markup(mode) replaces page nodes without evaluating the client again.
    function markup(mode) {
        // Existing requests must see the previous page's nodes as detached.
        if (marker) marker.isConnected = false;
        if (attempt) attempt.isConnected = false;
        // remove() consumes the auto trigger without simulating a full DOM.
        marker = mode === 'auto' ? {
            isConnected: true, remove() { this.isConnected = false; }
        } : null;
        // click() records navigation through the attempt's recovery link.
        attempt = mode === 'attempt' ? {
            isConnected: true, dataset: { statusUrl: '/outcome' }, click() { redirects++; }
        } : null;
    }
    markup(mode);
    // Supply only the browser APIs the connection client uses.
    const context = vm.createContext({ window, AbortController,
        MutationObserver: class {
            // constructor(callback) retains the page rebinding handler.
            constructor(callback) { this.callback = callback; }
            // observe() enables fixture-driven mutation notifications.
            observe() { observers.add(this.callback); }
            // disconnect() stops notifications after client cleanup.
            disconnect() { observers.delete(this.callback); }
        },
        document: {
            documentElement: {},
            // getElementById(id) exposes the current auto or attempt node.
            getElementById: id => id === 'cloudmin-ssh-auto' ? marker : attempt,
            // querySelector(selector) supplies only the Connect button.
            // Its click() method counts submissions without navigating.
            querySelector: () => ({ click() { submissions++; } })
        },
        // setTimeout(fn, [delay]) queues callbacks for step(); delay is unused.
        setTimeout(fn) { timers.set(++sequence, fn); return sequence; },
        // clearTimeout(id) lets navigation cancel scheduled work.
        clearTimeout(id) { timers.delete(id); },
        // fetch(url, options) checks request options and returns a queued reply.
        async fetch(url, options) {
            requests++;
            assert.equal(url, '/outcome');
            assert.equal(options.credentials, 'same-origin');
            const next = results.shift();
            // An Error fixture simulates a temporary request failure.
            if (next instanceof Error) throw next;
            // json() resolves the queued body as a successful browser response.
            return { ok: true, json: async () => next };
        }
    });
    // Evaluate once; navigation must reuse the installed observer.
    vm.runInContext(source, context);
    // marker/attempt getters expose the current page's nodes.
    return { window, get marker() { return marker; }, get attempt() { return attempt; }, timers,
        // navigate(mode) replaces controls and notifies all active observers.
        navigate(mode) { markup(mode); observers.forEach(callback => callback()); },
        // mutate() notifies observers without changing the page identity.
        mutate() { observers.forEach(callback => callback()); },
        // counts() reports only observable submissions, redirects and checks.
        counts: () => ({ submissions, redirects, requests }),
        // step() runs the next scheduled action and its promise callbacks.
        async step() {
            const [id, fn] = timers.entries().next().value;
            timers.delete(id);
            await fn();
            await new Promise(resolve => setImmediate(resolve));
        }
    };
}

// main() checks success, failure, stale pages and transient network failures.
async function main() {
    // Automatic entry submits once, including after returning to the SSH page.
    let test = fixture('auto');
    await test.step();
    assert.equal(test.counts().submissions, 1, 'auto uses the ordinary form once');
    assert.equal(test.marker.isConnected, false, 'automatic trigger is consumed');
    test.navigate('unrelated');
    test.navigate('auto');
    await test.step();
    assert.equal(test.counts().submissions, 2, 'returning to SSH submits without reloading its script');
    test.mutate();
    assert.equal(test.timers.size, 0, 'unrelated DOM updates cannot resubmit the same form');
    // Navigation cancels work even before the first scheduled callback runs.
    test.navigate('attempt');
    test.navigate('unrelated');
    assert.equal(test.timers.size, 0, 'navigation cancels an old attempt before it polls');
    test = fixture('auto');
    test.marker.isConnected = false;
    await test.step();
    assert.equal(test.counts().submissions, 0, 'late script cannot submit another page');
    // Successful and superseded attempts stop checking and keep the page open.
    for (const state of ['connected', 'gone']) {
        test = fixture('attempt', [{state: 'pending'}, {state}]);
        await test.step();
        await test.step();
        assert.equal(test.counts().redirects, 0, 'success and replaced attempts keep the current page');
        assert.equal(test.timers.size, 0, 'completed attempts stop polling');
    }
    // Failed login returns to settings without starting another relay.
    test = fixture('attempt', [{state: 'pending'}, {state: 'failed'}]);
    await test.step();
    await test.step();
    assert.equal(test.counts().redirects, 1, 'failed SSH returns to the settings link');
    assert.equal(test.counts().submissions, 0, 'failure never retries automatically');
    // A dropped outcome request retries the check without restarting SSH.
    test = fixture('attempt', [new Error('offline'), {state: 'connected'}]);
    await test.step();
    await test.step();
    assert.equal(test.counts().requests, 2, 'temporary network failure retries only the outcome check');
    // A stale failure cannot redirect away from a replacement page.
    test = fixture('attempt', [{state: 'failed'}]);
    test.attempt.isConnected = false;
    await test.step();
    assert.equal(test.counts().redirects, 0, 'old terminal cannot navigate a replacement page');
    // Explicit teardown removes both pending requests and navigation observers.
    test = fixture('attempt', [{state: 'pending'}]);
    await test.step();
    test.window.cloudminSshConnectCleanup();
    assert.equal(test.timers.size, 0, 'page cleanup cancels pending checks');
    test.navigate('auto');
    assert.equal(test.timers.size, 0, 'cleanup also removes the shared navigation observer');
    console.log('SSH automatic connection and recovery checks passed');
}
// Report asynchronous assertion failures through the test process exit status.
main().catch(error => { console.error(error); process.exitCode = 1; });
