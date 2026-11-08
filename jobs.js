/* initJobsStatus() keeps the jobs view current across theme navigation. */
(() => {
    // Reuse the existing observer when a theme executes this script again.
    if (window.cloudminJobsStatus) {
        window.cloudminJobsStatus.init();
        return;
    }
    let container,
        request,
        timer,
        revision,
        failures = 0;

    // stop() cancels work when this view is hidden or replaced.
    function stop() {
        clearTimeout(timer);
        request?.abort();
        request = undefined;
    }

    // refresh() fetches theme-rendered status without reloading the page
    // or menu.
    async function refresh() {
        // Keep at most one request for a visible, attached view.
        if (!container?.isConnected || document.hidden || request) return;
        const view = container;
        const controller = (request = new AbortController());
        const timeout = setTimeout(() => controller.abort(), 10000);
        try {
            const response = await fetch(view.dataset.url, {
                credentials: 'same-origin',
                cache: 'no-store',
                signal: controller.signal
            });
            // An HTTP error may be an HTML login page, not a status fragment.
            if (!response.ok) throw new Error('Status request failed');
            const result = await response.json();
            // Require both rendered content and its revision before replacing
            // the view.
            if (
                typeof result?.html !== 'string' ||
                typeof result.revision !== 'string'
            ) {
                throw new Error('Invalid status response');
            }
            // Late replies belong only to the still-visible requesting view.
            if (
                request !== controller ||
                container !== view ||
                !view.isConnected
            )
                return;
            const content = view.querySelector('[data-jobs-content]');
            // Preserve animations and text selection when the content
            // is unchanged.
            if (revision !== result.revision) {
                content.innerHTML = result.html;
                revision = result.revision;
            }
            content.hidden = false;
            view.querySelector('[data-jobs-warning]').hidden = true;
            failures = 0;
        } catch (error) {
            // An expired session or network failure must not appear as an
            // idle host.
            if (
                request !== controller ||
                container !== view ||
                !view.isConnected
            )
                return;
            view.querySelector('[data-jobs-content]').hidden = true;
            view.querySelector('[data-jobs-warning]').hidden = false;
            failures++;
        } finally {
            clearTimeout(timeout);
            // A superseded request cannot clear or reschedule its replacement.
            if (request === controller) {
                request = undefined;
                // Poll serially, backing off on failure and pausing in
                // hidden tabs.
                if (view.isConnected && !document.hidden) {
                    timer = setTimeout(
                        refresh,
                        Math.min(30000, 2000 * 2 ** Math.min(failures, 4))
                    );
                }
            }
        }
    }

    // init() attaches one refresh loop to the current page, including
    // restored views.
    function init() {
        const next = document.getElementById('cloudmin-jobs');
        // Mutation notifications for the same markup need no new polling loop.
        if (next === container) return;
        stop();
        container = next;
        failures = 0;
        revision = undefined;
        if (container) refresh();
    }
    window.cloudminJobsStatus = {init};
    // Hidden pages keep no pending requests; returning obtains a fresh
    // snapshot. visibilitychange(event) resumes polling only when the page
    // is visible.
    document.addEventListener('visibilitychange', () => {
        stop();
        if (!document.hidden) refresh();
    });
    window.addEventListener('pagehide', stop);
    // pageshow(event) refreshes a document restored from the browser cache.
    window.addEventListener('pageshow', () => {
        init();
        refresh();
    });
    new MutationObserver(init).observe(document.documentElement, {
        childList: true,
        subtree: true
    });
    // Wait until the document is parsed before binding the page.
    if (document.readyState === 'loading')
        document.addEventListener('DOMContentLoaded', init);
    // Initialize immediately when theme navigation has already parsed the page.
    else init();
})();
