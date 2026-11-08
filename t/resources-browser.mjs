// Exercise the actual Webmin resource markup and live updates in Chromium.
// Usage: node t/resources-browser.mjs [artifact-directory]
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {mkdtempSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// Use the installed Webmin root on a guest, or the sibling checkout locally.
const webmin = process.env.WEBMIN_ROOT || resolve(root, '../webmin');
const dir =
    process.argv[2] ||
    mkdtempSync(join(tmpdir(), 'cloudmin-resources-browser-'));
const markup = JSON.parse(
    execFileSync('perl', [join(root, 't/resources-ui-fixture.pl')], {
        encoding: 'utf8'
    })
);
// Strip widget scripts; the test loads the real status client and static
// widget CSS.
for (const key of Object.keys(markup))
    markup[key] = markup[key]
        .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
        .replace(/<link\b[^>]*>/gi, '');
const html = join(dir, 'resources.html');
writeFileSync(
    html,
    `<!doctype html><meta charset="utf-8">
<link rel="stylesheet" href="${pathToFileURL(join(webmin, 'unauthenticated/css/ui-lib.css'))}">
<style>body { font: 15px system-ui; margin: 20px; } table { border-collapse: collapse; } td { padding: 7px; } </style>
<script>
// fetch() supplies a local handshake; no network connection is opened.
window.fetch = async () => ({ ok: true, json: async () => ({socket_url: 'ws://fixture/status'}) });
window.WebSocket = class extends EventTarget {
 // constructor() schedules the open event after the client installs listeners.
 constructor() { super(); window.socket = this; this.readyState = 0; setTimeout(() => { this.readyState = 1; this.dispatchEvent(new Event('open')); }); }
 // send() discards subscriptions; close() exercises the client's disconnect
 // path.
 send() {} close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
 // reply(data) delivers a fixture snapshot through the actual message handler.
 reply(data) { this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(data) })); }
};
window.submissions = 0;
document.addEventListener('submit', event => { event.preventDefault(); window.submissions++; });
</script>
<div id="fixture">${markup.overview}</div>
<script src="${pathToFileURL(join(root, 'machine_status.js'))}"></script>`
);
const binary =
    process.env.CHROMIUM_BINARY ||
    (process.platform === 'darwin'
        ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
        : 'chromium');
// A fresh profile keeps this fixture separate from the user's browser session.
const chrome = spawn(
    binary,
    [
        '--headless',
        '--remote-debugging-pipe',
        '--no-first-run',
        // Root-run Linux fixtures need this flag; desktop runs keep
        // Chromium's sandbox.
        ...(process.platform === 'linux' && process.getuid() === 0
            ? ['--no-sandbox']
            : []),
        '--no-default-browser-check',
        '--disable-background-networking',
        '--disable-extensions',
        '--disable-sync',
        `--user-data-dir=${join(dir, 'browser-test-profile')}`,
        'about:blank'
    ],
    {stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe']}
);
let nextId = 0,
    buffer = '';
const pending = new Map();
// rejectPending(error) fails outstanding calls when Chromium stops or
// cannot start.
const rejectPending = error => {
    for (const request of pending.values()) request.reject(error);
    pending.clear();
};
chrome.on('error', rejectPending);
chrome.on('exit', code =>
    rejectPending(new Error(`Chromium exited (${code})`))
);
// onData(chunk) assembles NUL-delimited replies from Chromium's DevTools pipe.
chrome.stdio[4].on('data', chunk => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf('\0')) >= 0) {
        const message = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        const promise = pending.get(message.id);
        // Resolve only replies to pending commands, not unsolicited
        // DevTools events.
        if (promise) {
            pending.delete(message.id);
            message.error
                ? promise.reject(new Error(JSON.stringify(message.error)))
                : promise.resolve(message.result);
        }
    }
});

// command(method, [params], [sessionId]) sends a DevTools request over
// private pipes.
function command(method, params = {}, sessionId) {
    // Fail promptly if Chromium exited instead of waiting for a response.
    if (chrome.exitCode !== null || chrome.signalCode !== null)
        return Promise.reject(new Error('Chromium is closed'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
        pending.set(id, {resolve, reject});
        chrome.stdio[3].write(
            JSON.stringify({id, method, params, sessionId}) + '\0'
        );
    });
}
const timeout = setTimeout(() => {
    console.error('Resource browser checks timed out');
    chrome.kill();
    process.exitCode = 1;
}, 45000);
try {
    const {targetId} = await command('Target.createTarget', {
        url: 'about:blank'
    });
    const {sessionId} = await command('Target.attachToTarget', {
        targetId,
        flatten: true
    });
    // page(method, [params]) directs CDP commands to the fixture tab.
    const page = (method, params) => command(method, params, sessionId);
    // evaluate(expression) surfaces exceptions from rendering instead of
    // hiding them.
    const evaluate = async expression => {
        const result = await page('Runtime.evaluate', {
            expression,
            returnByValue: true,
            awaitPromise: true
        });
        // A page exception must fail the test instead of skipping assertions.
        if (result.exceptionDetails)
            throw new Error(JSON.stringify(result.exceptionDetails));
        return result.result.value;
    };
    await page('Page.enable');
    await page('Emulation.setDeviceMetricsOverride', {
        width: 1800,
        height: 1200,
        deviceScaleFactor: 1,
        mobile: false
    });
    await page('Page.navigate', {url: pathToFileURL(html).href});
    // Readiness is deterministic: socket construction follows parsing the
    // real config.
    await evaluate(
        `new Promise(resolve => { const check = () => window.socket?.readyState === 1 ? resolve(true) : setTimeout(check, 10); check(); })`
    );
    const id = '11111111-2222-3333-4444-555555555555';
    const record = {
        vm: {
            uuid: id,
            name: 'resource-fixture',
            state: 'running',
            active: 1,
            persistent: 1,
            autostart: 1,
            vcpus: 2,
            memory_kib: 1048576,
            addresses: [{address: '192.0.2.1'}],
            macs: ['52:54:00:00:00:01']
        },
        resources: {
            cpu_percent: 0.478253857414245,
            memory_percent: 30,
            memory_bytes: 1024 ** 3,
            memory_used_bytes: 0.3 * 1024 ** 3,
            disk_capacity_bytes: 10 * 1024 ** 3,
            disk_read_bytes_sec: 2048,
            disk_write_bytes_sec: 0,
            network_rx_bytes_sec: 1024,
            network_tx_bytes_sec: 0,
            disks: {vda: {capacity: 10 * 1024 ** 3, physical: 1024 ** 3}}
        },
        guest: {
            os: '<img src=x onerror="window.injected=true">',
            hostname: 'guest.test',
            kernel: '6.12',
            filesystem_used_bytes: 0.02 * 10 * 1024 ** 3,
            filesystems: [
                {
                    name: 'vda1',
                    mountpoint: '/',
                    fstype: 'xfs',
                    'total-bytes': 10 * 1024 ** 3,
                    'used-bytes': 0.02 * 10 * 1024 ** 3
                }
            ]
        },
        health: {
            agent: 'responding',
            ssh: 'responding',
            ssh_address: '192.0.2.1'
        }
    };
    // message() wraps the current record as a full collector snapshot.
    const message = () => ({
        type: 'status',
        full: 1,
        changed: {[id]: record},
        removed: []
    });
    // reply() sends that snapshot through the browser's fixture socket.
    const reply = async () =>
        evaluate('window.socket.reply(' + JSON.stringify(message()) + ')');
    // value(field) reads the text rendered for one resource field.
    const value = field =>
        evaluate(
            `document.querySelector('[data-vm-resource="${field}"]').textContent`
        );
    // tableVisible() includes visibility inherited from the table's wrapper.
    const tableVisible = () =>
        evaluate(
            `document.querySelector('#cloudmin-machines table').getClientRects().length > 0`
        );
    // emptyVisible() checks whether the empty-state message occupies
    // page space.
    const emptyVisible = () =>
        evaluate(
            `document.querySelector('[data-vm-empty]').getClientRects().length > 0`
        );
    assert.equal(
        await value('cpu'),
        '2',
        'initial markup shows capacity without an unknown percentage'
    );
    assert.equal(await value('memory'), '1 GiB');
    // Before the snapshot, neither the native form nor a theme's AJAX handler
    // may run.
    await evaluate(`document.querySelector('input[type=checkbox]').click()`);
    assert.equal(await evaluate('window.submissions'), 0);
    await reply();
    assert.equal(await tableVisible(), true);
    assert.equal(await emptyVisible(), false);
    assert.equal(
        await value('cpu'),
        '0.5% of 2',
        'overview rounds full-precision CPU readings'
    );
    assert.equal(await value('memory'), '30% of 1 GiB');
    assert.equal(await value('disk'), '2% of 10 GiB');
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-guest=os]').textContent`
        ),
        record.guest.os
    );
    assert.equal(
        await evaluate(
            `document.querySelectorAll('#fixture img[onerror]').length`
        ),
        0,
        'overview OS is plain text'
    );
    record.guest.os = 'Rocky Linux 10.2 (Red Quartz)';
    await reply();
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-guest=os]').textContent`
        ),
        'Rocky Linux 10.2',
        'OS omits the release codename'
    );
    record.guest.os = 'Debian GNU/Linux 13';
    await reply();
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-guest=os]').textContent`
        ),
        record.guest.os,
        'OS version follows live updates'
    );
    const overviewImage = await page('Page.captureScreenshot', {
        format: 'png',
        captureBeyondViewport: true
    });
    writeFileSync(
        join(dir, 'overview.png'),
        Buffer.from(overviewImage.data, 'base64')
    );
    assert.equal(
        await evaluate(
            `document.querySelector('#cloudmin-machines table tr:last-child').cells.length`
        ),
        11
    );
    await evaluate(`document.querySelector('input[type=checkbox]').click()`);
    assert.equal(
        await evaluate('window.submissions'),
        1,
        'boot toggle remains functional after column insertion'
    );
    await evaluate(
        `document.querySelector('form input[value=shutdown]').form.querySelector('button').click()`
    );
    assert.equal(
        await evaluate('window.submissions'),
        2,
        'shutdown button remains in the controls column'
    );
    record.vm.state = 'shutoff';
    record.vm.active = 0;
    record.resources.cpu_percent = null;
    record.resources.memory_percent = null;
    await reply();
    assert.equal(await value('cpu'), '2');
    assert.equal(await value('memory'), '1 GiB');
    assert.equal(
        await value('disk'),
        '10 GiB',
        'known disk capacity remains useful without usage'
    );
    assert.equal(
        await evaluate(`!!document.querySelector('form input[value=start]')`),
        true,
        'live state changes replace power buttons'
    );
    record.vm.state = 'running';
    record.vm.active = 1;
    record.resources.cpu_percent = 0;
    record.resources.memory_percent = 0;
    await reply();
    assert.equal(
        await value('cpu'),
        '0% of 2',
        'zero usage is a valid measurement'
    );
    assert.equal(await value('memory'), '0% of 1 GiB');
    record.resources.cpu_percent = 0.478253857414245;
    record.resources.memory_percent = 30;
    // Removing the last VM hides the whole table, including theme decorations.
    await evaluate(
        `window.socket.reply({type: 'status', changed: {}, removed: [${JSON.stringify(id)}]})`
    );
    assert.equal(await tableVisible(), false);
    assert.equal(await emptyVisible(), true);
    await reply();
    assert.equal(
        await tableVisible(),
        true,
        'a live addition restores the table'
    );
    assert.equal(await emptyVisible(), false);
    // A page that starts empty must also support the first VM arriving live.
    await evaluate(
        `document.getElementById('fixture').innerHTML = ${JSON.stringify(markup.empty)}; window.cloudminStatusInit();`
    );
    assert.equal(
        await tableVisible(),
        false,
        'initial empty table is hidden before the socket answers'
    );
    assert.equal(await emptyVisible(), true);
    await evaluate(
        `window.socket.reply({type: 'status', full: 1, changed: {}, removed: []})`
    );
    assert.equal(
        await tableVisible(),
        false,
        'empty snapshot keeps the table hidden'
    );
    await reply();
    assert.equal(await tableVisible(), true);
    assert.equal(await emptyVisible(), false);
    // Replace the page during SPA navigation, reusing the existing channel.
    // Exercise table-based layouts with a wrapper around the data table.
    await evaluate(`document.getElementById('fixture').innerHTML = ${JSON.stringify(markup.details)};
        const content = document.querySelector('[data-vm-filesystems]');
        const table = content.querySelector('table');
        const wrapper = document.createElement('table'); wrapper.className = 'wrapper';
        table.replaceWith(wrapper); wrapper.insertRow().insertCell().append(table);
        window.cloudminStatusInit();`);
    // Empty tables and their hints stay hidden before the first agent reply.
    const filesystemHidden = () =>
        evaluate(`document.querySelector('[data-vm-filesystems]').hidden`);
    const filesystemMessage = () =>
        evaluate(
            `document.querySelector('[data-vm-filesystems-message]').textContent`
        );
    assert.equal(await filesystemHidden(), true);
    assert.equal(await filesystemMessage(), 'Checking guest filesystems ..');
    // Themes can move the widget into its own panel, apart from the
    // detail tables.
    await evaluate(`const widget = document.getElementById('cloudmin-vm-status');
        const panel = document.createElement('div'); widget.before(panel); panel.append(widget);`);
    await reply();
    assert.equal(
        await evaluate(
            `document.querySelectorAll('#cloudmin-vm-status .ui_card dl').length`
        ),
        1,
        'main details share one compact description card'
    );
    // The power-action dropdown also uses details, but is not an accordion.
    assert.equal(
        await evaluate(
            `document.querySelectorAll('#cloudmin-vm-status table, #cloudmin-vm-status details:not(.ui_dropdown)').length`
        ),
        0,
        'tables and accordions stay outside the configuration widget'
    );
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-resource=disk_read]').closest('table').closest('.opener_hidden, .opener_shown')`
        ),
        null,
        'resource usage uses a regular table before the accordions'
    );
    assert.equal(
        await evaluate(
            `document.querySelectorAll('.opener_hidden')[document.querySelectorAll('.opener_hidden').length - 1].contains(document.querySelector('[data-vm-field=persistent]'))`
        ),
        true,
        'hardware is the last collapsed accordion'
    );
    // VM details use the same percentage formatting as the overview.
    assert.equal(
        await value('cpu'),
        '0.5% of 2',
        'details round full-precision CPU readings'
    );
    assert.equal(await value('disk_read'), '2 KiB/s');
    record.vm.autostart = 0;
    await reply();
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-field=autostart]').textContent`
        ),
        'No',
        'details follow live boot-policy changes'
    );
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-disk=vda][data-disk-field=capacity]').textContent`
        ),
        '10 GiB'
    );
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-guest=os]').textContent`
        ),
        record.guest.os
    );
    assert.equal(
        await evaluate(
            `document.querySelectorAll('#fixture img[onerror]').length`
        ),
        0,
        'guest strings cannot become HTML'
    );
    const filesystemRows = () =>
        evaluate(
            `document.querySelector('[data-vm-filesystems] tr.ui_columns_heads').closest('table').rows.length`
        );
    assert.equal(
        await filesystemRows(),
        2,
        'Heading inside tbody survives first update'
    );
    assert.equal(
        await evaluate(
            `!!document.querySelector('[data-vm-filesystems] table.wrapper > tbody[data-vm-filesystem-rows]')`
        ),
        false,
        'filesystem rows stay out of a theme layout table'
    );
    assert.equal(
        await filesystemHidden(),
        false,
        'agent data reveals the table and hint'
    );
    await reply();
    assert.equal(
        await filesystemRows(),
        2,
        'filesystem rows do not accumulate'
    );
    const detailsImage = await page('Page.captureScreenshot', {
        format: 'png',
        captureBeyondViewport: true
    });
    writeFileSync(
        join(dir, 'details.png'),
        Buffer.from(detailsImage.data, 'base64')
    );
    // Shutdown must hide even a previous, populated filesystem report.
    const guest = record.guest;
    record.vm.active = 0;
    record.vm.state = 'shutoff';
    await reply();
    assert.equal(await filesystemHidden(), true);
    assert.equal(
        await filesystemMessage(),
        'Start this virtual machine to view its mounted filesystems.'
    );
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-filesystem-rows]').rows.length`
        ),
        0
    );
    record.vm.active = 1;
    record.vm.state = 'running';
    delete record.guest;
    await reply();
    assert.equal(await filesystemHidden(), true);
    assert.equal(await filesystemMessage(), 'Checking guest filesystems ..');
    record.health.agent = 'unavailable';
    await reply();
    assert.match(await filesystemMessage(), /responding guest agent/);
    record.health.agent = 'responding';
    record.guest = {filesystems: []};
    await reply();
    assert.equal(await filesystemHidden(), true);
    assert.equal(
        await filesystemMessage(),
        'The guest agent has not reported any mounted disk filesystems.'
    );
    record.guest = guest;
    await reply();
    assert.equal(
        await filesystemHidden(),
        false,
        'a later agent report restores the table'
    );
    record.resources = {};
    record.guest = {error: 1};
    await reply();
    assert.equal(await value('cpu'), '2');
    assert.equal(await value('memory'), '1 GiB');
    assert.equal(await value('disk'), 'Unavailable');
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-filesystems-warning]').hidden`
        ),
        false
    );
    assert.equal(await filesystemHidden(), true, 'agent errors hide the table');
    assert.match(await filesystemMessage(), /responding guest agent/);
    record.guest = guest;
    await reply();
    await evaluate(`window.socket.close()`);
    assert.equal(
        await filesystemHidden(),
        true,
        'disconnect hides previous filesystem data'
    );
    assert.match(
        await filesystemMessage(),
        /Filesystem information is unavailable/
    );
    assert.equal(
        await value('memory'),
        'Unavailable',
        'disconnect never leaves a stale percentage'
    );
    assert.equal(
        await value('disk_read'),
        'Unavailable',
        'disconnect also clears fields in sibling accordions'
    );
    // Configured columns must stay aligned through additions and state changes.
    for (const columns of [
        'name,state',
        'name,state,os,memory,autostart,controls',
        'name,state,ips,macs'
    ]) {
        await evaluate(
            `document.getElementById('fixture').innerHTML = ${JSON.stringify(markup[columns])}; window.cloudminStatusInit();`
        );
        // check() waits for the fixture's mock socket before sending live data.
        await evaluate(
            `new Promise(resolve => { const check = () => window.socket?.readyState === 1 ? resolve(true) : setTimeout(check, 10); check(); })`
        );
        record.vm.active = 1;
        record.vm.state = 'running';
        record.vm.autostart = 1;
        await reply();
        const ids = columns.split(',');
        // cells() reads visible text in DOM order to check column alignment.
        const cells = () =>
            evaluate(
                `Array.from(document.querySelector('[data-vm-id]').closest('tr').cells, cell => cell.textContent.trim())`
            );
        let values = await cells();
        assert.equal(values.length, ids.length);
        assert.equal(values[0], record.vm.name);
        assert.match(values[1], /Running/);
        // Only layouts with addresses should have a destination for
        // their update.
        if (ids.includes('ips'))
            assert.match(values[ids.indexOf('ips')], /192.0.2.1/);
        // OS text follows the configured column and stays absent when hidden.
        assert.equal(
            await evaluate(
                `document.querySelectorAll('[data-vm-guest=os]').length`
            ),
            ids.includes('os') ? 1 : 0
        );
        if (ids.includes('os')) {
            assert.equal(values[ids.indexOf('os')], record.guest.os);
            delete record.guest;
            await reply();
            assert.equal((await cells())[ids.indexOf('os')], 'Unavailable');
            record.guest = guest;
            await reply();
        }
        // MAC updates must follow their named column rather than an old offset.
        if (ids.includes('macs'))
            assert.equal(values[ids.indexOf('macs')], record.vm.macs[0]);
        // Power changes must replace state and any visible action buttons.
        record.vm.state = 'shutoff';
        record.vm.active = 0;
        await reply();
        values = await cells();
        assert.match(values[1], /Shut off/);
        // Check the Start button only in layouts that include power controls.
        if (ids.includes('controls'))
            assert.match(values[ids.indexOf('controls')], /Start/);
        // Removing all rows exercises the live-template path on the
        // next snapshot.
        await evaluate(
            `document.querySelector('[data-vm-id]').closest('tr').remove()`
        );
        await reply();
        assert.equal((await cells()).length, ids.length);
        if (ids.includes('os'))
            assert.equal(
                (await cells())[ids.indexOf('os')],
                record.guest.os,
                'new live rows include OS'
            );
        // Newly inserted rows must retain the saved host-boot toggle state.
        if (ids.includes('autostart')) {
            assert.equal(
                await evaluate(
                    `document.querySelector('[data-vm-id]').closest('tr').cells[${ids.indexOf('autostart')}].querySelector('input[type=checkbox]').checked`
                ),
                true
            );
        }
    }
    // Later connection checks need the running state restored after
    // table tests.
    record.vm.active = 1;
    record.vm.state = 'running';
    // The SSH form uses one live message and native card state colors.
    await evaluate(
        `document.getElementById('fixture').innerHTML = ${JSON.stringify(markup.terminal)}; window.cloudminStatusInit();`
    );
    await evaluate(
        `new Promise(resolve => { const check = () => window.socket?.readyState === 1 ? resolve(true) : setTimeout(check, 10); check(); })`
    );
    assert.equal(
        await evaluate(
            `document.querySelectorAll('#cloudmin-vm-status [data-vm-field]').length`
        ),
        1
    );
    assert.equal(
        await evaluate(`!!document.querySelector('[data-vm-warning]')`),
        false,
        'SSH does not duplicate its message in an alert'
    );
    await reply();
    assert.equal(
        await evaluate(
            `document.querySelector('#cloudmin-ssh-status').classList.contains('ui_card_success')`
        ),
        true
    );
    record.health.ssh = 'unavailable';
    delete record.health.ssh_address;
    await reply();
    assert.equal(
        await evaluate(
            `document.querySelector('#cloudmin-ssh-status').classList.contains('ui_card_warning')`
        ),
        true
    );
    assert.equal(
        await evaluate(
            `document.querySelector('[data-vm-field=ssh]').textContent`
        ),
        'Not responding on port 22'
    );
    await evaluate(`window.socket.close()`);
    assert.equal(
        await evaluate(
            `document.querySelector('#cloudmin-ssh-status').classList.contains('ui_card_warning')`
        ),
        true
    );
    console.log(
        'PASS: rendered usage, live controls, detail navigation, filesystem headings, escaping and unavailable metrics'
    );
    console.log('Artifacts: ' + dir);
} finally {
    clearTimeout(timeout);
    chrome.kill();
}
