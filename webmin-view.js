// Match the host palette in the native proxy without saving guest preferences.
(() => {
    const view = document.querySelector('.cloudmin-webmin-view');
    // Deferred execution may arrive after navigation removed the guest view.
    if (!view) return;
    // Remove observers left by the previous view.
    window.cloudminWebminCleanup?.();
    const frame = view.querySelector('iframe');
    const owner = window.frameElement?.ownerDocument;
    // Derive the master destination from our own proxy URL, never guest input.
    const master = new URL(frame.src);
    master.pathname = master.pathname.replace(/\/link\.cgi\/\d+\/.*$/, '/');
    master.search = '';
    master.hash = '';
    const palettes = new Set([
        'blue',
        'brown',
        'gold',
        'green',
        'grey',
        'gunmetal',
        'maroon',
        'orange',
        'purple',
        'red',
        'teal',
        'white'
    ]);
    const attributes = [
        'data-bgs',
        'data-theme',
        'data-default-theme',
        'data-scheme'
    ];
    const paletteLoads = new WeakMap();
    let guests = [];

    // fullscreen() keeps only the guest visible when a legacy frame
    // is enlarged.
    function fullscreen() {
        view.classList.toggle(
            'cloudmin-webmin-fullscreen',
            !!owner && owner.fullscreenElement === window.frameElement
        );
    }
    owner?.addEventListener('fullscreenchange', fullscreen);
    fullscreen();

    // palette() reads the displayed host colors for the embedded view.
    function palette() {
        const root = document.documentElement;
        // attr(name) supports palettes stored on either page root.
        const attr = name =>
            root.getAttribute(name) || document.body.getAttribute(name);
        const scheme =
            attr('data-scheme') ||
            (attr('data-bgs') === 'nightRider'
                ? 'dark'
                : attr('data-bgs') === 'gainsboro'
                  ? 'light'
                  : null);
        const color = attr('data-default-theme') || attr('data-theme');
        return {
            scheme: ['dark', 'light'].includes(scheme) ? scheme : null,
            color: palettes.has(color) ? color : null
        };
    }

    // set(node, name, value) avoids triggering an observer for
    // unchanged colors.
    function set(node, name, value) {
        if (node && node.getAttribute(name) !== value)
            node.setAttribute(name, value);
    }

    // apply(doc) uses the guest's own stylesheets, through its existing proxy.
    function apply(doc) {
        const {scheme, color} = palette();
        // Wait for the guest document and host color scheme.
        if (!scheme || !doc.body) return;
        const nodes = [doc.documentElement, doc.body];
        const bundle = doc.querySelector(
            'link[href*="/unauthenticated/css/bundle."]'
        );
        if (bundle) {
            // Apply both the background palette and navigation color.
            const dark = scheme === 'dark';
            const accent =
                color || doc.body.getAttribute('data-default-theme') || 'blue';
            const navigation = dark
                ? 'gunmetal'
                : palettes.has(accent)
                  ? accent
                  : 'blue';
            nodes.forEach(node => {
                set(node, 'data-bgs', dark ? 'nightRider' : 'gainsboro');
                set(node, 'data-night-mode', dark ? '1' : '0');
                set(node, 'data-theme', navigation);
            });
            const wanted = new Set(
                dark
                    ? ['gunmetal', 'nightrider']
                    : navigation === 'blue'
                      ? []
                      : [navigation]
            );
            // Reuse matching palette links and disable unused ones.
            doc.querySelectorAll(
                'link[href*="/unauthenticated/css/palettes/"]'
            ).forEach(link => {
                const name = new URL(link.href).pathname
                    .split('/')
                    .pop()
                    .replace(/\.min\.css$/, '');
                link.disabled = !wanted.has(name);
                wanted.delete(name);
            });
            // Load only missing palettes; the guest version supplies the CSS.
            const loads = [];
            wanted.forEach(name => {
                const link = doc.createElement('link');
                link.rel = 'stylesheet';
                link.href = new URL(
                    'palettes/' + name + '.min.css',
                    bundle.href
                ).href;
                loads.push(
                    new Promise(resolve => {
                        // A missing palette must not hide an otherwise
                        // usable page.
                        link.addEventListener('load', resolve, {once: true});
                        link.addEventListener('error', resolve, {once: true});
                    })
                );
                doc.head.append(link);
            });
            // Wait for both earlier and newly requested palettes.
            if (loads.length)
                paletteLoads.set(
                    doc,
                    Promise.all([paletteLoads.get(doc), ...loads])
                );
        } else if (doc.defaultView.grayThemeApplyScheme) {
            // Use the page's color hook without saving preferences.
            if (
                nodes.some(node => node.getAttribute('data-scheme') !== scheme)
            ) {
                // Skip unchanged schemes to avoid repeated observer callbacks.
                doc.defaultView.grayThemeApplyScheme(scheme, false);
            }
        }
    }

    // reveal() shows the guest once its page and palette finish loading.
    // Keep the black loading surface visible while the proxy is slow.
    async function reveal() {
        try {
            const doc = frame.contentDocument;
            // Hide blank or partly loaded documents.
            if (
                doc &&
                (doc.URL === 'about:blank' || doc.readyState !== 'complete')
            )
                return;
            // Same-origin pages can inherit colors before becoming visible.
            if (doc) {
                apply(doc);
                await paletteLoads.get(doc);
            }
        } catch (_) {
            // Redirects outside the proxy must still show their destination.
        }
        requestAnimationFrame(() => {
            // Navigation may have discarded the view while stylesheets loaded.
            if (view.isConnected) frame.removeAttribute('data-webmin-loading');
        });
    }
    frame.addEventListener('load', reveal);
    reveal();

    // watch(target) watches an iframe or frame across guest navigation and
    // returns a cleanup callback for its document and nested frames.
    function watch(target) {
        let observer,
            documentCleanup,
            children = [];
        // loaded() replaces observers tied to the previous guest document.
        function loaded() {
            observer?.disconnect();
            documentCleanup?.();
            children.forEach(cleanup => cleanup());
            children = [];
            try {
                const doc = target.contentDocument;
                // Wait for the document before binding handlers.
                if (!doc?.body) return;
                // returnToMaster(event) opens the host outside the wrapper.
                // Other guest links keep their normal behavior.
                const returnToMaster = event => {
                    const link = event.target.closest?.('a[href]');
                    // Preserve modified clicks that open new tabs or windows.
                    if (
                        !link ||
                        event.button !== 0 ||
                        event.ctrlKey ||
                        event.metaKey ||
                        event.shiftKey ||
                        event.altKey
                    )
                        return;
                    const url = new URL(link.href, doc.URL);
                    // Handle only the known host destination.
                    if (
                        url.origin !== master.origin ||
                        url.pathname !== master.pathname
                    )
                        return;
                    event.preventDefault();
                    event.stopImmediatePropagation();
                    window.top.location.assign(master.href);
                };
                doc.addEventListener('click', returnToMaster, true);
                // documentCleanup() unbinds the old document's handler.
                documentCleanup = () =>
                    doc.removeEventListener('click', returnToMaster, true);
                // Guest navigation or scripts may restore their saved palette.
                apply(doc);
                observer = new MutationObserver(() => apply(doc));
                observer.observe(doc.documentElement, {
                    attributes: true,
                    attributeFilter: attributes
                });
                observer.observe(doc.body, {
                    attributes: true,
                    attributeFilter: attributes
                });
                observer.observe(doc.head, {childList: true});
                // Watch separate navigation and content documents too.
                children = [...doc.querySelectorAll('frame')].map(watch);
            } catch (_) {
                // A guest link may leave the host origin; leave that
                // page alone.
            }
        }
        target.addEventListener('load', loaded);
        loaded();
        // Release both this frame's handlers and any nested document watchers.
        return () => {
            target.removeEventListener('load', loaded);
            observer?.disconnect();
            documentCleanup?.();
            children.forEach(cleanup => cleanup());
        };
    }

    // update() carries the displayed colors into the embedded view.
    function update() {
        guests.forEach(cleanup => cleanup());
        guests = [watch(frame)];
    }
    const host = new MutationObserver(records => {
        // Navigation can replace the content pane without unloading
        // the document.
        if (!view.isConnected) window.cloudminWebminCleanup();
        // Status and menu updates do not change the displayed palette.
        else if (records.some(record => record.type === 'attributes')) update();
    });
    host.observe(document.documentElement, {
        attributes: true,
        attributeFilter: attributes
    });
    host.observe(document.body, {
        attributes: true,
        attributeFilter: attributes,
        childList: true,
        subtree: true
    });
    // cloudminWebminCleanup() releases guest documents when this view closes.
    window.cloudminWebminCleanup = () => {
        host.disconnect();
        owner?.removeEventListener('fullscreenchange', fullscreen);
        frame.removeEventListener('load', reveal);
        guests.forEach(cleanup => cleanup());
        guests = [];
    };
    update();
})();
