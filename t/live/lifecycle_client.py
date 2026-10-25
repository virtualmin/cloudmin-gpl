"""Exercise VM list controls through SPA navigation in a disposable-VM browser."""
import base64
import http.cookiejar
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

import websocket


# EvaluationError marks a page expression that failed, such as during navigation.
class EvaluationError(RuntimeError):
    pass


# check_lifecycle(opener, base, uuid, inspect, boot_id)
def check_lifecycle(opener, base, uuid, inspect, boot_id):
    """Operate only on the caller's fixture; verify guest state independently."""
    assert platform.system() == 'Linux' and os.geteuid() == 0
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required on the disposable VM'
    helper = Path(__file__).with_name('webmin-user.pl')

    # A read-only login must not render controls or accept forged power requests.
    password = secrets.token_urlsafe(36)
    user = 'cloudmin-frame-check'
    subprocess.run(['perl', str(helper), 'create-readonly', 'authentic-theme', user],
                   input=password + '\n', text=True, check=True)
    try:
        reader = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))

        # read(path, [fields]) sends requests as the read-only fixture account.
        def read(path, fields=None):
            data = None if fields is None else urllib.parse.urlencode(fields).encode()
            with reader.open(urllib.request.Request(base + path, data=data,
                headers={'Referer': base + '/server-manager/index.cgi'}), timeout=30) as response:
                return response.read().decode()

        time.sleep(1)
        read('/session_login.cgi')
        read('/session_login.cgi', {'user': user, 'pass': password, 'page': '/server-manager/index.cgi'})
        page = read('/server-manager/index.cgi')
        assert 'name="token"' not in page
        assert 'Start at boot' in page or 'not allowed to use the Cloudmin module' in page
        for action in ('start', 'shutdown', 'reboot', 'autostart'):
            page = read('/server-manager/index.cgi', {'action': action, 'id': uuid,
                                                      'token': 'forged', 'enabled': 1})
            assert ('read-only mode' in page and 'Cannot change virtual machine' in page
                    or 'not allowed to use the Cloudmin module' in page)
        print('Read-only account cannot render or submit VM controls: PASS', flush=True)
    finally:
        subprocess.run(['perl', str(helper), 'delete', 'authentic-theme', user], check=True)

    # Start a fresh browser on the VM; reuse only the fixture's HTTP session.
    with tempfile.TemporaryDirectory(prefix='cloudmin-lifecycle-browser-') as work:
        chrome = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--no-default-browser-check', '--disable-background-networking', '--disable-sync',
            '--window-size=1800,1200', '--user-data-dir=' + work, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        try:
            active = Path(work) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists() and chrome.poll() is None and time.monotonic() < deadline:
                time.sleep(0.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:' + port + route,
                                             timeout=30, suppress_origin=True)
            serial = 0
            session = None
            errors = []

            # call(method, [params]) waits for CDP replies without exposing cookies.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = dict(id=serial, method=method, params=params or {})
                # Browser-wide setup precedes attachment to the fixture tab.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    if reply.get('method') == 'Runtime.exceptionThrown':
                        # Keep the exception text; drop query strings from any URLs.
                        detail = reply['params']['exceptionDetails']
                        text = re.sub(r'\?[^\s]+', '?[redacted]',
                            detail.get('exception', {}).get('description', detail.get('text', 'JavaScript error')))
                        # Direct module loads have a known service-worker 404.
                        # Ignore this page-shell error when testing guest controls.
                        if not ('Failed to register a ServiceWorker' in text and
                                base + '/server-manager/service-worker.js' in text):
                            errors.append(text)
                    # Event messages do not complete the pending command.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, 'Browser command failed'
                        return reply.get('result', {})

            # evaluate(expression) reads or clicks controls in the actual page.
            def evaluate(expression):
                result = call('Runtime.evaluate', dict(expression=expression, returnByValue=True))
                # Navigation can invalidate an otherwise valid DOM expression.
                if 'exceptionDetails' in result:
                    raise EvaluationError('Browser evaluation failed')
                return result.get('result', {}).get('value')

            # wait(predicate, label, [seconds]) bounds asynchronous state changes.
            def wait(predicate, label, seconds=90):
                until = time.monotonic() + seconds
                while time.monotonic() < until:
                    try:
                        # Only an independently observed state ends the wait.
                        if predicate():
                            return
                    except EvaluationError:
                        # The page is being replaced; poll again after the navigation.
                        pass
                    time.sleep(1)
                raise AssertionError(label)

            target = call('Target.createTarget', dict(url='about:blank'))['targetId']
            session = call('Target.attachToTarget', dict(targetId=target, flatten=True))['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain + '.enable')
            jar = next(handler.cookiejar for handler in opener.handlers
                       if isinstance(handler, urllib.request.HTTPCookieProcessor))
            for cookie in jar:
                call('Network.setCookie', dict(name=cookie.name, value=cookie.value,
                    url=base, path=cookie.path, secure=cookie.secure))

            # Forms are identified by the fixture UUID, never by table position.
            forms = '''Array.from(document.querySelectorAll('#cloudmin-machines form'))
                .filter(f => f.querySelector('[name=id]')?.value === %s)''' % json.dumps(uuid)

            # load() waits for the inventory, the page's submit handlers and the
            # live status channel, which blocks actions until it has connected.
            def load():
                call('Page.navigate', dict(url=base + '/server-manager/index.cgi'))
                wait(lambda: evaluate('typeof jQuery !== "undefined" && (' + forms + ').length > 0'),
                     'VM controls did not render')
                wait(lambda: evaluate('''(() => {
                    const status = document.getElementById('cloudmin-vm-status');
                    return !status || status.dataset.statusConnected === '1';
                })()'''), 'Live status did not connect')
                time.sleep(1)

            # click(action, [message]) uses the visible control: the boot toggle,
            # a power action link or a submit button. A message confirms acceptance.
            def click(action, message=None):
                assert evaluate('''(() => {
                    const f = (%s).find(f => f.querySelector('[name=action]')?.value === %s);
                    const b = f?.querySelector('input[type=checkbox], a[href="#"], button.ui_submit, input.ui_submit[type=submit]');
                    if (!b) return false;
                    b.click(); return true;
                })()''' % (forms, json.dumps(action))), 'Missing ' + action + ' control'
                # Power actions show acceptance before their state changes.
                if message:
                    wait(lambda: evaluate('document.body.innerText.includes(' + json.dumps(message) + ')'),
                         action + ' did not show acceptance')
                # The boot toggle saves silently; allow its request to finish.
                else:
                    time.sleep(2)
                assert not errors, 'Browser raised JavaScript errors: ' + '; '.join(errors)

            load()
            # Invalid methods and tokens must leave the live guest untouched.
            for path, fields, expected in (
                ('/server-manager/index.cgi?action=shutdown&id=' + uuid, None, 'Use POST'),
                ('/server-manager/index.cgi', {'action': 'shutdown', 'id': uuid, 'token': 'bad'}, 'This form has expired'),
            ):
                data = None if fields is None else urllib.parse.urlencode(fields).encode()
                with opener.open(urllib.request.Request(base + path, data=data,
                    headers={'Referer': base + '/server-manager/index.cgi'}), timeout=30) as response:
                    assert expected in response.read().decode()
            assert inspect()['active'], 'Rejected request stopped the fixture'

            # The boot toggle shows its saved state instead of a success message.
            click('autostart')
            wait(lambda: inspect()['autostart'] == 1, 'Boot policy did not persist in libvirt')
            load()
            click('autostart')
            wait(lambda: inspect()['autostart'] == 0, 'Disable did not persist in libvirt')
            load()
            before = boot_id()
            assert before.returncode == 0 and before.stdout.strip(), 'Cannot read guest boot ID'
            click('reboot', 'Reboot requested')

            # changed_boot() proves an actual guest reboot, not just API acceptance.
            def changed_boot():
                try:
                    result = boot_id()
                    return result.returncode == 0 and result.stdout.strip() and result.stdout != before.stdout
                except subprocess.TimeoutExpired:
                    return False

            wait(changed_boot, 'Guest did not reboot', 180)
            load()
            click('shutdown', 'Shutdown requested')
            wait(lambda: not inspect()['active'], 'Guest did not shut down cleanly')
            load()
            click('start', 'Start requested')
            wait(lambda: inspect()['active'], 'Guest did not start')
            wait(lambda: boot_id().returncode == 0, 'SSH did not return after start', 180)
            load()
            # Retain only a screenshot of the inventory, which contains no credentials.
            screenshot = call('Page.captureScreenshot', dict(format='png', captureBeyondViewport=True))
            (Path(__file__).parent / 'lifecycle-dashboard.png').write_bytes(base64.b64decode(screenshot['data']))
            print('SPA controls: boot policy, real reboot, clean shutdown, start and SSH: PASS', flush=True)
        finally:
            if cdp:
                # Finish browser writes before removing its temporary profile.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, OSError):
                    pass
                cdp.close()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                chrome.kill()
                chrome.wait(timeout=10)
