// Test SSH check failures and browser Back without changing the host.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const listeners = {}, windowListeners = {}, requests = [], panels = [];
let respond, reject;

class Form {
    // constructor([action]) models the shared SSH destination and form token.
    constructor(action = 'backup_sched.cgi') {
        this.action = action;
        this.isConnected = true;
        this.valid = true;
        this.forwarded = 0;
        this.elements = Object.fromEntries(Object.entries({
            token: 'signed-token', attempt: 'a'.repeat(32), dest0_mode: 'ssh',
            dest0_ssh_host: '', dest0_ssh_port_def: '1'
        }).map(([name, value]) => [name, {value}]));
    }
    // getAttribute(name) returns the original submission endpoint.
    getAttribute(name) { return this[name]; }
    // reportValidity() supplies the browser's validation result.
    reportValidity() { return this.valid; }
    // querySelector() returns an attached fingerprint confirmation panel.
    querySelector() { return this.panel?.removed ? null : this.panel; }
    // append(panel) retains the fingerprint confirmation for assertions.
    append(panel) { this.panel = panel; }
    // requestSubmit([submitter]) models resubmission through the same listener.
    requestSubmit(submitter) {
        const event = submitEvent(this, submitter);
        listeners.submit(event);
        // Only a submit that passes preflight reaches the form handler.
        if (!event.prevented) { this.forwarded++; this.submitter = submitter; }
    }
}

// submitEvent(form, [submitter]) records whether preflight intercepts a submit.
function submitEvent(form, submitter = {name: 'save'}) {
    // preventDefault() records interception.
    // stopImmediatePropagation() is inert with only one listener installed.
    return {target: form, submitter, preventDefault() { this.prevented = true; }, stopImmediatePropagation() {}};
}

// Supply only the DOM and network operations used by the host-key listener.
const context = {
    HTMLFormElement: Form, URL, URLSearchParams, AbortSignal,
    FormData: class extends Map {
        // constructor(form) snapshots fields for destination comparisons.
        constructor(form) { super(Object.entries(form.elements).map(([name, field]) => [name, field.value])); }
    },
    // addEventListener(name, callback) retains the browser history listener.
    window: {addEventListener: (name, callback) => windowListeners[name] = callback},
    document: {
        baseURI: 'https://fixture/server-manager/backup_form.cgi',
        // addEventListener(name, callback) retains the submit listener.
        addEventListener: (name, callback) => listeners[name] = callback,
        // querySelectorAll() exposes attached panels for browser Back cleanup.
        querySelectorAll: () => panels.filter(panel => !panel.removed),
        // createElement() supplies an approval panel and stable buttons.
        createElement: () => {
            const buttons = {};
            // setAttribute() and scrollIntoView() ignore presentation.
            const panel = {dataset: {}, setAttribute() {}, scrollIntoView() {},
                // remove() marks the panel detached for later assertions.
                remove() { this.removed = true; },
                // querySelector(name) returns a stable mock button.
                querySelector(name) { return buttons[name] ||= {}; }};
            panels.push(panel);
            return panel;
        }
    },
    // fetch(url, options) records fields and lets tests decide reply timing.
    fetch: (url, options) => {
        requests.push(new URLSearchParams(options.body));
        return new Promise((resolve, fail) => {
            // respond(data, [ok]) supplies a JSON response.
            // reject(error) simulates a network failure.
            // json() returns the supplied body without a connection.
            respond = (data, ok = true) => resolve({ok, json: async () => data});
            reject = fail;
        });
    }
};
// Run the real script against the fixture, with no browser or server process.
vm.runInNewContext(fs.readFileSync('backup-host-key.js', 'utf8'), context);

(async () => {
    // Local and cloud destinations in either edition bypass the SSH listener.
    for (const action of ['backup.cgi', 'backup_sched.cgi', 'restore.cgi']) {
        const prefix = action === 'restore.cgi' ? 'src' : 'dest0';
        for (const mode of ['local', 's3', 'gcs', 'azure', 'bb', 'dropbox', 'drive']) {
            const form = new Form(action);
            form.elements[prefix+'_mode'] = {value: mode};
            const event = submitEvent(form), count = requests.length;
            await listeners.submit(event);
            assert.ok(!event.prevented, action+' submits '+mode+' directly');
            assert.equal(requests.length, count, 'no provider preflight request');
            assert.ok(!form.panel, 'no inline status or validation panel');
        }
    }
    // Failed probes must submit to each form's server handler.
    for (const action of ['backup.cgi', 'backup_sched.cgi', 'restore.cgi']) {
        const form = new Form(action), button = {name: 'save'};
        // Restore reads source fields; other forms read destination fields.
        if (action === 'restore.cgi') {
            form.elements.src_mode = {value: 'ssh'};
            form.elements.src_ssh_host = {value: ''};
        }
        // Pending checks must show no status panel or start duplicate requests.
        const pending = listeners.submit(submitEvent(form, button));
        assert.ok(!form.panel, 'SSH probe has no inline checking message');
        const count = requests.length;
        await listeners.submit(submitEvent(form, button));
        assert.equal(requests.length, count, 'duplicate clicks cannot start another probe');
        // Failed probes preserve the action and reach normal validation.
        respond({error: 'Enter a valid SSH server and port'});
        await pending;
        assert.equal(form.forwarded, 1, action+' forwards validation to error()');
        assert.equal(form.submitter, button, 'original action button is preserved');
        assert.ok(!form.panel, 'SSH failure has no inline error panel');

        // Back preserves the signed token and attempt ID so the form can retry.
        windowListeners.pageshow();
        form.elements.dest0_ssh_host.value = 'backup.example';
        // Correct the restore source as well as the backup destination.
        if (action === 'restore.cgi') form.elements.src_ssh_host.value = 'backup.example';
        const retry = listeners.submit(submitEvent(form, button));
        respond({status: 'trusted'});
        await retry;
        assert.equal(form.forwarded, 2, 'corrected form can be submitted again');
        assert.equal(form.elements.token.value, 'signed-token');
        assert.equal(form.elements.attempt.value, 'a'.repeat(32));
    }
    // Saved archives send their ID and pass through on a trusted response.
    const saved = new Form('restore.cgi');
    saved.elements.backup = {value: 'b'.repeat(32)};
    const inspect = listeners.submit(submitEvent(saved));
    assert.equal(requests.at(-1).get('backup'), saved.elements.backup.value);
    assert.ok(!saved.panel, 'saved archive lookup has no inline checking message');
    respond({status: 'trusted'});
    await inspect;
    assert.equal(saved.forwarded, 1);
    // Network errors also submit to the server for validation.
    const form = new Form();
    const lost = listeners.submit(submitEvent(form));
    reject(new Error('Connection lost'));
    await lost;
    assert.equal(form.forwarded, 1);

    // Unknown hosts still require explicit approval; cancellation saves nothing.
    const unknown = listeners.submit(submitEvent(form));
    respond({status: 'unknown', html: '<confirmation>', previous: 'old', proposed: 'new'});
    await unknown;
    assert.equal(form.forwarded, 1);
    form.panel.querySelector('[data-backup-host-cancel]').onclick();
    assert.ok(form.panel.removed);
    // A replacement approval sends both digests and forwards errors to the CGI.
    const changed = listeners.submit(submitEvent(form));
    respond({status: 'changed', html: '<confirmation>', previous: 'old', proposed: 'new'});
    await changed;
    const trust = form.panel.querySelector('[data-backup-host-trust]');
    const approval = trust.onclick({currentTarget: trust});
    assert.equal(requests.at(-1).get('action'), 'trust');
    assert.equal(requests.at(-1).get('proposed'), 'new');
    respond({error: 'SSH host key changed again'});
    await approval;
    assert.equal(form.forwarded, 2, 'approval failure reaches server trust validation');

    // Returning while a probe is pending discards its stale response.
    const stale = listeners.submit(submitEvent(form));
    const oldResponse = respond;
    windowListeners.pageshow();
    const fresh = listeners.submit(submitEvent(form));
    oldResponse({status: 'trusted'});
    await stale;
    assert.equal(form.forwarded, 2, 'stale response cannot submit after Back');
    respond({status: 'trusted'});
    await fresh;
    assert.equal(form.forwarded, 3);
    // Leaving the page without returning also discards the pending response.
    const abandoned = listeners.submit(submitEvent(form));
    form.isConnected = false;
    respond({status: 'trusted'});
    await abandoned;
    assert.equal(form.forwarded, 3, 'navigation discards late replies');
    console.log('PASS: all GPL/Pro destinations, backup/schedule/restore error forwarding, Back, tokens, SSH approval and stale replies');
})().catch(error => { console.error(error); process.exitCode = 1; });
