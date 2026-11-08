// initTerminal() uses Webmin's xterm client in themes without their
// own renderer.
(() => {
    const container = document.getElementById('terminal');
    // Ignore unrelated pages and a terminal that already owns its socket.
    if (!container || container.dataset.terminalStarted) return;
    container.dataset.terminalStarted = '1';
    const config = xterm_argv;
    const term = new Terminal({
        cols: config.cols,
        rows: config.rows,
        fontSize: Number(config.conf.fontsize) || 14,
        screenReaderMode: config.conf.screen_reader === 'true',
        ...config.options
    });
    // Attach Auto updates before the first terminal frame.
    if (container.xtermTheme) container.xtermTheme(term);
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(container);
    const socket = new WebSocket(config.socket_url, 'binary');
    let disposed = false;
    let failed = false;
    const badge = document.querySelector('[data-terminal-status] .ui_badge');

    // showStatus(state) sets the header badge for connected, failed or
    // disconnected, using the same labels and colors as the other consoles.
    function showStatus(state) {
        // A late socket event must not update a replacement page.
        if (disposed || !badge?.isConnected) return;
        badge.lastElementChild.textContent = config.status[state];
        badge.classList.remove(
            'ui_badge_info',
            'ui_badge_success',
            'ui_badge_warning',
            'ui_badge_danger'
        );
        badge.classList.add(
            'ui_badge_' +
                {
                    connected: 'success',
                    failed: 'danger',
                    disconnected: 'warning'
                }[state]
        );
    }

    // onResize(size) sends Webmin's resize control once the socket is open.
    term.onResize(size => {
        // Do not send resize controls before the transport handshake finishes.
        if (socket.readyState === WebSocket.OPEN) {
            socket.send('\\033[8;(' + size.rows + ');(' + size.cols + ')t');
        }
    });
    // open(event) attaches input and output after the WebSocket handshake.
    socket.addEventListener('open', () => {
        // A late open event must not resurrect an unloaded terminal.
        if (disposed) return;
        term.loadAddon(new AttachAddon.AttachAddon(socket));
        fit.fit();
        term.focus();
        showStatus('connected');
    });
    // resized(entries) fits an active terminal to its available page space.
    const observer = new ResizeObserver(() => {
        if (!disposed && socket.readyState === WebSocket.OPEN) fit.fit();
    });
    observer.observe(container);

    // error(event) keeps output visible and reports a transport failure once.
    socket.addEventListener('error', () => {
        if (container.xtermTheme) container.xtermTheme.dispose();
        failed = true;
        showStatus('failed');
        if (!disposed) term.write('\r\n' + config.failed);
    });
    // close(event) reports a normal close without duplicating an earlier error.
    socket.addEventListener('close', () => {
        observer.disconnect();
        if (container.xtermTheme) container.xtermTheme.dispose();
        if (!failed) showStatus('disconnected');
        if (!disposed && !failed) term.write('\r\n' + config.disconnected);
    });

    // dispose() closes the connection when this document or frame is unloaded.
    function dispose() {
        // Page lifecycle events may request cleanup more than once.
        if (disposed) return;
        disposed = true;
        observer.disconnect();
        if (container.xtermTheme) container.xtermTheme.dispose();
        socket.close();
        term.dispose();
        window.removeEventListener('pagehide', dispose);
    }
    window.addEventListener('pagehide', dispose);
})();
