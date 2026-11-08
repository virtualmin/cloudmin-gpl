// Exercise bridge recovery polling without opening a network connection.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// fixture([countdown], [themed]) models polling and theme page navigation.
// Defaults omit the countdown and supply a theme page loader.
function fixture(countdown = false, themed = true) {
    const timers = new Map(),
        requests = [],
        listeners = {},
        navigations = [];
    let nextTimer = 0,
        marker,
        tab = 'bridges';
    const counter = {textContent: ''};
    marker = {
        dataset: {
            state: countdown ? 'confirm' : 'rolling_back',
            remaining: '30'
        },
        // querySelector(selector) returns the optional confirmation counter.
        querySelector: () => (countdown ? counter : null)
    };
    const page = {
        isConnected: true,
        dataset: {
            url: '/prefix/server-manager/networks.cgi?status=1&selected=br0'
        },
        // querySelector(selector) exposes the recovery marker on this page.
        querySelector: selector =>
            selector === '#cloudmin-network-pending' ? marker : null,
        // querySelectorAll(selector) returns the selected tab.
        // getClientRects() marks that tab as visible.
        querySelectorAll: () => [
            {dataset: {networkTab: tab}, getClientRects: () => [1]}
        ],
        // innerHTML(value) rejects insertion that skips theme initialization.
        set innerHTML(value) {
            assert.fail('Do not insert uninitialized page fragments');
        }
    };
    const document = {
        hidden: false,
        readyState: 'complete',
        documentElement: {},
        // getElementById(id) supplies the fixture's only networking page.
        getElementById: () => page,
        // addEventListener(name, callback) saves handlers for visibility tests.
        addEventListener: (name, callback) => {
            listeners[name] = callback;
        }
    };
    const context = {
        document,
        window: {
            // addEventListener(name, callback) ignores unused window events.
            addEventListener() {},
            location: {
                href: 'https://host/prefix/server-manager/networks.cgi?tab=bridges&xnavigation=1',
                // replace(url) records navigation without loading a page.
                replace(url) {
                    navigations.push({url});
                }
            }
        },
        AbortController,
        URL,
        // Themes expose a page loader that records navigation and
        // its completion.
        ...(themed
            ? {
                  theme: {
                      api: {
                          page: {
                              // load(url, options) settles when the test
                              // resolves the navigation.
                              load(url, options) {
                                  return new Promise((resolve, reject) =>
                                      navigations.push({
                                          url,
                                          ...options,
                                          resolve,
                                          reject
                                      })
                                  );
                              }
                          }
                      }
                  }
              }
            : {}),
        // now() freezes the clock for repeatable countdown checks.
        performance: {now: () => 1000},
        // observe(target, options) does nothing; tests detach pages directly.
        MutationObserver: class {
            observe() {}
        },
        // setTimeout(callback, delay) queues work for explicit test ticks.
        setTimeout(callback) {
            timers.set(++nextTimer, callback);
            return nextTimer;
        },
        // clearTimeout(id) removes cancelled polls and fetch timeouts.
        clearTimeout(id) {
            timers.delete(id);
        },
        // fetch(url, options) queues a request for reply() to complete.
        fetch(url, options) {
            return new Promise(resolve =>
                requests.push({url, options, resolve})
            );
        }
    };
    vm.runInNewContext(fs.readFileSync('networks.js', 'utf8'), context);
    return {
        requests,
        navigations,
        page,
        counter,
        document,
        listeners,
        timers,
        // reply(result) delivers one server response and drains its callbacks.
        async reply(result) {
            // json() supplies the response body without opening a connection.
            requests.at(-1).resolve({ok: true, json: async () => result});
            await new Promise(resolve => setImmediate(resolve));
        },
        // tick() runs the next scheduled poll without waiting a real second.
        tick() {
            const [id, callback] = timers.entries().next().value;
            timers.delete(id);
            callback();
        },
        // selectTab(value) simulates switching tabs while a response
        // is pending.
        selectTab(value) {
            tab = value;
        }
    };
}

// main() checks themed navigation, completion, late responses and
// paused polling.
async function main() {
    // Any changed state must load a themed GET and retire the old polling loop.
    for (const state of ['rolled_back', 'rollback_failed', 'confirm', '']) {
        const test = fixture();
        assert.equal(
            test.requests.length,
            1,
            'recovery polls without a countdown element'
        );
        assert.match(
            test.requests[0].url,
            /networks.cgi\?status=1&selected=br0$/
        );
        assert.equal(test.requests[0].options.credentials, 'same-origin');
        await test.reply({state: 'rolling_back', remaining: -60});
        test.tick();
        assert.equal(
            test.requests.length,
            2,
            'running recovery continues polling'
        );
        await test.reply({state});
        const navigation = test.navigations[0];
        assert.equal(
            navigation.url,
            'https://host/prefix/server-manager/networks.cgi?selected=br0&tab=bridges'
        );
        assert.equal(
            navigation.method,
            'GET',
            'state changes never repeat a previous POST'
        );
        assert.equal(
            navigation.history,
            false,
            'automatic refresh adds no history entry'
        );
        assert.equal(
            test.timers.size,
            0,
            'polling waits for the theme navigation'
        );
        // Resolve navigation only after detaching the page that initiated it.
        test.page.isConnected = false;
        navigation.resolve();
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(
            test.requests.length,
            2,
            'the old page stops polling after replacement'
        );
        assert.equal(
            test.timers.size,
            0,
            'the detached page schedules no new work'
        );
    }
    // A failed theme navigation keeps recovery polling available for
    // another try.
    const retry = fixture();
    await retry.reply({state: 'rolled_back'});
    retry.navigations[0].reject(new Error('Connection interrupted'));
    await new Promise(resolve => setImmediate(resolve));
    retry.tick();
    assert.equal(
        retry.requests.length,
        2,
        'failed navigation retries through status polling'
    );

    // Default themes use a safe GET with the current tab and web prefix intact.
    const plain = fixture(false, false);
    plain.selectTab('interfaces');
    await plain.reply({state: 'rolled_back'});
    assert.equal(
        plain.navigations.length,
        0,
        'a tab change discards the older response'
    );
    plain.tick();
    await plain.reply({state: 'rolled_back'});
    assert.equal(
        plain.navigations[0].url,
        'https://host/prefix/server-manager/networks.cgi?selected=br0&tab=interfaces'
    );
    assert.equal(
        plain.timers.size,
        0,
        'document navigation stops the old polling loop'
    );

    // Responses received after leaving the networking page cannot
    // navigate back.
    const stale = fixture();
    stale.page.isConnected = false;
    await stale.reply({state: 'rolled_back'});
    assert.equal(
        stale.navigations.length,
        0,
        'a detached page ignores its late response'
    );

    // Confirmation keeps its countdown while ordinary recovery has no counter.
    const test = fixture(true);
    assert.equal(
        test.counter.textContent,
        '30',
        'confirmation still shows its countdown'
    );
    await test.reply({state: 'confirm', remaining: 20});
    test.tick();
    assert.equal(
        test.counter.textContent,
        '20',
        'confirmation countdown follows server time'
    );
    // Hiding the document aborts its request and suppresses subsequent polls.
    test.document.hidden = true;
    test.listeners.visibilitychange();
    assert.equal(
        test.requests.at(-1).options.signal.aborted,
        true,
        'hidden pages abort polling'
    );
    assert.equal(
        test.timers.size,
        1,
        'only the pending fetch timeout remains until it settles'
    );
    await test.reply({state: 'confirm', remaining: 15});
    assert.equal(
        test.timers.size,
        0,
        'a hidden page does not schedule another poll'
    );
    console.log(
        'PASS: recovery polling, themed GET navigation, retries, countdown and visibility'
    );
}
// catch(error) prints the failed assertion and sets a failing exit status.
main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
