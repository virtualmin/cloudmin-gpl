// Load Webmin's text renderer only when a serial console is opened.
let assets;

// loadAssets(config) loads xterm from config.path using versioned URLs.
// Share the pending load across SPA navigation; failures allow a later retry.
function loadAssets(config) {
    // Reuse a pending or completed load when another serial page opens.
    if (assets) return assets;
    const css = config.path + '/xterm.css?' + config.version;
    if (![...document.styleSheets].some(sheet => sheet.href?.endsWith(css))) {
        // Keep one stylesheet per version across terminal and console pages.
        const link = document.createElement('link');
        link.rel = 'stylesheet';
        link.href = css;
        document.head.append(link);
    }
    // load(name, global) loads a script and checks its expected window export.
    const load = (name, global) =>
        new Promise((resolve, reject) => {
            // A previous terminal page may already have loaded this component.
            if (window[global]) return resolve();
            const script = document.createElement('script');
            script.src = config.path + '/' + name + '.js?' + config.version;
            // A completed request without the expected export is still
            // a failure.
            script.onload = () =>
                window[global]
                    ? resolve()
                    : reject(new Error('Terminal client unavailable'));
            script.onerror = () => {
                // Discard the failed element so a later page can retry
                // the load.
                script.remove();
                reject(new Error('Cannot load terminal client'));
            };
            document.head.append(script);
        });
    // Load the addon after xterm; do not cache a rejected load indefinitely.
    assets = load('xterm', 'Terminal')
        .then(() => load('xterm-addon-fit', 'FitAddon'))
        .catch(error => {
            assets = null;
            throw error;
        });
    return assets;
}

// connect(container, config, controls) opens one serial port and releases it on
// navigation. controls retains nodes that themes may move into the header.
// config supplies the signed endpoint, status labels and xterm preferences.
// controls contains the screen, status badge, fullscreen and disconnect
// buttons. Themes can set container.dataset.consoleFontSize before connecting.
// The cloudmin-serial-font-size-changed event reports the new size
// in event.detail.
export function connect(
    container,
    config,
    {screen, badge, fullscreen, disconnect}
) {
    let term,
        fit,
        socket,
        disposed = false,
        failed = false,
        frame,
        pending = 0;
    let closed = false;
    let header = [],
        replayLeft,
        replaying = true;
    const request = new AbortController();
    const scheme = matchMedia('(prefers-color-scheme: dark)');
    const defaultFontSize = Number(config.xterm.conf.fontsize) || 14;
    // Themes supply a saved size before loading the client asynchronously.
    // Missing or invalid preferences retain the configured terminal default.
    const savedFontSize = Number(container.dataset.consoleFontSize);
    const fontSize =
        Number.isInteger(savedFontSize) &&
        savedFontSize >= 10 &&
        savedFontSize <= 32
            ? savedFontSize
            : defaultFontSize;

    // show(message, state) keeps status separate from untrusted guest output.
    function show(message, state) {
        badge.lastElementChild.textContent = message;
        badge.classList.remove(
            'ui_badge_info',
            'ui_badge_success',
            'ui_badge_warning',
            'ui_badge_danger'
        );
        badge.classList.add('ui_badge_' + state);
        // Only a ready connection can be released from this tab.
        disconnect.disabled = state !== 'success';
    }
    // palette() follows the user's Webmin terminal palette, including Auto.
    function palette() {
        const conf = config.xterm.conf;
        let options = config.xterm.options;
        if (conf.theme === 'auto') {
            // Prefer the page's theme, falling back to the OS color preference.
            const background =
                document.documentElement.getAttribute('data-bgs');
            const pageScheme = getComputedStyle(document.body).colorScheme;
            const mode = background
                ? background === 'nightRider'
                    ? 'dark'
                    : 'light'
                : ['dark', 'light'].includes(pageScheme)
                  ? pageScheme
                  : scheme.matches
                    ? 'dark'
                    : 'light';
            options = config.xterm.themes[mode];
        }
        screen.style.setProperty(
            '--terminal-background',
            options.theme.background
        );
        screen.style.setProperty(
            '--terminal-foreground',
            options.theme.foreground
        );
        if (term) {
            // Apply later palette changes to the existing terminal as well.
            term.options.theme = options.theme;
            term.options.minimumContrastRatio = options.minimumContrastRatio;
        }
    }
    // resize() fits the local display. This byte stream has no resize channel;
    // sending SSH terminal resize messages here would become guest input.
    function resize() {
        cancelAnimationFrame(frame);
        frame = requestAnimationFrame(() => {
            // Skip removed pages and hidden screens with no usable width.
            if (!disposed && term && screen.clientWidth) fit.fit();
        });
    }
    // zoomKey(event) changes text size locally, using the same shortcuts as
    // SSH. Capture them before xterm so they never become serial input or
    // page zoom.
    function zoomKey(event) {
        // Ignore zoom until xterm loads or after the page closes.
        if (disposed || !term) return;
        const platform =
            navigator.userAgentData?.platform || navigator.platform;
        const modifier = /Mac|iPhone|iPad|iPod/i.test(platform)
            ? event.metaKey
            : event.ctrlKey;
        // Let xterm handle other shortcuts, including Alt combinations.
        if (
            !modifier ||
            event.altKey ||
            !['=', '+', '-', '0'].includes(event.key)
        )
            return;
        // Reset to the configured size; keep zoom steps within SSH's limits.
        event.preventDefault();
        event.stopImmediatePropagation();
        const previous = term.options.fontSize;
        term.options.fontSize =
            event.key === '0'
                ? defaultFontSize
                : Math.max(
                      10,
                      Math.min(
                          32,
                          term.options.fontSize + (event.key === '-' ? -1 : 1)
                      )
                  );
        // Report actual changes so themes can save the user's chosen text size.
        container.dataset.consoleFontSize = term.options.fontSize;
        // Holding a zoom key at the limit must not keep saving the same size.
        if (term.options.fontSize !== previous) {
            container.dispatchEvent(
                new CustomEvent('cloudmin-serial-font-size-changed', {
                    detail: term.options.fontSize
                })
            );
        }
        resize();
    }
    screen.addEventListener('keydown', zoomKey, true);
    // Fit the display after layout changes, including theme-driven resizing.
    const sizes = new ResizeObserver(resize);
    sizes.observe(screen);
    // Follow both page theme changes and the OS preference while connected.
    const colors = new MutationObserver(palette);
    const colorAttrs = {
        attributes: true,
        attributeFilter: ['data-bgs', 'data-scheme', 'class', 'style']
    };
    colors.observe(document.documentElement, colorAttrs);
    colors.observe(document.body, colorAttrs);
    scheme.addEventListener('change', palette);
    palette();

    // fail(message) closes a failed or timed-out setup without losing
    // its output.
    function fail(message) {
        // Late errors must not replace a disconnected or removed page's state.
        if (disposed || closed) return;
        failed = true;
        clearTimeout(timeout);
        request.abort();
        socket?.close();
        // Loading can fail before a terminal exists; retain any output.
        if (term) term.options.disableStdin = true;
        show(message, 'danger');
    }
    // Include asset loading, route allocation and socket setup in one deadline.
    const timeout = setTimeout(() => fail(config.failed), 30000);

    // start() loads the renderer and obtains a fresh, signed serial connection.
    async function start() {
        try {
            await loadAssets(config.xterm);
            // Navigation or timeout may have ended the session during loading.
            if (disposed || request.signal.aborted) return;
            // Prepare the renderer, but accept no input until replay finishes.
            term = new window.Terminal({
                cols: 80,
                rows: 24,
                screenReaderMode: config.xterm.conf.screen_reader === 'true',
                ...config.xterm.options,
                fontSize,
                disableStdin: true
            });
            container.dataset.consoleFontSize = term.options.fontSize;
            fit = new window.FitAddon.FitAddon();
            term.loadAddon(fit);
            term.open(screen);
            palette();
            resize();
            // Obtain a new session-bound route through the signed console POST.
            const response = await fetch(config.endpoint, {
                method: 'POST',
                credentials: 'same-origin',
                signal: request.signal,
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: new URLSearchParams({
                    id: config.id,
                    token: config.token,
                    mode: 'serial'
                })
            });
            // HTTP failures may have no JSON error body to display.
            if (!response.ok) throw new Error(config.failed);
            const data = await response.json();
            // The page may have closed while the request was pending.
            if (disposed || request.signal.aborted) return;
            // Show the server's refusal without trying to connect.
            if (data.error || !data.socket_url)
                throw new Error(data.error || config.failed);
            socket = new WebSocket(data.socket_url, 'binary');
            socket.binaryType = 'arraybuffer';
            // onData(bytes) sends UTF-8 input only after replay has finished.
            term.onData(bytes => {
                // Suppress replies to queries from the recorded session.
                if (!replaying && socket.readyState === WebSocket.OPEN)
                    socket.send(new TextEncoder().encode(bytes));
            });
            // onBinary(bytes) preserves binary input without UTF-8 encoding.
            term.onBinary(bytes => {
                // Suppress historical replies and writes to a closing socket.
                if (!replaying && socket.readyState === WebSocket.OPEN) {
                    socket.send(
                        Uint8Array.from(bytes, char => char.charCodeAt(0))
                    );
                }
            });
            // open() leaves input disabled while replay is pending.
            socket.addEventListener('open', () => {
                // A late handshake must release a session already disposed.
                if (disposed) return socket.close();
            });
            // message(event) feeds guest bytes only to the terminal renderer.
            socket.addEventListener('message', event => {
                // Ignore late output and nonbinary WebSocket frames.
                if (
                    disposed ||
                    failed ||
                    closed ||
                    !(event.data instanceof ArrayBuffer)
                )
                    return;
                // Keep the guest's initial blank lines and escape sequences.
                let bytes = new Uint8Array(event.data);
                if (replayLeft === undefined) {
                    // The supervisor prefixes the stream with the
                    // replay length.
                    const take = Math.min(4 - header.length, bytes.length);
                    header.push(...bytes.subarray(0, take));
                    bytes = bytes.subarray(take);
                    // The four-byte prefix can span several WebSocket frames.
                    if (header.length < 4) return;
                    replayLeft = new DataView(
                        Uint8Array.from(header).buffer
                    ).getUint32(0);
                    // Enforce the supervisor's 64 KiB replay limit.
                    if (replayLeft > 65536) return fail(config.failed);
                }
                // Bound output waiting for the renderer, including a
                // background tab.
                pending += bytes.byteLength;
                if (pending > 1024 * 1024) return fail(config.failed);
                // Read the declared history before handling live output.
                if (replayLeft !== null) {
                    const count = Math.min(replayLeft, bytes.length);
                    const history = bytes.subarray(0, count);
                    term.write(history, () => {
                        pending -= history.byteLength;
                    });
                    replayLeft -= count;
                    bytes = bytes.subarray(count);
                    // Queue readiness after the last replay chunk, even when
                    // its length is zero. Input stays disabled until
                    // parsing ends.
                    if (!replayLeft) {
                        replayLeft = null;
                        // Cancel an unfinished historical escape sequence. It
                        // must not become a fresh terminal query on live input.
                        term.write('\x18', () => {
                            // Replay cannot revive a closed session.
                            if (
                                disposed ||
                                failed ||
                                closed ||
                                socket.readyState !== WebSocket.OPEN
                            )
                                return;
                            // Focus without sending guest input.
                            replaying = false;
                            clearTimeout(timeout);
                            term.options.disableStdin = false;
                            show(config.connected, 'success');
                            term.focus();
                        });
                    }
                }
                if (bytes.length) {
                    // Capture this view so later messages cannot change counts.
                    const live = bytes;
                    term.write(live, () => {
                        pending -= live.byteLength;
                    });
                }
            });
            socket.addEventListener('error', () => fail(config.failed));
            // close() retains the screen after the guest port or relay closes.
            socket.addEventListener('close', () => {
                clearTimeout(timeout);
                // Navigation has already removed this session's UI.
                if (disposed) return;
                closed = true;
                term.options.disableStdin = true;
                // Preserve a specific failure message after an error.
                if (!failed) show(config.disconnected, 'warning');
            });
        } catch (error) {
            // Cancellation already has its own cleanup or timeout message.
            if (!disposed && !failed) fail(error.message || config.failed);
        }
    }
    // disconnectConsole() releases this tab's port and retains the
    // final screen.
    function disconnectConsole() {
        // Repeated clicks and controls left on failed pages have no effect.
        if (disposed || closed || disconnect.disabled) return;
        closed = true;
        clearTimeout(timeout);
        term.options.disableStdin = true;
        socket.close();
        show(config.disconnected, 'warning');
    }
    disconnect.addEventListener('click', disconnectConsole);
    // Legacy frames must enter fullscreen through their parent document.
    const fullscreenTarget = document.fullscreenEnabled
        ? container
        : window.frameElement;
    const fullscreenDocument = fullscreenTarget?.ownerDocument;
    fullscreen.hidden = !fullscreenDocument?.fullscreenEnabled;
    // toggleFullscreen() keeps the text renderer and controls together.
    async function toggleFullscreen() {
        try {
            // Toggle only this console's fullscreen view.
            if (fullscreenDocument.fullscreenElement === fullscreenTarget)
                await fullscreenDocument.exitFullscreen();
            // Include the console controls when entering fullscreen.
            else await fullscreenTarget.requestFullscreen();
            term?.focus();
        } catch (_) {
            /* The browser may refuse fullscreen. */
        }
    }
    fullscreen.addEventListener('click', toggleFullscreen);
    // fullscreenChanged() fills the parent frame and restores layout on exit.
    function fullscreenChanged() {
        container.classList.toggle(
            'cloudmin-console-fullscreen',
            fullscreenTarget !== container &&
                fullscreenDocument?.fullscreenElement === fullscreenTarget
        );
        resize();
    }
    fullscreenDocument?.addEventListener('fullscreenchange', fullscreenChanged);
    fullscreenChanged();

    // dispose() closes the socket on full-page or SPA navigation,
    // without input.
    function dispose() {
        // DOM removal and pagehide can both report the same navigation.
        if (disposed) return;
        disposed = true;
        // Cancel setup and I/O before disposing the renderer they refer to.
        clearTimeout(timeout);
        cancelAnimationFrame(frame);
        request.abort();
        socket?.close();
        term?.dispose();
        // Release page observers and listeners, including theme-moved controls.
        sizes.disconnect();
        colors.disconnect();
        removed.disconnect();
        scheme.removeEventListener('change', palette);
        fullscreen.removeEventListener('click', toggleFullscreen);
        disconnect.removeEventListener('click', disconnectConsole);
        screen.removeEventListener('keydown', zoomKey, true);
        fullscreenDocument?.removeEventListener(
            'fullscreenchange',
            fullscreenChanged
        );
        window.removeEventListener('pagehide', dispose);
    }
    // SPA navigation removes the container without firing pagehide.
    const removed = new MutationObserver(() => {
        if (!container.isConnected) dispose();
    });
    removed.observe(document.body, {childList: true, subtree: true});
    window.addEventListener('pagehide', dispose);
    start();
}
