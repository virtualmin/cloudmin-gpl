// Exercise serial startup, redraw and input with real xterm in Chromium.
// Only the transport is simulated; no guest or workstation settings change.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const webmin = process.env.WEBMIN_ROOT || resolve(root, '../webmin');
const dir = mkdtempSync(join(tmpdir(), 'cloudmin-serial-browser-'));
const html = join(dir, 'serial.html');
// The fixture loads the actual client as a classic script without its export.
const client = readFileSync(join(root, 'serial-console.js'), 'utf8')
    .replace('export function connect(', 'function connectSerial(');
// asset(path) copies a file beside the fixture and returns its file URL.
// Confined browsers may see this directory but not the installed Webmin files.
const asset = path => {
    const target = join(dir, basename(path));
    copyFileSync(path, target);
    return pathToFileURL(target).href;
};
writeFileSync(html, `<!doctype html><meta charset="utf-8">
<link rel="stylesheet" href="${asset(join(webmin, 'unauthenticated/css/ui-lib.css'))}">
<link rel="stylesheet" href="${asset(join(webmin, 'xterm/xterm.css'))}">
<style>${readFileSync(join(root, 'console.css'), 'utf8')}</style>
<style>body { font: 15px system-ui; margin: 20px; } #host { height: 600px; display: flex; flex-direction: column; }
#cloudmin-console { flex: 1; min-height: 0; } #cloudmin-console [data-console-screen] { flex: 1; height: auto; min-height: 0; }</style>
<script src="${asset(join(webmin, 'xterm/xterm.js'))}"></script>
<script src="${asset(join(webmin, 'xterm/xterm-addon-fit.js'))}"></script>
<div id="header"></div><div id="host"></div>
<script>
window.sent = [];
// Retain the real xterm object so assertions can read its rendered buffer.
const RealTerminal = window.Terminal;
window.Terminal = class extends RealTerminal {
    // constructor(options) exposes the real xterm instance to assertions.
    constructor(options) { super(options); window.term = this; }
};
// fetch() returns a mock serial endpoint without contacting a server.
window.fetch = async () => ({ok: true, json: async () => ({socket_url: 'ws://fixture/serial'})});
window.WebSocket = class extends EventTarget {
    static OPEN = 1;
    // constructor() opens asynchronously, as a real WebSocket would.
    constructor() {
        super(); window.socket = this; this.readyState = 0;
        setTimeout(() => {
            this.readyState = 1; this.dispatchEvent(new Event('open'));
            // Fragment both the length prefix and replay at arbitrary boundaries.
            const history = new TextEncoder().encode(window.replay || '');
            const prefix = new Uint8Array(4);
            new DataView(prefix.buffer).setUint32(0, history.length);
            for (const byte of prefix) this.reply([byte]);
            for (let n = 0; n < history.length; n += 3) this.reply(history.subarray(n, n + 3));
        });
    }
    // send(bytes) records exactly what the client would send to the serial port.
    send(bytes) { window.sent.push(Array.from(bytes)); }
    // close() reports that the mock WebSocket has closed.
    close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
    // reply(bytes) delivers guest output as the binary frames used by the relay.
    reply(bytes) { this.dispatchEvent(new MessageEvent('message', {data: new Uint8Array(bytes).buffer})); }
};
${client}
// openSerial([savedSize], [defaultSize], [replay]) starts a fresh serial view.
// The default font size is 14 and the default replay is empty.
window.openSerial = async (savedSize, defaultSize = 14, replay = '') => {
    // Let the previous page's removal observer dispose its renderer first.
    document.getElementById('host').replaceChildren();
    await new Promise(resolve => setTimeout(resolve));
    window.sent = [];
    window.replay = replay;
    const header = document.getElementById('header');
    header.innerHTML = '<span class="ui_page" data-terminal-status><span class="ui_badge ui_badge_success"><span>Connected</span></span></span>';
    const container = document.createElement('div');
    container.id = 'cloudmin-console'; container.dataset.consoleMode = 'serial';
    // Test the default size when no saved preference is supplied.
    if (savedSize !== undefined) container.dataset.consoleFontSize = savedSize;
    // Record font changes without saving preferences.
    window.fontChanges = [];
    container.addEventListener('cloudmin-serial-font-size-changed', event => fontChanges.push(event.detail));
    container.innerHTML = '<div data-console-screen></div>';
    const status = document.createElement('span');
    status.className = 'ui_page';
    status.innerHTML = '<span class="ui_badge ui_badge_info"><span>Connecting</span></span>';
    header.append(status);
    document.getElementById('host').append(container);
    // The screen must already be black before xterm supplies palette variables.
    window.initialSerialBackground = getComputedStyle(container.firstChild).backgroundColor;
    // Load the actual xterm assets with a fixed palette and mocked transport.
    const config = {id: 'fixture', endpoint: '/connect', token: 'fixture',
        connected: 'Connected', failed: 'Failed', disconnected: 'Disconnected',
        xterm: {path: ${JSON.stringify(pathToFileURL(dir).href)}, version: 'fixture',
            conf: {theme: 'dark', fontsize: defaultSize}, options: {theme: {background: '#000', foreground: '#fff'}}}};
    // Model the theme's header placement for the disconnect control.
    const disconnect = document.createElement('button');
    disconnect.dataset.consoleAction = 'disconnect';
    disconnect.disabled = true;
    header.append(disconnect);
    connectSerial(container, config, {screen: container.firstChild, badge: status.firstChild,
        fullscreen: document.createElement('button'), disconnect});
    // Wait for the mock handshake and replay before checking input or output.
    await new Promise(resolve => {
        // wait() polls the badge until xterm finishes parsing the replay.
        const wait = () => status.textContent === 'Connected' ? resolve() : setTimeout(wait, 10);
        wait();
    });
};
// reply(chunks) waits until xterm has parsed every injected guest-output byte.
window.reply = async chunks => {
    for (const bytes of chunks) socket.reply(bytes);
    await new Promise(resolve => term.write('', resolve));
};
// lines() reads the first four rendered rows, ignoring trailing empty columns.
window.lines = () => Array.from({length: 4}, (_, row) => term.buffer.active.getLine(row)?.translateToString(true));
</script>`);
const binary = process.env.CHROMIUM_BINARY || (process.platform === 'darwin'
    ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : 'chromium');
// A fresh profile keeps this fixture separate from the user's browser session.
const chrome = spawn(binary, ['--headless', '--remote-debugging-pipe', '--no-first-run',
    // Root-run Linux fixtures need this flag; desktop runs keep Chromium's sandbox.
    ...(process.platform === 'linux' && process.getuid() === 0 ? ['--no-sandbox'] : []),
    '--no-default-browser-check', '--disable-background-networking', '--disable-extensions',
    '--disable-sync', `--user-data-dir=${join(dir, 'browser-test-profile')}`, 'about:blank'],
    {stdio:['ignore', 'ignore', 'ignore', 'pipe', 'pipe']});
let nextId = 0, buffer = '';
// Match DevTools replies to requests over the debugging pipe.
const pending = new Map();
// rejectPending(error) fails outstanding calls when Chromium stops or cannot start.
const rejectPending = error => {
    for (const request of pending.values()) request.reject(error);
    pending.clear();
};
chrome.on('error', rejectPending);
chrome.on('exit', code => rejectPending(new Error(`Chromium exited (${code})`)));
// onData(chunk) assembles NUL-delimited replies from Chromium's DevTools pipe.
chrome.stdio[4].on('data', chunk => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf('\0')) >= 0) {
        const message = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        const promise = pending.get(message.id);
        // Resolve only replies to pending commands, not unsolicited DevTools
        // events.
        if (promise) {
            pending.delete(message.id);
            message.error ? promise.reject(new Error(JSON.stringify(message.error))) : promise.resolve(message.result);
        }
    }
});

// command(method, [params], [sessionId]) sends a DevTools request over private pipes.
function command(method, params = {}, sessionId) {
    // Fail promptly if Chromium exited instead of waiting for a response.
    if (chrome.exitCode !== null || chrome.signalCode !== null) return Promise.reject(new Error('Chromium is closed'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        chrome.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
}
// Stop a stalled run and let finally clean up.
const timeout = setTimeout(() => { console.error('Serial browser checks timed out'); chrome.kill(); process.exitCode = 1; }, 45000);
try {
    // Attach only to the blank tab created in this fixture's isolated profile.
    const { targetId } = await command('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await command('Target.attachToTarget', { targetId, flatten: true });
    // page(method, [params]) sends commands to this isolated fixture tab.
    const page = (method, params) => command(method, params, sessionId);
    // evaluate(expression) fails on browser exceptions as well as assertions.
    const evaluate = async expression => {
        const result = await page('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
        // Report browser exceptions as test failures.
        if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
        return result.result.value;
    };
    await page('Page.enable');
    await page('Page.navigate', { url: pathToFileURL(html).href });
    await evaluate(`new Promise(resolve => { const wait = () => window.openSerial ? resolve() : setTimeout(wait, 10); wait(); })`);
    // Connecting must not submit a command left in an existing serial session.
    await evaluate('openSerial()');
    assert.equal(await evaluate('initialSerialBackground'), 'rgb(0, 0, 0)');
    assert.deepEqual(await evaluate('sent'), [], 'attachment sends no guest input');
    // Preserve fragmented CR/LF and UTF-8 exactly as the guest sends them.
    const prompt = Array.from(Buffer.from('guest-é$ '));
    await evaluate('reply(' + JSON.stringify([[13], [10, 13], [10], ...prompt.map(byte => [byte])]) + ')');
    assert.deepEqual(await evaluate('lines()'), ['', '', 'guest-é$ ', '']);
    assert.equal(await evaluate('term.buffer.active.cursorY'), 2);
    // Later output uses the same rendering path as the initial prompt.
    await evaluate('reply(' + JSON.stringify([Array.from(Buffer.from('\r\nguest-é$ '))]) + ')');
    assert.deepEqual(await evaluate('lines()'), ['', '', 'guest-é$ ', 'guest-é$ ']);
    // Ctrl+L reaches the guest exactly once; render the shell redraw unchanged.
    await evaluate('term.focus()');
    await page('Input.dispatchKeyEvent', {type: 'keyDown', key: 'l', code: 'KeyL', windowsVirtualKeyCode: 76, modifiers: 2});
    await page('Input.dispatchKeyEvent', {type: 'keyUp', key: 'l', code: 'KeyL', windowsVirtualKeyCode: 76, modifiers: 2});
    assert.deepEqual(await evaluate('sent'), [[12]], 'only the user sends a clear command');
    await evaluate('reply(' + JSON.stringify([Array.from(Buffer.from('\x1b[H\x1b[2Jguest-é$ '))]) + ')');
    assert.deepEqual(await evaluate('lines()'), ['guest-é$ ', '', '', '']);
    // Zoom uses the platform modifier while the serial terminal has focus.
    // Neither font changes nor reset may send input or zoom the browser page.
    for (const platform of ['MacIntel', 'Linux x86_64']) {
        await evaluate(`Object.defineProperty(navigator, 'platform', {value: '${platform}', configurable: true});
            Object.defineProperty(navigator, 'userAgentData', {value: undefined, configurable: true}); term.focus()`);
        const modifier = platform === 'MacIntel' ? 4 : 2;
        const pageScale = await evaluate('[devicePixelRatio, visualViewport.scale]');
        // zoom(key, [modifiers]) sends a real browser shortcut to xterm.
        const zoom = async (key, modifiers = modifier) => {
            const code = {'=': 'Equal', '+': 'Equal', '-': 'Minus', '0': 'Digit0'}[key];
            const number = {'=': 187, '+': 187, '-': 189, '0': 48}[key];
            for (const type of ['keyDown', 'keyUp']) {
                await page('Input.dispatchKeyEvent', {type, key, code, windowsVirtualKeyCode: number, modifiers});
            }
            await evaluate('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
        };
        await zoom('=');
        assert.equal(await evaluate('term.options.fontSize'), 15);
        assert.equal(await evaluate('fontChanges.at(-1)'), 15, 'zoom reports the applied size for saving');
        await zoom('+', modifier | 8);
        assert.equal(await evaluate('term.options.fontSize'), 16);
        await zoom('-');
        assert.equal(await evaluate('term.options.fontSize'), 15);
        await zoom('0');
        assert.equal(await evaluate('term.options.fontSize'), 14);
        // Repeated zoom keys must stop at the limits without extra saves.
        for (let n = 0; n < 25; n++) await zoom('=');
        assert.equal(await evaluate('term.options.fontSize'), 32, 'zoom has an upper bound');
        const savedCount = await evaluate('fontChanges.length');
        await zoom('=');
        assert.equal(await evaluate('fontChanges.length'), savedCount, 'unchanged zoom needs no save');
        for (let n = 0; n < 30; n++) await zoom('-');
        assert.equal(await evaluate('term.options.fontSize'), 10, 'zoom has a lower bound');
        await zoom('0');
        assert.deepEqual(await evaluate('[devicePixelRatio, visualViewport.scale]'), pageScale);
        assert.deepEqual(await evaluate('sent'), [[12]], 'zoom never reaches the serial port');
        assert.deepEqual(await evaluate('lines()'), ['guest-é$ ', '', '', '']);
        // Outside the screen, the shortcut remains available to other page controls.
        const handledOutside = await evaluate(`(() => {
            const event = new KeyboardEvent('keydown', {key: '=', ${platform === 'MacIntel' ? 'metaKey' : 'ctrlKey'}: true, bubbles: true, cancelable: true});
            document.getElementById('header').dispatchEvent(event);
            return event.defaultPrevented;
        })()`);
        assert.equal(handledOutside, false);
    }
    // Both badge containers use the same widget palette in light and dark modes.
    for (const scheme of ['light', 'dark']) {
        const colors = await evaluate(`(() => {
            document.body.dataset.uiScheme = '${scheme}';
            return [...document.querySelectorAll('.ui_badge')].map(node => {
                const style = getComputedStyle(node);
                return [style.color, style.backgroundColor, style.borderColor];
            });
        })()`);
        assert.deepEqual(colors[0], colors[1]);
        assert.notEqual(colors[0][1], 'rgba(0, 0, 0, 0)', 'badge has a state background');
    }
    // Resizing redraws text locally without sending terminal-control input.
    await page('Emulation.setDeviceMetricsOverride', {width: 800, height: 600, deviceScaleFactor: 1, mobile: false});
    await evaluate('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
    assert.deepEqual(await evaluate('sent'), [[12]]);
    // Restore before the first renderer is created, including a custom default.
    await evaluate('openSerial(19, 16)');
    assert.equal(await evaluate('term.options.fontSize'), 19, 'saved font size is restored on return');
    assert.deepEqual(await evaluate('fontChanges'), [], 'restoring a preference does not save it again');
    await evaluate(`document.querySelector('[data-console-screen]').dispatchEvent(new KeyboardEvent('keydown',
        {key: '0', ctrlKey: true, bubbles: true, cancelable: true}))`);
    assert.deepEqual(await evaluate('fontChanges'), [16], 'reset saves the configured default size');
    await evaluate('openSerial(fontChanges.at(-1), 16)');
    assert.equal(await evaluate('term.options.fontSize'), 16, 'saved reset is restored on return');
    assert.deepEqual(await evaluate('sent'), [], 'restoring zoom never adds serial input');
    // Missing, corrupt or out-of-range settings fall back to the module default.
    for (const savedSize of [0, 'invalid', 9, 33, 14.5]) {
        await evaluate('openSerial(' + JSON.stringify(savedSize) + ', 16)');
        assert.equal(await evaluate('term.options.fontSize'), 16, 'invalid preference uses configured default');
    }
    // Browser zoom changes both CSS viewport size and device-pixel rounding.
    // Every fitted row must stay inside the visible screen, including its inset.
    for (const zoom of [.75, .9, 1, 1.1, 1.25, 1.5, 1.75, 2]) {
        await page('Emulation.setDeviceMetricsOverride', {width: Math.round(1200 / zoom),
            height: Math.round(900 / zoom), deviceScaleFactor: zoom, mobile: false});
        for (const size of [10, 14, 19, 32]) {
            for (const height of [400, 411.5, 600]) {
                const geometry = await evaluate(`(async () => {
                    term.options.fontSize = ${size};
                    document.getElementById('host').style.height = '${height}px';
                    // Allow layout, ResizeObserver, fitting and xterm's paint
                    // to finish before measuring the final row.
                    for (let frame = 0; frame < 4; frame++) {
                        await new Promise(resolve => requestAnimationFrame(resolve));
                    }
                    const outer = document.querySelector('[data-console-screen]').getBoundingClientRect();
                    const inner = document.querySelector('.xterm-screen').getBoundingClientRect();
                    return {top: inner.top - outer.top, left: inner.left - outer.left,
                        bottom: outer.bottom - inner.bottom, right: outer.right - inner.right};
                })()`);
                assert.ok(Object.values(geometry).every(inset => inset >= 7.9),
                    `terminal is clipped at zoom ${zoom}, font ${size}, height ${height}: ${JSON.stringify(geometry)}`);
            }
        }
    }
    // Boot output that starts with an escape sequence retains its own layout.
    await evaluate('openSerial()');
    await evaluate('reply(' + JSON.stringify([Array.from(Buffer.from('\x1b[2J\x1b[H\r\nBooting\r\n'))]) + ')');
    assert.deepEqual(await evaluate('lines()'), ['', 'Booting', '', '']);
    // Reopening must keep new output's blank lines without sending input.
    await evaluate('openSerial()');
    await evaluate('reply(' + JSON.stringify([Array.from(Buffer.from('\r\nlogin: '))]) + ')');
    assert.deepEqual(await evaluate('lines()'), ['', 'login: ', '', '']);
    assert.deepEqual(await evaluate('sent'), [], 'reconnecting sends no guest input');
    // Replayed login text appears at once, with no extra newline or keystroke.
    const history = '\r\nSerial fixture\r\nlogin: tester';
    await evaluate('openSerial(undefined, 14, ' + JSON.stringify(history) + ')');
    assert.deepEqual(await evaluate('lines()'), ['', 'Serial fixture', 'login: tester', '']);
    assert.equal(await evaluate('term.buffer.active.cursorY'), 2);
    assert.deepEqual(await evaluate('sent'), [], 'replay preserves the unfinished username');
    // Historic terminal queries must not answer into a later login or shell.
    await evaluate('openSerial(undefined, 14, ' + JSON.stringify('\x1b[6n\x1b[c' + history + '\x1b[') + ')');
    await evaluate('reply([[54, 110]])');
    assert.deepEqual(await evaluate('sent'), [], 'complete and split historical queries send no replies');
    // Fresh terminal queries still receive replies after replay has finished.
    await evaluate('reply([[27, 91, 54, 110]])');
    assert.equal(await evaluate('sent.length'), 1, 'live terminal queries still work');
    // Disconnect releases the transport without clearing output or sending keys.
    const lastScreen = await evaluate('lines()');
    const lastInput = await evaluate('sent');
    const disconnect = 'document.querySelector("[data-console-action=disconnect]")';
    assert.equal(await evaluate(disconnect + '.disabled'), false, 'ready console offers disconnect');
    await evaluate(disconnect + '.click()');
    assert.equal(await evaluate('socket.readyState'), 3, 'disconnect closes the WebSocket');
    assert.equal(await evaluate('term.options.disableStdin'), true, 'disconnected terminal rejects input');
    assert.equal(await evaluate(disconnect + '.disabled'), true, 'disconnect cannot run twice');
    // Late messages and socket errors must not revive a manually closed session.
    await evaluate('reply([[27, 91, 54, 110], [120]])');
    await evaluate('socket.dispatchEvent(new Event("error"))');
    assert.equal(await evaluate('document.querySelector(".ui_badge_warning")?.textContent'), 'Disconnected');
    assert.deepEqual(await evaluate('lines()'), lastScreen, 'final serial output remains visible');
    assert.deepEqual(await evaluate('sent'), lastInput, 'disconnect and late events send no guest input');
    // Leaving the old page and reopening Serial creates a usable new session.
    await evaluate('openSerial()');
    assert.equal(await evaluate(disconnect + '.disabled'), false, 'returning to Serial allows a fresh connection');
    // The graphical viewport uses the same inset without clipping a zoomed image.
    const graphical = await evaluate(`(async () => {
        const host = document.getElementById('host');
        host.replaceChildren();
        await new Promise(resolve => setTimeout(resolve));
        host.innerHTML = '<div id="cloudmin-console" data-console-mode="graphical"><div data-console-screen style="width:500px;height:300px;flex:none"><div data-console-display style="left:8px;top:8px;width:640px;height:480px"></div></div></div>';
        const viewport = host.querySelector('[data-console-screen]');
        return {padding: getComputedStyle(viewport).padding, width: viewport.scrollWidth, height: viewport.scrollHeight};
    })()`);
    assert.deepEqual(graphical, {padding: '8px', width: 648, height: 488});
    console.log('PASS: real xterm replay, query suppression, fragmented output, Ctrl+L, disconnect, reconnect, resize, palettes, insets and zoom');
} finally {
    // Close the browser before removing its profile, even after a test failure.
    clearTimeout(timeout);
    try { await command('Browser.close'); } catch (_) { /* Chromium may already have exited. */ }
    await new Promise(resolve => { if (chrome.exitCode !== null || chrome.signalCode || !chrome.pid) resolve(); else chrome.once('exit', resolve); });
    rmSync(dir, {recursive: true, force: true});
}
