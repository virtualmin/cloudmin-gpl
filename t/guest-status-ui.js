// Exercise one shared browser channel, page replacement and transport failures.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../machine_status.js'), 'utf8');
const id = '11111111-2222-3333-4444-555555555555';

// harness([pageId]) supplies sockets, requests and page/visibility events.
function harness(pageId = id) {
    const timers = new Map(), listeners = new Map(), observers = [], requests = [], sockets = [], redirects = [];
    // location.reload() records ACL refreshes; replace() catches theme bypasses.
    const window = { location: { reload: () => redirects.push('reload'), replace: () => assert.fail('direct navigation bypasses the theme') }, addEventListener: (key, fn) => listeners.set(key, fn) };
    const document = { hidden: false, readyState: 'complete', body: {},
        getElementById: () => current,
        querySelector: selector => ({ '.vm-pending-state': current?.header.state,
            '[data-vm-header-pending]': current?.header.pending,
            '[data-vm-action-notice]': current?.notice })[selector],
        // Clicks must bubble from attached links to the navigation handlers.
        createElement: tag => {
            assert.equal(tag, 'a');
            return { click() { assert.equal(this.parent, current); redirects.push(this.href); },
                remove() { delete this.parent; } };
        },
        addEventListener: (key, fn) => listeners.set(key, fn) };
    // markup([reopen]) models status markup replaced by theme navigation.
    function markup(reopen = '') {
        // Model subtitle text and badge classes
        // independently of the status card.
        const caption = {}, badgeClasses = new Set();
        const header = { caption, badgeClasses, pending: { hidden: true }, state: {
            querySelector: () => caption,
            classList: { toggle: (name, enabled) => enabled ? badgeClasses.add(name) : badgeClasses.delete(name) }
        } };
        const fields = ['power', 'agent', 'ssh'].map(vmField => ({ dataset: { vmField }, textContent: '' }));
        const guestFields = ['os', 'hostname', 'kernel'].map(vmGuest => ({ dataset: { vmGuest }, textContent: '' }));
        const statusWarning = { hidden: true };
        // control([tagName]) models a primary group or a dropdown action.
        const control = (tagName = 'DIV') => ({ hidden: true, tagName,
            matches: selector => tagName !== 'DIV' && selector === '.ui_dropdown_item',
            contains: () => false, setAttribute(name, value) { this[name] = value; } });
        const start = control(), running = control(), paused = control();
        const active = control('A'), pause = control('BUTTON'), cycle = control('BUTTON');
        const menu = { open: false };
        const more = { hidden: true, querySelector: () => menu,
            querySelectorAll: () => [pause, active, cycle] };
        const classes = new Set(['ui_card', 'ui_card_warning']);
        const card = reopen === 'console' ? null : { classes, classList: {
            remove: (...names) => names.forEach(name => classes.delete(name)),
            add: name => classes.add(name) } };
        return { fields, guestFields, card, statusWarning, start, running, paused, active, pause, cycle, menu, more, header, isConnected: true,
            dataset: { config: JSON.stringify({ id: pageId, endpoint: '/status', unavailable: 'Unavailable', checking: 'Checking',
                usage: { unavailable: 'Unavailable', format: '$1% of $2', missing: '$1', rate: '$1/s' },
                units: ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'],
                labels: { index_state_running: 'Running', index_state_paused: 'Paused', index_state_unknown: 'Unknown', vm_agent_responding: 'Responding', vm_ssh_responding: 'Responding at $1 on port $2', vm_ssh_unavailable: 'Not responding on port $1' },
                reopen, url: '/connection' }) },
            contains: node => node.isOverviewAction, dispatchEvent: () => {},
            append: node => { node.parent = current; },
            querySelectorAll: selector => selector === '[data-vm-field]' ? fields :
                ({ '[data-vm-guest]': guestFields,
                    '[data-vm-resource], [data-vm-guest], [data-vm-disk]': guestFields,
                    '[data-vm-start]': [start], '[data-vm-running]': [running, pause],
                    '[data-vm-active]': [active], '[data-vm-paused]': [paused], '[data-vm-cycle]': [cycle] })[selector] || [],
            querySelector: selector => ({ '#cloudmin-ssh-status': card,
                '[data-vm-more]': more,
                '[data-vm-start]': start,
                '[data-vm-running]': running,
                '[data-vm-active]': active,
                '[data-vm-status-warning]': statusWarning })[selector] || null };
    }
    let current = markup();
    class Socket {
        // constructor(url) creates an unopened, explicitly driven transport.
        constructor(url) { this.url = url; this.readyState = 0; this.listeners = {}; this.sent = []; sockets.push(this); }
        // addEventListener(key, fn) retains each production transport callback.
        addEventListener(key, fn) { this.listeners[key] = fn; }
        // send(data) captures decoded subscription requests for assertions.
        send(data) { this.sent.push(JSON.parse(data)); }
        // open() completes the simulated handshake on demand.
        open() { this.readyState = 1; this.listeners.open(); }
        // reply(data) delivers one collector frame to the real renderer.
        reply(data) { this.listeners.message({ data: JSON.stringify(data) }); }
        // close() enters the production reconnect path without a network
        // socket.
        close() { this.readyState = 3; this.listeners.close(); }
    }
    const context = vm.createContext({ document, window, AbortController, Date, WebSocket: Socket,
        CustomEvent: class { constructor(type) { this.type = type; } },
        setTimeout: (fn, delay) => { const id = {}; timers.set(id, { fn, delay }); return id; },
        clearTimeout: id => timers.delete(id), setInterval: () => 1, clearInterval: () => {},
        MutationObserver: class { constructor(fn) { this.fn = fn; observers.push(this); } observe() {} disconnect() {} },
        fetch: (url, options) => new Promise((resolve, reject) => requests.push({ url, options, resolve, reject })) });
    // run() evaluates the client again while retaining its window state.
    const run = () => vm.runInContext(source, context);
    run();
    return { timers, listeners, requests, sockets, redirects, document, run,
        // current returns the markup presently attached to the simulated page.
        get current() { return current; },
        // replace([reopen]) triggers navigation to new status markup.
        replace(reopen = '') { current.isConnected = false; current = markup(reopen); observers.forEach(o => o.fn()); },
        // leave() simulates navigation away from Cloudmin.
        leave() { current.isConnected = false; current = undefined; observers.forEach(o => o.fn()); },
        // timer(delay) fires and removes the pending timer with this delay.
        timer(delay) { const [key, timer] = [...timers].find(([, timer]) => timer.delay === delay); timers.delete(key); timer.fn(); } };
}

// settle() drains asynchronous response parsing before checking the transport.
async function settle() { for (let i = 0; i < 8; i++) await Promise.resolve(); }
// status([ssh]) builds a complete snapshot with a selectable SSH health result.
const status = (ssh = 'responding') => ({ type: 'status', full: 1,
    changed: { [id]: { vm: { uuid: id, state: 'running', active: 1 }, health: {
        agent: 'responding', ssh, ssh_address: ssh === 'responding' ? '192.0.2.1' : undefined, terminal_available: true } } }, removed: [] });

// Check connection reuse, visible health changes, and reconnect cleanup.
(async () => {
    const t = harness();
    assert.equal(t.requests.length, 1, 'one setup request');
    t.requests[0].resolve({ ok: true, json: async () => ({ socket_url: 'wss://example/status' }) });
    await settle();
    const s = t.sockets[0]; s.open(); s.reply(status());
    // OS labels omit release codenames without changing other guest fields.
    for (const [reported, expected] of [
        ['Rocky Linux 10.2 (Red Quartz)', 'Rocky Linux 10.2'],
        ['Debian GNU/Linux 13 (trixie)', 'Debian GNU/Linux 13'],
        ['Ubuntu 26.04 LTS', 'Ubuntu 26.04 LTS'],
        [undefined, 'Unavailable']
    ]) {
        const frame = status();
        frame.changed[id].guest = { os: reported, hostname: 'guest (primary)', kernel: '6.12 (custom)' };
        s.reply(frame);
        assert.equal(t.current.guestFields[0].textContent, expected);
        assert.equal(t.current.guestFields[1].textContent, 'guest (primary)');
        assert.equal(t.current.guestFields[2].textContent, '6.12 (custom)');
    }
    s.reply(status());
    assert.equal(t.current.guestFields[0].textContent, 'Unavailable', 'missing guest data clears the previous OS');
    // State changes hide unavailable actions and close an open menu.
    assert.equal(t.current.pause.hidden, false, 'Pause is available while running');
    assert.equal(t.current.pause.disabled, false, 'visible Pause can submit');
    assert.equal(t.current.cycle.hidden, true, 'power cycle needs pending changes');
    t.current.menu.open = true;
    const savedPower = status(); savedPower.changed[id].vm.pending = { cpus: {} };
    s.reply(savedPower);
    assert.equal(t.current.cycle.hidden, false, 'saved changes enable power cycle');
    assert.equal(t.current.menu.open, false, 'changed actions close an open menu');
    const pausedPower = status(); pausedPower.changed[id].vm.state = 'paused';
    s.reply(pausedPower);
    assert.equal(t.current.paused.hidden, false, 'paused guests offer Resume');
    assert.equal(t.current.pause.disabled, true, 'paused guests cannot submit Pause again');
    assert.equal(t.current.pause['aria-disabled'], 'true', 'keyboard navigation skips hidden Pause');
    assert.equal(t.current.active.hidden, false, 'paused guests retain emergency actions');
    t.current.dataset.vmShutdownRequested = '1';
    s.reply(status());
    assert.equal(t.current.running.hidden, true, 'pending shutdown hides primary actions');
    assert.equal(t.current.pause.hidden, true, 'pending shutdown also hides Pause');
    const stoppedPower = status(); Object.assign(stoppedPower.changed[id].vm, { state: 'shutoff', active: 0 });
    s.reply(stoppedPower);
    assert.equal(t.current.more.hidden, true, 'empty secondary menu is hidden for a stopped operator guest');
    assert.equal(t.current.start.hidden, false, 'Start replaces the running controls');
    assert.equal(t.current.dataset.vmShutdownRequested, undefined, 'confirmed shutdown clears the pending request');
    s.reply(status());
    // Accepted requests clear only after this VM reaches the requested state.
    for (const [action, state, active] of [
        ['start', 'running', 1], ['resume', 'running', 1],
        ['shutdown', 'shutoff', 0], ['force_off', 'shutoff', 0], ['suspend', 'paused', 1]
    ]) {
        const notice = t.current.notice = { hidden: false,
            dataset: { vmActionNotice: action, vmActionId: id } };
        s.reply({ type: 'error' });
        assert.equal(notice.hidden, false, 'unknown status preserves the request notice');
        const confirmation = status();
        Object.assign(confirmation.changed[id].vm, { state, active });
        s.reply(confirmation);
        assert.equal(notice.hidden, true, action + ' notice clears on confirmation');
        s.reply({ type: 'error' });
        assert.equal(notice.hidden, true, 'completed notice stays cleared after disconnection');
    }
    const notice = t.current.notice = { hidden: false,
        dataset: { vmActionNotice: 'start', vmActionId: 'another-vm' } };
    s.reply(status());
    assert.equal(notice.hidden, false, 'another VM cannot clear the notice');
    notice.dataset.vmActionId = id;
    const paused = status(); paused.changed[id].vm.state = 'paused';
    s.reply(paused);
    assert.equal(notice.hidden, false, 'paused state does not confirm a start');
    notice.dataset.vmActionNotice = 'reboot';
    s.reply(status());
    assert.equal(notice.hidden, false, 'running alone cannot confirm a reboot');
    delete t.current.notice;
    assert.equal(t.current.fields[0].textContent, 'Running');
    assert.equal(t.current.header.caption.textContent, 'Running', 'header updates without a pending alert');
    assert.ok(t.current.header.badgeClasses.has('ui_badge_success'), 'running badge is green');
    // A paused VM retains its saved-change warning but loses running styling.
    const saved = status();
    saved.changed[id].vm.pending = { cpu_limit: { running: 2, saved: 3 } };
    saved.changed[id].vm.state = 'paused';
    s.reply(saved);
    assert.equal(t.current.header.caption.textContent, 'Paused');
    assert.ok(!t.current.header.badgeClasses.has('ui_badge_success'), 'paused badge loses its green color');
    assert.equal(t.current.header.pending.hidden, false, 'saved differences reveal the header warning');
    // Unknown state keeps the warning until a successful comparison clears it.
    s.reply({ type: 'error' });
    assert.equal(t.current.header.caption.textContent, 'Unknown', 'a lost channel clears stale power status');
    assert.equal(t.current.header.pending.hidden, false, 'unknown state preserves the pending warning');
    const applied = status(); applied.changed[id].vm.pending = {};
    s.reply(applied);
    assert.equal(t.current.header.pending.hidden, true, 'matching definitions clear the header warning');
    assert.equal(t.current.fields[2].textContent, 'Responding at 192.0.2.1 on port 22');
    // Both successful and failed probes name the saved nonstandard port.
    for (const state of ['responding', 'unavailable']) {
        const changedPort = status(state);
        changedPort.changed[id].health.ssh_port = 2222;
        s.reply(changedPort);
        assert.equal(t.current.fields[2].textContent, state === 'responding'
            ? 'Responding at 192.0.2.1 on port 2222' : 'Not responding on port 2222');
    }
    s.reply(status());
    assert.ok(t.current.card.classes.has('ui_card_success'), 'responding SSH has a green card');
    assert.equal(t.timers.size, 0, 'no polling timer after a status response');
    t.run();
    assert.equal(t.sockets.length, 1, 'cached theme script creates no extra socket');
    // Visibility changes pause messages without closing the shared transport.
    t.document.hidden = true; t.listeners.get('visibilitychange')();
    assert.equal(s.sent.at(-1).paused, true, 'hidden tab pauses subscription');
    assert.equal(s.readyState, 1, 'hidden tab retains the socket');
    t.document.hidden = false; t.listeners.get('visibilitychange')();
    assert.equal(s.sent.at(-1).paused, false, 'visible tab resumes the same subscription');
    // Missing, pending, and failed checks must remove a previous success state.
    s.reply(status('unavailable'));
    assert.ok(t.current.card.classes.has('ui_card_warning'), 'failed SSH check has an orange card');
    assert.ok(!t.current.card.classes.has('ui_card_success'), 'failed check removes the green accent');
    s.reply(status('inactive'));
    assert.ok(t.current.card.classes.has('ui_card_warning'), 'stopped guest has an orange card');
    for (const state of ['no_address', 'remote']) {
        s.reply(status(state));
        assert.ok(t.current.card.classes.has('ui_card_warning'), state + ' has an orange card');
    }
    const pending = status(); delete pending.changed[id].health;
    s.reply(pending);
    assert.equal(t.current.fields[2].textContent, 'Checking');
    assert.ok(t.current.card.classes.has('ui_card_warning'), 'pending probe has an orange card');
    const failed = status(); failed.changed[id].health.error = true;
    s.reply(failed);
    assert.equal(t.current.fields[2].textContent, 'Unavailable');
    assert.ok(t.current.card.classes.has('ui_card_warning'), 'probe error never leaves a green card');
    // Login guidance stays in the status field, but pending checks show no suffix.
    const message = 'The previous SSH connection did not complete. Check the settings and try again.';
    const suffix = '. ' + message;
    t.current.fields[2].dataset.vmMessage = message;
    for (const [record, value] of [
        [status('unavailable'), 'Not responding on port 22' + suffix],
        [status(), 'Responding at 192.0.2.1 on port 22' + suffix],
        [pending, 'Checking'],
        [status('unavailable'), 'Not responding on port 22' + suffix],
        [failed, 'Unavailable' + suffix],
        [{type: 'error'}, 'Unavailable' + suffix]
    ]) {
        s.reply(record);
        assert.equal(t.current.fields[2].textContent, value,
            'guidance is hidden while checking and restored when the check finishes');
    }
    // Replacing the page requests a snapshot on the existing connection.
    t.replace();
    assert.equal(t.sockets.length, 1, 'AJAX navigation reuses the socket');
    assert.equal(s.sent.at(-1).snapshot, true, 'replacement markup requests cached snapshot');
    s.reply(status());
    assert.equal(t.current.fields[0].textContent, 'Running');
    assert.ok(t.current.card.classes.has('ui_card_success'), 'AJAX navigation restores the green card');
    // A transport failure clears stale values and obtains a fresh route.
    const inactive = status();
    inactive.changed[id].vm = { uuid: id, state: 'shutoff', active: 0 };
    s.reply(inactive);
    assert.equal(t.current.start.hidden, false, 'a stopped guest offers Start');
    s.close();
    assert.equal(t.current.start.hidden, true, 'disconnect hides Start');
    assert.equal(t.current.running.hidden, true, 'disconnect hides Reboot and Shut down');
    assert.equal(t.current.active.hidden, true, 'disconnect hides Force power off');
    assert.ok(t.current.fields.every(f => f.textContent === 'Unavailable'), 'disconnect clears stale success');
    assert.ok(t.current.card.classes.has('ui_card_warning'), 'disconnect marks SSH status unknown');
    t.timer(1000); await settle();
    assert.equal(t.requests.length, 2, 'reconnect obtains fresh authenticated route');
    t.requests[1].resolve({ ok: true, json: async () => ({ socket_url: 'wss://example/status' }) });
    await settle();
    const next = t.sockets[1]; next.open(); next.reply(status());
    // Full navigation closes the socket; browser history can restore it.
    t.listeners.get('pagehide')();
    assert.equal(next.readyState, 3, 'full navigation releases the socket');
    t.listeners.get('pageshow')(); await settle();
    assert.equal(t.requests.length, 3, 'back/forward cache restores the subscription');
    t.requests[2].resolve({ ok: true, json: async () => ({ socket_url: 'wss://example/status' }) });
    await settle();
    const restored = t.sockets[2]; restored.open();
    // Waiting connection pages reopen once their guest becomes available.
    t.replace('console'); restored.reply(status());
    assert.equal(t.current.fields[0].textContent, 'Running', 'console still updates its power signal');
    t.replace('terminal'); restored.reply(status());
    assert.deepEqual(t.redirects, ['/connection'], 'waiting page reopens when available');
    // The editor waits for power-off, not guest health or a missing record.
    t.replace('edit_machine');
    for (const state of ['running', 'shutdown', 'paused', 'crashed', 'unknown']) {
        const update = status();
        update.changed[id].vm = { uuid: id, state, active: 1 };
        restored.reply(update);
    }
    restored.reply({ type: 'error' });
    restored.reply({ type: 'status', full: 1, changed: {}, removed: [id] });
    assert.equal(t.redirects.length, 1, 'unconfirmed shutdown never opens the editor');
    const stopped = { type: 'status', full: 1, changed: {
        [id]: { vm: { uuid: id, state: 'shutoff', active: 0 } }
    }, removed: [] };
    restored.reply(stopped);
    restored.reply(stopped);
    assert.equal(t.redirects.length, 2, 'confirmed shutdown reloads once without a health probe');
    t.replace(); restored.reply(stopped);
    assert.equal(t.redirects.length, 2, 'ordinary detail pages never reload after shutdown');
    assert.equal(t.current.start.hidden, false, 'shutdown reveals Start on the details page');
    assert.equal(t.current.running.hidden, true, 'shutdown hides running controls');
    assert.equal(t.current.active.hidden, true, 'shutdown hides emergency power-off');
    restored.reply(status());
    assert.equal(t.current.start.hidden, true, 'starting hides the details link');
    assert.equal(t.current.running.hidden, false, 'running guests offer Reboot and Shut down');
    for (const state of ['paused', 'shutdown', 'crashed', 'unknown']) {
        const update = status(); update.changed[id].vm.state = state;
        restored.reply(update);
        assert.equal(t.current.running.hidden, true, state + ' hides running controls');
        assert.equal(t.current.active.hidden, false, state + ' with an active domain keeps emergency power-off');
    }
    t.current.dataset.vmShutdownRequested = '1';
    restored.reply(status());
    assert.equal(t.current.running.hidden, true, 'a pending shutdown cannot be repeated');
    assert.equal(t.current.active.hidden, false, 'pending shutdown keeps emergency power-off');
    restored.reply(stopped);
    assert.equal(t.current.dataset.vmShutdownRequested, undefined, 'shutdown completion clears pending feedback');
    restored.reply(status());
    assert.equal(t.current.running.hidden, false, 'a later start restores running controls');
    restored.reply(stopped);
    restored.reply({ type: 'error' });
    assert.equal(t.current.start.hidden, true, 'unknown status hides Start');
    restored.reply(stopped);
    restored.reply({ type: 'status', full: 1, changed: {}, removed: [id] });
    assert.equal(t.current.start.hidden, true, 'removing the guest hides Start');
    assert.equal(t.current.active.hidden, true, 'removing the guest hides emergency power-off');
    t.leave(); t.timer(1000);
    assert.equal(restored.readyState, 3, 'leaving Cloudmin closes only the status connection');
    assert.equal(t.timers.size, 0, 'leaving cancels reconnect timers');

    // A capture guard must stop delegated theme handlers as well as native submit.
    const overview = harness('overview');
    const toggle = { checked: true, defaultChecked: false };
    const form = { isOverviewAction: true, elements: { id: { value: id }, enabled: { value: '1' } },
        querySelector: () => toggle };
    // submit([target]) captures both native cancellation and theme propagation.
    function submit(target = form) {
        const event = { target, prevented: false, stopped: false,
            preventDefault() { this.prevented = true; },
            stopImmediatePropagation() { this.stopped = true; } };
        overview.listeners.get('submit')(event);
        return event;
    }
    assert.equal(overview.current.statusWarning.hidden, true, 'normal startup has no warning flash');
    const blocked = submit();
    assert.ok(blocked.prevented && blocked.stopped, 'pending status blocks native and theme submissions');
    assert.equal(overview.current.statusWarning.hidden, false, 'blocked action explains why it did not run');
    assert.equal(toggle.checked, false, 'blocked toggle restores the rendered boot policy');
    assert.equal(form.elements.enabled.value, '0', 'blocked toggle restores the submitted value too');
    assert.equal(submit({}).stopped, false, 'unrelated forms remain usable');
    overview.requests[0].resolve({ ok: true, json: async () => ({ socket_url: 'wss://example/status' }) });
    await settle();
    const live = overview.sockets[0]; live.open();
    const snapshot = status(); snapshot.changed[id].vm.autostart = true;
    live.reply(snapshot);
    assert.equal(overview.current.dataset.statusConnected, '1', 'overview accepts a live snapshot');
    assert.equal(overview.current.statusWarning.hidden, true, 'fresh status clears the warning');
    const allowed = submit();
    assert.ok(!allowed.prevented && !allowed.stopped, 'healthy status allows actions through to the theme');
    live.reply({ type: 'error' });
    assert.equal(overview.current.statusWarning.hidden, false, 'collector errors explain paused controls');
    toggle.checked = false;
    form.elements.enabled.value = '0';
    assert.ok(submit().stopped, 'collector errors block actions even on an open socket');
    assert.equal(toggle.checked, true, 'blocked toggle restores the latest policy, not stale initial HTML');
    assert.equal(form.elements.enabled.value, '1');
    live.reply(snapshot);
    assert.equal(overview.current.statusWarning.hidden, true, 'collector recovery clears the warning');
    live.close();
    assert.equal(overview.current.statusWarning.hidden, false, 'transport loss explains paused controls');
    overview.timer(1000); await settle();
    overview.requests[1].resolve({ ok: true, json: async () => ({ socket_url: 'wss://example/status' }) });
    await settle();
    const reconnected = overview.sockets[1]; reconnected.open();
    assert.equal(overview.current.statusWarning.hidden, false, 'socket opening alone does not restore confidence');
    reconnected.reply(snapshot);
    assert.equal(overview.current.statusWarning.hidden, true, 'reconnected snapshot clears the warning');
    // Hidden pages must discard stale permission controls before becoming visible.
    overview.document.hidden = true;
    reconnected.reply({ type: 'access_changed' });
    assert.equal(overview.redirects.at(-1), 'reload', 'permission changes refresh controls even on hidden pages');
    console.log('PASS: snapshots, warnings, action guards, one channel, visibility, AJAX reuse, reconnect, ACL refresh and cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
