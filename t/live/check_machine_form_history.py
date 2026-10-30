#!/usr/bin/python3
"""Check creation controls after a failed submission and browser Back in both themes."""
import http.cookiejar
import argparse
import json
import shutil
import tempfile
import websocket
import os
from pathlib import Path
import platform
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request

# Keep fixture accounts and browser profiles on the authorized Linux host.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on an authorized Linux test host as root')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--webmin-tests', type=Path, default=Path(__file__).resolve().parent)
parser.add_argument('--theme', choices=('authentic-theme', 'gray-theme'))
parser.add_argument('--diagnose', action='store_true')
args = parser.parse_args()
here = args.webmin_tests.resolve()
base = 'https://127.0.0.1:10000'
cookies = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(cookies),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
helper = here / 'webmin-user.pl'
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
password = secrets.token_urlsafe(36)
created = False


# request(path, [fields], [as_json]) submits only the generated fixture session.
def request(path, fields=None, as_json=False):
    data = None
    headers = {'Referer': base + '/server-manager/machine_form.cgi'}
    # GET requests have no body; mutations use the controller's expected format.
    if fields is not None:
        data = (json.dumps(fields) if as_json else urllib.parse.urlencode(fields, doseq=True)).encode()
        headers['Content-Type'] = 'application/json' if as_json else 'application/x-www-form-urlencoded'
    with opener.open(urllib.request.Request(base + path, data=data, headers=headers), timeout=90) as response:
        page = response.read().decode()
    assert 'Error - Perl execution failed' not in page, path + ' crashed'
    return page


# browser_check() submits an invalid form, then restores it with browser Back.
def browser_check():
    binary = shutil.which('chromium') or shutil.which('chromium-browser')
    assert binary, 'Chromium is required'
    parent = Path('/root/snap/chromium/common') if binary.startswith('/snap/') else None
    # Snap Chromium can only use profiles within its allowed data directory.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-history-browser-', dir=parent) as profile:
        chrome = subprocess.Popen([binary, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--disable-background-networking', '--disable-sync', '--window-size=1600,1100',
            '--user-data-dir=' + profile, 'about:blank'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:' + port + route, timeout=30, suppress_origin=True)
            serial, session = 0, None

            # call(method, [params]) talks only to the isolated fixture browser.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = {'id': serial, 'method': method, 'params': params or {}}
                # Browser commands precede attachment; later calls target the
                # tab.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Ignore asynchronous events while waiting for this reply.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(expression) returns only explicitly selected fixture
            # data.
            def evaluate(expression):
                result = call('Runtime.evaluate', {'expression': '(window.frames.right || window).eval(' + json.dumps(expression) + ')', 'returnByValue': True})
                assert 'exceptionDetails' not in result, result.get('exceptionDetails')
                return result.get('result', {}).get('value')

            # wait(expression) bounds UI navigation and prints no form values.
            def wait(expression):
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    # Continue only after the page exposes the expected state.
                    if evaluate('!!(' + expression + ')'):
                        return
                    time.sleep(.25)
                raise AssertionError('Browser wait failed: ' + expression + '; page: ' + str(evaluate('document.body?.innerText.slice(-1600)')))

            # navigate(path) follows a link through the page's navigation handlers.
            def navigate(path):
                evaluate('var a=document.createElement("a"); a.href=' + json.dumps(path) + '; document.body.append(a); a.click(); a.remove()')

            # Reuse only the fixture session in a fresh isolated browser tab.
            target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain + '.enable')
            for cookie in cookies:
                call('Network.setCookie', {'name': cookie.name, 'value': cookie.value, 'url': base, 'path': cookie.path, 'secure': True})
            call('Page.navigate', {'url': base + '/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            # The content frame can start blank, with no referrer.
            if theme == 'gray-theme':
                tree = call('Page.getFrameTree')['frameTree']
                frame = next(child['frame']['id'] for child in tree['childFrames']
                             if child['frame'].get('name') == 'right')
                call('Page.navigate', {'url':base+'/server-manager/machine_form.cgi',
                                      'frameId':frame, 'referrer':base+'/'})
            else:
                # Exercise the page's navigation handlers instead of a direct load.
                navigate('/server-manager/machine_form.cgi')
            wait('document.querySelector("#vm-create-form") && document.querySelector("select[name=template]")')
            time.sleep(1)
            # Choose actual templates from the form's public preset metadata.
            choices = evaluate("""(() => {
                const p=JSON.parse(document.querySelector('script[data-vm-presets]').textContent);
                return Object.fromEntries(['virtualmin-pro','virtualmin-gpl'].map(software =>
                    [software,p.template.entries.find(t => t.settings.software===software)?.id]));
            })()""")
            assert all(choices.values()), 'Pro and GPL templates are required'

            # select(edition) exercises the theme's synthetic or native change path.
            def select(edition):
                evaluate("""(() => {
                    const s=document.querySelector('select[name=template]');
                    s.value=""" + json.dumps(choices[edition]) + """;
                    if (window.jQuery) window.jQuery(s).trigger('change');
                    else s.dispatchEvent(new Event('change',{bubbles:true}));
                })()""")

            # state() exposes visibility and public selectors, never credentials.
            def state():
                return evaluate("""(() => {
                    const f=document.querySelector('#vm-create-form');
                    return {template:f.elements.template.value,software:f.elements.software.value,
                        shown:[...f.querySelectorAll('[data-vm-license]')].every(r => !r.hidden),
                        enabled:!f.elements.virtualmin_serial.disabled && !f.elements.virtualmin_key.disabled};
                })()""")

            select('virtualmin-pro')
            assert state()['shown'] and state()['enabled'], 'Initial Pro selection failed'
            # Invalid identity guarantees server validation fails before any job.
            evaluate("""(() => {
                const f=document.querySelector('#vm-create-form');
                f.elements.name.value='invalid name for history test';
                f.elements.password.value='fixture-password-only';
                f.noValidate=true;
                f.querySelector('[type=submit]').click();
            })()""")
            wait('location.pathname.endsWith("/setup_machine.cgi") && document.body.innerText.includes("Cannot create virtual machine")')
            evaluate('top.history.back()')
            wait('location.pathname.endsWith("/machine_form.cgi") && document.querySelector("#vm-create-form")')
            time.sleep(.5)
            restored=state()
            select('virtualmin-gpl')
            gpl=state()
            select('virtualmin-pro')
            pro=state()
            if args.diagnose:
                # Diagnostics include selectors and visibility, never
                # credentials.
                print(theme + ': ' + json.dumps({'back':restored,'gpl':gpl,'pro':pro}), flush=True)
            else:
                # Back and both edition switches must update visibility and
                # inputs.
                assert restored['template']==choices['virtualmin-pro'] and restored['software']=='virtualmin-pro' and restored['shown'] and restored['enabled'], 'Back did not restore Pro controls: '+str(restored)
                assert gpl['software']=='virtualmin-gpl' and not gpl['shown'] and not gpl['enabled'], 'GPL did not hide license controls: '+str(gpl)
                assert pro['software']=='virtualmin-pro' and pro['shown'] and pro['enabled'], 'Pro did not show license controls: '+str(pro)
                print('PASS: '+theme+' failed submission, browser Back, GPL/Pro switching',flush=True)

        finally:
            # Close only the browser connection created by this fixture.
            if cdp:
                try:
                    call('Browser.close')
                except websocket.WebSocketException:
                    pass
                cdp.close()
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Bound teardown if this fixture browser stops responding.
                chrome.kill(); chrome.wait()


for theme in ([args.theme] if args.theme else ('authentic-theme', 'gray-theme')):
    created = False
    cookies.clear()
    try:
        # A per-user theme keeps the host administrator's preferences unchanged.
        subprocess.run(['perl', str(helper), 'create', theme, user], input=password+'\n', text=True, check=True)
        created = True
        request('/session_login.cgi')
        request('/session_login.cgi', {'user':user,'pass':password,'page':'/server-manager/index.cgi'})
        browser_check()
    finally:
        # Remove only this run's temporary account and session.
        if created:
            subprocess.run(['perl', str(helper), 'delete', theme, user], check=True)
