import RFB from './novnc/core/rfb.js';
import KeyTable from './novnc/core/input/keysym.js';

// Map the menu's browser key codes to the key symbols used by VNC.
const keySymbols = {
    ControlLeft: KeyTable.XK_Control_L, AltLeft: KeyTable.XK_Alt_L,
    Delete: KeyTable.XK_Delete, Backspace: KeyTable.XK_BackSpace,
    End: KeyTable.XK_End, Tab: KeyTable.XK_Tab, Enter: KeyTable.XK_Return,
    Escape: KeyTable.XK_Escape, PrintScreen: KeyTable.XK_Print, Pause: KeyTable.XK_Pause
};
for (let n = 1; n <= 12; n++) keySymbols['F' + n] = KeyTable['XK_F' + n];

// connect(container) renders one Cloudmin console and releases it on navigation.
export function connect(container) {
    // Navigation and repeated theme hooks must not create duplicate sessions.
    if (!container.isConnected || container.dataset.consoleStarted) return;
    container.dataset.consoleStarted = '1';
    const config = JSON.parse(container.dataset.consoleConfig);
    // Serial uses the same signed endpoint and cleanup, with a text renderer.
    if (config.mode === 'serial') {
        // Themes may move controls into their header while this import loads.
        const controls = {
            screen: container.querySelector('[data-console-screen]'),
            badge: container.querySelector('[data-console-status] .ui_badge'),
            fullscreen: container.querySelector('[data-console-action="fullscreen"]'),
            disconnect: container.querySelector('[data-console-action="disconnect"]')
        };
        import('./serial-console.js?' + config.serial_version).then(module => {
            // Do not reconnect a page removed while the module was loading.
            if (container.isConnected) module.connect(container, config, controls);
        }).catch(() => {
            // Report load failure in the same badge used for connection errors.
            const { badge } = controls;
            badge.classList.replace('ui_badge_info', 'ui_badge_danger');
            badge.lastElementChild.textContent = config.failed;
        });
        return;
    }
    const screen = container.querySelector('[data-console-screen]');
    const display = document.createElement('div');
    display.dataset.consoleDisplay = '1';
    const status = container.querySelector('[data-console-status]');
    const badge = status.querySelector('.ui_badge');
    const keys = container.querySelector('[data-console-action="keys"]');
    const keyboard = container.querySelector('[data-console-keyboard]');
    const keyMenu = container.querySelector('#cloudmin-console-keys');
    const keyItems = [...keyMenu.querySelectorAll('[data-console-key]')];
    let rfb, request, timeout, resizeFrame;
    let generation = 0;
    let disposed = false;
    let zoom = 100;

    // scale() fits the guest image, then applies the user's local zoom. Size
    // the target to that image so scrolling cannot run into empty margins.
    function scale() {
        // Layout callbacks may arrive after navigation removed this console.
        if (disposed || !screen.isConnected) return;
        const style = getComputedStyle(screen);
        const left = parseFloat(style.paddingLeft) || 0;
        const top = parseFloat(style.paddingTop) || 0;
        const bounds = screen.getBoundingClientRect();
        // Preserve fractional layout sizes, excluding any visible scrollbars.
        const width = bounds.width - (screen.offsetWidth - screen.clientWidth) -
            left - (parseFloat(style.paddingRight) || 0);
        const height = bounds.height - (screen.offsetHeight - screen.clientHeight) -
            top - (parseFloat(style.paddingBottom) || 0);
        const canvas = display.querySelector('canvas');
        const factor = canvas?.width && canvas.height ?
            Math.min(width / canvas.width, height / canvas.height) * zoom / 100 : 1;
        display.style.left = left + 'px';
        display.style.top = top + 'px';
        display.style.width = Math.max(0, canvas?.width ? canvas.width * factor : width) + 'px';
        display.style.height = Math.max(0, canvas?.height ? canvas.height * factor : height) + 'px';
        container.dataset.consoleZoom = zoom;
        // noVNC applies aspect-preserving scaling and adjusts mouse coordinates.
        if (rfb) rfb.scaleViewport = true;
    }
    // scheduleScale() coalesces layout and guest resolution changes in one frame.
    function scheduleScale() {
        cancelAnimationFrame(resizeFrame);
        resizeFrame = requestAnimationFrame(scale);
    }
    const resizeObserver = new ResizeObserver(scheduleScale);
    resizeObserver.observe(screen);
    // The first framebuffer and later guest mode changes arrive asynchronously.
    // Watch its intrinsic dimensions, not the CSS dimensions changed by scaling.
    const displayObserver = new MutationObserver(scheduleScale);
    displayObserver.observe(display, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['width', 'height']
    });

    // changeZoom(event) reads event.detail: -1/+1 for 10% steps, 0 to fit,
    // or {percent} to restore a saved zoom before the connection opens.
    // Resize noVNC's target so its own scaling keeps mouse coordinates correct.
    function changeZoom(event) {
        let percent = event.detail?.percent;
        // Relative shortcuts need an active guest; saved absolute zoom does
        // not.
        if (rfb && [-1, 0, 1].includes(event.detail)) {
            percent = event.detail === 0 ? 100 : zoom + event.detail * 10;
        }
        // Ignore malformed custom events instead of applying invalid
        // dimensions.
        if (!Number.isInteger(percent)) return;
        const previous = zoom;
        zoom = Math.max(50, Math.min(300, percent));
        scale();
        // Fit mode should not retain a scroll offset from a magnified display.
        if (zoom === 100) screen.scrollTo(0, 0);
        // Report the applied value so callers can save it without duplicating limits.
        if (zoom !== previous) {
            container.dispatchEvent(new CustomEvent('cloudmin-console-zoom-changed', { detail: zoom }));
        }
    }
    container.addEventListener('cloudmin-console-zoom', changeZoom);

    // zoomKey(event) handles local zoom while the guest canvas has focus.
    // Modifier releases still reach noVNC so guest keys cannot remain held.
    function zoomKey(event) {
        const platform = navigator.userAgentData?.platform || navigator.platform;
        const modifier = /Mac|iPhone|iPad|iPod/i.test(platform) ? event.metaKey : event.ctrlKey;
        // All other key combinations remain available to the guest.
        if (!modifier || event.altKey || !['=', '+', '-', '0'].includes(event.key)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        changeZoom({ detail: event.key === '0' ? 0 : event.key === '-' ? -1 : 1 });
    }
    screen.addEventListener('keydown', zoomKey, true);

    // show(message, [state]) updates the standard Webmin badge with plain text.
    function show(message, state = 'neutral') {
        badge.lastElementChild.textContent = message;
        badge.classList.remove('ui_badge_neutral', 'ui_badge_info',
            'ui_badge_success', 'ui_badge_warning', 'ui_badge_danger');
        badge.classList.add('ui_badge_' + state);
    }

    // stop() closes the current transport without sending keys to the guest.
    function stop() {
        generation++;
        clearTimeout(timeout);
        request?.abort();
        request = null;
        rfb?.disconnect();
        rfb = null;
        keys.disabled = true;
        closeKeys();
    }

    // start() gets a fresh signed connection; old callbacks cannot replace it.
    async function start() {
        stop();
        const current = generation;
        show(config.connecting, 'info');
        request = new AbortController();
        // connectionTimeout() cancels a stalled setup or VNC handshake.
        timeout = setTimeout(() => {
            stop();
            // Navigation may have removed the status badge before the timeout.
            if (!disposed) {
                show(config.failed, 'danger');
            }
        }, 30000);
        try {
            const response = await fetch(config.endpoint, {
                method: 'POST', credentials: 'same-origin', signal: request.signal,
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: new URLSearchParams({ id: config.id, token: config.token })
            });
            // A failed HTTP request may contain a Webmin login or error page.
            if (!response.ok) throw new Error(config.failed);
            const data = await response.json();
            // An old setup response cannot replace a newer connection.
            if (disposed || current !== generation) return;
            // Report backend errors before trying to construct a VNC client.
            if (data.error) throw new Error(data.error);
            if (!data.socket_url) throw new Error(config.failed);
            screen.replaceChildren(display);
            scale();
            rfb = new RFB(display, data.socket_url, { shared: true });
            rfb.scaleViewport = true;
            rfb.background = '#000';
            // connected(event) enables guest shortcuts for the current session.
            rfb.addEventListener('connect', () => {
                if (disposed || current !== generation) return;
                clearTimeout(timeout);
                keys.disabled = false;
                show(config.connected, 'success');
                scale();
                rfb.focus({ preventScroll: true });
            });
            // disconnected(event) distinguishes a clean close from a VNC
            // failure.
            rfb.addEventListener('disconnect', event => {
                if (disposed || current !== generation) return;
                rfb = null;
                clearTimeout(timeout);
                keys.disabled = true;
                closeKeys();
                show(event.detail.clean ? config.disconnected : config.failed,
                    event.detail.clean ? 'warning' : 'danger');
            });
            // Libvirt authorizes this socket. Unexpected VNC authentication is
            // an error, never a reason to ask for or expose a guest VNC secret.
            // credentialsrequired(event) closes that unexpected authentication
            // flow.
            rfb.addEventListener('credentialsrequired', () => {
                if (current !== generation) return;
                stop();
                show(config.failed, 'danger');
            });
        } catch (error) {
            // Aborted requests from navigation or restart no longer own the UI.
            if (disposed || current !== generation) return;
            stop();
            show(error.message || config.failed, 'danger');
        }
    }

    // closeKeys() hides shortcuts without moving focus away from another control.
    function closeKeys() {
        keyMenu.hidden = true;
        keys.setAttribute('aria-expanded', 'false');
    }

    // openKeys([last]) moves keyboard focus into the menu, away from the guest.
    function openKeys(last = false) {
        // Shortcuts cannot be sent before the VNC connection is ready.
        if (keys.disabled) return;
        keyMenu.hidden = false;
        keys.setAttribute('aria-expanded', 'true');
        keyItems[last ? keyItems.length - 1 : 0].focus();
    }
    // keysClicked() toggles the theme-independent shortcut menu.
    keys.addEventListener('click', () => {
        // Open from the trigger, or close an already visible menu.
        if (keyMenu.hidden) openKeys();
        // A second click dismisses the menu without sending a guest key.
        else closeKeys();
    });
    // keysPressed(event) enters the shortcut list using either arrow direction.
    keys.addEventListener('keydown', event => {
        // Only arrow keys move focus from the trigger into its shortcut list.
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            openKeys(event.key === 'ArrowUp');
        }
    });
    // shortcutClicked(event) sends one recognized chord, then returns guest
    // focus.
    keyMenu.addEventListener('click', event => {
        const item = event.target.closest('[data-console-key]');
        // Ignore menu padding and clicks made after the connection closed.
        if (!item || keys.disabled || !rfb) return;
        const codes = item.dataset.consoleKey.split(' ');
        // Only the fixed menu's recognized key symbols may reach noVNC.
        if (!codes.every(code => Object.hasOwn(keySymbols, code))) return;
        // Release modifiers in reverse order so no key stays held in the guest.
        for (const code of codes) rfb.sendKey(keySymbols[code], code, true);
        for (const code of codes.reverse()) rfb.sendKey(keySymbols[code], code, false);
        closeKeys();
        rfb.focus({ preventScroll: true });
    });
    // menuKey(event) navigates shortcuts or returns focus to the menu trigger.
    keyMenu.addEventListener('keydown', event => {
        const index = keyItems.indexOf(document.activeElement);
        let next;
        // Arrow navigation wraps at either end of the shortcut list.
        if (event.key === 'ArrowDown') next = (index + 1) % keyItems.length;
        else if (event.key === 'ArrowUp') next = (index + keyItems.length - 1) % keyItems.length;
        // Home and End jump directly to the list boundaries.
        else if (event.key === 'Home') next = 0;
        else if (event.key === 'End') next = keyItems.length - 1;
        // Escape dismisses the menu without choosing a shortcut.
        else if (event.key === 'Escape') {
            closeKeys();
            keys.focus();
        } else if (event.key === 'Tab') {
            // Restore the trigger before the browser chooses the next tab stop.
            closeKeys();
            keys.focus();
            return;
        } else return;
        event.preventDefault();
        event.stopPropagation();
        if (next !== undefined) keyItems[next].focus();
    });
    // dismissKeys(event) closes outside clicks without theme dropdown handlers.
    function dismissKeys(event) {
        if (!keyboard.contains(event.target)) closeKeys();
    }
    document.addEventListener('pointerdown', dismissKeys);
    // focusout(event) dismisses the menu only when focus leaves its controls.
    keyboard.addEventListener('focusout', event => {
        if (!keyboard.contains(event.relatedTarget)) closeKeys();
    });
    const fullscreen = container.querySelector('[data-console-action="fullscreen"]');
    // Legacy frames must enter fullscreen through their parent document.
    const fullscreenTarget = document.fullscreenEnabled ? container : window.frameElement;
    const fullscreenDocument = fullscreenTarget?.ownerDocument;
    fullscreen.hidden = !fullscreenDocument?.fullscreenEnabled;
    // fullscreenClicked(event) toggles browser fullscreen without resizing the
    // VM.
    fullscreen.addEventListener('click', async () => {
        try {
            // Exit when this console owns fullscreen; otherwise request entry.
            if (fullscreenDocument.fullscreenElement === fullscreenTarget) await fullscreenDocument.exitFullscreen();
            // Browsers authorize entry from this user-initiated event.
            else await fullscreenTarget.requestFullscreen();
            rfb?.focus({ preventScroll: true });
        } catch (_) { /* The browser may refuse fullscreen without changing the console. */ }
    });

    // fit() reapplies local scaling after fullscreen styles change. It also
    // handles Escape or the browser's exit control, without resizing the guest.
    function fit() {
        // Cover the content frame only while its parent owns fullscreen.
        container.classList.toggle('cloudmin-console-fullscreen',
            fullscreenTarget !== container && fullscreenDocument?.fullscreenElement === fullscreenTarget);
        closeKeys();
        cancelAnimationFrame(resizeFrame);
        // afterLayout() waits for fullscreen sizing before scaling the canvas.
        resizeFrame = requestAnimationFrame(() => {
            if (disposed || !rfb) return;
            scale();
            rfb.focus({ preventScroll: true });
        });
    }
    fullscreenDocument?.addEventListener('fullscreenchange', fit);
    fit();

    // dispose() releases callbacks and transport on theme or full-page
    // navigation.
    function dispose() {
        if (disposed) return;
        disposed = true;
        stop();
        cancelAnimationFrame(resizeFrame);
        fullscreenDocument?.removeEventListener('fullscreenchange', fit);
        container.removeEventListener('cloudmin-console-zoom', changeZoom);
        screen.removeEventListener('keydown', zoomKey, true);
        resizeObserver.disconnect();
        displayObserver.disconnect();
        document.removeEventListener('pointerdown', dismissKeys);
        observer.disconnect();
        window.removeEventListener('pagehide', dispose);
    }
    // removed(records) detects when theme navigation detaches this console.
    const observer = new MutationObserver(() => {
        if (!container.isConnected) dispose();
    });
    observer.observe(document.body, { childList: true, subtree: true });
    window.addEventListener('pagehide', dispose);
    start();
}

// Full-page themes load this module directly; navigation hooks can call connect
// again safely when a theme replaces the page without reloading the document.
const container = document.getElementById('cloudmin-console');
if (container) connect(container);
