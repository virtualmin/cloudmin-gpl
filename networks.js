/* initNetworkStatus() installs bridge progress and form listeners once. */
(() => {
    'use strict';
    // Reuse listeners when navigation loads this script again.
    if (window.cloudminNetworkStatus) {
        window.cloudminNetworkStatus.init();
        return;
    }
    let view, timer, request;

    // currentTab(page) finds the visible panel in the native tab widget.
    function currentTab(page) {
        return (
            Array.from(page.querySelectorAll('[data-network-tab]')).find(
                tab => tab.getClientRects().length
            )?.dataset.networkTab || 'overview'
        );
    }

    // updateFields(page) keeps DHCP and forwarding controls relevant to
    // the choice.
    function updateFields(page) {
        const form = page.querySelector(
            'input[name=action][value=create]'
        )?.form;
        // Review pages have no network-creation controls to update.
        if (!form) return;
        const isolated =
            form.querySelector('input[name=mode]:checked')?.value ===
            'isolated';
        form.elements.uplink.disabled = isolated;
        // Discard an uplink selection when forwarding is disabled.
        if (isolated) form.elements.uplink.value = '';
        // forEach(input) enables DHCP fields only when DHCP is selected.
        form.querySelectorAll('[data-network-dhcp] input').forEach(input => {
            input.disabled = !form.elements.dhcp.checked;
        });
    }

    // stop() releases polling when a theme replaces the current content.
    function stop() {
        clearTimeout(timer);
        request?.abort();
        request = undefined;
    }

    // reloadPage(page, tab) runs theme setup for newly available forms
    // and tabs.
    async function reloadPage(page, tab) {
        const url = new URL(page.dataset.url, window.location.href);
        url.searchParams.delete('status');
        url.searchParams.set('tab', tab);
        // A theme that loads pages itself initializes the new forms. Use an
        // explicit GET so a previous bridge submission is never repeated.
        const api = typeof theme === 'object' ? theme?.api?.page : undefined;
        if (typeof api?.load === 'function') {
            await api.load(url.href, {history: false, method: 'GET'});
        } else {
            // Other themes initialize their controls on a normal document load.
            window.location.replace(url.href);
            stop();
        }
    }

    // refresh() keeps the confirmation window usable after a brief disconnect.
    async function refresh() {
        const page = view;
        const panel = page?.querySelector('#cloudmin-network-pending');
        // Skip hidden documents, detached pages and overlapping requests.
        if (!page?.isConnected || !panel || request || document.hidden) return;
        const counter = panel.querySelector('#cloudmin-network-countdown');
        // Recovery polls without a countdown. Confirmation uses server time
        // because the browser and host clocks may differ.
        if (counter) {
            panel.cloudminExpires ??=
                performance.now() + Number(panel.dataset.remaining) * 1000;
            counter.textContent = String(
                Math.max(
                    0,
                    Math.ceil(
                        (panel.cloudminExpires - performance.now()) / 1000
                    )
                )
            );
        }
        const controller = (request = new AbortController());
        const tab = currentTab(page);
        // Abort stalled polls so a lost connection cannot block retries.
        const timeout = setTimeout(() => controller.abort(), 5000);
        try {
            const response = await fetch(page.dataset.url, {
                cache: 'no-store',
                credentials: 'same-origin',
                signal: controller.signal
            });
            // Failed requests retain the current display until the next poll.
            if (!response.ok) throw new Error('Status unavailable');
            const result = await response.json();
            // Refresh the countdown using server time after a
            // successful response.
            if (counter && typeof result.remaining === 'number')
                panel.cloudminExpires =
                    performance.now() + result.remaining * 1000;
            // Reload only the page and tab that requested this response. A late
            // response must not navigate away from newer content or a new tab.
            if (
                view === page &&
                page.isConnected &&
                request === controller &&
                currentTab(page) === tab &&
                typeof result.state === 'string' &&
                result.state !== panel.dataset.state
            ) {
                clearTimeout(timeout);
                await reloadPage(page, tab);
            }
        } catch (_) {
            /* Independent host recovery continues while disconnected. */
        } finally {
            clearTimeout(timeout);
            // An older request must not restart polling for a replaced page.
            if (request === controller) {
                request = undefined;
                // Poll while this page is attached and the document is visible.
                if (page.isConnected && !document.hidden)
                    timer = setTimeout(refresh, 1000);
            }
        }
    }

    // init() handles initial loads and theme navigation, with one polling loop.
    function init() {
        const next = document.getElementById('cloudmin-network-page');
        // Ignore mutations that leave the current network page in place.
        if (next === view) return;
        stop();
        view = next;
        // Initialize creation controls only on a network inventory page.
        if (view) updateFields(view);
        refresh();
    }
    window.cloudminNetworkStatus = {init};
    // change(event) applies network-mode choices from the current form.
    document.addEventListener('change', event => {
        // Limit form updates to controls belonging to the current page.
        if (view?.contains(event.target)) updateFields(view);
    });
    // visibilitychange() resumes polling only when the page is visible.
    document.addEventListener('visibilitychange', () => {
        stop();
        if (!document.hidden) refresh();
    });
    window.addEventListener('pagehide', stop);
    // pageshow() refreshes transaction state after browser history navigation.
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
    // A document already loaded needs no DOMContentLoaded listener.
    else init();
})();
