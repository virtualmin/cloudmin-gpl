"""Exercise License Manager navigation and progress in an isolated browser."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import websocket
from theme_support import is_spa_theme


# check_license_browser(cookies, theme) keeps saved credentials unchanged.
def check_license_browser(cookies, theme):
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for license browser checks'
    parent = Path('/root/snap/chromium/common') if browser.startswith('/snap/') else None
    # Snap needs its temporary profile in a directory it can access.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-license-browser-', dir=parent) as profile:
        chrome = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--no-default-browser-check', '--disable-background-networking', '--disable-sync',
            '--window-size=1600,1000', '--user-data-dir='+profile, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        try:
            # Connect only to the browser created for this fixture.
            active = Path(profile)/'DevToolsActivePort'
            deadline = time.monotonic()+30
            while not active.exists() and chrome.poll() is None and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:'+port+route,
                                              timeout=30, suppress_origin=True)
            serial, session = 0, None

            # call(method, [params]) waits for one CDP response without logging secrets.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = dict(id=serial, method=method, params=params or {})
                # Attach page commands only after creating the tab session.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    if reply.get('id') == serial:
                        # Unrelated browser events do not complete this request.
                        assert 'error' not in reply, 'Browser command failed'
                        return reply.get('result', {})

            # evaluate(expression) reads the active module pane in either theme.
            def evaluate(expression):
                reply = call('Runtime.evaluate', {'expression':
                    '(window.frames.right || window).eval('+json.dumps(expression)+')',
                    'returnByValue': True, 'userGesture': True})
                assert 'exceptionDetails' not in reply, 'Browser evaluation failed'
                return reply.get('result', {}).get('value')

            # wait(expression) allows navigation and the 20-second license timeout.
            def wait(expression):
                deadline = time.monotonic()+45
                while time.monotonic() < deadline:
                    if evaluate('!!('+expression+')'):
                        # Continue only after the requested page state is visible.
                        return
                    time.sleep(.2)
                raise AssertionError('License browser condition failed: '+expression)

            # follow(path) uses the theme's ordinary link handling.
            def follow(path):
                evaluate('(() => {const a=document.createElement("a"); a.href='+
                    json.dumps(path)+'; document.body.append(a); a.click(); a.remove();})()')

            target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain+'.enable')
            for cookie in cookies:
                call('Network.setCookie', {'name': cookie.name, 'value': cookie.value,
                    'url': 'https://127.0.0.1:10000', 'path': cookie.path, 'secure': True})
            call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            if is_spa_theme(theme):
                # Wait for SPA handlers before following the manager link.
                wait('document.body.getAttribute("data-initial-load") === "0"')
                follow('/server-manager/pro/license.cgi')
            else:
                # The frame theme needs its content frame selected explicitly.
                tree = call('Page.getFrameTree')['frameTree']
                frame = next(f['frame']['id'] for f in tree['childFrames']
                             if f['frame'].get('name') == 'right')
                call('Page.navigate', {'url': 'https://127.0.0.1:10000/server-manager/pro/license.cgi',
                    'frameId': frame, 'referrer': 'https://127.0.0.1:10000/'})
            wait('document.querySelector("input[name=license_key]")')
            assert evaluate('document.querySelector("input[name=license_key]").type') == 'text'
            assert not evaluate('document.body.innerText.includes("<span data-")'), 'Escaped date markup'
            if is_spa_theme(theme):
                # The current Pro route must stream progress and retain its shop label.
                assert evaluate('unbuffered_header_processor_allow("/server-manager/pro/update_license.cgi",true)'), 'License route is not progressive'
                shop = 'document.querySelector("#headln2r a[href*=cloudmin-professional-monthly-subscription]")'
                wait(shop+'?.querySelector(".fa-cloudmin")')
                assert evaluate(shop+'.innerText.trim()') == 'Cloudmin Shop', 'Shop label is hidden'
                assert evaluate(shop+'.getBoundingClientRect().width > 130'), 'Shop button is icon-sized'
                assert not evaluate('document.querySelector("#headln2r a[href*=help] ")'), 'Unexpected license help button'
            if evaluate('!!document.querySelector("[name=deregister]")'):
                # Review is safe; never confirm removal of the host's real license.
                evaluate('document.querySelector("[name=deregister]").click()')
                wait('document.querySelector("input[name=confirm]")')
                assert not evaluate('document.querySelector("input[name=license_key]")'), 'Review copies credentials'
                follow('/server-manager/pro/license.cgi')
                wait('document.querySelector("input[name=license_key]")')
            # A deliberately invalid replacement exercises streamed failure only.
            evaluate('document.querySelector("input[name=serial]").value="12345"; '
                'document.querySelector("input[name=license_key]").value="cloudmin-preprod-invalid-key"; '
                'document.querySelector("[name=update]").click()')
            wait('document.querySelector("[data-second-print]")')
            result = evaluate('document.querySelector("[data-second-print]").innerText.trim()')
            assert result.startswith('.. failed : '), 'Invalid fixture license was not refused'
            assert not result.endswith('.') and 'Cloudmin' not in result, 'Unexpected progress wording'
            assert not evaluate('document.querySelector("[data-fatal-error-text]")'), 'Progress opened a fatal error'
            print(theme+': license navigation, shop button, confirmation and progress passed')
        finally:
            # Close only this fixture's browser and temporary profile.
            if cdp:
                cdp.close()
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Bound teardown even if Chromium does not exit gracefully.
                chrome.kill()
                chrome.wait(timeout=10)
