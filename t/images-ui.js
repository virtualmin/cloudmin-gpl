// Exercise source switching and direct submission without a running browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const sourceCode = fs.readFileSync(
    require('node:path').join(__dirname, '../images.js'),
    'utf8'
);

// harness(type, [failure], [status], [responses]) supplies the DOM and network
// APIs in use. failure rejects job submission; status supplies one import
// polling result.
function harness(type, failure = false, status = null, responses = {}) {
    const listeners = {};
    const nodes = {};
    // element([value]) creates a control; addEventListener(name, handler)
    // records it.
    const element = (value = '') => ({
        value,
        hidden: false,
        disabled: false,
        dataset: {},
        addEventListener(name, handler) {
            listeners[value + ':' + name] = handler;
        }
    });
    const form = element('form');
    form.isConnected = true;
    // reportValidity() bypasses native validation, which the browser
    // fixture covers.
    form.reportValidity = () => true;
    form.elements = {};
    // Give each submitted field a distinct value to catch mixed-up field names.
    for (const name of [
        'token',
        'pool',
        'id',
        'format',
        'sha256',
        'url',
        'path',
        'image_file'
    ]) {
        form.elements[name] = element(name);
    }
    form.elements.install_type = element(type);
    form.elements.image_file.files = [{name: 'upload.qcow2', size: 8192}];
    // Supply the fixed page IDs and translated labels expected by images.js.
    nodes['cloudmin-image-form'] = form;
    nodes['cloudmin-image-labels'] = {
        dataset: {
            download: 'Download image',
            import: 'Import image',
            customNote: 'Import a standalone $1 disk image.',
            isoNote: 'Import an installer ISO.',
            formatRaw: 'Raw',
            maxBytes: String(responses.maxBytes || 0),
            uploadLimit: 'Image exceeds limit',
            uploading: 'Uploading',
            startError: 'Import error',
            pollError: 'Retrying'
        }
    };
    for (const id of ['submit', 'error', 'note', 'custom-note'])
        nodes['cloudmin-image-' + id] = element();
    nodes['cloudmin-upload-progress'] = element();
    nodes['cloudmin-custom-options'] = element();
    // querySelector() supplies progress nodes whose attribute methods
    // are no-ops.
    nodes['cloudmin-upload-progress'].querySelector = () => ({
        classList: {toggle() {}},
        setAttribute() {},
        removeAttribute() {},
        style: {}
    });
    const calls = [];
    const timers = [];
    // Polling mutates these detached row objects, as it does with paginated
    // tables. size.closest() supplies a cell; setAttribute() ignores
    // display-only metadata.
    const size = {setAttribute() {}, closest: () => ({setAttribute() {}})};
    // checksum.querySelector() returns details; innerHTML reads or
    // replaces them.
    const checksum = {
        detail: {open: true},
        querySelector() {
            return this.detail;
        },
        set innerHTML(value) {
            this.html = value;
            this.detail = {open: false};
        },
        get innerHTML() {
            return this.html;
        }
    };
    const failureDetails = {hidden: true, textContent: ''};
    const rowCells = {
        '[data-image-size]': size,
        '[data-image-checksum]': checksum,
        '[data-image-error]': failureDetails
    };
    // row.querySelector(selector) resolves cells; remove() records
    // row deletion.
    const row = {
        selected: true,
        querySelector: selector => rowCells[selector],
        remove() {
            this.removed = true;
        }
    };
    const state = {
        dataset: {imageState: 'test-job', imageActive: '1'},
        // closest(tag) resolves the containing row without needing an
        // actual DOM.
        closest: tag => (tag === 'tr' ? row : null)
    };
    const navigation = [];
    const location = {
        set href(value) {
            assert.fail('Direct navigation bypasses SPA themes');
        }
    };
    // Attached anchors must bubble their click to the theme's
    // navigation handler.
    form.append = link => {
        link.parent = form;
    };
    // Document lookups resolve fixture objects; window listeners need
    // no dispatch.
    const sandbox = {
        document: {
            getElementById: id => nodes[id],
            querySelectorAll: () => (status ? [state] : []),
            querySelector: () => null,
            createElement(tag) {
                assert.equal(tag, 'a');
                return {
                    click() {
                        assert.equal(this.parent, form);
                        assert.equal(form.isConnected, true);
                        navigation.push(this.href);
                    },
                    remove() {
                        this.parent = null;
                    }
                };
            }
        },
        window: {location, addEventListener() {}},
        // setTimeout(callback) records polling so the test can advance
        // it explicitly.
        URLSearchParams,
        setTimeout(callback) {
            timers.push(callback);
        },
        // fetch(url, options) records submissions or supplies the chosen
        // job status.
        fetch: async (url, options) => {
            calls.push({url, options});
            return {
                ok: true,
                json: async () => {
                    // A supplied response exercises parsing beyond the
                    // default job.
                    if ('json' in responses) return JSON.parse(responses.json);
                    return failure
                        ? {error: 'Select an OS'}
                        : url === 'image.cgi'
                          ? {
                                id: 'test-job',
                                state: type === 'upload' ? 'waiting' : 'queued'
                            }
                          : {jobs: [status]};
                }
            };
        },
        XMLHttpRequest: class {
            upload = {};
            // open(method, url) records the destination; headers are
            // irrelevant here.
            open(method, url) {
                calls.push({method, url});
            }
            // setRequestHeader() accepts the production upload
            // headers unchanged.
            setRequestHeader() {}
            // send(file) immediately emits a complete, successful
            // fixture upload.
            send(file) {
                assert.equal(file.name, 'upload.qcow2');
                this.upload.onprogress({
                    lengthComputable: true,
                    loaded: 8192,
                    total: 8192
                });
                this.status = responses.status || 200;
                this.responseText = responses.upload ?? '{"ok":1}';
                // Browser load handlers run after send() has returned.
                queueMicrotask(() => this.onload());
            }
        }
    };
    // Load the actual script into the isolated DOM and expose its submit
    // listener. submit() supplies no-op event cancellation methods to the
    // real handler.
    vm.runInNewContext(sourceCode, sandbox);
    return {
        nodes,
        form,
        calls,
        navigation,
        timers,
        state,
        size,
        checksum,
        row,
        failureDetails,
        submit: () =>
            listeners['form:submit']({
                preventDefault() {},
                stopImmediatePropagation() {}
            })
    };
}

// Downloads and local imports must not be intercepted by custom AJAX code.
(async () => {
    // Browser validation follows the configured cap rather than a fixed 8 GiB.
    for (const maximum of [0, 8 * 1024 ** 3, 16 * 1024 ** 3]) {
        const test = harness('upload', false, null, {maxBytes: maximum});
        test.form.elements.image_file.files[0].size = 9 * 1024 ** 3;
        await test.submit();
        // Configured upload limits must stop submission before creating a job.
        if (maximum && maximum < 9 * 1024 ** 3) {
            assert.equal(
                test.calls.length,
                0,
                'Oversized uploads fail before job creation'
            );
            assert.equal(
                test.nodes['cloudmin-image-error'].textContent,
                'Image exceeds limit'
            );
        } else {
            // Accepted uploads proceed to job progress.
            assert.deepEqual(test.navigation, ['setup_image.cgi?job=test-job']);
        }
    }
    for (const type of ['download', 'url', 'upload', 'local']) {
        const test = harness(type);
        const action = ['download', 'url'].includes(type)
            ? 'Download image'
            : 'Import image';
        assert.equal(test.nodes['cloudmin-image-submit'].value, action);
        assert.equal(
            test.nodes['cloudmin-custom-options'].hidden,
            type === 'download'
        );
        assert.equal(
            test.nodes['cloudmin-image-note'].hidden,
            type !== 'download'
        );
        assert.equal(
            test.nodes['cloudmin-image-custom-note'].hidden,
            type === 'download'
        );
        await test.submit();
        // Non-upload sources must leave submission to the native Webmin form.
        if (type !== 'upload') {
            assert.equal(
                test.calls.length,
                0,
                'Native Webmin progress form remains in charge'
            );
            continue;
        }
        const body = test.calls[0].options.body;
        assert.equal(body.get('install_type'), type);
        assert.equal(test.calls[0].options.method, 'POST');
        assert.deepEqual(test.navigation, ['setup_image.cgi?job=test-job']);
        // Upload submission must send the file after creating its waiting job.
        if (type === 'upload')
            assert(
                test.calls.some(
                    call => call.url === 'image-upload.cgi?job=test-job'
                )
            );
    }
    // A completed transfer must leave a later page alone.
    const departed = harness('upload');
    const pending = departed.submit();
    departed.form.isConnected = false;
    await pending;
    assert.deepEqual(departed.navigation, []);
    const rejected = harness('upload', true);
    await rejected.submit();
    assert.equal(
        rejected.nodes['cloudmin-image-error'].textContent,
        'Select an OS'
    );
    assert.equal(rejected.nodes['cloudmin-image-submit'].disabled, false);
    assert.deepEqual(rejected.navigation, []);
    assert.equal(
        rejected.form.elements.token.value,
        'token',
        'Uncertain submissions retain their token'
    );
    // A blocked license reaches the normal POST without creating an AJAX job.
    const unlicensed = harness('upload');
    unlicensed.form.cloudminNativeSubmit = true;
    await unlicensed.submit();
    assert.equal(
        unlicensed.calls.length,
        0,
        'License refusal uses the native form error page'
    );
    assert.deepEqual(unlicensed.navigation, []);
    for (const field of ['json', 'upload']) {
        const retry = harness('upload', false, null, {
            [field]: JSON.stringify({
                error: 'Attempt failed',
                retry_token: 'next-token'
            })
        });
        await retry.submit();
        assert.equal(
            retry.form.elements.token.value,
            'next-token',
            'Confirmed failure gets a fresh attempt'
        );
        assert.deepEqual(retry.navigation, []);
    }
    // Malformed or non-object replies must end the upload and restore
    // the button.
    for (const field of ['json', 'upload']) {
        for (const reply of [
            '<html>login</html>',
            'null',
            '[]',
            '"unexpected"'
        ]) {
            const test = harness('upload', false, null, {[field]: reply});
            await test.submit();
            assert.equal(
                test.nodes['cloudmin-image-error'].textContent,
                'Import error'
            );
            assert.equal(test.nodes['cloudmin-image-submit'].disabled, false);
            assert.deepEqual(test.navigation, []);
        }
    }
    const updating = harness('download', false, {
        id: 'test-job',
        state: 'downloading',
        label: 'Downloading',
        percent: 50,
        bytes: 1024,
        size: '1 KiB',
        checksum: 'Not verified'
    });
    await updating.timers.shift()();
    assert.equal(updating.state.textContent, 'Downloading (50%)');
    assert.equal(updating.size.textContent, '1 KiB');
    assert.equal(
        updating.row.selected,
        true,
        'Progress refresh preserves the selection'
    );
    // Polling must retain errors and progress when optional columns are absent.
    const compact = harness('download', false, {
        id: 'test-job',
        state: 'failed',
        label: 'Failed',
        terminal: 1,
        detail: 'Checksum mismatch'
    });
    // querySelector(selector) models a row with only its required error field.
    compact.row.querySelector = selector =>
        selector === '[data-image-error]' ? compact.failureDetails : null;
    await compact.timers.shift()();
    assert.equal(
        compact.state.textContent,
        'Failed',
        'hidden size and checksum do not break polling'
    );
    assert.equal(
        compact.failureDetails.textContent,
        'Checksum mismatch',
        'compact tables retain errors'
    );
    const verified = harness('download', false, {
        id: 'test-job',
        state: 'ready',
        terminal: 1,
        label: 'Ready',
        checksum: 'Passed',
        checksum_html: 'Passed',
        bytes: 1024,
        size: '1 KiB'
    });
    await verified.timers.shift()();
    assert.equal(
        verified.checksum.textContent,
        'Passed',
        'Polling shows a plain checksum result'
    );
    for (const state of ['ready', 'failed', 'interrupted']) {
        const finished = harness('download', false, {
            id: 'test-job',
            state,
            terminal: 1,
            label: state,
            detail: 'Checksum <mismatch>',
            bytes: 1024,
            size: '1 KiB'
        });
        await finished.timers.shift()();
        assert.equal(finished.failureDetails.hidden, state === 'ready');
        // Failed imports must expose their diagnostic text without
        // clearing selection.
        if (state !== 'ready')
            assert.equal(
                finished.failureDetails.textContent,
                'Checksum <mismatch>'
            );
        assert.equal(finished.row.selected, true);
    }
    const deleted = harness('download', false, {
        id: 'test-job',
        state: 'deleted',
        label: 'Deleted',
        terminal: 1,
        bytes: 0,
        size: '0 B',
        checksum: 'Not verified'
    });
    await deleted.timers.shift()();
    assert.equal(deleted.row.removed, true);
    assert.equal(deleted.timers.length, 0, 'Terminal jobs stop polling');
    console.log(
        'PASS: native download forms, upload progress, progress-page navigation, and inline errors'
    );
})().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
