"""Check live job progress and table layout on a disposable Linux Cloudmin VM.

Uses temporary Webmin users and status records; never starts job workers.
Requires Chromium and python3-websocket on the guest.
"""
import json
import base64
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import websocket


# check_jobs(cookies, theme) exercises refreshed rows in a fresh browser profile.
def check_jobs(cookies, theme):
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for the jobs browser check'
    # Snap's private /tmp is not the controller's /tmp; use its writable area.
    parent = Path('/root/snap/chromium/common') if browser.startswith('/snap/') else None
    # Create a profile directory visible inside the Snap browser sandbox.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-jobs-browser-', dir=parent) as profile:
        chrome = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--no-default-browser-check', '--disable-background-networking', '--disable-sync',
            '--window-size=1600,1000', '--user-data-dir='+profile, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        try:
            active = Path(profile)/'DevToolsActivePort'
            deadline = time.monotonic()+20
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:'+port+route,
                                              timeout=30, suppress_origin=True)
            serial, session = 0, None

            # call(method, [params]) waits for the matching browser command reply.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = {'id': serial, 'method': method, 'params': params or {}}
                # Attach tab commands only after a target session exists.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Unsolicited browser events do not finish the pending command.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(expression) returns a JSON-compatible value from the page.
            def evaluate(expression):
                # Frame layouts can redirect a direct module URL into their shell.
                expression = ('(window.frames.right || window).eval('+json.dumps(expression)+')')
                result = call('Runtime.evaluate', {'expression': expression, 'returnByValue': True})
                # Treat page-script failures as test failures instead of missing values.
                if result.get('exceptionDetails'):
                    raise AssertionError(result['exceptionDetails'])
                return result.get('result', {}).get('value')

            # wait(expression) polls the current page for up to 45 seconds.
            def wait(expression):
                deadline = time.monotonic()+45
                while time.monotonic() < deadline:
                    # Proceed when the rendered document meets the requested condition.
                    if evaluate('!!('+expression+')'):
                        return
                    time.sleep(.25)
                detail = evaluate('document.body?.innerText.slice(0, 1500)')
                raise AssertionError('Browser condition failed: '+expression+'; page: '+str(detail))

            target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain+'.enable')
            for cookie in cookies:
                call('Network.setCookie', {'name': cookie.name, 'value': cookie.value,
                     'url': 'https://127.0.0.1:10000', 'path': cookie.path, 'secure': True})
            # Enter through an ordinary link so the theme owns its navigation.
            call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            # A frame shell can exist before its right-hand page has a referrer.
            wait('document.location.href.startsWith("https://127.0.0.1:10000/") && document.readyState === "complete"')
            evaluate("(() => { const a = document.createElement('a'); a.href = '/server-manager/jobs.cgi'; document.body.append(a); a.click(); a.remove(); })()")
            wait('document.querySelector("#cloudmin-jobs [data-jobs-content]")')
            was_empty = evaluate('document.querySelector("#cloudmin-jobs .ui_empty") !== null')
            # An initially empty inventory must still render its empty-state icon.
            if was_empty:
                assert evaluate('document.querySelector("#cloudmin-jobs .ui_empty_icon svg") !== null')
            # Job controls must submit their own ID, action and signed token.
            assert evaluate('''Array.from(document.querySelectorAll('#cloudmin-jobs form')).every(f =>
                f.method === 'post' && f.querySelector('[name=token]')?.value &&
                f.querySelector('[name=job]')?.value && f.querySelector('[name=action]')?.value)''')
            print('Status loaded; empty:', was_empty, flush=True)
            evaluate('window.jobsRoot = document.querySelector("#cloudmin-jobs"); top.jobsMenu = top.document.querySelector("aside") || top.frames.left.document.body; true')
            picture = call('Page.captureScreenshot', {'format':'jpeg', 'quality':65})
            Path('/tmp/jobs-empty-'+theme+'.jpg').write_bytes(base64.b64decode(picture['data']))
            evaluate("window.fixtureRow = () => Array.from(document.querySelectorAll('.cloudmin-jobs-table > tbody > tr')).find(r => r.textContent.includes('Live progress fixture <image>'))")
            job_id = secrets.token_hex(16)
            job_path = Path('/var/webmin/modules/server-manager/image-jobs')/(job_id+'.json')
            record = {'id':job_id, 'name':'Live progress fixture <image>', 'owner':'cloudmin-ui-check',
                      'created':int(time.time()), 'updated':int(time.time()), 'pid':os.getpid(),
                      'state':'downloading', 'bytes':256*1024**2, 'total':1024**3}
            second_path = job_path.with_name(secrets.token_hex(16)+'.json')
            # publish() atomically replaces a status fixture without starting a worker.
            def publish():
                record['updated']=int(time.time())
                temporary=job_path.with_suffix('.tmp')
                temporary.write_text(json.dumps(record))
                temporary.chmod(0o600)
                temporary.replace(job_path)
            try:
                second_path.write_text(json.dumps({**record, 'id':second_path.stem,
                    'name':'Another active image with a much longer name'}))
                second_path.chmod(0o600)
                publish()
                wait('window.fixtureRow()?.querySelector(`[aria-valuenow="25"]`)')
                # Refreshed HTML must retain the theme's table API and cell padding.
                evaluate('''window.jobsLayout = () => {
                    const row = window.fixtureRow(), table = row.closest('table');
                    const heads = [...table.rows[0].cells];
                    return {
                        themeClass: table.classList.contains('table') ? 'authentic-theme' : 'gray-theme',
                        widths: [...row.cells].map(c => c.getBoundingClientRect().width),
                        padding: [...row.cells].map(c => parseFloat(getComputedStyle(c).paddingLeft)),
                        aligned: [...row.cells].every((c, i) => {
                            const cell = c.getBoundingClientRect(), head = heads[i].getBoundingClientRect();
                            return Math.abs(cell.left - head.left) < 1 &&
                                Math.abs(parseFloat(getComputedStyle(c).paddingLeft) -
                                         parseFloat(getComputedStyle(heads[i]).paddingLeft)) < 1;
                        }),
                        fits: [...row.cells].every(c => c.scrollWidth <= c.clientWidth + 1)
                    };
                }; true''')
                original = evaluate('jobsLayout()')
                assert original['themeClass'] == theme, original
                assert min(original['padding']) >= 4, original
                assert original['aligned'] and original['fits'], original
                # compare_layout() checks spacing through phase and inventory changes.
                def compare_layout():
                    current = evaluate('jobsLayout()')
                    assert current['aligned'] and current['fits'], current
                    assert all(abs(a-b) < 1 for a,b in zip(original['widths'], current['widths'])), current
                print('Themed cells, matching headers and padding: PASS', flush=True)
                assert evaluate('document.querySelector("#cloudmin-jobs").innerText.includes("Live progress fixture <image>")')
                assert evaluate('window.fixtureRow().querySelectorAll("a,button,input,form").length') == 0
                # Compare the page and sidebar, which must survive every progress update.
                time.sleep(2)
                record['bytes']=768*1024**2
                publish()
                wait('window.fixtureRow()?.querySelector(`[aria-valuenow="75"]`)')
                picture = call('Page.captureScreenshot', {'format':'jpeg', 'quality':65})
                Path('/tmp/jobs-running-'+theme+'.jpg').write_bytes(base64.b64decode(picture['data']))
                record.update(state='importing', transferred=384*1024**2)
                publish()
                wait('window.fixtureRow()?.querySelector(`[aria-valuenow="50"]`)')
                compare_layout()
                record.update(source='download', checksum_algorithm='sha512', checksum_source='vendor')
                record['state']='verifying'
                publish()
                wait('window.fixtureRow()?.querySelector(".ui_progress_indeterminate")')
                compare_layout()
                second_path.unlink()
                wait("!document.querySelector('#cloudmin-jobs').innerText.includes('Another active image')")
                compare_layout()
                # Narrow pages scroll only the table, keeping cell content readable.
                call('Emulation.setDeviceMetricsOverride', {'width':760, 'height':900,
                     'deviceScaleFactor':1, 'mobile':False})
                wait("document.querySelector('.cloudmin-jobs-scroll').clientWidth < 768")
                assert evaluate('jobsLayout().fits')
                assert evaluate("document.querySelector('.cloudmin-jobs-scroll').scrollWidth >= document.querySelector('.cloudmin-jobs-scroll').clientWidth")
                call('Emulation.clearDeviceMetricsOverride')
                record['state']='ready'
                publish()
                wait('!window.fixtureRow()')
                # Removing the fixture must restore the original empty state.
                if was_empty:
                    wait('document.querySelector("#cloudmin-jobs .ui_empty")')
                assert evaluate('window.jobsRoot === document.querySelector("#cloudmin-jobs")')
                assert evaluate('top.jobsMenu === (top.document.querySelector("aside") || top.frames.left.document.body)')
                print('Measured progress, stable columns, narrow layout, completion and stable menu: PASS', flush=True)
            finally:
                job_path.unlink(missing_ok=True)
                second_path.unlink(missing_ok=True)
        finally:
            if cdp:
                # Let Chromium stop its profile writers before removing the directory.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, OSError):
                    pass
                cdp.close()
            # If DevTools never connected, terminate the owned browser directly.
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
    assert platform.system() == 'Linux' and os.geteuid() == 0, 'Run on a disposable Linux VM as root'
    helper = str(Path(__file__).with_name('webmin-user.pl'))
    for theme in ('authentic-theme', 'gray-theme'):
        password = secrets.token_urlsafe(36)
        created = False
        try:
            subprocess.run(['perl', helper, 'create', theme], input=password+'\n', text=True, check=True)
            created = True
            time.sleep(1)
            cookies = http.cookiejar.CookieJar()
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                urllib.request.HTTPCookieProcessor(cookies),
                urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
            base = 'https://127.0.0.1:10000'
            with opener.open(base+'/session_login.cgi', timeout=30) as response:
                response.read()
            data = urllib.parse.urlencode({'user':'cloudmin-ui-check', 'pass':password, 'page':'/'}).encode()
            with opener.open(base+'/session_login.cgi', data, timeout=30) as response:
                response.read()
            print(theme, flush=True)
            check_jobs(cookies, theme)
        finally:
            # Do not revoke an account that this run failed to create.
            if created:
                subprocess.run(['perl', helper, 'delete'], check=True)
