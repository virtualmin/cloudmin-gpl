// Exercise native-tab persistence without contacting a host or starting a guest.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('inventory-tabs.js', 'utf8');

// fixture(prefix) represents Authentic (att_) or Webmin (div_) panels.
function fixture(prefix) {
    const requests = [], observers = [], frames = [];
    let selected = 'images', marker, error, panels;
    // navigate() replaces the marker and panels as SPA navigation would.
    function navigate() {
        // A replaced page must no longer receive a pending request's warning.
        if (marker) marker.isConnected = error.isConnected = false;
        error = {hidden: true, isConnected: true};
        marker = {isConnected: true, dataset: {inventoryTabs: JSON.stringify({
            page: 'images', tabs: ['images', 'add', 'catalogue'],
            token: 'signed', url: '/server-manager/save_inventory_tab.cgi'
        })}};
        // getClientRects() gives only the selected panel a visible rectangle.
        panels = Object.fromEntries(['images', 'add', 'catalogue'].map(id =>
            [prefix + id, {getClientRects: () => selected === id ? [1] : []}]));
    }
    navigate();
    // Provide only the DOM operations used by the real client script.
    const context = vm.createContext({URLSearchParams, window: {},
        document: {documentElement: {},
            // querySelectorAll() supplies the current inventory marker.
            querySelectorAll: () => marker ? [marker] : [],
            // querySelector() supplies its save-error display.
            querySelector: () => error,
            // getElementById(id) resolves panels using the chosen theme prefix.
            getElementById: id => panels[id]},
        MutationObserver: class {
            // constructor(callback) retains the client's mutation observer.
            constructor(callback) { observers.push(callback); }
            // observe() is inert; switchTo() delivers the simulated mutations.
            observe() {}
        },
        // requestAnimationFrame(callback) queues a check for switchTo().
        requestAnimationFrame: callback => frames.push(callback),
        // fetch(url, options) leaves replies pending to expose ordering races.
        fetch(url, options) {
            return new Promise(resolve => requests.push({url, options, resolve}));
        }
    });
    vm.runInContext(source, context);
    // Expose browser events and replies without real timers or a host.
    return {requests, observers, context,
        // error getter returns the current page's warning node.
        get error() { return error; },
        // switchTo(id) changes visibility and coalesces theme notifications.
        switchTo(id) {
            selected = id;
            observers.forEach(callback => callback());
            observers.forEach(callback => callback());
            assert.equal(frames.length, 1);
            frames.shift()();
        },
        // navigate(id) supplies a new server-selected tab after SPA navigation.
        navigate(id) { selected = id; navigate(); context.window.cloudminInventoryTabs(); },
        // reply(index, [saved]) resolves a queued request; saved defaults to 1.
        // Drain promise callbacks so the next queued save is observable.
        async reply(index, saved = 1) {
            requests[index].resolve({ok: true, json: async () => ({saved})});
            await new Promise(resolve => setImmediate(resolve));
        }
    };
}

// main() checks both themes, request signing, rapid switches and SPA reuse.
async function main() {
    for (const prefix of ['att_', 'div_']) {
        // Initialization saves the tab through a signed same-origin POST.
        const test = fixture(prefix);
        assert.equal(test.requests.length, 1, 'initial selection is saved');
        const request = test.requests[0];
        assert.equal(request.options.method, 'POST');
        assert.equal(request.options.credentials, 'same-origin');
        assert.deepEqual(Object.fromEntries(request.options.body),
            {page: 'images', tab: 'images', token: 'signed'});
        // Rapid changes coalesce to the latest tab while a request is pending.
        test.switchTo('add');
        test.switchTo('catalogue');
        assert.equal(test.requests.length, 1, 'rapid saves do not run concurrently');
        await test.reply(0);
        assert.equal(test.requests.length, 2);
        assert.equal(test.requests[1].options.body.get('tab'), 'catalogue', 'last selection wins');
        await test.reply(1);
        // Unchanged or hidden panels must not generate additional writes.
        test.switchTo('catalogue');
        assert.equal(test.requests.length, 2, 'redraw does not save unchanged tabs');
        test.switchTo('hidden');
        assert.equal(test.requests.length, 2, 'hidden panels do not reset memory');
        // Save failures appear on the page and clear after a successful save.
        test.navigate('add');
        assert.equal(test.requests.length, 3, 'SPA navigation binds the new page');
        await test.reply(2, 0);
        assert.equal(test.error.hidden, false, 'save failure leaves a non-blocking explanation');
        test.switchTo('images');
        await test.reply(3);
        assert.equal(test.error.hidden, true, 'a later successful save clears the explanation');
        // Reloading the script must reuse its observer and tracked selection.
        vm.runInContext(source, test.context);
        assert.equal(test.observers.length, 1, 'reloaded script reuses its observer');
        assert.equal(test.requests.length, 4, 'script reload does not save unchanged selection');
        // An older POST must not overwrite the new choice after navigation.
        test.switchTo('catalogue');
        test.navigate('add');
        test.switchTo('images');
        assert.equal(test.requests.length, 5, 'new page waits for the previous page save');
        await test.reply(4);
        assert.equal(test.requests[5].options.body.get('tab'), 'images', 'newest page choice wins');
        await test.reply(5);
    }
    console.log('PASS: inventory tab persistence in both native tab layouts');
}
// Report asynchronous assertion failures as a failed test process.
main().catch(error => { console.error(error); process.exitCode = 1; });
