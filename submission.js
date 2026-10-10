/* Initialize submission guards for browser and theme navigation. */
(() => {
    // Navigation can reload this script without replacing the document.
    if (window.cloudminSubmissionReady) return;
    window.cloudminSubmissionReady = true;
    // Busy flags belong to live forms; attempt history survives navigation.
    let states = new WeakMap();
    const memory = new Map();
    const submitting = new Set();
    const blocked = new WeakSet();
    const operations = /^(create|clone|capture_image|update|delete|delete_disk|power_cycle|snapshot_create|snapshot_restore|snapshot_delete)$/;

    // cloudminSubmissionFinished(form) releases upload and theme submit guards.
    window.cloudminSubmissionFinished = form => { states.delete(form); submitting.delete(form); };
    // pageshow() clears busy flags restored by browser history, retaining IDs.
    window.addEventListener('pageshow', () => { states = new WeakMap(); submitting.clear(); });
    // ajaxComplete(event, xhr, settings) releases completed theme submissions.
    if (window.jQuery) window.jQuery(document).on('ajaxComplete.cloudminSubmission', (_event, _xhr, settings) => {
        // Background refreshes must not unlock a form that is still submitting.
        if (settings.type?.toUpperCase() !== 'POST') return;
        const path = new URL(settings.url, document.baseURI).pathname;
        for (const form of submitting) {
            // Only the matching submission may release this form's guard.
            if (states.get(form)?.path === path) window.cloudminSubmissionFinished(form);
        }
    });

    // submit(event) checks the previous attempt before submitting the form.
    async function submit(event) {
        const form = event.target;
        // Leave unrelated forms and read-only navigation to their own handlers.
        if (!(form instanceof HTMLFormElement) || form.method.toLowerCase() !== 'post') return;
        // Read the action attribute; a named control can shadow form.action.
        const destination = new URL(form.getAttribute('action'), document.baseURI);
        const path = destination.pathname;
        const image = /\/setup_image\.cgi$/.test(path);
        const operation = form.elements.vm_operation?.value || form.elements.action?.value;
        // Check attempts only for actions that create background jobs.
        if (!image && (!/\/(setup_machine|clone_machine|image_machine|edit_machine|snapshots|machine)\.cgi$/.test(path) || !operations.test(operation))) return;
        const token = form.elements.token?.value;
        // Forms without a signed token cannot participate in attempt checks.
        if (!token) return;
        let state = states.get(form);
        // Allow our forwarded submit through, while suppressing extra clicks.
        if (state?.forward) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        // A created guest stays blocked even after browser history restoration.
        if (blocked.has(form) || state?.busy || !form.reportValidity()) return;
        state = { busy: true, path };
        states.set(form, state);
        submitting.add(form);
        // Keep separate histories for operations sharing one signed form token.
        const field = image ? 'image_attempts' : 'attempt';
        const key = 'cloudmin-submission:' + token + ':' + (image ? 'image' : operation);
        let previous = memory.get(key) || form.elements[field]?.value || '';
        // Session storage holds IDs only, never passwords or form contents.
        try { previous = sessionStorage.getItem(key) || previous; } catch (_) { /* Use this page's memory. */ }
        let error = form.querySelector('[data-submission-error]');
        // Clear an earlier check error before requesting a new decision.
        if (error) error.hidden = true;
        try {
            // Propose an ID locally; the server decides whether to use it.
            const proposed = Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join('');
            const fields = new URLSearchParams({ token, proposed, kind: image ? 'image' : 'vm', operation: operation || '', [field]: previous });
            if (image && form.elements.install_type.value === 'download') {
                // Batch imports advance each failed selection independently.
                fields.set('selection', new FormData(form).getAll('id').join('\n'));
            }
            const response = await fetch(new URL('submission.cgi', destination), {
                method: 'POST', credentials: 'same-origin', body: fields, cache: 'no-store', signal: AbortSignal.timeout(30000)
            });
            // Submit only after the server confirms an attempt ID.
            if (!response.ok) throw new Error('Could not check the previous attempt. Please try again.');
            const result = await response.json();
            // Show the server's reason when it refuses another attempt.
            if (result.error) {
                const problem = new Error(result.error);
                problem.retryable = result.retryable;
                throw problem;
            }
            // Never forward the form without its confirmed attempt data.
            if (typeof result[field] !== 'string' || !result[field]) throw new Error('Invalid submission response. Please reload the form.');
            memory.set(key, result[field]);
            try { sessionStorage.setItem(key, result[field]); } catch (_) { /* History can retain the hidden input. */ }
            // Never submit a page the user left while the check was running.
            if (!form.isConnected) { window.cloudminSubmissionFinished(form); return; }
            let input = form.elements[field];
            if (!input) {
                // Native and theme submissions serialize the same hidden field.
                input = document.createElement('input');
                input.type = 'hidden'; input.name = field;
                form.append(input);
            }
            input.value = result[field];
            // Preserve the button; expose the native override only during dispatch
            // so license refusals reach Webmin's error page on this submission.
            state.forward = true;
            form.cloudminNativeSubmit = !!result.native_submit;
            form.requestSubmit(event.submitter || undefined);
            delete form.cloudminNativeSubmit;
            state.forward = false;
        } catch (problem) {
            // Transient failures permit another check; completed creation does not.
            window.cloudminSubmissionFinished(form);
            // Navigation during a failed check leaves no form to update.
            if (!form.isConnected) return;
            if (!error) {
                // Render server guidance as text without interpreting HTML.
                error = document.createElement('div');
                error.dataset.submissionError = '';
                error.setAttribute('role', 'alert');
                const template = document.getElementById('cloudmin-submission-alert');
                // Use the theme's alert markup when this form supplied it.
                if (template) error.append(template.content.cloneNode(true));
                form.prepend(error);
            }
            const message = error.querySelector('[data-submission-message]') || error;
            message.textContent = problem.message || 'Could not check the previous attempt. Please try again.';
            error.hidden = false;
            if (problem.retryable === 0) {
                // Keep submission blocked until the user opens a fresh form.
                blocked.add(form);
                for (const control of form.elements) {
                    // A hidden submit may have a separate visible button.
                    if (control.type === 'submit' || control.type === 'image' ||
                        control.classList.contains('ui_form_end_submit')) {
                        control.disabled = true;
                        // Hide the footer too, so its spacing does not remain.
                        const container = control.closest('.ui_form_end_buttons') || control;
                        container.hidden = true;
                        container.style.setProperty('display', 'none', 'important');
                    }
                }
            }
            // Bring the explanation into view when submission began below it.
            error.scrollIntoView({ block: 'center' });
        }
    }
    // Capture before the theme or upload handler serializes the form.
    document.addEventListener('submit', submit, true);
})();
