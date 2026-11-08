// Submit signed SSH forms and watch login attempts across page navigation.
(() => {
    // Stop any previous copy before installing a shared navigation observer.
    window.cloudminSshConnectCleanup?.();
    let current;
    // stopCurrent() stays empty until bind() installs page cleanup.
    let stopCurrent = () => {};
    // bind() handles new page markup even when navigation reuses this script.
    function bind() {
        const marker = document.getElementById('cloudmin-ssh-auto');
        const attempt = document.getElementById('cloudmin-ssh-attempt');
        const next = marker || attempt;
        // Unrelated DOM updates must not submit or poll the same page again.
        if (next === current) return;
        stopCurrent();
        current = next;
        // Pages without SSH controls need neither a timer nor a request.
        if (!next) return;
        let stopped = false;
        let timer;
        const controller = new AbortController();

        // dispose() stops requests after navigation or a replacement SSH page.
        function dispose() {
            stopped = true;
            clearTimeout(timer);
            controller.abort();
        }
        stopCurrent = dispose;

        // poll() checks login outcomes until authentication or failure.
        async function poll() {
            // Detached page nodes cannot update the current page.
            if (stopped || !attempt.isConnected) {
                dispose();
                return;
            }
            try {
                const response = await fetch(attempt.dataset.statusUrl, {
                    credentials: 'same-origin',
                    cache: 'no-store',
                    signal: controller.signal
                });
                // An HTTP error stops checks without declaring login failure.
                if (!response.ok) {
                    dispose();
                    return;
                }
                const result = await response.json();
                // Navigation may have replaced the terminal during the request.
                if (stopped || !attempt.isConnected) {
                    dispose();
                    return;
                }
                if (result.state === 'failed') {
                    // Normal navigation also closes the failed terminal.
                    dispose();
                    attempt.click();
                    return;
                }
                // Stop after success, lost access or a superseded attempt.
                if (result.error || result.state !== 'pending') {
                    dispose();
                    return;
                }
            } catch (error) {
                // Retry a dropped check only while this page remains active.
                if (stopped) return;
            }
            // Check again without starting another SSH connection.
            timer = setTimeout(poll, 1500);
        }

        // start() runs after navigation handlers can intercept form submission.
        function start() {
            // A cancelled startup must not submit another page's form.
            if (stopped) return;
            if (marker?.isConnected) {
                // Consume the trigger before submitting the signed form.
                marker.remove();
                document
                    .querySelector('form[action*="tab=ssh"] [name="connect"]')
                    ?.click();
            } else if (attempt?.isConnected) {
                // Check the launched relay without submitting again.
                poll();
            } else {
                // The scheduled page was removed before startup ran.
                dispose();
            }
        }
        timer = setTimeout(start, 0);
    }

    // Navigation may replace the page without evaluating its scripts again.
    const observer = new MutationObserver(bind);
    observer.observe(document.documentElement, {
        childList: true,
        subtree: true
    });
    // cleanup() removes the shared observer on unload or script replacement.
    function cleanup() {
        observer.disconnect();
        stopCurrent();
        window.removeEventListener('pagehide', cleanup);
    }
    window.cloudminSshConnectCleanup = cleanup;
    window.addEventListener('pagehide', cleanup);
    bind();
})();
