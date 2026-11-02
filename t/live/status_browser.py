"""Browser checks called by the socket integration test with its fixture session."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid
import websocket

# check_browser(jar, theme, conn) checks control layout and live row updates.
# jar holds the test session's cookies. theme labels screenshots and results.
# conn is an open libvirt connection used to create a stopped, diskless guest.
def check_browser(jar, theme, conn):
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser
    # Snap's private /tmp is not visible to the test controller.
    parent = Path('/root/snap/chromium/common') if browser.startswith('/snap/') else None
    if parent:
        # A fresh Snap installation may not have created this shared directory.
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-status-browser-', dir=parent) as profile:
        chrome = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu', '--remote-debugging-port=0',
            '--ignore-certificate-errors', '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
            '--disable-sync', '--window-size=1800,1200', '--user-data-dir=' + profile, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        fixture = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 20
            while not active.exists() and time.monotonic() < deadline: time.sleep(0.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:' + port + route, timeout=20, suppress_origin=True)
            serial, session = 0, None
            # call(method, [params]) matches CDP replies to this test's
            # commands.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = dict(id=serial, method=method, params=params or {})
                # Browser-wide setup runs before a target session exists.
                if session: command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Ignore unsolicited events while waiting for this reply.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, 'CDP failure'
                        return reply.get('result', {})
            # evaluate(expression) returns a JavaScript value from the module
            # page, or None for script errors or results without a value.
            def evaluate(expression):
                # A direct module URL can redirect into the frame layout.
                expression = '(window.frames.right || window).eval(' + json.dumps(expression) + ')'
                result = call('Runtime.evaluate', dict(expression=expression, returnByValue=True))
                # Navigation can temporarily invalidate the queried document.
                if 'exceptionDetails' in result: return None
                return result.get('result', {}).get('value')
            # wait(expression) bounds DOM and live-channel readiness to 25
            # seconds.
            def wait(expression):
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    # Continue only when the current document meets the
                    # condition.
                    if evaluate("!!(" + expression + ")"): return
                    time.sleep(0.25)
                raise AssertionError('Browser condition failed: ' + expression)
            # Reuse only the fixture session in a fresh browser profile.
            target = call('Target.createTarget', dict(url='about:blank'))['targetId']
            session = call('Target.attachToTarget', dict(targetId=target, flatten=True))['sessionId']
            for domain in ('Page', 'Runtime', 'Network'): call(domain + '.enable')
            for cookie in jar:
                call('Network.setCookie', dict(name=cookie.name, value=cookie.value,
                    url='https://127.0.0.1:10000', path=cookie.path, secure=cookie.secure))
            # Block discovery to measure controls before any live update.
            call('Network.setBlockedURLs', dict(urls=['*machine_status.cgi*']))
            call('Page.navigate', dict(url='https://127.0.0.1:10000/server-manager/index.cgi'))
            wait('document.readyState === "complete" && document.fonts.status === "loaded" && document.querySelector("[data-vm-id]")')
            # For each VM link, record its control markup and dimensions.
            # Exclude tokens and resource values, which can change on updates.
            controls = """Array.from(document.querySelectorAll('[data-vm-id]')).map(marker => {
                const config = JSON.parse(document.getElementById('cloudmin-vm-status').dataset.config);
                const cell = marker.closest('tr').cells[config.columns.indexOf('controls')];
                const buttons = Array.from(cell.querySelectorAll('button.ui_action_small'));
                const wrapper = cell.querySelector('.ui_cluster');
                return {
                    id: marker.dataset.vmId,
                    legacy: !!cell.querySelector('[data-btns], a.ui_link'),
                    shape: Array.from(cell.querySelectorAll('div, form, button')).map(el => el.tagName),
                    actions: buttons.map(button => button.form.elements.action.value),
                    sizes: buttons.map(button => [button.offsetWidth, button.offsetHeight]),
                    height: wrapper?.offsetHeight,
                    pause: !!cell.querySelector('input[value="suspend"]') === !!cell.querySelector('button .ui_svg_icon_pause')
                };
            })"""
            # Require buttons and a Pause icon wherever suspension is offered.
            initial = evaluate(controls)
            assert initial and any(row['actions'] for row in initial), 'Missing initial power controls'
            assert all(not row['legacy'] and row['pause'] for row in initial), 'Initial controls use legacy links or lack a Pause icon'
            # Unblock discovery so normal retries deliver the first snapshot.
            call('Network.setBlockedURLs', dict(urls=[]))
            wait('document.querySelector("#cloudmin-vm-status")?.dataset.statusConnected === "1"')
            expected = len(conn.listAllDomains())
            wait('document.querySelectorAll("[data-vm-id]").length === ' + str(expected))
            # Replacing controls must preserve their wrapper, size and actions.
            updated = {row['id']: row for row in evaluate(controls)}
            for row in initial:
                assert updated[row['id']] == row, 'First live update changed the controls: ' + json.dumps([row, updated[row['id']]])
            # Later inventory events must reuse the established connection.
            discoveries = evaluate('performance.getEntriesByType("resource").filter(e => e.name.includes("machine_status.cgi")).length')
            assert evaluate('document.querySelectorAll("#cloudmin-overview .ui_stat_value svg").length') == 4, 'Live counts removed tile icons'
            # Defining a stopped, diskless guest triggers inventory events
            # safely.
            ident = str(uuid.uuid4())
            name = 'cloudmin-status-browser-' + ident[:8]
            arch = conn.getInfo()[0]
            machine = 'virt' if arch == 'aarch64' else 'q35'
            fixture = conn.defineXML(f"<domain type='kvm'><name>{name}</name><uuid>{ident}</uuid><memory unit='MiB'>64</memory><vcpu>1</vcpu><os><type arch='{arch}' machine='{machine}'>hvm</type></os></domain>")
            selector = '[data-vm-id="' + ident + '"]'
            row = 'document.querySelector(' + json.dumps(selector) + ')?.closest("tr")'
            wait(row + '?.textContent.includes(' + json.dumps(name) + ')')
            assert evaluate(row + '.cells.length') == 10, 'Wrong row shape'
            # Both themes use the same controls for newly discovered guests.
            wait(row + '?.querySelector("td:last-child .ui_cluster button.ui_action_small")')
            assert not evaluate(row + '.querySelector("td:last-child [data-btns], td:last-child a.ui_link")'), 'Live controls contain legacy links or wrappers'
            assert evaluate('performance.getEntriesByType("resource").filter(e => e.name.includes("machine_status.cgi")).length') == discoveries
            # The new row contains a real signed form and can change its own fixture.
            evaluate(row + '.querySelector("input[type=checkbox]").click()')
            deadline = time.monotonic() + 15
            while not fixture.autostart() and time.monotonic() < deadline: time.sleep(0.25)
            assert fixture.autostart(), 'Live toggle did not submit its signed fixture form'
            wait('document.querySelector("#cloudmin-vm-status")?.dataset.statusConnected === "1"')
            fixture.undefine(); fixture = None
            wait('!document.querySelector(' + json.dumps(selector) + ')')
            # Retain a screenshot of the resulting table for visual inspection.
            image = call('Page.captureScreenshot', dict(format='png'))
            output = Path(os.environ.get('CLOUDMIN_STATUS_ARTIFACTS', tempfile.gettempdir()))
            (output / (theme + '-status.png')).write_bytes(base64.b64decode(image['data']))
            print('PASS: ' + theme + ' stable controls, row addition/removal and signed autostart', flush=True)
        finally:
            # Remove only this test's domain if an assertion interrupted
            # cleanup.
            if fixture is not None: fixture.undefine()
            # Let Chromium finish profile writes before deleting the directory.
            if cdp:
                try: call('Browser.close')
                except Exception: pass
                cdp.close()
            try: chrome.wait(timeout=5)
            except subprocess.TimeoutExpired: chrome.kill(); chrome.wait()
