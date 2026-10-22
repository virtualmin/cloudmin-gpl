// Exercise form replacement with real Chromium and jQuery, without guest credentials.
// Usage: node t/images-browser.mjs [artifact-directory]
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const webmin = process.env.WEBMIN_ROOT || resolve(root, '../webmin');
const dir = process.argv[2] || mkdtempSync(join(tmpdir(), 'cloudmin-images-browser-'));
// Render the actual Webmin form, using only task files and the local jQuery copy.
const fragment = execFileSync('perl', [join(root, 't/images-browser-fixture.pl')], {encoding:'utf8'})
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '');
// Installed hosts can supply a local jQuery copy without the File Manager module.
const jquery = pathToFileURL(process.env.JQUERY_PATH || join(webmin, 'filemin/unauthenticated/jquery/jquery.min.js')).href;
const script = pathToFileURL(join(root, 'images.js')).href;
const html = join(dir, 'images.html');
writeFileSync(html, `<!doctype html><meta charset="utf-8"><script src="${jquery}"></script>
<div id="content">${fragment}</div><script src="${script}"></script>`);
const binary = process.env.CHROMIUM_BINARY || (process.platform === 'darwin'
    ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : 'chromium');
// A fresh profile keeps this fixture separate from the user's browser session.
const chrome = spawn(binary, ['--headless', '--remote-debugging-pipe', '--no-first-run',
    ...(process.platform === 'linux' && process.getuid() === 0 ? ['--no-sandbox'] : []),
    '--no-default-browser-check', '--disable-background-networking', '--disable-extensions',
    '--disable-sync', `--user-data-dir=${join(dir, 'browser-test-profile')}`, 'about:blank'],
    {stdio:['ignore', 'ignore', 'ignore', 'pipe', 'pipe']});
let nextId = 0, buffer = '';
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
const timeout = setTimeout(() => { console.error('Browser checks timed out'); chrome.kill(); process.exitCode = 1; }, 45000);
try {
    const {targetId} = await command('Target.createTarget', {url:'about:blank'});
    const {sessionId} = await command('Target.attachToTarget', {targetId, flatten:true});
    // page(method, [params]) directs commands to this test tab's session.
    const page = (method, params) => command(method, params, sessionId);
    // evaluate(expression) reports browser exceptions instead of silently skipping assertions.
    const evaluate = async expression => {
        const result = await page('Runtime.evaluate', {expression, returnByValue:true, awaitPromise:true});
        // Surface browser-side assertion failures in the test process.
        if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
        return result.result.value;
    };
    await page('Page.enable');
    await page('Page.addScriptToEvaluateOnNewDocument', {source: `
        // fetch(url) holds one size probe; releaseSize() later supplies its result.
        window.fetch = async url => {
            // Reject unexpected requests so the fixture cannot silently use the
            // network.
            if (url !== 'image-size.cgi?id=size-unknown') throw new Error('Unexpected size request');
            return new Promise(resolve => {
                window.releaseSize = () => resolve({ok:true, json:async () => ({bytes:268435456})});
            });
        };`});
    await page('Page.navigate', {url:pathToFileURL(html).href});
    for (let n = 0; n < 100; n++) {
        // Wait for the form and document before exercising its controls.
        if (await evaluate("document.readyState === 'complete' && !!document.querySelector('#cloudmin-image-form')")) break;
        await new Promise(r => setTimeout(r, 50));
    }
    // Estimates must count hidden selections and disclose missing sizes.
    // chooseImage(id, checked) changes a checkbox through the native event path.
    await evaluate(`window.chooseImage = (id, checked) => {
        const row = document.querySelector('[data-download-id="' + id + '"]');
        const checkbox = row.querySelector('[data-ui-multi-item]');
        checkbox.checked = checked;
        checkbox.dispatchEvent(new Event('change', {bubbles:true}));
    }; chooseImage('size-a', true); chooseImage('size-b', true);`);
    // totalText() reads the displayed estimate after each selection change.
    const totalText = () => evaluate("document.querySelector('#cloudmin-download-total').textContent");
    assert.equal(await totalText(), 'Estimated download: 1.5 GiB');
    await evaluate(`document.querySelector('[data-download-id="size-b"]').hidden = true;
        chooseImage('size-unknown', true);`);
    assert.equal(await totalText(), 'Estimated download: 1.5 GiB. Some image sizes are unavailable.');
    await evaluate(`chooseImage('size-a', false); chooseImage('size-b', false);`);
    assert.equal(await totalText(), 'Download size unavailable.');
    // Finish the held probe and require the displayed estimate to refresh.
    await evaluate('releaseSize()');
    for (let n = 0; n < 40 && await totalText() !== 'Estimated download: 256 MiB'; n++) {
        await new Promise(r => setTimeout(r, 25));
    }
    assert.equal(await totalText(), 'Estimated download: 256 MiB', 'Fresh metadata updates the selected total');
    assert.equal(await evaluate("document.querySelector('[data-download-id=\"size-unknown\"] .ui_multi_meta > span').textContent"), '256 MiB');
    await evaluate(`chooseImage('size-unknown', false);
        document.querySelector('[data-download-id="size-unknown"]').dataset.downloadRefresh = '0';
        document.querySelector('[data-download-id="size-b"]').hidden = false;`);
    assert.equal(await evaluate("document.querySelector('#cloudmin-download-total').hidden"), true);
    // Retain the initial markup for later PJAX replacement and history tests.
    await evaluate(`window.originalForm = document.querySelector('#content').innerHTML;
        // selectSource(type) exercises synthetic jQuery change events.
        window.selectSource = type => {
            const source = document.querySelector('[name=install_type]');
            source.value = type;
            jQuery(source).trigger('change');
        };
        window.submissions = 0;
        // fetch(url, options) counts upload submissions and returns a known error.
        window.fetch = async (url, options) => {
            submissions++;
            // Verify the intercepted upload submission includes the selected
            // filename.
            if (url !== 'image.cgi' || options.body.get('filename') !== 'fixture.qcow2') throw new Error('Wrong upload request');
            return {ok:true, json:async () => ({error:'Fixture upload reached'})};
        };`);
    // Themes call the exported initializer when they replace or restore content.
    for (const visit of ['initial', 'navigation', 'history']) {
        // Replace the form to exercise handler setup after navigation and
        // restoration.
        if (visit !== 'initial') {
            await evaluate(`document.querySelector('#content').innerHTML = '';
                window.cloudminImagesInit();
                document.querySelector('#content').innerHTML = originalForm;
                { const input = document.querySelector('#cloudmin-image-submit');
                  const button = document.createElement('button');
                  button.id = input.id;
                  button.type = 'button';
                  button.value = input.value;
                  button.textContent = input.value;
                  input.replaceWith(button); }
                window.cloudminImagesInit();
                window.cloudminImagesInit();`);
        }
        await evaluate(`chooseImage('size-a', true); chooseImage('size-b', true);`);
        assert.equal(await totalText(), 'Estimated download: 1.5 GiB', visit + ': restored selection total');
        for (const type of ['upload', 'url', 'local', 'download']) {
            await evaluate(`selectSource('${type}')`);
            assert.equal(await evaluate("document.querySelector('#cloudmin-image-submit').value"),
                ['upload', 'local'].includes(type) ? 'Import image' : 'Download selected images', `${visit}: ${type} button`);
            // Restored forms use a button element, whose visible text must also
            // change.
            if (visit !== 'initial') {
                assert.equal(await evaluate("document.querySelector('#cloudmin-image-submit').textContent"),
                    ['upload', 'local'].includes(type) ? 'Import image' : 'Download selected images');
            }
            assert.equal(await evaluate("document.querySelector('#cloudmin-image-note').hidden"), type !== 'download');
            assert.equal(await evaluate("document.querySelector('#cloudmin-image-custom-note').hidden"), type === 'download');
            assert.equal(await evaluate("document.querySelector('#cloudmin-custom-options').hidden"), type === 'download');
            assert.equal(await evaluate("document.querySelector('#cloudmin-download-total').hidden"), type !== 'download');
        }
        // Submit a real File through both native and jQuery event paths.
        await evaluate(`{ selectSource('upload');
            const file = new DataTransfer();
            file.items.add(new File(['fixture'], 'fixture.qcow2'));
            document.querySelector('[name=image_file]').files = file.files;
            const form = document.querySelector('#cloudmin-image-form');
            ${visit === 'history' ? "jQuery(form).trigger('submit');" : "form.dispatchEvent(new Event('submit', {bubbles:true, cancelable:true}));"}
        }`);
        assert.equal(await evaluate("document.querySelector('#cloudmin-image-error').textContent"), 'Fixture upload reached');
    }
    assert.equal(await evaluate('submissions'), 3, 'One upload handler per form');
    // A delegated click handler must receive successful upload navigation.
    await evaluate(`window.uploadNavigation = [];
        document.addEventListener('click', event => {
            const link = event.target.closest('a');
            if (!link || !link.href.includes('setup_image.cgi?job=')) return;
            event.preventDefault();
            uploadNavigation.push(link.getAttribute('href'));
        });
        window.fetch = async () => ({ok:true, json:async () => ({id:'fixture-job', state:'waiting'})});
        window.XMLHttpRequest = class {
            upload = {};
            open() {}
            setRequestHeader() {}
            send(file) {
                if (!(file instanceof File)) throw new Error('Upload did not send a File');
                this.status = 200;
                this.responseText = '{"ok":1}';
                window.finishUpload = () => this.onload();
            }
        };
        document.querySelector('#cloudmin-image-form').dispatchEvent(new Event('submit', {bubbles:true, cancelable:true}));`);
    await evaluate('finishUpload()');
    assert.deepEqual(await evaluate('uploadNavigation'), ['setup_image.cgi?job=fixture-job']);
    assert.equal(await evaluate('document.querySelectorAll("a[href*=setup_image]").length'), 0,
        'Temporary navigation link is removed');
    // A late completion cannot navigate away from a replacement page.
    await evaluate(`document.querySelector('#cloudmin-image-submit').disabled = false;
        document.querySelector('#cloudmin-image-form').dispatchEvent(new Event('submit', {bubbles:true, cancelable:true}));`);
    await evaluate(`document.querySelector('#content').replaceChildren(); finishUpload();`);
    assert.deepEqual(await evaluate('uploadNavigation'), ['setup_image.cgi?job=fixture-job']);
    console.log('PASS: download estimates, unknown sizes, refresh, uploads, navigation and history');
} finally {
    clearTimeout(timeout);
    chrome.kill();
}
