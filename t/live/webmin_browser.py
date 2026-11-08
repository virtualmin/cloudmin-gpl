"""
Exercise root-only guest Webmin embedding without changing account settings.
"""

import json
import os
import signal
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import websocket


# check_webmin_browser(uuid, [webmin_only]) uses a temporary root session.
# webmin_only defaults to false; true skips the later serial and
# graphical checks.
def check_webmin_browser(uuid, webmin_only=False):
    helper = Path(__file__).with_name('webmin-user.pl')
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for guest Webmin checks'
    parent = (
        Path('/root/snap/chromium/common')
        if browser.startswith('/snap/')
        else None
    )
    # Confined Chromium needs a profile inside its permitted guest directory.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    # Use a temporary root session; keep administrator settings unchanged.
    credentials = json.loads(
        subprocess.check_output(
            ['perl', str(helper), 'root-session'], text=True
        )
    )
    theme = credentials['theme']
    chrome = cdp = profile = None
    try:
        # Use a fresh browser profile to exclude saved sessions.
        profile = tempfile.TemporaryDirectory(
            prefix='cloudmin-webmin-browser-', dir=parent
        )
        chrome = subprocess.Popen(
            [
                browser,
                '--headless',
                '--no-sandbox',
                '--disable-gpu',
                '--remote-debugging-port=0',
                '--ignore-certificate-errors',
                '--no-first-run',
                '--no-default-browser-check',
                '--disable-background-networking',
                '--disable-sync',
                '--window-size=1600,1000',
                '--user-data-dir=' + profile.name,
                'about:blank',
            ],
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Connect only to the debugging endpoint created by this test browser.
        active = Path(profile.name) / 'DevToolsActivePort'
        deadline = time.monotonic() + 30
        while not active.exists() and time.monotonic() < deadline:
            time.sleep(.2)
        port, route = active.read_text().splitlines()
        cdp = websocket.create_connection(
            'ws://127.0.0.1:' + port + route, timeout=30, suppress_origin=True
        )
        serial, session = 0, None
        paused, sent = [], []

        # call(method, [params]) handles events while waiting for a CDP reply.
        def call(method, params=None):
            nonlocal serial
            serial += 1
            command = dict(id=serial, method=method, params=params or {})
            # Browser-level setup precedes page-session attachment.
            if session:
                command['sessionId'] = session
            cdp.send(json.dumps(command))
            while True:
                reply = json.loads(cdp.recv())
                # Hold intercepted requests until the loading surface
                # is checked.
                if reply.get('method') == 'Fetch.requestPaused':
                    paused.append(reply['params']['requestId'])
                # Record whether startup sends input before the user types.
                if reply.get('method') == 'Network.webSocketFrameSent':
                    frame = reply['params']['response']
                    # Capture binary guest input, not WebSocket control frames.
                    if frame['opcode'] == 2:
                        sent.append(frame['payloadData'])
                # Ignore events and replies unrelated to this command.
                if reply.get('id') == serial:
                    assert 'error' not in reply, reply.get('error')
                    return reply.get('result', {})

        # evaluate(expression, [navigating]) uses the module's content pane.
        def evaluate(expression, navigating=False):
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
            # Navigation can replace the execution context while a check runs.
            if navigating and 'exceptionDetails' in result:
                return None
            assert 'exceptionDetails' not in result, (
                'Browser evaluation failed: '
                + str(
                    result.get('exceptionDetails', {})
                    .get('exception', {})
                    .get('description', '')
                    .splitlines()[:1]
                )
            )
            return result.get('result', {}).get('value')

        # wait(expression) allows navigation and guest startup to settle.
        def wait(expression):
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                # Retry while navigation replaces the document.
                if evaluate('!!(' + expression + ')', navigating=True):
                    return
                time.sleep(.3)
            detail = evaluate('document.body?.innerText.slice(-1200)')
            raise AssertionError(
                'Webmin browser condition failed: '
                + expression
                + '; page: '
                + str(detail)
            )

        # resume_requests([abort]) releases delayed requests. Serial setup
        # is aborted so this display check cannot take a user's live port.
        def resume_requests(abort=False):
            while paused:
                # Keep display checks from taking the user's serial port.
                if abort:
                    call(
                        'Fetch.failRequest',
                        {
                            'requestId': paused.pop(0),
                            'errorReason': 'BlockedByClient',
                        },
                    )
                else:
                    # Webmin and graphical checks continue their delayed setup.
                    call('Fetch.continueRequest', {'requestId': paused.pop(0)})
            call('Fetch.disable')

        # loading_surface(selector) checks paint before initialization.
        def loading_surface(selector):
            wait('document.querySelector(' + json.dumps(selector) + ')')
            deadline = time.monotonic() + 10
            # Wait for a paused request before checking the loading background.
            while not paused and time.monotonic() < deadline:
                evaluate('true')
                time.sleep(.05)
            assert paused, 'No initialization request was delayed'
            assert evaluate(
                '(s => {const e=document.querySelector(s); return getComputedStyle(e).backgroundColor === "rgb(0, 0, 0)" && e.getBoundingClientRect().height >= 240})( '
                + json.dumps(selector)
                + ')'
            ), 'Loading surface is not a visible black rectangle'

        # check_header_controls(selectors) compares normal and hovered
        # controls with the native Help button in the same header.
        def check_header_controls(selectors):
            call('Page.bringToFront')
            help_button = '.panel-heading a[href*="/help.cgi/"]'
            style = '(s => {const e=document.querySelector(s), c=getComputedStyle(e); return {background:c.backgroundColor, color:c.color, border:c.borderColor, height:e.getBoundingClientRect().height, top:e.getBoundingClientRect().top}})'
            call(
                'Input.dispatchMouseEvent',
                {'type': 'mouseMoved', 'x': 0, 'y': 0},
            )
            time.sleep(.3)
            normal = evaluate(style + '(' + json.dumps(help_button) + ')')
            # Match native dimensions and colors before testing pointer hover.
            for selector in selectors:
                actual = evaluate(style + '(' + json.dumps(selector) + ')')
                assert actual == normal, (
                    'Header control does not match native Help styling: '
                    + selector
                    + '; expected '
                    + str(normal)
                    + '; got '
                    + str(actual)
                )
                # All remote access actions belong to the left of Help.
                assert evaluate(
                    '(s => document.querySelector(s).getBoundingClientRect().right <= document.querySelector('
                    + json.dumps(help_button)
                    + ').getBoundingClientRect().left + 1)('
                    + json.dumps(selector)
                    + ')'
                ), 'Header control appears to the right of Help: ' + selector
                assert (
                    evaluate(
                        'document.querySelector('
                        + json.dumps(selector)
                        + ').textContent.trim()'
                    )
                    == ''
                ), 'Header control is not an icon'
                assert evaluate(
                    '!!document.querySelector('
                    + json.dumps(selector)
                    + ').getAttribute("aria-label")'
                ), 'Icon has no accessible label'
                assert evaluate(
                    '(s => {const icon=document.querySelector(s).querySelector("svg, i"); return !!icon && (icon.tagName.toLowerCase() === "svg" || !["none", "normal", "\\\"\\\""].includes(getComputedStyle(icon, "::before").content))})('
                    + json.dumps(selector)
                    + ')'
                ), 'Header icon has no glyph'
            hovered = []
            # Move the real pointer so CSS hover selectors take effect.
            for selector in [help_button, *selectors]:
                rect = evaluate(
                    'document.querySelector('
                    + json.dumps(selector)
                    + ').getBoundingClientRect().toJSON()'
                )
                call(
                    'Input.dispatchMouseEvent',
                    {
                        'type': 'mouseMoved',
                        'x': rect['x'] + rect['width'] / 2,
                        'y': rect['y'] + rect['height'] / 2,
                    },
                )
                time.sleep(.3)
                assert evaluate(
                    'document.querySelector('
                    + json.dumps(selector)
                    + ').matches(":hover")'
                ), (
                    'Pointer did not reach header control: '
                    + selector
                    + '; hit '
                    + str(
                        evaluate(
                            'document.elementFromPoint('
                            + str(rect['x'] + rect['width'] / 2)
                            + ','
                            + str(rect['y'] + rect['height'] / 2)
                            + ')?.outerHTML'
                        )
                    )
                )
                value = evaluate(style + '(' + json.dumps(selector) + ')')
                # Help has its own hover text color; compare the shared
                # button background, border and geometry instead.
                value.pop('color')
                hovered.append(value)
            assert all(value == hovered[0] for value in hovered[1:]), (
                'Header hover styling differs from native Help: ' + str(hovered)
            )
            call(
                'Input.dispatchMouseEvent',
                {'type': 'mouseMoved', 'x': 0, 'y': 0},
            )

        # fullscreen_geometry(selector) measures the rendered icon, since
        # identical SVG markup can still shrink inside a padded button.
        def fullscreen_geometry(selector):
            return evaluate(
                '(s => {const b=document.querySelector(s).getBoundingClientRect(), i=document.querySelector(s + " svg").getBoundingClientRect(); return {width:i.width,height:i.height,x:i.x-b.x,y:i.y-b.y}})('
                + json.dumps(selector)
                + ')'
            )

        # Set only the temporary session cookie before opening the host shell.
        target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
        session = call(
            'Target.attachToTarget', {'targetId': target, 'flatten': True}
        )['sessionId']
        for domain in ('Page', 'Runtime', 'Network'):
            call(domain + '.enable')
        call(
            'Network.setCookie',
            {
                'name': 'sid',
                'value': credentials['sid'],
                'url': 'https://127.0.0.1:10000',
                'secure': True,
                'httpOnly': True,
            },
        )
        call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
        wait('top.document.querySelector("aside") || top.frames.left')
        route = '/server-manager/remote_access.cgi?id=' + uuid + '&tab=webmin'
        # Wait for navigation handlers before clicking a link.
        if theme == 'authentic-theme':
            wait('document.body.getAttribute("data-initial-load") === "0"')
        else:
            # Frames exist before their initial document loads. Wait for a
            # real page so navigation sends Webmin its required referrer.
            wait(
                'location.protocol === "https:" && document.readyState === "complete" && document.body?.innerText.length > 20'
            )
        # Delay the proxy document to inspect the black surface before loading.
        call(
            'Fetch.enable',
            {
                'patterns': [
                    {
                        'urlPattern': '*servers/link.cgi/*',
                        'resourceType': 'Document',
                    }
                ]
            },
        )
        evaluate(
            '(() => {let a=document.createElement("a"); a.href='
            + json.dumps(route)
            + '; document.body.append(a); a.click(); a.remove();})()'
        )
        wait(
            'document.querySelector(".cloudmin-webmin-notice [data-webmin-direct]")'
        )
        assert not evaluate(
            'document.querySelector("select[name=webmin_view]") !== null'
        )
        assert evaluate(
            'document.querySelector(".cloudmin-webmin-notice").innerText.includes("compromise the host and all other virtual machines")'
        )
        assert not evaluate(
            'document.querySelector(".cloudmin-webmin-view iframe") !== null'
        )
        assert not paused, 'Default options requested a proxied guest page'
        direct = evaluate('document.querySelector("[data-webmin-direct]").href')
        assert (
            direct.startswith('https://') and '/servers/link.cgi/' not in direct
        )
        assert evaluate(
            'new URL(document.querySelector("[data-webmin-direct]").href).origin !== location.origin'
        )
        # Both actions follow the warning, without a mode selector or
        # hidden panel.
        assert evaluate(
            'document.querySelector(".cloudmin-webmin-notice [data-webmin-direct]").getBoundingClientRect().height > 0'
        )
        assert evaluate(
            'document.querySelector(".cloudmin-webmin-notice [type=submit]").getBoundingClientRect().height > 0'
        )
        expected_alerts = (
            1
            if evaluate(
                'document.querySelector("[name=accept_webmin_address]") !== null'
            )
            else 0
        )
        assert (
            evaluate(
                'document.querySelectorAll(".cloudmin-webmin-notice .ui_card_warning").length'
            )
            == 1
        )
        assert (
            evaluate(
                'document.querySelectorAll(".cloudmin-webmin-notice .alert-warning").length'
            )
            == expected_alerts
        )
        assert not evaluate(
            'document.querySelector(".cloudmin-webmin-notice .ui_card_foot, .cloudmin-webmin-notice .ui_form_grouped_buttons") !== null'
        )
        assert evaluate(
            'document.querySelector(".cloudmin-webmin-notice [type=submit]").closest(".ui_card_body") !== null'
        )
        assert evaluate(
            'document.querySelector(".cloudmin-webmin-notice [type=submit]").getBoundingClientRect().left - document.querySelector(".cloudmin-webmin-notice [data-webmin-direct]").getBoundingClientRect().right < 30'
        )
        if expected_alerts:
            # Address warnings must appear before the card, not inside its body.
            assert evaluate(
                'document.querySelector(".cloudmin-webmin-notice > .alert-warning").getBoundingClientRect().bottom <= document.querySelector(".cloudmin-webmin-notice > .ui_card").getBoundingClientRect().top'
            )
        if not evaluate(
            'document.querySelector("[name=accept_webmin_address]") !== null'
        ):
            # The address-acceptance button replaces Connect when an IP changed.
            evaluate('document.querySelector("[name=connect_webmin]").click()')
        wait(
            'document.querySelector(".cloudmin-webmin-view iframe, [name=accept_webmin_address]")'
        )
        # Accept a pending test address only when the host confirms its lease.
        if evaluate(
            'document.querySelector("[name=accept_webmin_address]") !== null'
        ):
            assert evaluate(
                'document.body.innerText.includes("matches a host DHCP lease")'
            ), 'Changed address lacks host lease evidence'
            evaluate(
                'document.querySelector("[name=accept_webmin_address]").click()'
            )
        wait('document.querySelector(".cloudmin-webmin-view iframe")')
        assert not evaluate(
            'document.querySelector("select[name=webmin_view]") !== null'
        )
        assert not evaluate(
            'document.querySelector(".cloudmin-webmin-notice, [data-webmin-direct]") !== null'
        )
        print(
            theme
            + ': warning card, both actions and embedded submission passed',
            flush=True,
        )
        frame = 'document.querySelector(".cloudmin-webmin-view iframe")'
        loading_surface('.cloudmin-webmin-view')
        assert evaluate(
            'getComputedStyle(' + frame + ').visibility === "hidden"'
        ), 'Blank guest iframe is visible while loading'
        # Release the document and verify automatic login and embedded layout.
        resume_requests()
        wait(frame + '.contentDocument?.body?.innerText.includes("Virtualmin")')
        wait('getComputedStyle(' + frame + ').visibility === "visible"')
        assert not evaluate(
            frame
            + '.contentDocument.querySelector("input[name=pass]") !== null'
        ), 'Guest login was requested'
        assert evaluate(frame + '.getBoundingClientRect().height > 300'), (
            'Guest frame collapsed'
        )
        assert (
            evaluate(
                'document.querySelectorAll(".vm-console-tab-label").length'
            )
            == 4
        )
        assert evaluate(
            'document.querySelector("[data-webmin-action=fullscreen]").closest(".panel-heading, table.header") !== null'
        ), 'Controls are outside the header'
        assert evaluate(
            'document.querySelector("[data-webmin-action=fullscreen]").getBoundingClientRect().right <= document.querySelector("[data-webmin-action=new-tab]").getBoundingClientRect().left + 1'
        ), 'Fullscreen must appear before the new-window control'
        # Check how the header renders action icons.
        if theme == 'authentic-theme':
            check_header_controls(
                [
                    '[data-webmin-action=new-tab]',
                    '[data-webmin-action=fullscreen]',
                ]
            )
            webmin_fullscreen_icon = evaluate(
                'document.querySelector("[data-webmin-action=fullscreen] svg")?.outerHTML'
            )
            assert webmin_fullscreen_icon, (
                'Webmin fullscreen does not use the console SVG icon'
            )
            webmin_fullscreen_geometry = fullscreen_geometry(
                '[data-webmin-action=fullscreen]'
            )
        # Check the bottom edge and a real resize in both theme layouts.
        assert evaluate(
            'Math.abs(innerHeight - '
            + frame
            + '.getBoundingClientRect().bottom) < 60'
        ), 'Frame does not fill the available height'
        height = evaluate(frame + '.getBoundingClientRect().height')
        call(
            'Emulation.setDeviceMetricsOverride',
            {
                'width': 1600,
                'height': 800,
                'deviceScaleFactor': 1,
                'mobile': False,
            },
        )
        wait(frame + '.getBoundingClientRect().height < ' + str(height - 50))
        assert evaluate(
            'Math.abs(innerHeight - '
            + frame
            + '.getBoundingClientRect().bottom) < 60'
        ), 'Frame does not follow the resized viewport'
        call('Emulation.clearDeviceMetricsOverride')
        # Check fullscreen edges, then return to the embedded view.
        evaluate(
            'document.querySelector("[data-webmin-action=fullscreen]").click()'
        )
        wait('document.fullscreenElement || top.document.fullscreenElement')
        wait(
            'Math.abs('
            + frame
            + '.getBoundingClientRect().top) < 1 && Math.abs(innerHeight - '
            + frame
            + '.getBoundingClientRect().bottom) < 1'
        )
        evaluate(
            '(document.fullscreenElement ? document : top.document).exitFullscreen()'
        )
        wait('!document.fullscreenElement && !top.document.fullscreenElement')
        print(
            theme
            + ': header controls, full-height iframe, resize and fullscreen passed',
            flush=True,
        )
        # Change only this fixture's displayed colors, without saving either
        # host or guest preferences. The guest uses separate
        # palette stylesheets.
        backgrounds = []
        for scheme in ('dark', 'light'):
            # Set background and accent colors through page attributes.
            if theme == 'authentic-theme':
                evaluate(
                    'for (const n of [document.documentElement, document.body]) {'
                    + 'n.setAttribute("data-bgs", '
                    + json.dumps(
                        'nightRider' if scheme == 'dark' else 'gainsboro'
                    )
                    + ');'
                    + 'n.setAttribute("data-default-theme", "teal");'
                    + 'n.setAttribute("data-theme", '
                    + json.dumps('gunmetal' if scheme == 'dark' else 'teal')
                    + ');}'
                )
            else:
                # Use the palette hook without saving preferences.
                evaluate(
                    'grayThemeApplyScheme(' + json.dumps(scheme) + ', false)'
                )
            expected = 'nightRider' if scheme == 'dark' else 'gainsboro'
            wait(
                frame
                + '.contentDocument.documentElement.getAttribute("data-bgs") === '
                + json.dumps(expected)
            )
            wait(
                '[...'
                + frame
                + '.contentDocument.querySelectorAll("link[href*=\\"/css/palettes/\\"]")].every(l => l.disabled || l.sheet)'
            )
            backgrounds.append(
                evaluate(
                    'getComputedStyle('
                    + frame
                    + '.contentDocument.body).backgroundColor'
                )
            )
        assert backgrounds[0] != backgrounds[1], (
            'Guest palette did not change its rendered background'
        )
        # The accent color must follow hosts that expose it separately.
        if theme == 'authentic-theme':
            wait(
                frame
                + '.contentDocument.body.getAttribute("data-theme") === "teal"'
            )
        # Full navigation must reapply the inherited scheme.
        evaluate(frame + '.contentWindow.location.reload()')
        wait(frame + '.contentDocument?.body?.innerText.includes("Virtualmin")')
        wait(
            frame
            + '.contentDocument.documentElement.getAttribute("data-bgs") === "gainsboro"'
        )
        print(
            theme
            + ': inherited dark/light palette, accent and guest reload passed',
            flush=True,
        )
        if theme == 'gray-theme':
            # Load a host page inside the frame to exercise its color hook
            # without changing the real guest's preferences.
            original = evaluate(frame + '.src')
            evaluate(frame + '.src = "/server-manager/index.cgi"')
            wait(frame + '.contentWindow.grayThemeApplyScheme')
            for scheme in ('dark', 'light'):
                evaluate(
                    'grayThemeApplyScheme(' + json.dumps(scheme) + ', false)'
                )
                wait(
                    frame
                    + '.contentDocument.documentElement.getAttribute("data-scheme") === '
                    + json.dumps(scheme)
                )
            evaluate(frame + '.src = ' + json.dumps(original))
            wait(
                frame
                + '.contentDocument?.body?.innerText.includes("Virtualmin")'
            )
            wait(
                frame
                + '.contentDocument.documentElement.getAttribute("data-bgs") === "gainsboro"'
            )
            print(theme + ': embedded document color hook passed', flush=True)
        # The new-tab control uses a separate guest origin, without
        # host cookies.
        assert (
            evaluate(
                'document.querySelector("[data-webmin-action=new-tab]").href'
            )
            == direct
        )
        original_session = session
        evaluate(
            'document.querySelector("[data-webmin-action=new-tab]").click()'
        )
        opened = None
        deadline = time.monotonic() + 10
        while not opened and time.monotonic() < deadline:
            targets = call('Target.getTargets')['targetInfos']
            opened = next(
                (
                    t
                    for t in targets
                    if t['type'] == 'page'
                    and t['targetId'] != target
                    and t['url'].startswith(direct)
                ),
                None,
            )
            time.sleep(.1)
        assert opened, 'Open in new tab did not open the guest address'
        session = call(
            'Target.attachToTarget',
            {'targetId': opened['targetId'], 'flatten': True},
        )['sessionId']
        wait('location.href.startsWith(' + json.dumps(direct) + ')')
        assert evaluate('window.opener === null'), (
            'Direct guest retains a host window reference'
        )
        cookies = call('Network.getCookies', {'urls': [direct]})['cookies']
        assert not any(c.get('value') == credentials['sid'] for c in cookies), (
            'Host session applies to the direct guest'
        )
        call('Target.closeTarget', {'targetId': opened['targetId']})
        session = original_session
        print(
            theme + ': direct new tab has no opener or host session cookie',
            flush=True,
        )
        # The master link must leave the wrapper and open the host.
        master_link = (
            frame + '.contentDocument.querySelector(".servers-index-link > a")'
        )
        call('Page.bringToFront')
        wait('getComputedStyle(' + frame + ').visibility === "visible"')
        wait(
            master_link
            + ' && '
            + frame
            + '.contentWindow.getComputedStyle('
            + master_link
            + ').visibility === "visible"'
        )
        evaluate(master_link + '.scrollIntoView({block:"center"})')
        rect = evaluate(
            '(() => {const a='
            + master_link
            + '.getBoundingClientRect(), f='
            + frame
            + '.getBoundingClientRect(); return {x:a.x+f.x+a.width/2,y:a.y+f.y+a.height/2}})()'
        )
        for event in ('mousePressed', 'mouseReleased'):
            call(
                'Input.dispatchMouseEvent',
                {
                    'type': event,
                    'x': rect['x'],
                    'y': rect['y'],
                    'button': 'left',
                    'clickCount': 1,
                },
            )
        wait(
            'top.location.pathname === "/servers/" && !top.document.querySelector(".cloudmin-webmin-view")'
        )
        # The URL changes before the replacement host document finishes loading.
        if theme == 'authentic-theme':
            wait('document.body?.getAttribute("data-initial-load") === "0"')
        else:
            # Full-page navigation needs its replacement document to be ready.
            wait('document.body && document.readyState === "complete"')
        print(theme + ': master link leaves the embedded view', flush=True)
        # Returning to Webmin shows the warning and both actions without loading
        # a guest.
        route = '/server-manager/remote_access.cgi?id=' + uuid + '&tab=webmin'
        evaluate(
            '(() => {let a=document.createElement("a"); a.href='
            + json.dumps(route)
            + '; document.body.append(a); a.click(); a.remove();})()'
        )
        wait(
            'document.querySelector(".cloudmin-webmin-notice [data-webmin-direct]")'
        )
        assert not evaluate(
            'document.querySelector("select[name=webmin_view]") !== null'
        )
        assert evaluate(
            'document.querySelector(".cloudmin-webmin-notice").innerText.includes("compromise the host and all other virtual machines")'
        )
        assert not evaluate(
            'document.querySelector(".cloudmin-webmin-view iframe") !== null'
        )
        # Selecting the active tab must return from embedding to the choices.
        evaluate('document.querySelector("[name=connect_webmin]").click()')
        wait('document.querySelector(".cloudmin-webmin-view iframe")')
        wait(
            'document.querySelector(".vm-console-tab-label[data-console-tab-url*=webmin]").closest("a").getAttribute("data-toggle") === null'
        )
        evaluate(
            'document.querySelector(".vm-console-tab-label[data-console-tab-url*=webmin]").closest("a").click()'
        )
        wait(
            'document.querySelector(".cloudmin-webmin-notice [data-webmin-direct]")'
        )
        assert not evaluate(
            'document.querySelector(".cloudmin-webmin-view iframe") !== null'
        )
        print(
            theme + ': active Webmin tab returns to connection choices',
            flush=True,
        )
        if webmin_only:
            # A Webmin-only run must leave both console connections untouched.
            return
        # Pause client loading and connection setup to inspect the first
        # painted screen in both themes, without sending guest keystrokes.
        session = call(
            'Target.attachToTarget', {'targetId': target, 'flatten': True}
        )['sessionId']
        for mode in ('serial', 'graphical'):
            call(
                'Fetch.enable',
                {
                    'patterns': [
                        {'urlPattern': '*server-manager/console.js*'},
                        {'urlPattern': '*server-manager/console-connect.cgi'},
                    ]
                },
            )
            sent.clear()
            route = (
                '/server-manager/remote_access.cgi?id=' + uuid + '&tab=' + mode
            )
            evaluate(
                '(() => {let a=document.createElement("a"); a.href='
                + json.dumps(route)
                + '; document.body.append(a); a.click(); a.remove();})()'
            )
            wait(
                'document.querySelector("#cloudmin-console")?.dataset.consoleMode === '
                + json.dumps(mode)
            )
            loading_surface('#cloudmin-console [data-console-screen]')
            resume_requests(abort=mode == 'serial')
            # Aborting serial setup must leave the guest's input untouched.
            if mode == 'serial':
                assert not sent, 'Serial startup sends guest keystrokes'
            else:
                # Let graphical setup finish for the toolbar checks.
                wait(
                    'document.querySelector("[data-console-status] .ui_badge_success")'
                )
        print(
            theme + ': delayed loading surfaces without serial input passed',
            flush=True,
        )
        if theme == 'authentic-theme':
            # Check the shared console controls without sending guest input.
            session = call(
                'Target.attachToTarget', {'targetId': target, 'flatten': True}
            )['sessionId']
            route = (
                '/server-manager/remote_access.cgi?id='
                + uuid
                + '&tab=graphical'
            )
            evaluate(
                '(() => {let a=document.createElement("a"); a.href='
                + json.dumps(route)
                + '; document.body.append(a); a.click(); a.remove();})()'
            )
            wait(
                'document.querySelector("#cloudmin-console[data-console-header]")'
            )
            wait(
                'document.querySelector("[data-console-status] .ui_badge_success")'
            )
            assert (
                evaluate(
                    'document.querySelector("[data-console-action=fullscreen] svg").outerHTML'
                )
                == webmin_fullscreen_icon
            ), 'Webmin and console fullscreen icons differ'
            console_fullscreen_geometry = fullscreen_geometry(
                '[data-console-action=fullscreen]'
            )
            assert console_fullscreen_geometry == webmin_fullscreen_geometry, (
                'Fullscreen icon sizes or alignment differ: Webmin '
                + str(webmin_fullscreen_geometry)
                + '; console '
                + str(console_fullscreen_geometry)
            )
            # Check the active palette without saving changes to root's theme.
            check_header_controls(
                [
                    '[data-console-action=fullscreen]',
                    '[data-console-action=keys]',
                ]
            )
            evaluate(
                'document.querySelector("[data-console-action=fullscreen]").click()'
            )
            wait('document.fullscreenElement?.id === "cloudmin-console"')
            assert evaluate(
                'document.fullscreenElement.querySelector("[data-console-action=fullscreen]").classList.contains("btn-default")'
            ), 'Fullscreen toolbar lost its button style'
            evaluate('document.exitFullscreen()')
            wait('!document.fullscreenElement')
            check_header_controls(
                [
                    '[data-console-action=fullscreen]',
                    '[data-console-action=keys]',
                ]
            )
            print(
                theme
                + ': graphical controls, hover and fullscreen return passed',
                flush=True,
            )
    finally:
        # Close Chromium itself before removing its profile; snap may launch
        # it through a wrapper that exits before the browser process does.
        if cdp:
            try:
                call('Browser.close')
            except (AssertionError, websocket.WebSocketException):
                # Shutdown may close the debugging socket before replying.
                pass
            cdp.close()
        # Stop this test's process group, including browser wrappers.
        if chrome:
            try:
                os.killpg(chrome.pid, signal.SIGTERM)
            except ProcessLookupError:
                # Browser.close may have already stopped the process group.
                pass
            chrome.wait(timeout=15)
        # Revoke the temporary host session before discarding browser files.
        subprocess.run(
            ['perl', str(helper), 'delete-root-session'],
            input=credentials['sid'] + '\n',
            text=True,
            check=True,
        )
        if profile:
            # Browser children may briefly hold files after the wrapper exits.
            for attempt in range(5):
                try:
                    profile.cleanup()
                    break
                except OSError:
                    # Report persistent cleanup failures after bounded retries.
                    if attempt == 4:
                        raise
                    time.sleep(.5)
