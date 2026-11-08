/* initImageClient() installs upload, estimate and import-progress handlers. */
(() => {
    // Navigation can execute this script again on an existing document.
    if (window.cloudminImagesInit) {
        window.cloudminImagesInit();
        return;
    }
    // Track DOM objects so restored HTML receives fresh event handlers.
    const initialized = new WeakSet();

    // initImages() binds the current form once, including replaced
    // form elements.
    function initImages() {
        const form = document.getElementById('cloudmin-image-form');
        // Ignore other pages and forms whose handlers are already attached.
        if (!form || initialized.has(form)) return;
        initialized.add(form);
        const labels = document.getElementById('cloudmin-image-labels').dataset;
        const source = form.elements.install_type;
        const format = form.elements.format;
        const button = document.getElementById('cloudmin-image-submit');
        const error = document.getElementById('cloudmin-image-error');
        const progress = document.getElementById('cloudmin-upload-progress');
        const total = document.getElementById('cloudmin-download-total');
        const choices = total
            ? [...form.querySelectorAll('[data-download-id]')]
            : [];

        // Replace each group dot with its bundled logo, keeping the
        // heading text.
        for (const row of choices) {
            const heading = row.previousElementSibling;
            // Only the first image in each distribution follows a heading.
            if (!heading?.matches('[data-ui-multi-heading]')) continue;
            // The heading names the OS, so its fixed-size logo is decorative.
            const icon = document.createElement('img');
            icon.src = row.dataset.imageIcon;
            icon.alt = '';
            icon.width = icon.height = 16;
            icon.style.cssText =
                'width:16px;height:16px;object-fit:contain;flex-shrink:0';
            heading.querySelector('.ui_svg_icon')?.replaceWith(icon);
        }

        // formatBytes(bytes) keeps estimates compact and consistent with
        // Webmin units.
        function formatBytes(bytes) {
            const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
            let unit = 0;
            while (bytes >= 1024 && unit < units.length - 1) {
                bytes /= 1024;
                unit++;
            }
            return (
                new Intl.NumberFormat(undefined, {
                    maximumFractionDigits: 2
                }).format(bytes) +
                ' ' +
                units[unit]
            );
        }

        // updateEstimate() sums checked rows, including those hidden
        // by filtering.
        function updateEstimate() {
            // Views without download estimates have nothing to total.
            if (!total) return;
            const selected = choices.filter(
                row => row.querySelector('[data-ui-multi-item]').checked
            );
            total.hidden = source.value !== 'download' || !selected.length;
            const known = selected.filter(
                row => Number(row.dataset.downloadBytes) > 0
            );
            const bytes = known.reduce(
                (sum, row) => sum + Number(row.dataset.downloadBytes),
                0
            );
            total.textContent = !known.length
                ? labels.downloadUnknown
                : (known.length === selected.length
                      ? labels.downloadEstimate
                      : labels.downloadPartial
                  ).replace('$1', formatBytes(bytes));
        }

        // refreshSizes() fetches only stale estimates, with three requests at
        // a time.
        async function refreshSizes() {
            const queue = choices.filter(
                row => row.dataset.downloadRefresh === '1'
            );
            // next() consumes the shared queue until navigation removes
            // this form.
            async function next() {
                while (queue.length && form.isConnected) {
                    const row = queue.shift();
                    const controller = new AbortController();
                    const timeout = setTimeout(() => controller.abort(), 20000);
                    try {
                        const response = await fetch(
                            'image-size.cgi?id=' +
                                encodeURIComponent(row.dataset.downloadId),
                            {signal: controller.signal}
                        );
                        const result = await responseJSON(response);
                        // A completed request must not update a replaced page.
                        if (!form.isConnected) return;
                        if (
                            Number.isSafeInteger(result.bytes) &&
                            result.bytes > 0
                        ) {
                            // Only a valid size replaces the existing estimate
                            // and filter text.
                            row.dataset.downloadBytes = result.bytes;
                            const size = row.querySelector(
                                '.ui_multi_meta > span'
                            );
                            const previous = size.textContent;
                            size.textContent = formatBytes(result.bytes);
                            row.dataset.uiMultiText =
                                row.dataset.uiMultiText.replace(
                                    previous,
                                    size.textContent
                                );
                            updateEstimate();
                        }
                    } catch (problem) {
                        // Retain the last estimate when the publisher cannot
                        // be reached.
                    } finally {
                        clearTimeout(timeout);
                    }
                }
            }
            await Promise.all([next(), next(), next()]);
        }

        // updateFormat() describes the selected disk format or installer media.
        function updateFormat() {
            document.getElementById('cloudmin-image-custom-note').textContent =
                format.value === 'iso'
                    ? labels.isoNote
                    : labels.customNote.replace(
                          '$1',
                          format.value === 'raw' ? labels.formatRaw : 'QCOW2'
                      );
        }

        // updateSource() keeps custom format options out of
        // catalogue downloads.
        function updateSource() {
            const download =
                source.value === 'download' || source.value === 'url';
            if (button) {
                // Both input and button submit controls are supported by
                // Webmin themes.
                button.value = download ? labels.download : labels.import;
                // A button displays its child text rather than its
                // value attribute.
                if (button.tagName === 'BUTTON')
                    button.textContent = button.value;
            }
            document.getElementById('cloudmin-custom-options').hidden =
                source.value === 'download';
            document.getElementById('cloudmin-image-note').hidden =
                source.value !== 'download';
            document.getElementById('cloudmin-image-custom-note').hidden =
                source.value === 'download';
            form.elements.url.required = source.value === 'url';
            form.elements.path.required = source.value === 'local';
            form.elements.image_file.required = source.value === 'upload';
            updateFormat();
            updateEstimate();
        }

        // responseJSON(response) reports expired sessions and
        // server-side errors.
        async function responseJSON(response) {
            // HTTP failures may contain a login page rather than an
            // API response.
            if (!response.ok) throw new Error(labels.startError);
            let result;
            try {
                result = await response.json();
            } catch (problem) {
                // A login or Webmin error page in place of JSON means the
                // request was refused.
                throw new Error(labels.startError);
            }
            // Application failures use an error field even with a successful
            // HTTP status.
            if (!result || typeof result !== 'object' || Array.isArray(result))
                throw new Error(labels.startError);
            if (result.error)
                throw Object.assign(new Error(result.error), {
                    retryToken: result.retry_token
                });
            return result;
        }

        // upload(id, file) streams a selected File to an already-created
        // upload job.
        function upload(id, file) {
            // executor(resolve, reject) waits for the upload response
            // or a network error.
            return new Promise((resolve, reject) => {
                const xhr = new XMLHttpRequest();
                xhr.open('POST', 'image-upload.cgi?job=' + id);
                xhr.setRequestHeader(
                    'X-Cloudmin-Token',
                    form.elements.token.value
                );
                xhr.setRequestHeader(
                    'Content-Type',
                    'application/octet-stream'
                );
                // onprogress(event) shows bytes sent by the browser, before
                // server processing.
                xhr.upload.onprogress = event => {
                    // Percentages require a known request length.
                    if (!event.lengthComputable) return;
                    const percent = Math.round(
                        (100 * event.loaded) / event.total
                    );
                    progress
                        .querySelector('.ui_progress')
                        .setAttribute('aria-valuenow', percent);
                    progress.querySelector('.ui_progress_bar').style.width =
                        percent + '%';
                    progress.querySelector('.ui_progress_value').textContent =
                        percent + '%';
                };
                // onload() accepts completion only when the server also
                // reports success.
                xhr.onload = () => {
                    let result;
                    try {
                        result = JSON.parse(xhr.responseText);
                    } catch (problem) {
                        // An HTML error page instead of JSON means the upload
                        // was refused.
                        return reject(new Error(labels.startError));
                    }
                    // HTTP or application errors must not advance to the
                    // progress page.
                    if (
                        !result ||
                        typeof result !== 'object' ||
                        Array.isArray(result)
                    )
                        return reject(new Error(labels.startError));
                    if (xhr.status !== 200 || result.error)
                        return reject(
                            Object.assign(
                                new Error(result.error || labels.startError),
                                {retryToken: result.retry_token}
                            )
                        );
                    resolve();
                };
                // onerror() reports transport failures without a server
                // response body.
                xhr.onerror = () => reject(new Error(labels.startError));
                xhr.send(file);
            });
        }

        // submitUpload(event) uploads files unless the native form is required.
        async function submitUpload(event) {
            // Submit other sources normally; use the same path for
            // license errors.
            if (source.value !== 'upload' || form.cloudminNativeSubmit) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            // Avoid duplicate transfers and honor native field
            // validation first.
            if (!button || button.disabled || !form.reportValidity()) return;
            error.hidden = true;
            const file = form.elements.image_file.files[0];
            try {
                // Reject unusable files before creating a durable waiting job.
                const maximum = Number(labels.maxBytes || 0);
                if (!file || !file.size || (maximum && file.size > maximum))
                    throw new Error(
                        file ? labels.uploadLimit : labels.chooseFile
                    );
                button.disabled = true;
                const fields = new URLSearchParams({
                    ajax: '1',
                    token: form.elements.token.value,
                    install_type: 'upload',
                    image_attempts: form.elements.image_attempts?.value || '',
                    pool: form.elements.pool.value,
                    filename: file.name,
                    format: form.elements.format.value,
                    sha256: form.elements.sha256.value
                });
                const job = await responseJSON(
                    await fetch('image.cgi', {
                        method: 'POST',
                        credentials: 'same-origin',
                        body: fields
                    })
                );
                progress.hidden = false;
                // An idempotent retry may already have a completed upload body.
                if (job.state === 'waiting') await upload(job.id, file);
                // Follow a normal link through the page's navigation handlers.
                // An upload finishing after navigation must not replace the
                // new page.
                if (!form.isConnected) return;
                const link = document.createElement('a');
                link.href = 'setup_image.cgi?job=' + job.id;
                link.hidden = true;
                form.append(link);
                link.click();
                link.remove();
            } catch (problem) {
                // Legacy uploads rotate tokens only after a confirmed failure.
                if (problem.retryToken && !form.elements.image_attempts?.value)
                    form.elements.token.value = problem.retryToken;
                // Attempt-aware forms must pass the shared check
                // before retrying.
                window.cloudminSubmissionFinished?.(form);
                error.textContent = problem.message || labels.startError;
                error.hidden = false;
                button.disabled = false;
            }
        }

        // Retain row references because DataTables can detach paginated rows.
        const cells = Array.from(
            document.querySelectorAll('[data-image-state]')
        );
        let active = cells
            .filter(cell => cell.dataset.imageActive === '1')
            .map(cell => cell.dataset.imageState);
        // refreshImages() updates existing rows without losing checks
        // or pagination.
        async function refreshImages() {
            // End polling after navigation or when every tracked job
            // has finished.
            if (!form.isConnected || !active.length) return;
            try {
                const result = await responseJSON(
                    await fetch(
                        'image-status.cgi?batch=1&job=' +
                            active.slice(0, 100).join(','),
                        {credentials: 'same-origin', cache: 'no-store'}
                    )
                );
                for (const status of result.jobs) {
                    const cell = cells.find(
                        item => item.dataset.imageState === status.id
                    );
                    // Ignore results for rows that are no longer
                    // represented here.
                    if (!cell) continue;
                    cell.textContent =
                        status.label +
                        (status.percent != null && !status.terminal
                            ? ' (' + status.percent + '%)'
                            : '');
                    cell.title = status.detail;
                    // Paging may detach a row from document, so query within
                    // the row.
                    const row = cell.closest('tr');
                    const failure = row.querySelector('[data-image-error]');
                    failure.hidden = !['failed', 'interrupted'].includes(
                        status.state
                    );
                    failure.textContent = failure.hidden ? '' : status.detail;
                    const table =
                        cell.closest('table') ||
                        document.querySelector('table[data-sortable="1"]');
                    const size = row.querySelector('[data-image-size]');
                    if (size) {
                        // Update text and sort data only when the size column
                        // is shown.
                        size.textContent = status.size;
                        size.setAttribute('data-filesize-bytes', status.bytes);
                        size.closest('td').setAttribute(
                            'data-order',
                            status.bytes
                        );
                    }
                    // The checksum column is optional; polling still tracks
                    // the job.
                    const checksum = row.querySelector('[data-image-checksum]');
                    if (checksum) checksum.textContent = status.checksum;
                    const dataTable = window.jQuery?.fn?.dataTable?.isDataTable(
                        table
                    )
                        ? window.jQuery(table).DataTable()
                        : null;
                    if (status.state === 'deleted') {
                        // Remove through DataTables when initialized,
                        // preserving its index.
                        if (dataTable) dataTable.row(row).remove().draw(false);
                        // Plain tables have no separate row index to maintain.
                        else row.remove();
                        // Refresh the cached sort and filter values after
                        // changing cell text.
                    } else if (dataTable) dataTable.row(row).invalidate('dom');
                }
                active = active.filter(
                    id => !result.jobs.some(s => s.id === id && s.terminal)
                );
            } catch (problem) {
                // Keep the user's selections intact during a
                // temporary disconnect.
            }
            // Retry transient polling failures while any import remains active.
            if (active.length) setTimeout(refreshImages, 2000);
        }

        form.addEventListener('submit', submitUpload, true);
        source.addEventListener('change', updateSource);
        format.addEventListener('change', updateFormat);
        form.addEventListener('change', updateEstimate);
        if (window.jQuery) {
            // Theme scripts can trigger jQuery events without dispatching
            // native events.
            window.jQuery(form).on('submit.cloudminImages', submitUpload);
            // selectionChanged(event) bridges synthetic selector changes.
            window
                .jQuery([source, format])
                .on('change.cloudminImages', event => {
                    // Native changes already reached the form; bridge only
                    // synthetic ones.
                    if (!event.originalEvent)
                        event.target.dispatchEvent(
                            new Event('change', {bubbles: true})
                        );
                });
        }
        updateSource();
        // Size probes are needed only for catalogue download choices.
        if (choices.length) refreshSizes();
        // Resume polling jobs already active when the page was opened.
        if (active.length) setTimeout(refreshImages, 2000);
    }

    // Themes can initialize replacement forms without loading this
    // script again.
    window.cloudminImagesInit = initImages;
    window.addEventListener('pageshow', initImages);
    // Initialize immediately only after the initial document has been parsed.
    if (document.readyState === 'loading')
        document.addEventListener('DOMContentLoaded', initImages);
    // Deferred script loading may run after DOMContentLoaded already fired.
    else initImages();
})();
