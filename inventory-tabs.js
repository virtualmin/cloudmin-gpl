/* Remember native inventory tabs without changing theme navigation. */
(() => {
    'use strict';
    // SPA navigation can load this script again; keep one observer per document.
    if (window.cloudminInventoryTabs) {
        window.cloudminInventoryTabs();
        return;
    }
    // Track each page marker, but keep write queues across SPA replacements.
    const states = new WeakMap();
    const queues = new Map();

    // save(state, tab) saves a tab using its page config and error node.
    // Writes remain ordered across rapid switches and SPA page replacements.
    async function save(state, tab) {
        const key = state.config.page;
        // Give each inventory its own queue on the first save.
        if (!queues.has(key)) queues.set(key, {});
        const queue = queues.get(key);
        queue.pending = {state, tab};
        // The active writer picks up the latest choice after its current POST.
        if (queue.saving) return;
        queue.saving = true;
        while (queue.pending) {
            // Coalesce unsent choices while keeping requests sequential.
            const next = queue.pending;
            queue.pending = null;
            const {config, error} = next.state;
            try {
                // Keep the signed save alive when the user leaves the page.
                const response = await fetch(config.url, {
                    method: 'POST', credentials: 'same-origin', keepalive: true,
                    body: new URLSearchParams({page: config.page,
                        tab: next.tab, token: config.token})
                });
                const result = response.ok && await response.json();
                // HTTP errors and rejected saves share one inline explanation.
                if (!result.saved) throw new Error('Preference was not saved');
                // A successful save clears any earlier warning on this page.
                if (error) error.hidden = true;
            } catch (_) {
                // The tab remains usable when its preference cannot be written.
                if (error?.isConnected) error.hidden = false;
            }
        }
        queue.saving = false;
    }

    // refresh() follows visible panels in all themes.
    function refresh() {
        document.querySelectorAll('[data-inventory-tabs]').forEach(node => {
            let state = states.get(node);
            // Newly inserted pages have their own token and error display.
            if (!state) {
                const config = JSON.parse(node.dataset.inventoryTabs);
                state = {config, error: document.querySelector(
                    '[data-inventory-tabs-error="' + config.page + '"]')};
                states.set(node, state);
            }
            // Themes use different prefixes for their visible panels.
            const tab = state.config.tabs.find(id => {
                const panel = document.getElementById('att_' + id) ||
                    document.getElementById('div_' + id);
                return panel && panel.getClientRects().length;
            });
            // Save only a visible selection that changed since the last scan.
            if (!tab || tab === state.last) return;
            state.last = tab;
            save(state, tab);
        });
    }

    // Coalesce theme class changes and inventory redraws into one layout check.
    let queued = false;
    const observer = new MutationObserver(() => {
        // A scheduled frame already covers any additional mutations.
        if (queued) return;
        queued = true;
        requestAnimationFrame(() => {
            queued = false;
            refresh();
        });
    });
    // Watch tab visibility and page replacement, then capture the initial tab.
    observer.observe(document.documentElement, {subtree: true, childList: true,
        attributes: true, attributeFilter: ['class', 'style', 'hidden']});
    window.cloudminInventoryTabs = refresh;
    refresh();
})();
