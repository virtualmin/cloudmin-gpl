/* Confirm SSH host identity before submitting backup and restore forms. */
(() => {
    // Navigation may load this script repeatedly.
    if (window.cloudminBackupHostReady) return;
    window.cloudminBackupHostReady = true;
    let states = new WeakMap();
    // pageshow() clears prompts and ignores old replies, preserving tokens.
    window.addEventListener('pageshow', () => {
        states = new WeakMap();
        document
            .querySelectorAll('[data-backup-host-confirm]')
            .forEach(panel => panel.remove());
    });

    // destination(form) returns an SSH address or saved archive ID, or null.
    function destination(form) {
        const fields = new FormData(form);
        // Listed archives resolve their destination from the private
        // server record.
        if (fields.get('backup')) return {backup: fields.get('backup')};
        const prefix = fields.has('src_mode') ? 'src' : 'dest0';
        // Local and cloud destinations need no SSH trust check.
        if (fields.get(prefix + '_mode') !== 'ssh') return null;
        return {
            host: fields.get(prefix + '_ssh_host') || '',
            port:
                fields.get(prefix + '_ssh_port_def') === '1'
                    ? '22'
                    : fields.get(prefix + '_ssh_port') || '22'
        };
    }

    // submit(event) intercepts SSH and saved-archive forms for trust checks.
    async function submit(event) {
        const form = event.target;
        // Only form submissions can supply destination fields and a token.
        if (!(form instanceof HTMLFormElement)) return;
        const url = new URL(form.getAttribute('action'), document.baseURI);
        // Leave other actions and schedule deletion to their form handlers.
        if (
            !/\/(backup|backup_sched|restore)\.cgi$/.test(url.pathname) ||
            event.submitter?.name === 'delete'
        )
            return;
        const target = destination(form);
        // Let ordinary non-SSH submissions reach the existing form handler.
        if (!target) return;
        let state = states.get(form);
        // Permit the one resubmission to the server-side form handler.
        if (state?.forward) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        // Suppress duplicate probes while keeping normal form validation.
        if (state?.busy || !form.reportValidity()) return;
        // Keep this check tied to the current destination.
        form.querySelector('[data-backup-host-confirm]')?.remove();
        let panel;
        const identity = JSON.stringify(target);
        state = {busy: true};
        states.set(form, state);

        // request(action, [extra]) checks trust or approves reviewed keys.
        // Both requests use the form's existing signed token.
        async function request(action, extra = {}) {
            const response = await fetch(new URL('backup-host-key.cgi', url), {
                method: 'POST',
                credentials: 'same-origin',
                cache: 'no-store',
                body: new URLSearchParams({
                    ...target,
                    token: form.elements.token.value,
                    action,
                    ...extra
                }),
                signal: AbortSignal.timeout(45000)
            });
            // Failed probes fall back to the form handler's validation and
            // error page. The handler independently requires trusted keys.
            if (!response.ok)
                throw new Error(
                    'Could not check the SSH server. Please try again.'
                );
            const result = await response.json();
            // Let the form handler report validation errors.
            if (result.error) throw new Error(result.error);
            // Discard these replies after navigation or browser Back.
            if (!form.isConnected || states.get(form) !== state)
                throw new Error('The form was closed.');
            // Let the form handler revalidate edits made during the check.
            if (JSON.stringify(destination(form)) !== identity)
                throw new Error(
                    'The destination changed. Submit the form again to check it.'
                );
            return result;
        }

        // forward() lets the form handler validate input and SSH trust, using
        // error() for failures so browser Back can restore the original form.
        function forward() {
            panel?.remove();
            state.busy = false;
            // A late reply must not submit an abandoned or restored form.
            if (!form.isConnected || states.get(form) !== state) return;
            // Bypass this listener only during the synchronous resubmission.
            state.forward = true;
            try {
                form.requestSubmit(event.submitter || undefined);
            } finally {
                state.forward = false;
            }
        }
        try {
            const result = await request('check');
            // Existing matching trust needs no further confirmation.
            if (result.status === 'trusted') {
                forward();
                return;
            }
            // Malformed approval replies fall back to server validation.
            if (!['unknown', 'changed'].includes(result.status) || !result.html)
                throw new Error('Invalid SSH host check response.');
            // The server escapes the host and fingerprints in this card.
            panel = document.createElement('div');
            panel.dataset.backupHostConfirm = '1';
            panel.innerHTML = result.html;
            form.append(panel);
            panel.scrollIntoView({block: 'nearest'});
            // cancel() dismisses the prompt without persisting any trust.
            panel.querySelector('[data-backup-host-cancel]').onclick = () => {
                state.busy = false;
                panel.remove();
            };
            // trust(event) binds approval to the displayed old and
            // candidate keys.
            panel.querySelector('[data-backup-host-trust]').onclick =
                async event => {
                    event.currentTarget.disabled = true;
                    try {
                        // Do not save approval if the destination changed
                        // while reviewing.
                        if (JSON.stringify(destination(form)) !== identity)
                            throw new Error(
                                'The destination changed. Submit the form again to check it.'
                            );
                        const accepted = await request('trust', {
                            previous: result.previous,
                            proposed: result.proposed
                        });
                        // Unexpected approval replies use server validation.
                        if (accepted.status !== 'trusted')
                            throw new Error('SSH host approval failed.');
                        forward();
                        // The form handler checks trust again if
                        // approval fails.
                    } catch (error) {
                        forward();
                    }
                };
            // Probe errors reach the form handler, which still checks
            // SSH trust.
        } catch (error) {
            forward();
        }
    }
    // Capture before the theme or progress handler starts the original request.
    document.addEventListener('submit', submit, true);
})();
