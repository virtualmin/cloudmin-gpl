#!/usr/bin/python3
"""
Check the creation image picker in a browser without creating a virtual machine.
"""

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
import websocket

assert sys.platform == 'linux' and os.geteuid() == 0
helper = Path(__file__).with_name('webmin-user.pl')
base = 'https://127.0.0.1:10000'
cookies = http.cookiejar.CookieJar()
client = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(cookies),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)


# request(path, [fields]) uses a temporary account on the test host only.
def request(path, fields=None):
    data = (
        urllib.parse.urlencode(fields).encode() if fields is not None else None
    )
    req = urllib.request.Request(
        base + path, data=data, headers={'Referer': base + '/'}
    )
    return client.open(req, timeout=60).read().decode()


password = secrets.token_urlsafe(36)
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
subprocess.run(
    ['perl', str(helper), 'create', 'authentic-theme', user],
    input=password + '\n',
    text=True,
    check=True,
)
try:
    time.sleep(1)
    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {
            'user': user,
            'pass': password,
            'page': '/server-manager/machine_form.cgi',
        },
    )
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required'
    # Snap's private /tmp cannot expose the browser's DevTools port to
    # this test.
    parent = (
        Path('/root/snap/chromium/common')
        if browser.startswith('/snap/')
        else None
    )
    # Snap Chromium needs a profile directory visible inside its sandbox.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-image-picker-browser-', dir=parent
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
                '--disable-popup-blocking',
                '--window-size=1800,1100',
                '--user-data-dir=' + profile,
                'about:blank',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        socket = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            socket = websocket.create_connection(
                'ws://127.0.0.1:' + port + route,
                timeout=45,
                suppress_origin=True,
            )
            serial, session = 0, None

            # call(method, [params]) returns the matching DevTools result.
            def call(method, params=None):
                global serial
                serial += 1
                payload = {
                    'id': serial,
                    'method': method,
                    'params': params or {},
                }
                # Attach tab commands only after the session has been created.
                if session:
                    payload['sessionId'] = session
                socket.send(json.dumps(payload))
                while True:
                    reply = json.loads(socket.recv())
                    # Ignore events until this command receives its
                    # numbered reply.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(js) runs assertions against the actual themed document.
            def evaluate(js):
                result = call(
                    'Runtime.evaluate',
                    {
                        'expression': js,
                        'returnByValue': True,
                        'awaitPromise': True,
                        'userGesture': True,
                    },
                )
                assert 'exceptionDetails' not in result, result
                return result.get('result', {}).get('value')

            # wait(js) bounds asynchronous theme navigation.
            def wait(js):
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    # Wait for actual DOM state rather than relying on fixed
                    # load delays.
                    if evaluate(js):
                        return
                    time.sleep(.2)
                raise AssertionError('Timed out: ' + js)

            target = call('Target.createTarget', {'url': 'about:blank'})[
                'targetId'
            ]
            session = call(
                'Target.attachToTarget', {'targetId': target, 'flatten': True}
            )['sessionId']
            for domain in ('Network', 'Page', 'Runtime'):
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
            wait('!!document.querySelector("aside a[href*=machine_form]")')
            evaluate(
                'document.querySelector("aside a[href*=machine_form]").click()'
            )
            wait(
                '!!document.querySelector("#vm-create-form [data-vm-manage-images]")'
            )
            # Module settings may initially collapse the image section.
            evaluate('''(() => {
                const link = document.querySelector('#vm-create-form [data-vm-manage-images]');
                if (!link.getBoundingClientRect().height)
                    document.getElementById('hiddenopener_vm_image').click();
            })()''')
            wait(
                'document.querySelector("#vm-create-form [data-vm-manage-images]").getBoundingClientRect().height > 0'
            )
            # Native navigation should share one responsive group with
            # the selector.
            state = evaluate('''(() => {
                const form = document.getElementById('vm-create-form');
                const link = form.querySelector('[data-vm-manage-images]');
                const picker = form.elements.image;
                const group = link.parentElement.getBoundingClientRect();
                const button = link.getBoundingClientRect();
                const select = picker.getBoundingClientRect();
                return {target: link.target, icon: !!link.querySelector('svg'),
                    classes: link.className,
                    normal: link.classList.contains('ui_action_normal'),
                    height: button.height,
                    expectedHeight: 28,
                    grouped: picker.parentElement === link.parentElement,
                    gap: button.left-select.right,
                    expectedGap: parseFloat(getComputedStyle(link.parentElement).columnGap),
                    fits: button.right <= group.right+1,
                    inline: Math.abs((button.top+button.bottom)-(select.top+select.bottom)) < 4};
            })()''')
            assert not state['target'] and state['icon'] and state['normal'], (
                state
            )
            assert (
                state['expectedHeight'] > 0
                and abs(state['height'] - state['expectedHeight']) < 1
            ), state
            assert state['grouped'] and state['fits'] and state['inline'], state
            assert (
                state['expectedGap'] > 0
                and abs(state['gap'] - state['expectedGap']) < 1
            ), state
            # A long and short option must change the select width without
            # extra margins.
            widths = evaluate('''(() => {
                const picker = document.querySelector('#vm-create-form select[name=image]');
                const selected = picker.selectedOptions[0], original = selected.text;
                selected.text = 'Short';
                const short = picker.getBoundingClientRect().width;
                selected.text = 'A longer image name (10 GiB; default)';
                const long = picker.getBoundingClientRect().width;
                selected.text = original;
                return {short, long};
            })()''')
            assert widths['long'] > widths['short'] + 50, widths
            print(
                'PASS: 28px icon button and content-sized image selector share a spaced group',
                state,
                flush=True,
            )

            # Optional hints belong inside all three static-network inputs.
            assert evaluate(
                '["gateway4", "gateway6", "dns"].every(name => document.querySelector(`[name=${name}]`).placeholder === "Optional")'
            )
            assert not evaluate(
                'Array.from(document.querySelectorAll("#cloudmin-vm-addresses span")).some(el => el.textContent.trim() === "Optional")'
            )
            print(
                'PASS: gateway and DNS optional hints are placeholders',
                flush=True,
            )

            # The shell must handle the link with AJAX in the existing
            # browser tab.
            tabs_before = len(call('Target.getTargets')['targetInfos'])
            evaluate(
                'window.cloudminPickerNavigation = true; document.querySelector("[data-vm-manage-images]").click()'
            )
            wait('!!document.querySelector("#cloudmin-image-sources")')
            assert evaluate('window.cloudminPickerNavigation === true'), (
                'Navigation reloaded the theme shell'
            )
            assert (
                len(call('Target.getTargets')['targetInfos']) == tabs_before
            ), 'Image Manager opened a new window'
            assert not evaluate(
                '!!document.querySelector("#vm-create-form")'
            ), 'Image Manager did not replace the creation page'
            print(
                'PASS: Manage images uses same-tab AJAX navigation', flush=True
            )

        finally:
            # Close DevTools only if browser setup established the socket.
            if socket:
                # Let Chromium stop its profile writers before removing
                # the profile.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, OSError):
                    pass
                socket.close()
            else:
                # Browser setup may fail before a DevTools connection exists.
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
finally:
    subprocess.run(
        ['perl', str(helper), 'delete', 'authentic-theme', user], check=True
    )
