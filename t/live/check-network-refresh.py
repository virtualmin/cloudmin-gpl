#!/usr/bin/python3
"""Check SPA status refresh with a temporary account and browser profile.

Run as root inside the Linux test host. No network settings are changed.
For removal review checks, add --bridge-removal --bridge NAME --port NAME.
"""

import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

# Parse fixture targets before loading browser tools or creating a test account.
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--bridge-removal',
    action='store_true',
    help='Check bridge removal review without applying it',
)
parser.add_argument(
    '--bridge', metavar='NAME', help='Existing bridge to review'
)
parser.add_argument(
    '--port', metavar='NAME', help='Expected Ethernet port of the bridge'
)
args = parser.parse_args()
if args.bridge_removal and not (args.bridge and args.port):
    # Removal review must use an explicitly chosen bridge and port.
    parser.error('--bridge-removal requires --bridge NAME and --port NAME')

import websocket

# Account setup and browser files belong on the Linux guest, with assertions on.
assert sys.platform == 'linux' and os.geteuid() == 0 and __debug__
helper = Path(__file__).with_name('webmin-user.pl')
base = 'https://127.0.0.1:10000'
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
password = secrets.token_urlsafe(36)
cookies = http.cookiejar.CookieJar()
client = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(cookies),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)


# request(path, [fields]) sends a local GET, or a POST with the supplied fields.
def request(path, fields=None):
    data = (
        urllib.parse.urlencode(fields).encode() if fields is not None else None
    )
    req = urllib.request.Request(
        base + path, data=data, headers={'Referer': base + '/'}
    )
    with client.open(req, timeout=30) as response:
        return response.read().decode()


# Give only the temporary account module access and a theme with SPA navigation.
subprocess.run(
    ['perl', str(helper), 'create', 'authentic-theme', user],
    input=password + '\n',
    text=True,
    check=True,
)
try:
    # Authenticate the fixture account and refuse to interrupt pending recovery.
    subprocess.run(
        ['perl', str(helper), 'acl', 'authentic-theme', user],
        input=json.dumps({'admin': 1}),
        text=True,
        check=True,
    )
    time.sleep(1)
    request('/session_login.cgi')
    request('/session_login.cgi', {'user': user, 'pass': password, 'page': '/'})
    state = json.loads(request('/server-manager/networks.cgi?status=1'))
    assert set(state) == {'state', 'remaining'}, (
        'Status should contain no raw form markup'
    )
    assert state['state'] in ('', 'complete', 'rolled_back'), (
        'Wait for the current bridge operation to finish'
    )
    # Use a fresh headless browser profile with no saved user cookies or state.
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required'
    # Snap browsers need a profile outside their private /tmp mount.
    parent = (
        Path('/root/snap/chromium/common')
        if browser.startswith('/snap/')
        else None
    )
    if parent:
        # Snap Chromium can access its own writable profile parent.
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-network-refresh-', dir=parent
    ) as profile:
        process = subprocess.Popen(
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
        socket = None
        try:
            # Wait for Chromium's randomly assigned local debugging endpoint.
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            socket = websocket.create_connection(
                'ws://127.0.0.1:' + port + route,
                timeout=30,
                suppress_origin=True,
            )
            serial, session, requests = 0, None, []

            # call(method, [params]) records requests while waiting for a
            # CDP reply.
            def call(method, params=None):
                global serial
                serial += 1
                command = {
                    'id': serial,
                    'method': method,
                    'params': params or {},
                }
                if session:
                    # Route page commands to the attached session.
                    command['sessionId'] = session
                socket.send(json.dumps(command))
                while True:
                    reply = json.loads(socket.recv())
                    if reply.get('method') == 'Network.requestWillBeSent':
                        # Record requests while waiting for the reply.
                        requests.append(reply['params']['request'])
                    if reply.get('id') == serial:
                        # Ignore other replies until this command completes.
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(js) returns browser values without exposing
            # fixture cookies.
            def evaluate(js):
                result = call(
                    'Runtime.evaluate',
                    {'expression': js, 'returnByValue': True},
                )
                assert 'exceptionDetails' not in result, result.get(
                    'exceptionDetails'
                )
                return result.get('result', {}).get('value')

            # wait(js) bounds page and theme initialization checks.
            def wait(js):
                deadline = time.monotonic() + 40
                while time.monotonic() < deadline:
                    if evaluate(js):
                        # Stop once the page meets the requested condition.
                        return
                    time.sleep(.2)
                raise AssertionError('Browser condition failed: ' + js)

            # Attach one page and transfer only this fixture's login cookies.
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
                        'url': base,
                        'path': cookie.path,
                        'secure': True,
                    },
                )
            call('Page.navigate', {'url': base + '/'})
            wait(
                'document.readyState === "complete" && !!document.querySelector("aside")'
            )
            # Open Networking through the SPA navigation handler.
            evaluate("""(() => {
                const link = document.createElement('a');
                link.href = '/server-manager/networks.cgi?tab=bridges';
                document.body.append(link); link.click(); link.remove();
            })()""")
            wait(
                "!!document.querySelector('#cloudmin-network-page') && !!document.querySelector('input[name=action][value=bridge_review]')"
            )
            # Check that the theme stacks each label above its field.
            layout = """(() => {
                const input = document.querySelector('input[name=action][value=bridge_review]');
                // Wait until navigation has supplied the creation form.
                if (!input) return false;
                const field = input.form.querySelector('input[name=name]');
                const label = field?.closest('tr')?.querySelector('.col_label');
                // Measure only visible fields with a label.
                if (!label || !field.getClientRects().length) return false;
                const a = label.getBoundingClientRect(), b = field.getBoundingClientRect();
                return b.top >= a.bottom - 2 && Math.abs(b.left - a.left) < 4;
            })()"""
            has_creation_fields = evaluate(
                '!!document.querySelector("input[name=action][value=bridge_review]").form.querySelector("input[name=name]")'
            )
            if has_creation_fields:
                # Hosts without an eligible port have no fields to measure.
                wait(layout)
            # A simulated pending status must trigger a GET-only SPA reload
            # when the next real status arrives.
            history_length = evaluate('history.length')
            requests.clear()
            # callback() simulates recovery by changing only browser markers.
            evaluate("""(() => {
                window.networkRefreshPage = document.getElementById('cloudmin-network-page');
                document.querySelector('input[name=action][value=bridge_review]').form.remove();
                const marker = document.createElement('span');
                marker.id = 'cloudmin-network-pending'; marker.dataset.state = 'rolling_back';
                networkRefreshPage.querySelector('[data-network-tab=bridges]').append(marker);
                window.dispatchEvent(new Event('pageshow'));
            })()""")
            wait(
                "!!window.networkRefreshPage && document.getElementById('cloudmin-network-page') !== networkRefreshPage && !!document.querySelector('input[name=action][value=bridge_review]')"
            )
            if has_creation_fields:
                # The automatic refresh must reapply the theme's field layout.
                wait(layout)
            assert evaluate('history.length') == history_length, (
                'Refresh added browser history'
            )
            assert evaluate(
                "document.querySelector('[data-network-tab=bridges]').getClientRects().length > 0"
            ), 'Refresh changed the active tab'
            # Tabs must remain interactive after the themed content replacement.
            evaluate(
                "document.querySelector('a[href=\"#att_net_interfaces\"]').click()"
            )
            wait(
                "document.querySelector('[data-network-tab=interfaces]').getClientRects().length > 0"
            )
            evaluate(
                "document.querySelector('a[href=\"#att_net_bridges\"]').click()"
            )
            wait(
                "document.querySelector('[data-network-tab=bridges]').getClientRects().length > 0"
            )
            if has_creation_fields:
                # Switching tabs must preserve the initialized form too.
                wait(layout)
            # Count page loads separately from status polls.
            navigation = [
                r
                for r in requests
                if urllib.parse.urlparse(r['url']).path
                == '/server-manager/networks.cgi'
                and 'status=1' not in urllib.parse.urlparse(r['url']).query
            ]
            assert len(navigation) == 1 and navigation[0]['method'] == 'GET', (
                'Expected exactly one safe page GET'
            )
            print(
                'PASS: form layout, active tab, tab controls and GET-only refresh',
                flush=True,
            )
            if args.bridge_removal:
                # Review the requested existing bridge without applying removal.
                selector = 'input[name=action][value=bridge_remove_review]'
                review = (
                    'Array.from(document.querySelectorAll('
                    + json.dumps(selector)
                    + ')).find(input => input.form.elements.namedItem("name").value === '
                    + json.dumps(args.bridge)
                    + ')'
                )
                wait('!!(' + review + ')')
                button_height = evaluate(
                    '('
                    + review
                    + ').form.querySelector("button").getBoundingClientRect().height'
                )
                assert 0 < button_height <= 40, (
                    'Removal button should remain compact'
                )
                evaluate(
                    '(' + review + ').form.querySelector("button").click()'
                )
                wait(
                    '!!document.querySelector("input[name=action][value=bridge_remove]")'
                )
                # callback() reads the signed review form fields.
                form = evaluate('''(() => {
                    const form = document.querySelector('input[name=action][value=bridge_remove]').form;
                    return Object.fromEntries(new FormData(form));
                })()''')
                assert (
                    form['name'] == args.bridge and form['source'] == args.port
                ), f'Expected bridge {args.bridge} with port {args.port}'
                assert evaluate(
                    'document.body.innerText.includes("Review Bridge Removal")'
                )
                assert evaluate(
                    'document.body.innerText.includes("restores the bridge")'
                )
                # HTTP review must keep configuration backups private.
                before = json.loads(
                    request('/server-manager/api.cgi?action=bridge_status')
                )
                reviewed = json.loads(
                    request(
                        '/server-manager/api.cgi',
                        {
                            'action': 'bridge_remove_review',
                            'name': form['name'],
                            'token': form['token'],
                        },
                    )
                )
                assert reviewed['result']['source'] == args.port, (
                    f'Expected port {args.port} for {args.bridge}'
                )
                assert not {'files', 'saved', 'port'} & set(reviewed['result'])
                # Submit an invalid revision and verify no transaction changed.
                rejected = json.loads(
                    request(
                        '/server-manager/api.cgi',
                        {
                            'action': 'bridge_remove',
                            'name': form['name'],
                            'revision': 'stale',
                            'token': form['token'],
                        },
                    )
                )
                assert 'review the bridge again' in rejected['error']
                after = json.loads(
                    request('/server-manager/api.cgi?action=bridge_status')
                )
                assert before == after, (
                    'Rejected HTTP request changed the transaction'
                )
                print(
                    f'PASS: {args.bridge} on {args.port}: compact removal button, review form and HTTP API validation',
                    flush=True,
                )
        finally:
            # Only the browser and temporary profile created by this test
            # are closed.
            if socket:
                # Ask the browser we launched to close through its own endpoint.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, OSError):
                    # An already closed browser needs no further socket command.
                    pass
                socket.close()
            else:
                # Startup may have failed before the debugging socket appeared.
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Bound cleanup even if Chromium does not close normally.
                process.kill()
                process.wait()
finally:
    # Remove the fixture account, its sessions and its saved tab preference.
    subprocess.run(
        ['perl', str(helper), 'delete', 'authentic-theme', user], check=True
    )
    preferences = Path('/var/webmin/modules/server-manager')
    (preferences / ('inventory-tabs-' + user.replace('-', '%2D'))).unlink(
        missing_ok=True
    )
