#!/usr/bin/python3
"""Exercise live charts and API permissions with temporary Webmin accounts.

Run as root on an authorized Linux test host. Existing guests are read only.
Requires Chromium and python3-websocket, as do the other browser fixtures.
"""

import argparse
import http.cookiejar
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import signal
import tempfile
import time
import urllib.parse
import urllib.request
import urllib.error
import websocket
import libvirt

# Require root on Linux before creating fixture accounts or browsers.
assert os.uname().sysname == 'Linux' and os.geteuid() == 0
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(1)))
base = 'https://127.0.0.1:10000'
helper = Path(__file__).with_name('webmin-user.pl')


def session(theme, user, password):
    """session(theme, user, password) creates a loopback-only fixture login."""
    subprocess.run(
        ['perl', str(helper), 'create', theme, user],
        input=password + '\n',
        text=True,
        check=True,
    )
    subprocess.run(
        ['perl', str(helper), 'acl', theme, user],
        input=json.dumps({'admin': 1}),
        text=True,
        check=True,
    )
    time.sleep(1)
    # Use a fresh cookie jar and loopback connection for each temporary account.
    cookies = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookies),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )
    # Initialize login cookies before submitting credentials directly to Webmin.
    opener.open(base + '/session_login.cgi', timeout=30).read()
    body = urllib.parse.urlencode(
        {'user': user, 'pass': password, 'page': '/'}
    ).encode()
    opener.open(
        urllib.request.Request(
            base + '/session_login.cgi',
            data=body,
            headers={'Referer': base + '/'},
        ),
        timeout=30,
    ).read()
    return opener, cookies


def api(opener, **values):
    """api(opener, **values) sends API query fields without logging cookies."""
    request = urllib.request.Request(
        base + '/server-manager/api.cgi?' + urllib.parse.urlencode(values),
        headers={
            'Referer': base + '/server-manager/',
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
        },
    )
    response = opener.open(request, timeout=30)
    body = response.read()
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        title = re.search(rb'<title>(.*?)</title>', body, re.S)
        raise AssertionError(
            'API returned '
            + str(response.headers.get('Content-Type'))
            + ' at '
            + response.url
            + ' title='
            + str(title.group(1) if title else None)
        ) from None


def statistics_page(opener, guest=None, allowed=True):
    """statistics_page(opener, [guest], [allowed]) checks page access.

    Guest defaults to the host page. Allowed defaults to True.
    """
    path = '/server-manager/statistics.cgi'
    # An explicit UUID selects the guest page. Omitting it exercises
    # host access.
    if guest is not None:
        path += '?' + urllib.parse.urlencode({'id': guest})
    request = urllib.request.Request(
        base + path, headers={'Referer': base + '/'}
    )
    try:
        body = opener.open(request, timeout=30).read().decode()
    except urllib.error.HTTPError as error:
        assert not allowed and error.code == 403, error.code
        return
    assert ('data-statistics=' in body) == allowed, (
        'Wrong statistics page access: ' + path
    )


def browser(cookies, theme, guest):
    """
    browser(cookies, theme, guest) checks navigation, rendering and ranges.
    """
    binary = shutil.which('chromium') or shutil.which('chromium-browser')
    assert binary, 'Chromium required'
    parent = (
        Path('/root/snap/chromium/common')
        if binary.startswith('/snap/')
        else None
    )
    # Snap Chromium can write its isolated profile only inside its allowed tree.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-statistics-', dir=parent
    ) as profile:
        chrome = subprocess.Popen(
            [
                binary,
                '--headless',
                '--no-sandbox',
                '--disable-gpu',
                '--remote-debugging-port=0',
                '--ignore-certificate-errors',
                '--no-first-run',
                '--disable-background-networking',
                '--disable-sync',
                '--window-size=1600,1100',
                '--user-data-dir=' + profile,
                'about:blank',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cdp = None
        try:
            # Wait for this browser instance to publish its own
            # debugging endpoint.
            portfile = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not portfile.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = portfile.read_text().splitlines()
            cdp = websocket.create_connection(
                'ws://127.0.0.1:' + port + route,
                timeout=30,
                suppress_origin=True,
            )
            serial, target_session = 0, None
            exceptions = []
            contexts = {}
            statistics_reads = 0

            def call(method, params=None):
                """
                call(method, [params]) sends CDP requests with an optional
                parameter map.
                """
                nonlocal serial, statistics_reads
                serial += 1
                command = {
                    'id': serial,
                    'method': method,
                    'params': params or {},
                }
                # Route page commands through the attached target once one has
                # been created.
                if target_session:
                    command['sessionId'] = target_session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Keep script errors for the final assertion, even between
                    # command replies.
                    if reply.get('method') == 'Runtime.exceptionThrown':
                        exceptions.append(reply['params']['exceptionDetails'])
                    # Count real statistics requests to verify that navigation
                    # stops polling.
                    if (
                        reply.get('method') == 'Network.requestWillBeSent'
                        and '/server-manager/api.cgi?action=statistics&'
                        in reply['params']['request']['url']
                    ):
                        statistics_reads += 1
                    # Remember frame contexts so uPlot objects can be inspected
                    # in either theme.
                    if reply.get('method') == 'Runtime.executionContextCreated':
                        context = reply['params']['context']
                        auxiliary = context.get('auxData', {})
                        # Ignore isolated extension worlds that do not own the
                        # module objects.
                        if auxiliary.get('isDefault') and auxiliary.get(
                            'frameId'
                        ):
                            contexts[auxiliary['frameId']] = context['id']
                    # Return only the response matching this call after handling
                    # queued events.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply.get('error')
                        return reply.get('result', {})

            def evaluate(expression):
                """
                evaluate(expression) reads the module frame in either theme.
                """
                result = call(
                    'Runtime.evaluate',
                    {
                        'expression': '(window.frames.right || window).eval('
                        + json.dumps(expression)
                        + ')',
                        'returnByValue': True,
                        'userGesture': True,
                    },
                )
                assert 'exceptionDetails' not in result, result.get(
                    'exceptionDetails'
                )
                return result.get('result', {}).get('value')

            def wait(expression):
                """wait(expression) bounds asynchronous chart loading."""
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    # Stop at the first successful observation without waiting
                    # the full deadline.
                    if evaluate('!!(' + expression + ')'):
                        return
                    time.sleep(.25)
                # Report visible state on timeout without dumping session
                # cookies or secrets.
                diagnostic = evaluate(
                    '({notice:document.querySelector(".cloudmin-statistics-notice")?.textContent,'
                    'status:document.querySelector(".cloudmin-statistics-status")?.textContent,'
                    'owner:document.querySelector(".cloudmin-statistics")?.dataset.statistics,'
                    'visible:document.querySelector(".cloudmin-statistics")?.checkVisibility()})'
                )
                raise AssertionError(
                    'Timed out: '
                    + expression
                    + '; '
                    + str(diagnostic)
                    + '; '
                    + str(exceptions)
                )

            def navigate(path):
                """
                navigate(path) follows each theme's normal content navigation.
                """
                # Navigate within the content frame when present.
                if theme == 'gray-theme':
                    tree = call('Page.getFrameTree')['frameTree']
                    frame = next(
                        c['frame']['id']
                        for c in tree['childFrames']
                        if c['frame'].get('name') == 'right'
                    )
                    call(
                        'Page.navigate',
                        {
                            'url': base + path,
                            'frameId': frame,
                            'referrer': base + '/',
                        },
                    )
                else:
                    # SPA navigation uses the theme's link handler.
                    evaluate(
                        'var a=document.createElement("a"); a.href='
                        + json.dumps(path)
                        + '; document.body.append(a); a.click(); a.remove()'
                    )

            def chart_state():
                """
                chart_state() reads actual uPlot scales without production test
                hooks.
                """
                group = 'statistics-chart-check'
                try:
                    # Query the frame's own context, not a cross-frame wrapper.
                    # uPlot returns plain objects rather than class instances.
                    tree = call('Page.getFrameTree')['frameTree']
                    frame = tree['frame']['id']
                    # Inspect charts in the frame that loaded them.
                    if theme == 'gray-theme':
                        frame = next(
                            c['frame']['id']
                            for c in tree['childFrames']
                            if c['frame'].get('name') == 'right'
                        )
                    # Inspect connected chart objects without adding test-only
                    # production hooks.
                    prototype = call(
                        'Runtime.evaluate',
                        {
                            'expression': 'Object.getPrototypeOf(uPlot.prototype)',
                            'contextId': contexts[frame],
                            'objectGroup': group,
                        },
                    )
                    objects = call(
                        'Runtime.queryObjects',
                        {
                            'prototypeObjectId': prototype['result'][
                                'objectId'
                            ],
                            'objectGroup': group,
                        },
                    )
                    result = call(
                        'Runtime.callFunctionOn',
                        {
                            'objectId': objects['objects']['objectId'],
                            'returnByValue': True,
                            'functionDeclaration': '''function() {
                            return Array.from(this).filter(p => Object.hasOwn(p, 'scales') &&
                                Object.hasOwn(p, 'root') && p.root?.isConnected &&
                                p.root.closest('.cloudmin-statistics') &&
                                !p.root.closest('[hidden]') &&
                                !p.root.closest('.cloudmin-statistics-plot-empty')).map(p => ({
                                    min: p.scales.x.min, max: p.scales.x.max, points: p.data[0].length,
                                    valid: p.data.slice(1).map(values => values.filter(v => v != null).length),
                                    last: p.data.slice(1).map(values => values.findLast(v => v != null))
                                }));
                        }''',
                        },
                    )
                    assert 'exceptionDetails' not in result, result.get(
                        'exceptionDetails'
                    )
                    return result['result']['value']
                finally:
                    call('Runtime.releaseObjectGroup', {'objectGroup': group})

            def check_charts(period, single=False):
                """check_charts(period, [single]) checks axes and sample counts.

                Period is in seconds. Single defaults to False and tests a
                response containing exactly one point when True.
                """
                plots = chart_state()
                assert plots, 'No connected statistics charts'
                for plot in plots:
                    assert abs(plot['max'] - plot['min'] - period) < .001, plot
                    assert abs(plot['max'] - time.time()) < 120, plot
                    # A sparse initial response still needs the full requested
                    # time range.
                    if single:
                        assert plot['points'] == 1, plot
                    else:
                        # A metric that just became available may have only one
                        # valid summary, even when the other charts
                        # have history.
                        assert plot['points'] > 1 and max(plot['valid']) >= 1, (
                            plot
                        )
                # Normal fixtures need at least one real line rather than
                # isolated points.
                if not single:
                    assert any(max(plot['valid']) > 1 for plot in plots), plots
                # The status shows the sample interval, a tooltip with the
                # latest reading time and a countdown to the next refresh.
                status = evaluate('''(() => {
                    const node = document.querySelector(".cloudmin-statistics-status");
                    const fill = document.querySelector(".cloudmin-statistics-countdown-fill");
                    return {text: node.textContent, title: node.title, transition: fill.style.transition,
                        visible: fill.parentNode.checkVisibility(), height: fill.getBoundingClientRect().height};
                })()''')
                assert re.fullmatch(r'\d+ s samples', status['text']), status
                assert re.fullmatch(
                    r'updated \d+:\d\d:\d\d( [AP]M)?', status['title']
                ), status
                assert (
                    status['visible']
                    and status['height'] > 0
                    and 'width' in status['transition']
                ), status
                print(
                    'PASS chart range',
                    theme,
                    period,
                    'seconds,',
                    len(plots),
                    'charts,',
                    plots[0]['points'],
                    'points',
                    flush=True,
                )

            def menu_link(path):
                """
                menu_link(path) finds the real sidebar link in either theme.
                """
                return (
                    '''(() => {
                    const wanted = new URL('''
                    + json.dumps(path)
                    + ''', location.origin);
                    const doc = (top.frames.left || top).document;
                    return [...doc.querySelectorAll('a[href]')].find(a => {
                        const url = new URL(a.href);
                        return url.pathname === wanted.pathname &&
                            url.searchParams.get('id') === wanted.searchParams.get('id');
                    });
                })()'''
                )

            def select_period(value):
                """
                select_period(value) clicks a period segment, as a user would.
                """
                evaluate(
                    'document.querySelector(\'[name=statistics_range][value="'
                    + str(value)
                    + '"]\').click()'
                )

            def visible_charts():
                """
                visible_charts() counts chart cards that a device filter has not
                hidden.
                """
                return evaluate(
                    '[...document.querySelectorAll(".cloudmin-statistics-chart")].filter(card => card.checkVisibility()).length'
                )

            def check_refresh_scroll():
                """
                check_refresh_scroll() waits for a real tick while scrolled
                down.
                """
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': 1100,
                        'height': 550,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                time.sleep(.5)
                evaluate('''(() => {
                    const panel = document.querySelector('.cloudmin-statistics');
                    panel.querySelectorAll('.cloudmin-statistics-chart')[2].scrollIntoView({block: 'start'});
                })()''')
                time.sleep(.5)
                before = evaluate('''(() => {
                    const panel = document.querySelector('.cloudmin-statistics');
                    let scroller = panel.parentElement;
                    while (scroller && scroller !== document.body &&
                        !(scroller.scrollHeight > scroller.clientHeight &&
                        /auto|scroll/.test(getComputedStyle(scroller).overflowY))) scroller = scroller.parentElement;
                    // Fall back to scrolling the document.
                    if (!scroller || scroller === document.body) scroller = document.scrollingElement;
                    // What matters is where the viewed chart sits on screen. The
                    // browser's scroll anchoring may legitimately change scrollTop
                    // to keep it there when a notice appears above it.
                    const card = panel.querySelectorAll('.cloudmin-statistics-chart')[2];
                    window.statisticsScrollCheck = {scroller, card, top: scroller.scrollTop, cardTop: card.getBoundingClientRect().top,
                        canvas: panel.querySelector('canvas'), movement: 0, watching: true,
                        notice: panel.querySelector('.cloudmin-statistics-notice').textContent,
                        heights: [...panel.querySelectorAll('.cloudmin-statistics-chart')].map(node => node.offsetHeight)};
                    const check = window.statisticsScrollCheck;
                    // sample() tracks the viewed card's maximum movement on
                    // screen.
                    const sample = () => {
                        check.movement = Math.max(check.movement, Math.abs(card.getBoundingClientRect().top - check.cardTop));
                        // Sample every painted frame until the assertion stops
                        // observation.
                        if (check.watching) requestAnimationFrame(sample);
                    };
                    sample();
                    return {scroll: check.top, card: check.cardTop};
                })()''')
                assert before['scroll'] > 100, (
                    'Scroll fixture must be below the top of the page'
                )
                previous_max = chart_state()[0]['max']
                # A new notice changes the height above the viewed chart. This
                # exercises scroll anchoring, not just an unchanged DOM refresh.
                evaluate('''(() => {
                    window.statisticsScrollOriginal = window.fetch;
                    window.fetch = async (...args) => {
                        const response = await window.statisticsScrollOriginal(...args);
                        // Alter only statistics responses inside this browser
                        // fixture.
                        if (!String(args[0]).includes('action=statistics&')) return response;
                        const body = await response.json();
                        body.result.collector.error = 'Temporary collection warning for the scroll fixture. '.repeat(8);
                        return new Response(JSON.stringify(body), {status: response.status, headers: response.headers});
                    };
                })()''')
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    time.sleep(.5)
                    plots = chart_state()
                    # A moving right edge proves that a normal polling refresh
                    # has completed.
                    if plots and plots[0]['max'] > previous_max:
                        break
                else:
                    # Exhausting the deadline means no live refresh
                    # was observed.
                    raise AssertionError(
                        'Visible history does not refresh automatically'
                    )
                time.sleep(.5)
                after = evaluate('''(() => {
                    const check = window.statisticsScrollCheck;
                    check.watching = false;
                    window.fetch = window.statisticsScrollOriginal;
                    delete window.statisticsScrollOriginal;
                    return {scroll: check.scroller.scrollTop, card: check.card.getBoundingClientRect().top, movement: check.movement,
                        sameCanvas: check.canvas === document.querySelector('.cloudmin-statistics canvas'),
                        notices: [check.notice, document.querySelector('.cloudmin-statistics-notice').textContent],
                        heights: [check.heights, [...document.querySelectorAll('.cloudmin-statistics-chart')].map(node => node.offsetHeight)]};
                })()''')
                assert (
                    after['movement'] <= 2
                    and abs(after['card'] - before['card']) <= 2
                ), (before, after)
                assert after['notices'][1] != after['notices'][0], (
                    'Injected notice did not appear above the viewed chart'
                )
                assert after['sameCanvas'], (
                    'Background refresh replaces the chart canvas'
                )
                call('Emulation.clearDeviceMetricsOverride')
                print(
                    'PASS automatic refresh preserves scroll and chart nodes',
                    theme,
                    flush=True,
                )

            def check_palette():
                """
                check_palette() checks that color changes preserve charts and
                zoom.
                """
                # Zoom first to catch range resets when colors change.
                evaluate('''(() => {
                    const root = document.querySelector('.cloudmin-statistics');
                    root.scrollIntoView({block: 'start'});
                    const over = root.querySelector('.u-over'), rect = over.getBoundingClientRect();
                    over.dispatchEvent(new WheelEvent('wheel', {bubbles: true, cancelable: true,
                        shiftKey: true, deltaY: -100, clientX: rect.left + rect.width / 2,
                        clientY: rect.top + rect.height / 2}));
                    // Hold data replies so repainting cannot rely on a refresh.
                    window.statisticsLoadingCheck.hold = true;
                    const check = window.statisticsPaletteCheck = {
                        root, canvases: [...root.querySelectorAll('canvas')], paints: new Map(),
                        original: CanvasRenderingContext2D.prototype.fillText,
                        scheme: document.documentElement.getAttribute('data-ui-scheme'),
                        dark: document.documentElement.getAttribute('data-bgs') === 'nightRider',
                        period: root.querySelector('[name=statistics_range]:checked').value
                    };
                    // fillText(...args) records chart text colors, then draws
                    // with the original arguments.
                    CanvasRenderingContext2D.prototype.fillText = function(...args) {
                        // Record colors only for this panel's canvases.
                        if (check.canvases.includes(this.canvas)) check.paints.set(this.canvas, this.fillStyle);
                        return check.original.apply(this, args);
                    };
                })()''')
                time.sleep(.1)
                before = [(p['min'], p['max']) for p in chart_state()]
                original_dark = evaluate(
                    'window.statisticsPaletteCheck.root.style.colorScheme === "dark"'
                )
                try:
                    for dark in (not original_dark, original_dark):
                        # Exercise both palettes with data replies still held.
                        evaluate(
                            '''(() => {
                            window.statisticsPaletteCheck.paints.clear();
                            const dark = '''
                            + json.dumps(dark)
                            + ''';
                            // Use the page's own toggle when available.
                            if (typeof theme_toggle_night_mode === 'function') theme_toggle_night_mode(dark ? 1 : 0);
                            // Other themes use the shared widget palette.
                            else document.documentElement.setAttribute('data-ui-scheme', dark ? 'dark' : 'light');
                        })()'''
                        )
                        deadline = time.monotonic() + 8
                        while True:
                            state = evaluate('''(() => {
                                const check = window.statisticsPaletteCheck, style = getComputedStyle(check.root);
                                // Use canvas color formatting for the comparison.
                                const ctx = document.createElement('canvas').getContext('2d');
                                ctx.fillStyle = style.getPropertyValue('--ui-fg-muted').trim();
                                const toolbar = check.root.querySelector('.cloudmin-statistics-toolbar');
                                let behind = '';
                                for (let node = toolbar.parentElement; node && node !== document.documentElement; node = node.parentElement) {
                                    const color = getComputedStyle(node).backgroundColor;
                                    // Match the nearest visible background.
                                    if (!/^(transparent|rgba\\(.*,\\s*0\\))$/.test(color)) { behind = color; break; }
                                }
                                // Check colors and confirm that chart nodes
                                // and the selected period are unchanged.
                                return {painted: check.canvases.every(canvas => check.paints.get(canvas) === ctx.fillStyle),
                                    background: getComputedStyle(toolbar).backgroundColor === behind,
                                    scheme: check.root.style.colorScheme,
                                    sameCanvas: check.canvases.every((canvas, i) => check.root.querySelectorAll('canvas')[i] === canvas),
                                    period: check.root.querySelector('[name=statistics_range]:checked').value === check.period};
                            })()''')
                            # Wait until charts, toolbar and controls all match.
                            if (
                                state['painted']
                                and state['background']
                                and state['scheme']
                                == ('dark' if dark else 'light')
                            ):
                                break
                            assert time.monotonic() < deadline, (
                                'Palette change did not repaint charts or toolbar',
                                dark,
                                state,
                            )
                            time.sleep(.1)
                        # Recoloring must preserve chart nodes, period and zoom.
                        assert state['sameCanvas'] and state['period'], state
                        assert [
                            (p['min'], p['max']) for p in chart_state()
                        ] == before, 'Palette change reset zoom'
                    print(
                        'PASS palette changes repaint charts and keep zoom without a data refresh',
                        theme,
                        flush=True,
                    )
                finally:
                    # Restore the palette, release held replies and reset zoom.
                    evaluate('''(() => {
                        const check = window.statisticsPaletteCheck;
                        CanvasRenderingContext2D.prototype.fillText = check.original;
                        // Restore the page toggle through its own handler.
                        if (typeof theme_toggle_night_mode === 'function') theme_toggle_night_mode(check.dark ? 1 : 0);
                        // Remove the override if the palette was inherited.
                        else if (check.scheme == null) document.documentElement.removeAttribute('data-ui-scheme');
                        // Otherwise restore the explicit palette choice.
                        else document.documentElement.setAttribute('data-ui-scheme', check.scheme);
                        window.statisticsLoadingCheck.hold = false;
                        window.statisticsLoadingCheck.release.splice(0).forEach(resolve => resolve());
                        check.root.querySelector('.u-over').dispatchEvent(new MouseEvent('dblclick', {bubbles: true}));
                        delete window.statisticsPaletteCheck;
                    })()''')

            def check_sticky_toolbar():
                """
                check_sticky_toolbar() checks toolbar position and background
                while charts scroll beneath it.
                """
                # A short viewport forces the toolbar to stick.
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': 1100,
                        'height': 550,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                time.sleep(.5)
                evaluate(
                    'document.querySelectorAll(".cloudmin-statistics-chart")[2].scrollIntoView({block: "start"})'
                )
                time.sleep(.5)
                state = evaluate('''(() => {
                    const toolbar = document.querySelector('.cloudmin-statistics-toolbar');
                    const rect = toolbar.getBoundingClientRect();
                    const first = document.querySelector('.cloudmin-statistics-chart').getBoundingClientRect();
                    // Probe where the chart passes beneath the toolbar,
                    // or inside the toolbar if they don't overlap.
                    const x = Math.min(Math.max(first.left + first.width / 2, rect.left + 1), rect.right - 1);
                    const y = Math.min(Math.max(first.bottom - 1, rect.top + 1), rect.bottom - 1);
                    const hit = document.elementFromPoint(x, y);
                    // Find the expected offset and background.
                    let above = 0, behind = '';
                    for (let node = toolbar; node && node !== document.documentElement; node = node.parentElement) {
                        for (let prev = node.previousElementSibling; prev; prev = prev.previousElementSibling) {
                            const style = getComputedStyle(prev);
                            // Leave room for sticky headers.
                            if (style.position === 'sticky') above += prev.getBoundingClientRect().height + (parseFloat(style.top) || 0);
                        }
                        // Use the nearest nontransparent background.
                        const color = node === toolbar ? '' : getComputedStyle(node).backgroundColor;
                        if (!behind && color && !/^(transparent|rgba\\(.*,\\s*0\\))$/.test(color)) behind = color;
                    }
                    return {position: getComputedStyle(toolbar).position, top: rect.top, bottom: rect.bottom, above,
                        colors: [getComputedStyle(toolbar).backgroundColor, behind], firstTop: first.top,
                        hit: toolbar.contains(hit), periods: toolbar.querySelector('.cloudmin-statistics-periods').checkVisibility()};
                })()''')
                # The toolbar stays below headers and covers scrolled charts.
                assert (
                    state['position'] == 'sticky'
                    and abs(state['top'] - state['above']) <= 1
                ), state
                assert (
                    state['firstTop'] < state['bottom']
                    and state['hit']
                    and state['periods']
                ), state
                assert (
                    state['colors'][1]
                    and state['colors'][0] == state['colors'][1]
                ), state
                # Restore the viewport for later checks.
                call('Emulation.clearDeviceMetricsOverride')
                print(
                    'PASS period controls stay in view while charts scroll beneath',
                    theme,
                    flush=True,
                )

            def check_zoom():
                """
                check_zoom() exercises Shift-wheel, shared scales, live ticks
                and reset.
                """

                def wheel(**options):
                    """
                    wheel(**options) dispatches a wheel gesture at a quarter of
                    the plot width.
                    """
                    return evaluate(
                        '''(() => {
                        const target = document.querySelector('.cloudmin-statistics .u-over');
                        const rect = target.getBoundingClientRect();
                        const options = Object.assign({deltaY: -100, shiftKey: true, count: 1}, '''
                        + json.dumps(options)
                        + ''');
                        let prevented = false;
                        for (let n = 0; n < options.count; n++) {
                            const event = new WheelEvent('wheel', {bubbles: true, cancelable: true,
                                clientX: rect.left + rect.width / 4, clientY: rect.top + rect.height / 2, ...options});
                            window.statisticsZoomAnchor = (event.clientX - rect.left) / rect.width;
                            target.dispatchEvent(event);
                            prevented = event.defaultPrevented;
                        }
                        return prevented;
                    })()'''
                    )

                initial = chart_state()[0]
                assert not wheel(shiftKey=False), (
                    'Ordinary scrolling is intercepted'
                )
                assert not wheel(ctrlKey=True), 'Browser zoom is intercepted'
                assert wheel(), 'Shift-wheel zoom was not handled'
                zoomed = chart_state()
                expected_span = 3600 / 1.14
                expected_min = initial['min'] + (
                    3600 - expected_span
                ) * evaluate('window.statisticsZoomAnchor')
                for plot in zoomed:
                    assert (
                        abs(plot['max'] - plot['min'] - expected_span) < .01
                    ), plot
                    assert abs(plot['min'] - expected_min) < .01, (
                        initial,
                        expected_min,
                        plot,
                    )
                # A real collector refresh must keep the chosen absolute time
                # window while still updating the existing chart objects.
                reads = statistics_reads
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    time.sleep(.25)
                    busy = evaluate(
                        'document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                    )
                    # Require a completed refresh, not merely the start of a
                    # network request.
                    if statistics_reads > reads and not busy:
                        break
                else:
                    # A zoomed chart must keep polling within the same deadline.
                    raise AssertionError('Zoomed history stopped refreshing')
                for plot in chart_state():
                    assert abs(plot['min'] - expected_min) < .01, plot
                    assert (
                        abs(plot['max'] - plot['min'] - expected_span) < .01
                    ), plot
                # Shift can map wheel movement onto the horizontal axis. Check
                # that line-mode deltas work in both directions too.
                assert wheel(deltaY=0, deltaX=-3, deltaMode=1)
                narrower = chart_state()[0]
                assert narrower['max'] - narrower['min'] < expected_span
                assert wheel(deltaY=0, deltaX=3, deltaMode=1)
                restored = chart_state()[0]
                assert (
                    abs(restored['max'] - restored['min'] - expected_span)
                    < .01
                ), restored
                # Without Shift a sideways wheel pans the zoomed window, and so
                # does a drag.
                before = chart_state()[0]
                assert wheel(shiftKey=False, deltaY=0, deltaX=30), (
                    'Sideways wheel did not pan'
                )
                panned = chart_state()[0]
                assert (
                    panned['min'] > before['min']
                    and abs(
                        (panned['max'] - panned['min'])
                        - (before['max'] - before['min'])
                    )
                    < .01
                ), (before, panned)
                evaluate('''(() => {
                    const over = document.querySelector('.cloudmin-statistics .u-over');
                    const parent = over.closest('.cloudmin-statistics-plot');
                    const rect = over.getBoundingClientRect();
                    // at(x) builds a consistent pointer gesture inside the
                    // plot.
                    const at = x => ({bubbles: true, cancelable: true, pointerId: 7, button: 0,
                        clientX: rect.left + x, clientY: rect.top + rect.height / 2});
                    parent.dispatchEvent(new PointerEvent('pointerdown', at(rect.width * .6)));
                    parent.dispatchEvent(new PointerEvent('pointermove', at(rect.width * .3)));
                    parent.dispatchEvent(new PointerEvent('pointerup', at(rect.width * .3)));
                })()''')
                dragged = chart_state()[0]
                assert dragged['min'] > panned['min'], (panned, dragged)
                assert all(
                    abs(plot['min'] - dragged['min']) < .01
                    for plot in chart_state()
                ), 'Charts panned apart'
                wheel(count=100)
                closest = chart_state()[0]
                assert 40 <= closest['max'] - closest['min'] < 3600, closest
                wheel(deltaY=100, count=100)
                check_charts(3600)
                wheel()
                evaluate(
                    'document.querySelector(".cloudmin-statistics .u-over").dispatchEvent(new MouseEvent("dblclick", {bubbles: true}))'
                )
                check_charts(3600)
                wheel()
                for period in (86400, 3600):
                    select_period(period)
                    wait(
                        '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                    )
                    check_charts(period)
                print(
                    'PASS Shift-wheel zoom, panning and resets stay aligned through live updates',
                    theme,
                    flush=True,
                )

            def check_custom_range():
                """
                check_custom_range() applies an explicit window and returns to
                live periods.
                """
                select_period('custom')
                wait(
                    '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                )
                assert evaluate(
                    'document.querySelector(".cloudmin-statistics-custom").checkVisibility()'
                ), 'Custom inputs hidden'
                # Check the theme's calendar or the native date/time fields.
                themed = evaluate('''(() => {
                    const api = typeof theme !== 'undefined' ? theme : window.theme;
                    return typeof api?.api?.datepicker?.create === 'function' && !!api.api.datepicker.available?.();
                })()''')
                date_type = evaluate(
                    'document.querySelector("[name=statistics_from_date]").type'
                )
                assert date_type == ('text' if themed else 'date'), date_type
                assert (
                    evaluate(
                        'document.querySelector("[name=statistics_from_time]").hidden'
                    )
                    == themed
                )
                # Exercise the replacement calendar only when the theme supplies
                # that API.
                if themed:
                    evaluate(
                        'document.querySelector("[name=statistics_from_date]").focus()'
                    )
                    time.sleep(.6)
                    state = evaluate('''({calendar: !!document.querySelector(".air-datepicker.-active-"),
                        clock: !!document.querySelector(".air-datepicker.-active- .air-datepicker-time"),
                        value: document.querySelector("[name=statistics_from_date]").value})''')
                    assert state['calendar'] and state['clock'], state
                    assert re.fullmatch(
                        r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}', state['value']
                    ), state
                    evaluate(
                        'document.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true}))'
                    )
                    time.sleep(.3)
                    assert not evaluate(
                        'document.querySelector(".air-datepicker.-active-")'
                    ), 'Calendar stayed open'
                heights = evaluate(
                    '[...document.querySelectorAll(".cloudmin-statistics-custom input, .cloudmin-statistics-custom .ui_action")]'
                    '.filter(node => node.checkVisibility()).map(node => Math.round(node.getBoundingClientRect().height))'
                )
                assert (
                    len(heights) == (3 if themed else 5)
                    and len(set(heights)) == 1
                ), heights
                # The default window is the last day, ending on the
                # quarter hour.
                plots = chart_state()
                assert plots and all(
                    abs(plot['max'] - plot['min'] - 86400) < 1
                    and 0 <= time.time() - plot['max'] < 960
                    for plot in plots
                ), plots
                # Quarter-hour choices need an end on a quarter-hour boundary.
                end = (int(time.time()) - 600) // 900 * 900
                evaluate(
                    '''(() => {
                    // pad(n) formats a local date component as two digits.
                    const pad = n => String(n).padStart(2, '0');
                    // set(prefix, t) fills range controls from Unix seconds.
                    const set = (prefix, t) => {
                        const d = new Date(t * 1000);
                        const date = document.querySelector('[name=' + prefix + '_date]');
                        const time = document.querySelector('[name=' + prefix + '_time]');
                        const day = d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
                        const clock = pad(d.getHours()) + ':' + pad(d.getMinutes());
                        // The themed calendar combines the local date and time.
                        if (time.hidden) date.value = day + ' ' + clock;
                        // Native browser controls keep the two fields separate.
                        else { date.value = day; time.value = clock; }
                    };
                    set('statistics_from', '''
                    + str(end - 7200)
                    + ''');
                    set('statistics_to', '''
                    + str(end)
                    + ''');
                    document.querySelector('.cloudmin-statistics-apply').click();
                })()'''
                )
                wait(
                    '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                )
                plots = chart_state()
                assert plots and all(
                    abs(plot['max'] - plot['min'] - 7200) < 61
                    and abs(plot['max'] - end) < 61
                    for plot in plots
                ), plots
                select_period(3600)
                wait(
                    '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                )
                assert not evaluate(
                    'document.querySelector(".cloudmin-statistics-custom").checkVisibility()'
                )
                check_charts(3600)
                print(
                    'PASS custom range applies an explicit window',
                    theme,
                    flush=True,
                )

            def check_tooltip():
                """
                check_tooltip() hovers a chart and expects readings beside the
                cursor, with no legend.
                """
                evaluate('''(() => {
                    const over = document.querySelector('.cloudmin-statistics-chart-cpu .u-over');
                    const rect = over.getBoundingClientRect();
                    over.dispatchEvent(new MouseEvent('mousemove', {bubbles: true,
                        clientX: rect.left + rect.width * .8, clientY: rect.top + rect.height / 2}));
                })()''')
                time.sleep(.4)
                state = evaluate('''(() => {
                    const tip = document.querySelector('.cloudmin-statistics-chart-cpu .cloudmin-statistics-tooltip');
                    const legend = document.querySelector('.cloudmin-statistics .u-legend');
                    return {visible: !!tip && tip.checkVisibility(),
                        rows: tip ? tip.querySelectorAll('.cloudmin-statistics-tooltip-row').length : 0,
                        legend: legend ? getComputedStyle(legend).display : 'none'};
                })()''')
                # Guests read usage and the wait for the host in one tooltip.
                assert (
                    state['visible']
                    and state['rows'] == (1 if owner == 'host' else 2)
                    and state['legend'] == 'none'
                ), state
                evaluate('''document.querySelector('.cloudmin-statistics-chart-cpu .u-over').dispatchEvent(
                    new MouseEvent('mouseleave', {bubbles: true}))''')
                print(
                    'PASS hover readings replace the legend', theme, flush=True
                )

            def check_initial_loading(owner):
                """
                check_initial_loading(owner) holds the first API reply until
                frames appear.
                """
                wait(
                    'window.statisticsLoadingCheck?.waiting > 0 && document.querySelector(".cloudmin-statistics canvas")'
                )
                state = evaluate('''(() => {
                    const panel = document.querySelector('.cloudmin-statistics');
                    window.statisticsInitialCanvas = panel.querySelector('canvas');
                    return {loading: panel.querySelectorAll('.cloudmin-statistics-plot-loading').length,
                        messages: [...panel.querySelectorAll('.cloudmin-statistics-empty')]
                            .every(node => node.checkVisibility() && node.textContent === 'Loading statistics...'),
                        busy: panel.querySelector('.cloudmin-statistics-status').getAttribute('aria-busy'),
                        notice: panel.querySelector('.cloudmin-statistics-notice').textContent};
                })()''')
                # Hosts add the load average row to the four shared charts.
                assert state['loading'] == (5 if owner == 'host' else 4), state
                assert (
                    state['messages']
                    and state['busy'] == 'true'
                    and not state['notice']
                ), state
                assert all(not any(plot['valid']) for plot in chart_state()), (
                    'Loading charts contain invented readings'
                )

                def header_layouts():
                    """
                    header_layouts() measures headers at desktop and phone
                    widths.
                    """
                    layouts = {}
                    # Sample both column layouts and narrow card breakpoints.
                    for width in (1920, 1600, 1440, 1280, 1100, 900, 480):
                        call(
                            'Emulation.setDeviceMetricsOverride',
                            {
                                'width': width,
                                'height': 1100,
                                'deviceScaleFactor': 1,
                                'mobile': False,
                            },
                        )
                        time.sleep(.3)
                        layouts[width] = (
                            evaluate('''[...document.querySelectorAll('.cloudmin-statistics-chart')].map(card => {
                            const value = card.querySelector('.cloudmin-statistics-value');
                            const detail = card.querySelector('.cloudmin-statistics-detail');
                            const title = card.querySelector('.ui_card_title');
                            // Relative offsets ignore scrolling and page notices.
                            return {top: card.getBoundingClientRect().top,
                                valueTop: value.getBoundingClientRect().top - title.getBoundingClientRect().top,
                                overflow: card.scrollWidth - card.clientWidth,
                                chart: card.querySelector('[data-chart]').dataset.chart,
                                plot: card.querySelector('[data-chart]').getBoundingClientRect().top - card.getBoundingClientRect().top,
                                value: value.getBoundingClientRect().height,
                                detail: detail.getBoundingClientRect().height};
                        })''')
                        )
                    call('Emulation.clearDeviceMetricsOverride')
                    # Guest values belong beside their titles at every width.
                    if owner != 'host':
                        for width, layout in layouts.items():
                            assert all(
                                abs(row['valueTop']) <= 1
                                and row['overflow'] <= 1
                                for row in layout
                            ), (width, layout)
                            for left, right in zip(layout, layout[1:]):
                                # Adjacent cards in one row share a
                                # plot baseline.
                                if abs(left['top'] - right['top']) <= 1:
                                    assert (
                                        abs(left['plot'] - right['plot']) <= 1
                                    ), (width, left, right)
                    return layouts

                # Both headline rows must reserve space before data arrives.
                loading_layouts = header_layouts()
                assert all(
                    row['value'] > 0 and row['detail'] > 0
                    for layout in loading_layouts.values()
                    for row in layout
                ), loading_layouts
                # Release data into the same canvases before measuring again.
                evaluate('''(() => {
                    const check = window.statisticsLoadingCheck;
                    check.hold = false;
                    check.release.splice(0).forEach(release => release());
                })()''')
                wait(
                    '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                )
                assert evaluate(
                    'window.statisticsInitialCanvas === document.querySelector(".cloudmin-statistics canvas")'
                )
                assert not evaluate(
                    'document.querySelector(".cloudmin-statistics-plot-loading")'
                )
                # Readings must not move the plot within its card.
                for width, layout in header_layouts().items():
                    for before, after in zip(loading_layouts[width], layout):
                        assert abs(before['plot'] - after['plot']) <= 1, (
                            width,
                            before,
                            after,
                        )
                print(
                    'PASS loading reserves headline rows and preserves canvases',
                    theme,
                    owner,
                    flush=True,
                )

            def check_changes():
                """
                check_changes() tests the timeline and period labels with
                browser-only events. Stored history is untouched.
                """
                evaluate('''window.statisticsEventFixture = [
                    {t: Math.floor(Date.now()/1000)-1800, kind: 'disk-source', detail: 'Disk vda changed <fixture>'},
                    {t: Math.floor(Date.now()/1000)-1900, kind: 'lifecycle', detail: 'Virtual machine started'}
                ];''')
                # Reuse the same events across periods to catch stale summaries.
                for period, count in (
                    (3600, 1),
                    (3600, 2),
                    (21600, 2),
                    ('custom', 2),
                    (3600, 0),
                ):
                    evaluate(
                        '''(() => {
                        const original = window.fetch;
                        // fetch(...args) injects the next event list.
                        window.fetch = async (...args) => {
                            const response = await original(...args);
                            // Leave other requests unchanged.
                            if (!String(args[0]).includes('action=statistics&')) return response;
                            window.fetch = original;
                            const body = await response.clone().json();
                            body.result.events = window.statisticsEventFixture.slice(0, '''
                        + str(count)
                        + ''');
                            window.statisticsEventRange = {from: body.result.from, to: body.result.to};
                            return new Response(JSON.stringify(body), {status: response.status, headers: response.headers});
                        };
                        // Retain a row to detect unnecessary rebuilding.
                        window.statisticsPreviousEvent = document.querySelector('.cloudmin-statistics-events li');
                        const control = document.querySelector('[name=statistics_range][value="'''
                        + str(period)
                        + '''"]');
                        control.checked = true;
                        control.dispatchEvent(new Event('change', {bubbles: true}));
                    })()'''
                    )
                    wait(
                        '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                    )
                    # Inspect timeline markup and the selected period label.
                    state = evaluate('''(() => {
                        const section = document.querySelector('.cloudmin-statistics-changes');
                        const items = [...section.querySelectorAll('ol.ui_feed > .ui_feed_item')];
                        const first = items[0];
                        // date(t) formats Unix seconds in local time.
                        const date = t => new Date(t*1000).toLocaleString([], {
                            month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'});
                        const range = window.statisticsEventRange;
                        return {visible: section.checkVisibility(), title: section.querySelector('.ui_card_title').textContent,
                            summary: section.querySelector('.cloudmin-statistics-events-summary').textContent,
                            custom: 'between ' + date(range.from) + ' and ' + date(range.to),
                            details: items.map(item => item.querySelector('.ui_feed_text').textContent),
                            times: items.map(item => item.querySelector('time.ui_feed_when').dateTime),
                            dated: !first || first.querySelector('time').textContent === date(window.statisticsEventFixture[0].t),
                            line: first && getComputedStyle(first).borderLeftWidth,
                            marker: first && getComputedStyle(first, '::before').width,
                            same: first === window.statisticsPreviousEvent,
                            tags: section.querySelectorAll('fixture').length};
                    })()''')
                    assert (
                        state['visible'] == bool(count)
                        and state['title'] == 'Events'
                    ), state
                    assert (
                        len(state['details']) == count and state['tags'] == 0
                    ), state
                    # Empty periods leave neither a timeline nor an old summary.
                    if not count:
                        assert state['summary'] == '', state
                        continue
                    # Check safe text, newest-first order and timeline styling.
                    assert (
                        state['details'][0] == 'Disk vda changed <fixture>'
                    ), state
                    assert state['times'] == sorted(
                        state['times'], reverse=True
                    ), state
                    assert (
                        state['line'] == '2px' and state['marker'] == '10px'
                    ), state
                    when = (
                        state['custom']
                        if period == 'custom'
                        else 'in the last hour'
                        if period == 3600
                        else 'in the last 6 hours'
                    )
                    assert (
                        state['summary']
                        == 'Showing '
                        + str(count)
                        + (' event ' if count == 1 else ' events ')
                        + when
                    ), state
                    # Changed periods keep rows when events are unchanged.
                    if period == 21600:
                        assert state['same'], state
                    # Custom ranges need dates on event timestamps.
                    if period == 'custom':
                        assert state['dated'], state
                # Discard browser-only fixtures before the next check.
                evaluate(
                    'delete window.statisticsEventFixture; delete window.statisticsEventRange; delete window.statisticsPreviousEvent;'
                )
                print(
                    'PASS event timeline shows selected periods, escapes text and hides when empty',
                    theme,
                    flush=True,
                )

            def check_filesystem_empty():
                """
                check_filesystem_empty() checks missing guest readings without
                changing history.
                """
                evaluate('''(() => {
                    const original = window.fetch;
                    window.fetch = async (...args) => {
                        const response = await original(...args);
                        // Alter only statistics responses inside this browser
                        // fixture.
                        if (!String(args[0]).includes('action=statistics&')) return response;
                        window.fetch = original;
                        const body = await response.clone().json();
                        body.result.live.guest = null;
                        body.result.series.forEach(row => {
                            row.values.filesystem_total = null;
                            row.values.filesystem_used = null;
                        });
                        return new Response(JSON.stringify(body), {status: response.status, headers: response.headers});
                    };
                    document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));
                })()''')
                wait(
                    '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                )
                state = evaluate('''(() => {
                    const card = document.querySelector('.cloudmin-statistics-filesystems');
                    const message = card.querySelector('.cloudmin-statistics-empty');
                    return {visible: !!message && message.checkVisibility(), text: message ? message.textContent : '',
                        bars: card.querySelectorAll('.cloudmin-statistics-mount').length};
                })()''')
                assert state['visible'] and state['bars'] == 0, state
                assert 'No current filesystem readings.' in state['text'], state
                assert 'guest agent that reports disk space' in state['text'], (
                    state
                )
                print(
                    'PASS missing filesystem readings explain the guest-agent requirement',
                    theme,
                    flush=True,
                )

            def check_host_readings():
                """
                check_host_readings() verifies current host values and
                unavailable readings.
                """
                for available in (True, False):
                    evaluate(
                        '''(() => {
                        const original = window.fetch;
                        window.fetch = async (...args) => {
                            const response = await original(...args);
                            // Alter only statistics responses inside this
                            // browser fixture.
                            if (!String(args[0]).includes('action=statistics&')) return response;
                            window.fetch = original;
                            const body = await response.clone().json();
                            body.result.collector.available = '''
                        + json.dumps(available)
                        + ''';
                            body.result.live = {values: {cpu: 12.5, load_1: 0.42, load_5: 0.38, load_15: 0.35,
                                memory_allocated: 8589934592, memory_used: 0, disk_read: 1024, disk_write: 2048,
                                network_receive: 512, network_transmit: 256}};
                            return new Response(JSON.stringify(body), {status: response.status, headers: response.headers});
                        };
                        document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));
                    })()'''
                    )
                    wait(
                        '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                    )
                    state = evaluate('''({values: [...document.querySelectorAll(".cloudmin-statistics-chart .cloudmin-statistics-value")].map(node => node.textContent),
                        memory: document.querySelector(".cloudmin-statistics-chart-memory .cloudmin-statistics-detail").textContent,
                        load: document.querySelector(".cloudmin-statistics-chart-load .cloudmin-statistics-detail").textContent,
                        disk: document.querySelector(".cloudmin-statistics-chart-disk .cloudmin-statistics-detail").textContent})''')
                    expected = ['12.5%', '0.42', '0 B', '3 KiB/s', '768 B/s']
                    assert state['values'] == (
                        expected if available else ['–'] * 5
                    ), state
                    # Check real zero usage and auxiliary labels only while the
                    # cache is fresh.
                    if available:
                        assert (
                            'of 8 GiB (0%)' in state['memory']
                            and 'Read 1 KiB/s' in state['disk']
                            and 'Write 2 KiB/s' in state['disk']
                        ), state
                        assert (
                            '5 min 0.38' in state['load']
                            and '15 min 0.35' in state['load']
                        ), state
                print(
                    'PASS host readings preserve zero and clear stale data',
                    theme,
                    flush=True,
                )

            def check_device_selector(owner):
                """
                check_device_selector(owner) varies browser-only inventory and
                period choices.
                """
                evaluate('''(() => {
                    const original = window.fetch;
                    const check = window.statisticsDeviceCheck = {original, disks: 1, networks: 1, requests: []};
                    const host = JSON.parse(document.querySelector('.cloudmin-statistics').dataset.statistics).owner === 'host';
                    window.fetch = async (...args) => {
                        const response = await original(...args);
                        // Alter only statistics responses inside this browser
                        // fixture.
                        if (!String(args[0]).includes('action=statistics&')) return response;
                        const params = new URL(args[0], location.href).searchParams;
                        const selected = params.get('entity');
                        check.requests.push(selected);
                        const body = await response.clone().json();
                        const disks = check.byPeriod ? (params.get('to') - params.get('from') > 3600 ? 2 : 1) : check.disks;
                        body.result.entities = [
                            ...Array.from({length: disks}, (_, i) => ({id: 'disk'+i, kind: host ? 'block' : 'disk', label: 'Disk '+i})),
                            ...Array.from({length: check.networks}, (_, i) => ({id: 'net'+i, kind: host ? 'uplink' : 'nic', label: 'Interface '+i}))];
                        body.result.series = [body.result.from, body.result.to].map(t => ({t,
                            values: {cpu: selected ? 99 : 17, disk_read: 32, network_receive: 64}, coverage: {}}));
                        return new Response(JSON.stringify(body), {status: response.status, headers: response.headers});
                    };
                })()''')
                try:
                    for disks, networks in (
                        (0, 0),
                        (1, 0),
                        (0, 1),
                        (1, 1),
                        (2, 0),
                        (0, 2),
                        (2, 1),
                        (1, 2),
                    ):
                        evaluate(
                            '''Object.assign(window.statisticsDeviceCheck, '''
                            + json.dumps({'disks': disks, 'networks': networks})
                            + ''');
                            document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));'''
                        )
                        wait(
                            '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                        )
                        state = evaluate('''({visible: document.querySelector('.cloudmin-statistics-device').checkVisibility(),
                            options: document.querySelector('[name=statistics_device]').options.length})''')
                        visible = disks > 1 or networks > 1
                        assert state == {
                            'visible': visible,
                            'options': disks + networks + 1 if visible else 1,
                        }, state
                    # A wider period includes a removed disk. Shrinking the
                    # period must fetch totals, even if the selected
                    # disk remains.
                    for selected in ('disk0', 'disk1'):
                        evaluate(
                            'Object.assign(window.statisticsDeviceCheck, {byPeriod: true, networks: 1})'
                        )
                        select_period(86400)
                        wait(
                            '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                        )
                        evaluate(
                            '''var select = document.querySelector('[name=statistics_device]'); select.value = '''
                            + json.dumps(selected)
                            + ''';
                            select.dispatchEvent(new Event('change', {bubbles: true}));'''
                        )
                        wait(
                            '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                        )
                        assert visible_charts() == 1
                        # Device-specific guest views must also hide aggregate
                        # filesystem bars.
                        if owner != 'host':
                            assert not evaluate(
                                'document.querySelector(".cloudmin-statistics-filesystems").checkVisibility()'
                            )
                        evaluate('window.statisticsDeviceCheck.requests = []')
                        select_period(3600)
                        wait(
                            '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                        )
                        assert evaluate(
                            'window.statisticsDeviceCheck.requests'
                        ) == [selected, None]
                        assert not evaluate(
                            'document.querySelector(".cloudmin-statistics-device").checkVisibility()'
                        )
                        assert visible_charts() == (5 if owner == 'host' else 4)
                        assert any(
                            plot['last'][:1] == [17] for plot in chart_state()
                        ), 'Default view did not fetch aggregate CPU readings'
                    print(
                        'PASS device counts and period changes preserve aggregate readings',
                        theme,
                        owner,
                        flush=True,
                    )
                finally:
                    evaluate('''window.fetch = window.statisticsDeviceCheck.original; delete window.statisticsDeviceCheck;
                        document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));''')
                    wait(
                        '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                    )

            def check_failed_refresh(owner):
                """
                check_failed_refresh(owner) clears readings after a rejected
                refresh and recovers.
                """
                evaluate('''(() => {
                    const check = window.statisticsFailureCheck = {original: window.fetch, fail: false, used: 524288};
                    window.fetch = async (...args) => {
                        const response = await check.original(...args);
                        // Alter only statistics responses inside this browser
                        // fixture.
                        if (!String(args[0]).includes('action=statistics&')) return response;
                        // Simulate access revocation after a successful private
                        // reading.
                        if (check.fail) return new Response('{}', {status: 403});
                        const body = await response.json();
                        const entry = {name: 'private-fixture', mountpoint: '/private-fixture',
                            capacity: 1048576, allocation: check.used,
                            'total-bytes': 1048576, 'used-bytes': check.used};
                        // Host and guest responses expose storage through
                        // different fields.
                        if (body.result.live.values) body.result.live.pools = [entry];
                        // Guest filesystem entries use guest-agent byte field
                        // names.
                        else body.result.live.guest = {filesystems: [entry]};
                        return new Response(JSON.stringify(body), {status: response.status, headers: response.headers});
                    };
                    document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));
                })()''')
                try:
                    wait(
                        'document.querySelector(".cloudmin-statistics-mounts").textContent.includes("private-fixture")'
                    )
                    # Missing usage must stay distinct from an empty filesystem.
                    # Overcommit keeps the real figure. Only the bar stops
                    # at full.
                    for used, expected, width in (
                        (None, '– of 1 MiB (–%)', '0%'),
                        (0, '0 B of 1 MiB (0%)', '0%'),
                        (2097152, '2 MiB of 1 MiB (200%)', '100%'),
                    ):
                        evaluate(
                            'window.statisticsFailureCheck.used = '
                            + json.dumps(used)
                            + ''';
                            document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));'''
                        )
                        wait(
                            '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                        )
                        usage = evaluate('''({text: document.querySelector(".cloudmin-statistics-mount-usage").textContent,
                            width: document.querySelector(".cloudmin-statistics-mount .ui_progress_bar").style.width})''')
                        assert usage == {'text': expected, 'width': width}, (
                            usage
                        )
                    evaluate('''window.statisticsFailureCheck.fail = true;
                        document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));''')
                    wait(
                        'document.querySelector(".cloudmin-statistics-notice").dataset.state === "danger"'
                    )
                    state = evaluate('''({mounts: document.querySelector(".cloudmin-statistics-mounts").textContent,
                        change: document.querySelector(".cloudmin-statistics-change").textContent,
                        canvases: document.querySelectorAll(".cloudmin-statistics canvas").length,
                        values: [...document.querySelectorAll(".cloudmin-statistics-value")].map(node => node.textContent),
                        bar: document.querySelector(".cloudmin-statistics-bar-fill").style.width})''')
                    assert (
                        not state['mounts']
                        and not state['change']
                        and state['canvases'] == 0
                    ), state
                    assert (
                        all(value == '–' for value in state['values'])
                        and state['bar'] == '0px'
                    ), state
                    print(
                        'PASS failed refresh clears charts and storage readings',
                        theme,
                        owner,
                        flush=True,
                    )
                finally:
                    evaluate('''window.fetch = window.statisticsFailureCheck.original; delete window.statisticsFailureCheck;
                        document.querySelector('[name=statistics_range]:checked').dispatchEvent(new Event('change', {bubbles: true}));''')
                    wait(
                        'document.querySelector(".cloudmin-statistics canvas") && !document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                    )

            # Attach one isolated page and observe its runtime, navigation
            # and requests.
            target = call('Target.createTarget', {'url': 'about:blank'})[
                'targetId'
            ]
            target_session = call(
                'Target.attachToTarget', {'targetId': target, 'flatten': True}
            )['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain + '.enable')
            # Delay statistics replies in new content frames too. Collection
            # and requests continue normally.
            call(
                'Page.addScriptToEvaluateOnNewDocument',
                {
                    'source': '''(() => {
                const original = window.fetch;
                const check = window.statisticsLoadingCheck = {hold: true, waiting: 0, release: []};
                window.fetch = (...args) => {
                    const response = original(...args);
                    // Leave other requests and already released refreshes
                    // unchanged.
                    if (!check.hold || !String(args[0]).includes('action=statistics&')) return response;
                    check.waiting++;
                    return Promise.all([response, new Promise(resolve => check.release.push(resolve))])
                        .then(([response]) => response);
                };
            })();'''
                },
            )
            # Authenticate the fixture browser without logging or
            # exporting credentials.
            for cookie in cookies:
                call(
                    'Network.setCookie',
                    {
                        'name': cookie.name,
                        'value': cookie.value,
                        'url': base,
                        'path': cookie.path,
                        'secure': True,
                    },
                )
            call('Page.navigate', {'url': base + '/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            # Wait for SPA link handlers before the first navigation.
            wait(
                '!top.document.querySelector("aside") || top.document.body.dataset.initialLoad === "0"'
            )
            # Exercise both statistics pages through real navigation in
            # each theme.
            for owner in ('host', guest):
                overview = (
                    '/server-manager/index.cgi'
                    if owner == 'host'
                    else '/server-manager/machine.cgi?id=' + guest
                )
                path = '/server-manager/statistics.cgi' + (
                    '' if owner == 'host' else '?id=' + guest
                )
                navigate(overview)
                marker = (
                    '#cloudmin-overview'
                    if owner == 'host'
                    else '#cloudmin-vm-status'
                )
                wait('document.querySelector(' + json.dumps(marker) + ')')
                assert not evaluate(
                    'document.querySelector(".cloudmin-statistics, [id^=host_tabs], [id^=vm_details_tabs]")'
                ), 'Overview/details still contain statistics tabs or charts'
                # Use actual menu links and check their labels.
                link = menu_link(path)
                wait(link)
                title = (
                    'Host Statistics' if owner == 'host' else 'Guest Statistics'
                )
                assert evaluate(
                    '('
                    + link
                    + ').textContent.includes('
                    + json.dumps(title)
                    + ')'
                )
                # Check the shared chart icon supplied by this theme.
                if theme == 'authentic-theme':
                    assert evaluate(
                        '('
                        + link
                        + ').querySelector(".fa-area-chart") !== null'
                    ), 'Missing statistics menu icon'
                # Hold data replies to inspect the initial axes before
                # releasing measurements.
                evaluate(
                    'window.statisticsLoadingCheck.hold = true; window.statisticsLoadingCheck.waiting = 0'
                )
                evaluate('(' + link + ').click()')
                wait(
                    'document.querySelector(".cloudmin-statistics") && '
                    'JSON.parse(document.querySelector(".cloudmin-statistics").dataset.statistics).owner === '
                    + json.dumps(owner)
                )
                assert evaluate(
                    'document.body.textContent.includes('
                    + json.dumps(title)
                    + ')'
                )
                wait(
                    'document.querySelector(".cloudmin-statistics").getClientRects().length'
                )
                evaluate(
                    'document.querySelector(".cloudmin-statistics").scrollIntoView({block:"start"})'
                )
                check_initial_loading(owner)
                assert not evaluate(
                    'document.querySelector(".cloudmin-statistics-notice").textContent.includes("Could not")'
                )
                assert (
                    evaluate(
                        "document.querySelectorAll('script[src*=\"uplot.min.js\"]').length"
                    )
                    <= 1
                )
                assert (
                    evaluate(
                        'document.querySelectorAll(".cloudmin-statistics").length'
                    )
                    == 1
                )
                assert evaluate(
                    'document.querySelector(".cloudmin-statistics").scrollWidth <= document.querySelector(".cloudmin-statistics").clientWidth + 2'
                )
                # After release, check ranges and failed refreshes.
                check_charts(3600)
                check_palette()
                check_failed_refresh(owner)
                if owner != 'host':
                    # The guest CPU chart carries a second series: time its
                    # vCPUs waited for the host, from libvirt's vcpu stats.
                    cpu = chart_state()[0]
                    assert len(cpu['valid']) == 2 and cpu['valid'][1] >= 1, cpu
                    detail = evaluate(
                        'document.querySelector(".cloudmin-statistics-chart-cpu .cloudmin-statistics-detail").textContent'
                    )
                    assert re.search(r'waiting \d+\.\d%', detail), detail
                    print(
                        'PASS guest CPU chart reports time waiting for the host',
                        theme,
                        flush=True,
                    )
                else:
                    # Hosts list their storage pools as usage bars and show what
                    # running guests hold against the host's capacity.
                    state = evaluate('''({pools: document.querySelectorAll(".cloudmin-statistics-pools .cloudmin-statistics-mount").length,
                        cpu: document.querySelector(".cloudmin-statistics-chart-cpu .cloudmin-statistics-detail").textContent,
                        memory: document.querySelector(".cloudmin-statistics-chart-memory .cloudmin-statistics-detail").textContent})''')
                    assert (
                        state['pools'] >= 1
                        and re.search(r'\d+ vCPUs allocated', state['cpu'])
                        and 'allocated to guests' in state['memory']
                    ), state
                    print(
                        'PASS host lists storage pools and guest allocations',
                        theme,
                        flush=True,
                    )
                # Agent-capable fixtures must render at least one filesystem
                # usage bar.
                if owner != 'host' and args.require_filesystems:
                    wait('document.querySelector(".cloudmin-statistics-mount")')
                check_refresh_scroll()
                check_sticky_toolbar()
                check_zoom()
                check_custom_range()
                check_tooltip()
                check_changes()
                # Host headlines and guest filesystem empty states need
                # different fixtures.
                if owner == 'host':
                    check_host_readings()
                else:
                    # Missing agent readings need an explanation instead of
                    # empty bars.
                    check_filesystem_empty()
                check_device_selector(owner)
                # A longer history range must remain usable before testing
                # narrow viewports.
                select_period(86400)
                wait(
                    '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                )
                assert evaluate(
                    'document.querySelector(".cloudmin-statistics .uplot canvas") !== null'
                )
                check_charts(86400)
                # Narrow viewports must resize canvases rather than overflow.
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': 480,
                        'height': 900,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                time.sleep(.5)
                assert evaluate(
                    'document.querySelector(".cloudmin-statistics").scrollWidth <= document.querySelector(".cloudmin-statistics").clientWidth + 2'
                ), 'Narrow chart panel overflows'
                call('Emulation.clearDeviceMetricsOverride')
                # A browser-only sparse response exercises first-sample scaling.
                # Existing history and the running collector remain untouched.
                evaluate('''(() => {
                    const original = window.fetch;
                    window.fetch = async (...args) => {
                        const response = await original(...args);
                        // Alter only statistics responses inside this browser
                        // fixture.
                        if (!String(args[0]).includes('action=statistics&')) return response;
                        window.fetch = original;
                        const body = await response.clone().json();
                        const row = body.result.series.findLast(row =>
                            Object.values(row.values).some(value => value != null));
                        body.result.series = row ? [row] : [];
                        return new Response(JSON.stringify(body), {
                            status: response.status, headers: response.headers});
                    };
                    document.querySelector('[name=statistics_range][value="3600"]').click();
                })()''')
                wait(
                    '!document.querySelector(".cloudmin-statistics-status").hasAttribute("aria-busy")'
                )
                check_charts(3600, single=True)
                # Leaving a statistics page must release its polling timer.
                evaluate('(' + menu_link(overview) + ').click()')
                wait('document.querySelector(' + json.dumps(marker) + ')')
                assert not evaluate(
                    'document.querySelector(".cloudmin-statistics")'
                )
                time.sleep(.5)
                evaluate('true')
                paused_reads = statistics_reads
                time.sleep(11)
                evaluate('true')
                assert statistics_reads == paused_reads, (
                    'Statistics keep polling after navigation'
                )
                # Returning to the page must start a new polling lifecycle.
                evaluate('(' + menu_link(path) + ').click()')
                wait(
                    'document.querySelector(".cloudmin-statistics")?.checkVisibility()'
                )
                evaluate(
                    'document.querySelector(".cloudmin-statistics").scrollIntoView({block:"start"})'
                )
                wait(
                    'document.querySelector(".cloudmin-statistics .uplot canvas")'
                )
                assert statistics_reads > paused_reads, (
                    'Reopened history does not refresh'
                )
                print(
                    'PASS browser',
                    theme,
                    'host' if owner == 'host' else 'VM',
                    flush=True,
                )
            # The relative service-worker URL has a known module-page 404,
            # also excluded by the console and lifecycle browser fixtures.
            errors = []
            for error in exceptions:
                description = error.get('exception', {}).get('description', '')
                if (
                    'Failed to register a ServiceWorker' in description
                    and '404' in description
                    and base + '/server-manager/service-worker.js'
                    in description
                ):
                    print(
                        'NOTE existing theme service-worker 404',
                        theme,
                        flush=True,
                    )
                else:
                    # Any other script error is a fixture failure.
                    errors.append(error)
            assert not errors, errors
        finally:
            # Close the fixture browser even when a chart or access
            # assertion fails.
            if cdp:
                try:
                    cdp.send(
                        json.dumps({'id': 999999, 'method': 'Browser.close'})
                    )
                except websocket.WebSocketException:
                    pass
                cdp.close()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                chrome.kill()
                chrome.wait(timeout=10)


def live_status(opener, cookies, guest):
    """
    live_status(opener, cookies, guest) checks readings on the status WebSocket.
    """
    request = urllib.request.Request(
        base + '/server-manager/machine_status.cgi',
        headers={'Referer': base + '/'},
    )
    channel = json.loads(opener.open(request, timeout=30).read())
    assert 'socket_url' in channel, channel.get('error')
    sock = websocket.create_connection(
        channel['socket_url'],
        cookie='; '.join(item.name + '=' + item.value for item in cookies),
        origin=base,
        sslopt={'cert_reqs': ssl.CERT_NONE},
        timeout=30,
    )
    try:
        sock.send(json.dumps({'id': 'overview', 'paused': False}))
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            sock.settimeout(max(.1, deadline - time.monotonic()))
            message = json.loads(sock.recv())
            assert message.get('type') != 'error', message
            resources = (
                message.get('changed', {}).get(guest, {}).get('resources') or {}
            )
            # Wait for a measured rate rather than accepting an initial
            # counter baseline.
            if resources.get('cpu_percent') is not None:
                assert resources.get('memory_bytes', 0) > 0
                print(
                    'PASS shared collector readings reach the existing status channel',
                    flush=True,
                )
                return
        raise AssertionError(
            'Status channel did not receive collected resources'
        )
    finally:
        sock.close()


# Select an existing running guest without creating or reconfiguring guests.
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--guest', help='Prefer this running VM UUID for the browser checks'
)
parser.add_argument(
    '--require-filesystems',
    action='store_true',
    help='Require guest-agent filesystem readings for the selected VM',
)
args = parser.parse_args()
connection = libvirt.openReadOnly('qemu:///system')
guests = [
    domain.UUIDString()
    for domain in connection.listAllDomains()
    if domain.isActive()
]
connection.close()
assert guests, (
    'At least one running test VM is required for live chart validation'
)
# Honor a requested running UUID without silently substituting another guest.
if args.guest:
    assert args.guest in guests, 'Requested VM must be running'
    guests.remove(args.guest)
    guests.insert(0, args.guest)
# Each theme gets its own temporary account, cookie jar and browser profile.
for theme in ('authentic-theme', 'gray-theme'):
    user = 'cloudmin-ui-check-' + secrets.token_hex(4)
    password = secrets.token_urlsafe(36)
    try:
        opener, cookies = session(theme, user, password)
        deadline = time.monotonic() + 150
        while True:
            host = api(opener, action='statistics', id='host')['result']
            vm = api(opener, action='statistics', id=guests[0])['result']
            # Begin assertions only after the collector has a current, measured
            # VM rate.
            if (
                host['collector']['available']
                and vm.get('live', {}).get('resources', {}).get('cpu_percent')
                is not None
            ):
                break
            assert time.monotonic() < deadline, (
                'Collector never produced a fresh rate'
            )
            time.sleep(1)
        assert host['collector']['available'], host.get('collector')
        assert not host['collector'].get('error'), host.get('collector')
        assert vm['live']['resources']['cpu_percent'] is not None
        assert any(
            row['values']['memory_allocated'] is not None
            for row in vm['series']
        )
        # Agent-capable fixtures must reach both the live cache and stored
        # charts. This catches a collector using libvirt's forbidden
        # read-only connection.
        if args.require_filesystems:
            deadline = time.monotonic() + 150
            while True:
                guest = vm['live'].get('guest') or {}
                recorded = any(
                    row['values']['filesystem_total'] is not None
                    and row['values']['filesystem_used'] is not None
                    for row in vm['series']
                )
                # Require the agent reading in both the live cache and persisted
                # chart data.
                if (
                    guest.get('filesystem_total_bytes', 0) > 0
                    and guest.get('filesystem_used_bytes') is not None
                    and recorded
                ):
                    break
                assert time.monotonic() < deadline, (
                    'Filesystem readings never reached live cache and history'
                )
                time.sleep(1)
                vm = api(opener, action='statistics', id=guests[0])['result']
            print(
                'PASS guest filesystem readings reach the live cache and stored history',
                theme,
                flush=True,
            )
        # Check export retry stability and owner scoping through
        # authenticated calls.
        batch = api(opener, action='statistics_export', limit=1)['result']
        assert batch['rows'], (
            'Wait at least one minute after first collection before running this fixture'
        )
        assert (
            batch == api(opener, action='statistics_export', limit=1)['result']
        )
        assert (
            api(
                opener,
                action='statistics',
                id=guests[0],
                entity=host['host_id'],
            )['result']['series']
            == []
        )
        statistics_page(opener)
        statistics_page(opener, guests[0])
        statistics_page(opener, 'invalid', allowed=False)
        browser(cookies, theme, guests[0])
        live_status(opener, cookies, guests[0])
        # Change the same session's ACL and verify
        # immediate filtering/revocation.
        subprocess.run(
            ['perl', str(helper), 'acl', theme, user],
            input=json.dumps({'admin': 0, 'vms': guests[0]}),
            text=True,
            check=True,
        )
        assert 'result' in api(opener, action='statistics', id=guests[0])
        assert 'error' in api(opener, action='statistics', id='host')
        assert 'error' in api(opener, action='statistics_export')
        statistics_page(opener, guests[0])
        statistics_page(opener, allowed=False)
        # A second running guest makes the cross-guest denial observable.
        if len(guests) > 1:
            assert 'error' in api(opener, action='statistics', id=guests[1])
            statistics_page(opener, guests[1], allowed=False)
        # Revoking the last guest grant must affect the already
        # authenticated session.
        subprocess.run(
            ['perl', str(helper), 'acl', theme, user],
            input=json.dumps({'admin': 0}),
            text=True,
            check=True,
        )
        assert 'error' in api(opener, action='statistics', id=guests[0])
        statistics_page(opener, guests[0], allowed=False)
        print(
            'PASS API scope, export retry and live ACL revocation',
            theme,
            flush=True,
        )
    finally:
        subprocess.run(['perl', str(helper), 'delete', theme, user], check=True)
print(
    'Temporary Webmin users and browser profiles removed; guests unchanged',
    flush=True,
)
