"""Click Active Jobs controls through real browser navigation."""
from contextlib import contextmanager
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import websocket


@contextmanager
def job_actions_browser(cookies, job):
    """job_actions_browser(cookies, job) yields clicks scoped to one job ID."""
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for the job controls check'
    parent = Path('/root/snap/chromium/common') if browser.startswith('/snap/') else None
    # Snap cannot access the controller's private /tmp.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-job-actions-', dir=parent) as profile:
        chrome = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--no-default-browser-check', '--disable-background-networking', '--disable-sync',
            '--window-size=1600,1000', '--user-data-dir=' + profile, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists() and chrome.poll() is None and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:' + port + route,
                                             timeout=30, suppress_origin=True)
            serial, session = 0, None
            posts = []

            def call(method, params=None):
                """call(method, [params]) sends CDP and records actions."""
                nonlocal serial
                serial += 1
                command = {'id': serial, 'method': method, 'params': params or {}}
                # Browser commands run before attachment; later ones use the
                # tab.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Never retain session cookies or form tokens in diagnostics.
                    if reply.get('method') == 'Network.requestWillBeSent':
                        request = reply['params']['request']
                        if request['method'] == 'POST' and urllib.parse.urlsplit(request['url']).path == '/server-manager/jobs.cgi':
                            # Record only this fixture's action POST.
                            fields = urllib.parse.parse_qs(request.get('postData', ''))
                            if fields.get('job') == [job]:
                                # Keep only action names for diagnostics.
                                posts.extend(fields.get('action', []))
                    if reply.get('id') == serial:
                        # Wait for this command's reply, skipping events.
                        assert 'error' not in reply, 'Browser command failed'
                        return reply.get('result', {})

            def evaluate(expression):
                """evaluate(expression) reads values from the test tab."""
                result = call('Runtime.evaluate', {'expression': expression, 'returnByValue': True})
                assert not result.get('exceptionDetails'), 'Browser evaluation failed'
                return result.get('result', {}).get('value')

            def wait(expression):
                """wait(expression) awaits page state for up to 30 seconds."""
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if evaluate('!!(' + expression + ')'):
                        # Continue when the requested page state is reached.
                        return
                    time.sleep(.2)
                raise AssertionError('Job control did not return to Active Jobs')

            # Reuse only the test login in a new tab and temporary browser
            # profile.
            target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain + '.enable')
            for cookie in cookies:
                call('Network.setCookie', {'name': cookie.name, 'value': cookie.value,
                     'url': 'https://127.0.0.1:10000', 'path': cookie.path, 'secure': True})
            call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
            wait('document.querySelector("aside") && document.readyState === "complete"')
            # Enter through the theme's link handling, then allow its status refresh.
            evaluate("(() => { const a = document.createElement('a'); a.href = '/server-manager/jobs.cgi'; document.body.append(a); a.click(); a.remove(); })()")
            wait('document.getElementById("cloudmin-jobs")')
            time.sleep(2.5)

            def click(action):
                """click(action) requires one POST from this job's button."""
                selector = ('Array.from(document.querySelectorAll("#cloudmin-jobs form")).find(f => '
                            'f.querySelector("[name=job]")?.value === ' + json.dumps(job) + ' && '
                            'f.querySelector("[name=action]")?.value === ' + json.dumps(action) + ')')
                wait(selector)
                posts.clear()
                evaluate('window.fixtureJobsRoot = document.getElementById("cloudmin-jobs"); (' + selector + ').querySelector("button[type=submit]").click()')
                wait('!window.fixtureJobsRoot?.isConnected && document.getElementById("cloudmin-jobs")')
                assert posts == [action], 'Button did not submit exactly one job action'
                assert not evaluate('document.body.innerText.includes("Confirm Job Action")'), 'Unexpected confirmation page'

            yield click
        finally:
            # Close only the browser and debugging connection created above.
            if cdp:
                cdp.close()
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Bound teardown if graceful browser shutdown gets stuck.
                chrome.kill()
                chrome.wait(timeout=5)
