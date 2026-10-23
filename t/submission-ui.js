// Exercise submission lifecycle without a browser profile or host changes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const listeners = {}, windowListeners = {}, jqueryListeners = {}, storage = new Map(), requests = [];
let accept, reject, forwarded = 0;
class Form {
    // constructor([path], [operation]) models the creation form by default.
    constructor(path = 'setup_machine.cgi', operation = 'create') {
        this.destination = 'https://fixture/server-manager/' + path;
        this.action = { value: operation }; // Named controls shadow form.action.
        this.method = 'post'; this.isConnected = true;
        this.elements = { token: { value: 'signed-token' }, action: { value: operation }, install_type: { value: 'local' } };
        // A visible type=button control can be paired with a hidden submit.
        // setProperty(name, value, priority) records the footer's forced
        // hiding.
        this.footer = { hidden: false,
            style: { setProperty(name, value, priority) { this[name] = value; this.priority = priority; } } };
        // control(type, proxy) gives real and proxy buttons the same footer.
        const control = (type, proxy) => ({ type, disabled: false, hidden: false,
            classList: { contains: name => proxy && name === 'ui_form_end_submit' },
            closest: selector => selector === '.ui_form_end_buttons' ? this.footer : null,
            // setProperty(name, value, priority) models the standalone
            // fallback.
            style: { setProperty(name, value, priority) { this[name] = value; this.priority = priority; } } });
        this.button = control('submit', false);
        this.proxy = control('button', true);
        this.ordinary = control('button', false);
        this.elements[Symbol.iterator] = () => [this.button, this.proxy, this.ordinary][Symbol.iterator]();
        // Streaming forms leave the native action URL visible to the theme.
        if (['setup_machine.cgi', 'clone_machine.cgi', 'image_machine.cgi'].includes(path)) {
            this.elements.vm_operation = this.elements.action;
            delete this.elements.action;
            this.action = this.destination;
        }
        this.valid = true;
    }
    // getAttribute(name) exposes the URL despite the named action control.
    getAttribute(name) { return name === 'action' ? this.destination : null; }
    // reportValidity() supplies the fixture's browser validation result.
    reportValidity() { return this.valid; }
    // querySelector() returns the error element created by the handler.
    querySelector() { return this.error; }
    // append(input) registers a generated hidden control for the next submit.
    append(input) { this.elements[input.name] = input; }
    // prepend(error) retains the inline error for assertions.
    prepend(error) { this.error = error; }
    // requestSubmit(submitter) dispatches a second event like the browser does.
    requestSubmit(submitter) {
        // Record the one-dispatch override before submission.js clears it.
        this.forwardedNative = this.cloudminNativeSubmit;
        const event = submitEvent(this, submitter);
        listeners.submit(event);
        // Count only submissions allowed through the handshake's forward guard.
        if (!event.prevented) forwarded++;
    }
}
// submitEvent(form, [submitter]) keeps the original button when resubmitting.
function submitEvent(form, submitter = {}) {
    return { target: form, submitter, preventDefault() { this.prevented = true; }, stopImmediatePropagation() {} };
}
// Capture browser events and let each test resolve its pending network reply.
const context = {
    HTMLFormElement: Form, URL, URLSearchParams, Uint8Array, AbortSignal, crypto: webcrypto,
    location: { href: 'https://fixture/' },
    sessionStorage: { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value) },
    window: { addEventListener: (name, fn) => windowListeners[name] = fn,
        jQuery: () => ({ on: (name, fn) => jqueryListeners[name] = fn }) },
    document: { baseURI: 'https://fixture/server-manager/machine_form.cgi',
        addEventListener: (name, fn) => listeners[name] = fn,
        // getElementById() exercises the plain alert fallback without a
        // template.
        getElementById: () => null,
        // createElement() supplies inert alert methods for DOM-free assertions.
        createElement: () => ({ dataset: {}, setAttribute() {}, querySelector() {}, scrollIntoView() {} })
    },
    fetch: async (url, options) => {
        requests.push(new URLSearchParams(options.body));
        return new Promise((resolve, fail) => { accept = data => resolve({ ok: true, json: async () => data }); reject = fail; });
    }
};
vm.runInNewContext(fs.readFileSync('submission.js', 'utf8'), context);
// tick() lets fetch and response continuations settle.
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
    // Browser validation happens before any attempt ID is requested.
    const form = new Form();
    form.valid = false;
    await listeners.submit(submitEvent(form));
    assert.equal(requests.length, 0, 'invalid form never requests an attempt');
    // Suppress duplicate clicks throughout both the check and actual submit.
    form.valid = true;
    const submission = listeners.submit(submitEvent(form));
    await tick();
    assert.equal(requests[0].get('attempt'), '');
    assert.match(requests[0].get('proposed'), /^[a-f0-9]{32}$/);
    await listeners.submit(submitEvent(form));
    assert.equal(requests.length, 1, 'double-click during handshake is suppressed');
    accept({ attempt: 'a'.repeat(32) });
    await submission;
    assert.equal(forwarded, 1);
    assert.equal(form.elements.attempt.value, 'a'.repeat(32));
    assert.equal(form.elements.token.value, 'signed-token', 'security token remains unchanged');
    await listeners.submit(submitEvent(form));
    assert.equal(requests.length, 1, 'double-click during submission is suppressed');
    // Returning through history starts a check against the preceding attempt.
    windowListeners.pageshow();
    const retry = listeners.submit(submitEvent(form));
    await tick();
    assert.equal(requests[1].get('attempt'), 'a'.repeat(32), 'Back retains the preceding attempt');
    accept({ attempt: 'b'.repeat(32) });
    await retry;
    assert.equal(forwarded, 2, 'safe retry forwards a fresh attempt');
    // Theme navigation replaces the form; session storage preserves its chain.
    const restored = new Form();
    const lost = listeners.submit(submitEvent(restored));
    await tick();
    assert.equal(requests[2].get('attempt'), 'b'.repeat(32), 'SPA replacement restores attempt from session storage');
    reject(new Error('Connection lost'));
    await lost;
    assert.equal(forwarded, 2, 'lost handshake never submits blindly');
    assert.equal(restored.button.hidden, false, 'temporary errors leave retry available');
    // A failed check leaves the previous ID intact and displays server
    // guidance.
    const recovered = listeners.submit(submitEvent(restored));
    await tick();
    assert.equal(requests[3].get('attempt'), 'b'.repeat(32), 'lost reply retains the preceding ID');
    accept({ error: 'Previous attempt needs recovery' });
    await recovered;
    assert.equal(restored.error.textContent, 'Previous attempt needs recovery');
    assert.equal(forwarded, 2);
    // A late reply cannot submit a form removed during navigation.
    const abandoned = listeners.submit(submitEvent(restored));
    await tick(); restored.isConnected = false;
    accept({ attempt: 'c'.repeat(32) }); await abandoned;
    assert.equal(forwarded, 2, 'leaving the page during the check cannot submit');
    // Upload failures release the guard but still require another server check.
    const image = new Form('setup_image.cgi', '');
    const upload = listeners.submit(submitEvent(image));
    await tick();
    accept({ image_attempts: JSON.stringify({ '': 'd'.repeat(32) }) }); await upload;
    assert.equal(forwarded, 3);
    context.window.cloudminSubmissionFinished(image);
    const uploadRetry = listeners.submit(submitEvent(image));
    await tick();
    assert.equal(requests.at(-1).get('image_attempts'), image.elements.image_attempts.value);
    accept({ image_attempts: JSON.stringify({ '': 'e'.repeat(32) }) }); await uploadRetry;
    assert.equal(forwarded, 4, 'upload failure unlocks the form for a checked retry');
    // Only the form's own theme request may release its pending-submit guard.
    const completed = jqueryListeners['ajaxComplete.cloudminSubmission'];
    const count = requests.length;
    completed(null, null, { type: 'POST', url: 'machine_status.cgi' });
    await listeners.submit(submitEvent(image));
    assert.equal(requests.length, count, 'background AJAX cannot unlock a submitted form');
    completed(null, null, { type: 'POST', url: 'setup_image.cgi' });
    const ajaxRetry = listeners.submit(submitEvent(image));
    await tick();
    assert.equal(requests.length, count + 1, 'completed theme submission unlocks its form');
    // License denial must forward to the native form without an inline error.
    accept({ image_attempts: JSON.stringify({ '': 'e'.repeat(32) }), native_submit: 1 }); await ajaxRetry;
    assert.equal(forwarded, 5);
    assert.equal(image.forwardedNative, true, 'license refusal reaches the native submit handler');
    assert.equal(image.cloudminNativeSubmit, undefined, 'later submissions do not retain the native override');
    assert.equal(image.error, undefined, 'license refusal does not create an inline error');
    // Cloning uses the same guarded submission and retry handshake.
    const clone = new Form('clone_machine.cgi', 'clone');
    const cloning = listeners.submit(submitEvent(clone));
    await tick();
    assert.equal(requests.at(-1).get('operation'), 'clone');
    accept({ attempt: 'f'.repeat(32) }); await cloning;
    assert.equal(forwarded, 6);
    // Pro image capture uses the same attempt check and preserves the CSRF token.
    const capture = new Form('image_machine.cgi', 'capture_image');
    const capturing = listeners.submit(submitEvent(capture));
    await tick();
    assert.equal(requests.at(-1).get('operation'), 'capture_image');
    accept({ attempt: '1'.repeat(32) }); await capturing;
    assert.equal(forwarded, 7);
    assert.equal(capture.elements.token.value, 'signed-token');
    // Failed software setup hides Create and rejects keyboard/history retries.
    const created = new Form();
    const denied = listeners.submit(submitEvent(created));
    await tick();
    accept({ error: 'The virtual machine was created.', retryable: 0 });
    await denied;
    assert.equal(created.error.textContent, 'The virtual machine was created.');
    assert.equal(created.error.hidden, false);
    assert.equal(created.button.disabled, true);
    assert.equal(created.proxy.disabled, true);
    assert.equal(created.footer.hidden, true, 'the whole submit footer is hidden');
    assert.equal(created.footer.style.display, 'none');
    assert.equal(created.footer.style.priority, 'important', 'theme styles cannot leave footer spacing');
    assert.equal(created.ordinary.hidden, false, 'ordinary form controls are retained');
    const checks = requests.length;
    windowListeners.pageshow();
    const keyboard = submitEvent(created);
    await listeners.submit(keyboard);
    assert.equal(keyboard.prevented, true);
    assert.equal(requests.length, checks, 'history cannot unlock completed creation');
    assert.equal(forwarded, 7, 'blocked form cannot submit through the keyboard');
    console.log('PASS: validation, double-clicks, Back, SPA restoration, lost replies, recovery, navigation, upload retries and AJAX guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
