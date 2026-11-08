"""Check networking forms and live bridge confirmation on a disposable Linux Cloudmin VM.

Uses a temporary account, network and management bridge; restores the bridge afterward.
Requires Chromium and python3-websocket on the guest.
"""

import json
import base64
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import websocket


# check_networks(cookies, theme, [interface], [skip_bridge]) tests the rendered
# UI. skip_bridge checks layout and network actions without moving
# host addresses.
def check_networks(cookies, theme, interface=None, skip_bridge=True):
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for the networking browser check'
    # Snap's private /tmp is not the controller's /tmp; use its writable area.
    parent = (
        Path('/root/snap/chromium/common')
        if browser.startswith('/snap/')
        else None
    )
    # Place the profile where a Snap browser can read and write it.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-jobs-browser-', dir=parent
    ) as profile:
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
                '--user-data-dir=' + profile,
                'about:blank',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cdp = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 20
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection(
                'ws://127.0.0.1:' + port + route,
                timeout=30,
                suppress_origin=True,
            )
            serial, session = 0, None

            # call(method, [params]) waits for the matching browser
            # command reply.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = {
                    'id': serial,
                    'method': method,
                    'params': params or {},
                }
                # Tab commands need a session only after attachment.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Ignore browser events until the numbered command
                    # reply arrives.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(expression) returns a JSON-compatible value from
            # the page.
            def evaluate(expression):
                # Frame layouts can redirect a direct module URL into
                # their shell.
                expression = (
                    '(window.frames.right || window).eval('
                    + json.dumps(expression)
                    + ')'
                )
                result = call(
                    'Runtime.evaluate',
                    {'expression': expression, 'returnByValue': True},
                )
                # Page-script failures must not masquerade as missing controls.
                if result.get('exceptionDetails'):
                    raise AssertionError(result['exceptionDetails'])
                return result.get('result', {}).get('value')

            # wait(expression) allows document replacement during
            # theme navigation.
            def wait(expression):
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    # Wait for the complete document and the requested
                    # visible state.
                    if evaluate(
                        '!!(document.body && document.readyState === "complete" && ('
                        + expression
                        + '))'
                    ):
                        return
                    time.sleep(.25)
                detail = evaluate('document.body?.innerText.slice(0, 1500)')
                raise AssertionError(
                    'Browser condition failed: '
                    + expression
                    + '; page: '
                    + str(detail)
                )

            target = call('Target.createTarget', {'url': 'about:blank'})[
                'targetId'
            ]
            session = call(
                'Target.attachToTarget', {'targetId': target, 'flatten': True}
            )['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain + '.enable')
            for cookie in cookies:
                call(
                    'Network.setCookie',
                    {
                        'name': cookie.name,
                        'value': cookie.value,
                        'url': 'https://127.0.0.1:10000',
                        'path': cookie.path,
                        'secure': True,
                    },
                )
            # Enter through an ordinary link so the theme owns its navigation.
            call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            # A frame shell can exist before its right-hand page has a referrer.
            wait(
                'document.location.href.startsWith("https://127.0.0.1:10000/") && document.readyState === "complete"'
            )
            evaluate(
                "(() => { const a = document.createElement('a'); a.href = '/server-manager/networks.cgi'; document.body.append(a); a.click(); a.remove(); })()"
            )
            wait('document.querySelector("#cloudmin-network-page")')

            # tab(name) uses the same native controls as the VM editor.
            def tab(name):
                evaluate(
                    "(() => { const a = document.querySelector('a[href=\"#att_net_"
                    + name
                    + "\"], a#tab_net_"
                    + name
                    + ", #tab_net_"
                    + name
                    + " a'); if (a) a.click(); })()"
                )
                wait(
                    "document.querySelector('[data-network-tab="
                    + name
                    + "]')?.getClientRects().length > 0"
                )
                assert evaluate(
                    "Array.from(document.querySelectorAll('[data-network-tab]')).filter(t => t.getClientRects().length).length === 1"
                )

            # open_form(name) expands only the requested setup section.
            def open_form(name):
                evaluate(
                    "(() => { const d = document.querySelector('details[data-name=\""
                    + name
                    + "\"]'); if (d) { if (!d.open) d.querySelector('summary').click(); } else if (!document.querySelector('#hiddendiv_"
                    + name
                    + "')?.getClientRects().length) { document.querySelector('#hiddenopener_"
                    + name
                    + "').click(); } })()"
                )
                wait(
                    "document.querySelector('details[data-name=\""
                    + name
                    + "\"]')?.open || document.querySelector('#hiddendiv_"
                    + name
                    + "')?.getClientRects().length > 0"
                )

            # aligned_facts() checks column positions even after facts wrap to
            # new rows.
            def aligned_facts():
                return evaluate("""Array.from(document.querySelectorAll('.cloudmin-network-facts'))
                    .filter(list => list.getClientRects().length).every(list => {
                        const boxes = Array.from(list.children).map(item => item.getBoundingClientRect());
                        const gap = parseFloat(getComputedStyle(list).columnGap);
                        const step = Math.min(...boxes.map(box => box.width)) + gap;
                        const left = list.getBoundingClientRect().left;
                        return boxes.every(box => {
                            const offset = box.left - left;
                            return Math.abs(offset - Math.round(offset / step) * step) < 2;
                        });
                    })""")

            # Overview totals use unique VMs, and links open the selected card.
            wait(
                "document.querySelector('[data-network-tab=overview]')?.getClientRects().length > 0"
            )

            # overview_counts() reads the four rendered network summary values.
            def overview_counts():
                return evaluate(
                    "Array.from(document.querySelectorAll('.cloudmin-network-summary .ui_stat_value')).map(e => Number(e.textContent.trim()))"
                )

            initial_counts = overview_counts()
            inventory_counts = evaluate("""(() => {
                const networks = Array.from(document.querySelectorAll('[data-network-name]'));
                const bridges = document.querySelectorAll('[data-network-tab=bridges] .ui_card');
                const guests = new Set(Array.from(document.querySelectorAll('[data-network-tab=networks] .cloudmin-network-guest, [data-network-tab=bridges] .cloudmin-network-guest')).map(a => a.getAttribute('href')));
                return [networks.length, networks.filter(n => n.querySelector('.ui_card_actions .ui_badge_success')).length, bridges.length, guests.size];
            })()""")
            assert initial_counts == inventory_counts, (
                initial_counts,
                inventory_counts,
            )
            assert evaluate(
                "Array.from(document.querySelectorAll('.cloudmin-network-summary .ui_stat')).every(e => getComputedStyle(e).borderRadius === '0px')"
            ), 'Summary tiles must have square corners'
            for section in ('networks', 'bridges'):
                tab('overview')
                selected = evaluate(
                    """(() => {
                    const links = Array.from(document.querySelectorAll('.cloudmin-network-overview-table a')).filter(a => new URL(a.href).searchParams.get('tab') === """
                    + json.dumps(section)
                    + """);
                    const link = links.at(-1);
                    if (!link) return null;
                    const name = link.textContent;
                    link.click();
                    return name;
                })()"""
                )
                # Only test card selection when this section has an
                # inventory link.
                if selected:
                    wait(
                        "document.querySelector('[data-network-tab="
                        + section
                        + "] .cloudmin-network-selected')?.getClientRects().length > 0"
                    )
                    assert (
                        evaluate(
                            "document.querySelector('[data-network-tab="
                            + section
                            + "] .ui_card_title').textContent.trim()"
                        )
                        == selected
                    )
            tab('overview')
            for width in (1600, 1000, 760, 480):
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': width,
                        'height': 1000,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                time.sleep(.3)
                assert evaluate(
                    "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
                ), 'Overview overflows at ' + str(width)
                assert evaluate(
                    "Array.from(document.querySelectorAll('.cloudmin-network-summary .ui_stat')).every(e => e.scrollWidth <= e.clientWidth + 1)"
                ), 'Summary tile overflows at ' + str(width)
            call('Emulation.clearDeviceMetricsOverride')

            # Verify real card layout, tab isolation and a narrower viewport.
            tab('networks')
            wait("document.querySelector('[data-network-name] .ui_card')")
            assert evaluate(
                "document.querySelector('[data-network-name]').textContent.includes('192.168.122.1/24')"
            )
            assert evaluate(
                "document.querySelector('.cloudmin-network-page').classList.contains('ui_page')"
            )
            # Icons must not change an inline action's position or
            # text alignment.
            assert evaluate("""(() => {
                const original = document.querySelector('input[value=autostart]').form.querySelector('.ui_action');
                const icon = original.querySelector('svg');
                const failures = [];
                for (const tag of ['button', 'a']) {
                    for (const size of ['small', 'normal', 'large']) {
                        const action = document.createElement(tag);
                        action.className = original.className.replace(/ui_action_small|ui_action_large/g, '') + ' ui_action_' + size;
                        action.innerHTML = original.innerHTML;
                        const content = action.querySelector('.ui_action_content');
                        content.querySelector('svg')?.remove();
                        content.prepend(icon.cloneNode(true));
                        original.replaceWith(action);
                        try {
                            const measure = () => {
                                const origin = action.closest('dd').getBoundingClientRect().top;
                                return [action, content.lastElementChild].flatMap(e => {
                                    const r = e.getBoundingClientRect();
                                    return [r.top - origin, r.height];
                                });
                            };
                            const withIcon = measure();
                            content.querySelector('svg').remove();
                            const withoutIcon = measure();
                            if (withIcon.some((v, i) => Math.abs(v - withoutIcon[i]) > .1)) {
                                failures.push(tag + ':' + size);
                            }
                        } finally {
                            action.replaceWith(original);
                        }
                    }
                }
                return failures.length === 0;
            })()"""), 'Adding an icon moves the action or its label'
            for name in ('overview', 'bridges', 'interfaces', 'networks'):
                tab(name)
                picture = call('Page.captureScreenshot', {'format': 'png'})
                Path(
                    '/var/tmp/cloudmin-network-' + theme + '-' + name + '.png'
                ).write_bytes(base64.b64decode(picture['data']))
            for width in (1600, 1280, 1000, 760):
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': width,
                        'height': 1000,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                for name in ('networks', 'bridges', 'interfaces'):
                    tab(name)
                    assert evaluate(
                        "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
                    ), 'Page overflows viewport at ' + str(width)
                    assert aligned_facts(), (
                        'Fact columns do not line up at ' + str(width)
                    )
                    # Retain the intermediate-width layout for
                    # visual inspection.
                    if width == 1000:
                        picture = call(
                            'Page.captureScreenshot', {'format': 'png'}
                        )
                        Path(
                            '/var/tmp/cloudmin-network-'
                            + theme
                            + '-'
                            + name
                            + '-narrow.png'
                        ).write_bytes(base64.b64decode(picture['data']))
            # Empty bridges offer compact guidance with setup already available.
            tab('bridges')
            # A host without bridges must explain the empty bridge inventory.
            if not evaluate(
                "document.querySelector('[data-network-tab=bridges] .ui_card')"
            ):
                assert not evaluate(
                    "document.querySelector('[data-network-tab=bridges] .ui_empty')"
                )
                assert evaluate(
                    "document.querySelector('input[name=action][value=bridge_review]').form.querySelector('input[name=name]').getClientRects().length > 0"
                )
            call('Emulation.clearDeviceMetricsOverride')
            tab('networks')
            open_form('create_network')
            picture = call('Page.captureScreenshot', {'format': 'png'})
            Path(
                '/var/tmp/cloudmin-network-' + theme + '-create.png'
            ).write_bytes(base64.b64decode(picture['data']))
            call(
                'Emulation.setDeviceMetricsOverride',
                {
                    'width': 760,
                    'height': 1000,
                    'deviceScaleFactor': 1,
                    'mobile': False,
                },
            )
            assert evaluate(
                "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
            ), 'Creation form overflows narrow viewport'
            call('Emulation.clearDeviceMetricsOverride')
            wait("window.cloudminNetworkStatus")
            assert evaluate(
                "document.querySelector('input[name=dhcp_start]').disabled"
            )
            evaluate("document.querySelector('input[name=dhcp]').click()")
            assert not evaluate(
                "document.querySelector('input[name=dhcp_start]').disabled"
            )
            evaluate("document.querySelector('input[name=dhcp]').click()")
            evaluate(
                "document.querySelector('input[name=mode][value=isolated]').click()"
            )
            assert evaluate(
                "document.querySelector('select[name=uplink]').disabled"
            )
            # Native Webmin form submission must create a real
            # persistent network.
            evaluate(
                "(() => { const f = document.querySelector('input[name=action][value=create]').form; f.elements.name.value='cmwebtest'; f.elements.ipv4.value='192.168.231.1/24'; f.querySelector('button[type=submit]').click(); })()"
            )
            wait('document.querySelector(\'[data-network-name="cmwebtest"]\')')
            assert overview_counts() == [
                initial_counts[0] + 1,
                initial_counts[1] + 1,
                *initial_counts[2:],
            ], 'Overview did not include the new network'

            # Toggle only the fixture's boot setting and compare its rendered
            # position. boot_action() measures the boot button's position, size
            # and icon.
            def boot_action():
                return evaluate("""(() => {
                    const form = document.querySelector('[data-network-name=cmwebtest] input[value=autostart]').form;
                    const button = form.querySelector('.ui_action');
                    const box = button.getBoundingClientRect();
                    return {top: box.top - form.closest('.ui_dl_row').getBoundingClientRect().top,
                        height: box.height, icon: button.querySelector('svg').classList.contains('ui_svg_icon_check') ? 'check' : 'x'};
                })()""")

            enabled = boot_action()
            assert enabled['icon'] == 'check'
            for value, icon in ((1, 'x'), (0, 'check')):
                evaluate(
                    "document.querySelector('[data-network-name=cmwebtest] input[value=autostart]').form.querySelector('button').click()"
                )
                wait(
                    "document.querySelector('[data-network-name=cmwebtest] input[value=autostart]')?.form.elements.enabled.value === '"
                    + str(value)
                    + "'"
                )
                current = boot_action()
                assert current['icon'] == icon
                assert (
                    abs(enabled['top'] - current['top']) < .1
                    and abs(enabled['height'] - current['height']) < .1
                ), 'Autostart toggle shifts vertically'
            # The card offers stop, then a separate deletion confirmation.
            evaluate(
                "document.querySelector('[data-network-name=cmwebtest] input[value=stop]').form.querySelector('button[type=submit]').click()"
            )
            wait(
                "document.querySelector('[data-network-name=cmwebtest] input[value=delete_review]')"
            )
            assert overview_counts() == [
                initial_counts[0] + 1,
                *initial_counts[1:],
            ], 'Stopped network is counted as active'
            # Separate POST forms must align like the buttons in a single form.
            assert evaluate("""(() => {
                const buttons=Array.from(document.querySelectorAll('[data-network-name=cmwebtest] .ui_card_foot button'));
                return buttons.length === 2 && Math.abs(buttons[0].getBoundingClientRect().top - buttons[1].getBoundingClientRect().top) < 1;
            })()"""), 'Start and Delete buttons are vertically offset'
            picture = call('Page.captureScreenshot', {'format': 'png'})
            Path(
                '/var/tmp/cloudmin-network-' + theme + '-stopped.png'
            ).write_bytes(base64.b64decode(picture['data']))
            evaluate(
                "document.querySelector('[data-network-name=cmwebtest] input[value=delete_review]').form.querySelector('button[type=submit]').click()"
            )
            wait('document.querySelector("input[name=action][value=delete]")')
            assert evaluate(
                'document.body.innerText.includes("saved network configuration will be removed")'
            )
            evaluate(
                "document.querySelector('input[name=action][value=delete]').form.submit()"
            )
            wait(
                'document.querySelector("#cloudmin-network-page") && !document.querySelector(\'[data-network-name="cmwebtest"]\')'
            )
            assert overview_counts() == initial_counts, (
                'Deleted network remains in the overview'
            )
            tab('bridges')
            open_form('create_bridge')
            picture = call('Page.captureScreenshot', {'format': 'png'})
            Path(
                '/var/tmp/cloudmin-network-' + theme + '-bridge-form.png'
            ).write_bytes(base64.b64decode(picture['data']))
            # An opted-out bridge test must not begin a host network change.
            if skip_bridge:
                print(
                    'Overview totals, card navigation, responsive layout, forms and network lifecycle: PASS',
                    flush=True,
                )
                return
            # A real management bridge is reviewed, applied and confirmed in
            # the UI.
            plan = json.loads(
                subprocess.check_output(
                    [
                        'perl',
                        str(Path(__file__).with_name('network-fixture.pl')),
                        'review',
                        'cmtestbr',
                        interface,
                    ]
                )
            )
            seconds = plan['confirm_timeout']
            evaluate(
                "(() => { const f=document.querySelector('input[value=bridge_review]').form; f.elements.name.value='cmtestbr'; f.elements.source.value="
                + json.dumps(interface)
                + "; f.submit(); })()"
            )
            wait('document.querySelector("input[name=action][value=bridge]")')
            assert evaluate(
                'document.body.innerText.includes('
                + json.dumps('within ' + str(seconds) + ' seconds')
                + ')'
            )
            evaluate(
                "document.querySelector('input[name=action][value=bridge]').form.submit()"
            )
            wait('document.querySelector("#cloudmin-network-page")')
            evaluate(
                "window.networkPage=document.querySelector('#cloudmin-network-page'); true"
            )
            wait('document.querySelector("input[name=action][value=confirm]")')
            assert evaluate(
                'window.networkPage === document.querySelector("#cloudmin-network-page")'
            )
            assert evaluate('document.body.innerText.includes("cmtestbr")')
            # Switching tabs during live recovery must preserve the countdown.
            tab('interfaces')
            time.sleep(2)
            wait(
                "document.querySelector('[data-network-tab=interfaces]').getClientRects().length > 0"
            )
            remaining = evaluate(
                'Number(document.querySelector("#cloudmin-network-countdown").textContent)'
            )
            assert 0 < remaining <= seconds, remaining
            evaluate(
                "document.querySelector('input[name=action][value=confirm]').form.submit()"
            )
            wait(
                'document.body.innerText.includes("network settings were confirmed")'
            )
            wait(
                "document.querySelector('[data-network-tab=bridges]').getClientRects().length > 0"
            )
            tab('interfaces')
            tab('bridges')
            print(
                'Cards, tabs, responsive layout, form choices, network lifecycle and live bridge confirmation: PASS',
                flush=True,
            )
        except Exception:
            # Close the browser through DevTools when its connection
            # was established.
            if cdp:
                print(
                    'Visible page:',
                    evaluate('document.body?.innerText.slice(-5000)'),
                    flush=True,
                )
                picture = call('Page.captureScreenshot', {'format': 'png'})
                Path(
                    '/var/tmp/cloudmin-network-' + theme + '-failure.png'
                ).write_bytes(base64.b64decode(picture['data']))
            raise
        finally:
            if cdp:
                # Let Chromium stop its profile writers before removing
                # the directory.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, OSError):
                    pass
                cdp.close()
            # Stop the owned browser directly if DevTools setup failed.
            else:
                chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                chrome.kill()
                chrome.wait()


# Temporary authentication and status records are removed even after failures.
if __name__ == '__main__':
    import http.cookiejar, secrets, ssl, urllib.parse, urllib.request, os
    import platform
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument('interface', nargs='?')
    parser.add_argument('--theme', choices=('authentic-theme', 'gray-theme'))
    parser.add_argument('--skip-bridge', action='store_true')
    parser.add_argument(
        '--test-bridge',
        action='store_true',
        help='Explicitly allow moving the named test NIC onto a bridge',
    )
    args = parser.parse_args()
    # Require a root-run disposable guest and enabled Python assertions.
    if platform.system() != 'Linux' or os.geteuid() != 0 or not __debug__:
        raise SystemExit(
            'Run without Python optimization on a disposable Linux VM as root'
        )
    # Host bridge changes need an explicit source interface and opt-in.
    if args.test_bridge and (not args.interface or args.skip_bridge):
        parser.error(
            '--test-bridge requires an interface and cannot be combined with --skip-bridge'
        )
    args.skip_bridge = not args.test_bridge
    helper = str(Path(__file__).with_name('webmin-user.pl'))
    for theme in (
        (args.theme,) if args.theme else ('authentic-theme', 'gray-theme')
    ):
        password = secrets.token_urlsafe(36)
        created = False
        try:
            subprocess.run(
                ['perl', helper, 'create', theme],
                input=password + '\n',
                text=True,
                check=True,
            )
            created = True
            time.sleep(1)
            cookies = http.cookiejar.CookieJar()
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}),
                urllib.request.HTTPCookieProcessor(cookies),
                urllib.request.HTTPSHandler(
                    context=ssl._create_unverified_context()
                ),
            )
            base = 'https://127.0.0.1:10000'
            with opener.open(
                base + '/session_login.cgi', timeout=30
            ) as response:
                response.read()
            data = urllib.parse.urlencode(
                {'user': 'cloudmin-ui-check', 'pass': password, 'page': '/'}
            ).encode()
            with opener.open(
                base + '/session_login.cgi', data, timeout=30
            ) as response:
                response.read()
            print(theme, flush=True)
            check_networks(cookies, theme, args.interface, args.skip_bridge)
        finally:
            fixture = str(Path(__file__).with_name('network-fixture.pl'))
            try:
                state = json.loads(
                    subprocess.check_output(['perl', fixture, 'status'])
                )
                # Roll back only this test bridge when the run left a
                # transaction behind.
                if (
                    not args.skip_bridge
                    and state
                    and state.get('name') == 'cmtestbr'
                    and state.get('state') != 'rolled_back'
                ):
                    subprocess.run(
                        ['perl', fixture, 'restore-fixture', 'cmtestbr'],
                        check=True,
                    )
            finally:
                # Delete the temporary account only after successful creation.
                if created:
                    subprocess.run(['perl', helper, 'delete'], check=True)
