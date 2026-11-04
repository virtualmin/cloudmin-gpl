#!/usr/bin/python3
"""Exercise failed creation, hardware edits and image imports in a browser."""
import http.cookiejar
import json
import shutil
import tempfile
import websocket
import re
import os
from pathlib import Path
import platform
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request

# Keep fixture accounts, browser profiles and guest changes on a Linux test
# host.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on an authorized Linux test host as root')
here = Path(__file__).resolve().parent
base = 'https://127.0.0.1:10000'
cookies = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(cookies),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
helper = here / 'webmin-user.pl'
user = 'cloudmin-ui-check'
password = secrets.token_urlsafe(36)
created = False
fixture_jobs = []
fixture_images = []


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


# api(action, [fields]) uses the public controller, including its token checks.
def api(action, fields=None):
    result = json.loads(request('/server-manager/api.cgi' + ('?action=' + action if fields is None else ''),
        None if fields is None else {'action': action, **fields}, fields is not None))
    assert 'result' in result, result.get('error', 'Missing API result')
    return result['result']


# wait_state(ident, expected) observes a real worker without replaying it.
def wait_state(ident, expected):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        job = api('status', {'job': ident})
        if job['state'] in ('complete', 'failed', 'cancelled'):
            # Check the final outcome as soon as the worker stops.
            assert job['state'] == expected, job.get('error', job['state'])
            return job
        time.sleep(.25)
    raise AssertionError('Worker timed out')


# browser_check() exercises navigation and browser history with real failed jobs.
def browser_check():
    binary = shutil.which('chromium') or shutil.which('chromium-browser')
    assert binary, 'Chromium is required'
    parent = Path('/root/snap/chromium/common') if binary.startswith('/snap/') else None
    # Snap Chromium can only use profiles within its allowed data directory.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-retry-browser-', dir=parent) as profile, tempfile.TemporaryDirectory(prefix='cloudmin-retry-', dir='/tmp') as work:
        work = Path(work)
        work.chmod(0o755)
        chrome = subprocess.Popen([binary, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--disable-background-networking', '--disable-sync', '--window-size=1600,1100',
            '--user-data-dir=' + profile, 'about:blank'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp, gate, collision = None, None, None
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
            navigate('/server-manager/machine_form.cgi')
            wait('document.querySelector("#vm-create-form")?.dataset.softwareReady === "1" && window.cloudminSubmissionReady')
            name = 'cloudmin-create-check-retry-' + secrets.token_hex(4)
            evaluate('window.f=document.querySelector("#vm-create-form").elements; f.name.value=' + json.dumps(name) + '; f.cpus.value=1; f.memory_mib.value=512; f.memory_mib_units.value=1048576; f.start.value=0; f.autostart.value=0; f.password.value=' + json.dumps(secrets.token_urlsafe(32)) + '; f.password.dispatchEvent(new Event("change",{bubbles:true}))')
            token = evaluate('f.token.value')
            # Hold disk work so duplicate submits can be observed before
            # creation.
            gate = subprocess.Popen(['perl', str(here / 'submission-gate.pl'), str(work)], stdout=subprocess.DEVNULL)
            deadline = time.monotonic() + 10
            while not (work / 'locked').exists() and time.monotonic() < deadline:
                time.sleep(.1)
            assert (work / 'locked').exists(), 'Disk gate did not start'
            evaluate('document.querySelector("#vm-create-form").requestSubmit(document.querySelector("#vm-create-form [type=submit]")); document.querySelector("#vm-create-form").requestSubmit(document.querySelector("#vm-create-form [type=submit]"))')
            deadline = time.monotonic() + 30
            job = None
            while time.monotonic() < deadline:
                matches = [j for j in api('list') if j['name'] == name]
                if matches:
                    # Multiple matching jobs would mean the duplicate guard
                    # failed.
                    assert len(matches) == 1, 'Double-click created duplicate jobs'
                    job = matches[0]
                    break
                time.sleep(.25)
            assert job, 'Form did not submit a job: ' + str(evaluate('document.body.innerText.slice(-1200)'))
            fixture_jobs.append(job['id'])
            assert evaluate('sessionStorage.getItem(' + json.dumps('cloudmin-submission:' + token + ':create') + ')'), 'Shared submission handler was bypassed'
            # Simulate a genuine external conflict arising after validation.
            xml = work / 'collision.xml'
            xml.write_text('<domain type="kvm"><name>' + name + '</name><memory unit="MiB">64</memory><vcpu>1</vcpu><os><type>hvm</type></os></domain>')
            subprocess.run(['virsh', 'define', str(xml)], check=True, stdout=subprocess.DEVNULL)
            collision = name
            (work / 'release').touch()
            gate.wait(timeout=15)
            failed = wait_state(job['id'], 'failed')
            assert not failed.get('cleanup_pending'), failed.get('error')
            subprocess.run(['virsh', 'undefine', collision], check=True, stdout=subprocess.DEVNULL)
            collision = None
            # Restore the submitted form after removing the external conflict.
            wait('document.body.innerText.includes("failed")')
            evaluate('history.back()')
            wait('document.querySelector("#vm-create-form")?.dataset.softwareReady === "1"')
            assert evaluate('document.querySelector("#vm-create-form").elements.token.value') == token, 'Back did not restore the original form token'
            # Cached navigation may restore the HTML before the user's typed values.
            evaluate('window.f=document.querySelector("#vm-create-form").elements; f.name.value=' + json.dumps(name) + '; f.cpus.value=1; f.memory_mib.value=512; f.memory_mib_units.value=1048576; f.start.value=0; f.autostart.value=0; f.password.value=' + json.dumps(secrets.token_urlsafe(32)) + '; f.password.dispatchEvent(new Event("change",{bubbles:true})); document.querySelector("#vm-create-form").requestSubmit(document.querySelector("#vm-create-form [type=submit]"))')
            deadline = time.monotonic() + 40
            replacement = None
            while time.monotonic() < deadline:
                matches = [j for j in api('list') if j['name'] == name and j['id'] != job['id']]
                if matches:
                    # The retry must allocate exactly one replacement job.
                    assert len(matches) == 1
                    replacement = matches[0]
                    break
                time.sleep(.25)
            assert replacement, 'Back retry did not create a new job: ' + str(evaluate('document.body.innerText.slice(-1200)'))
            fixture_jobs.append(replacement['id'])
            ready = wait_state(replacement['id'], 'complete')
            assert api('status', {'job': job['id']})['state'] == 'failed', 'Retry rewrote failed history'
            print('PASS: double-click and Back retry after fixing a real creation failure', flush=True)
            # A hardware job also retries after its external configuration
            # conflict is fixed.
            navigate('/server-manager/edit_machine.cgi?id=' + ready['uuid'])
            wait('document.querySelector("#vm-edit-form") && window.cloudminSubmissionReady')
            original = subprocess.check_output(['virsh', 'dumpxml', ready['uuid'], '--inactive', '--security-info'], text=True)
            original_file = work / 'original.xml'
            original_file.write_text(original)
            changed_file = work / 'changed.xml'
            changed_file.write_text(original.replace('</name>', '</name><description>External fixture edit</description>', 1) if '<description>' not in original else re.sub(r'<description>.*?</description>', '<description>External fixture edit</description>', original, count=1, flags=re.S))
            # Gate the edit worker until a conflicting definition is in place.
            (work / 'locked').unlink()
            (work / 'release').unlink()
            gate = subprocess.Popen(['perl', str(here / 'submission-gate.pl'), str(work)], stdout=subprocess.DEVNULL)
            deadline = time.monotonic() + 10
            while not (work / 'locked').exists() and time.monotonic() < deadline:
                time.sleep(.1)
            assert (work / 'locked').exists()
            # Use the external Save button associated with the hardware form.
            evaluate('window.ed=document.querySelector("#vm-edit-form"); ed.elements.description.value="Retry fixture description"; ed.requestSubmit(document.querySelector(".ui_submit[form=vm-edit-form]"))')
            deadline = time.monotonic() + 30
            update = None
            while time.monotonic() < deadline:
                found = [j for j in api('list') if j['name'] == name and j['operation'] == 'update']
                if found:
                    # Capture the single original edit before changing the
                    # guest.
                    assert len(found) == 1
                    update = found[0]
                    break
                time.sleep(.25)
            assert update, 'Editor did not submit'
            subprocess.run(['virsh', 'define', str(changed_file)], check=True, stdout=subprocess.DEVNULL)
            (work / 'release').touch()
            gate.wait(timeout=15)
            failed_update = wait_state(update['id'], 'failed')
            assert not failed_update.get('cleanup_pending'), failed_update.get('error')
            subprocess.run(['virsh', 'define', str(original_file)], check=True, stdout=subprocess.DEVNULL)
            wait('document.body.innerText.includes("configuration changed")')
            evaluate('history.back()')
            # Revisit the form and retry with its external Save button.
            wait('document.querySelector("#vm-edit-form")')
            evaluate('window.ed=document.querySelector("#vm-edit-form"); ed.elements.description.value="Retry fixture description"; ed.requestSubmit(document.querySelector(".ui_submit[form=vm-edit-form]"))')
            deadline = time.monotonic() + 30
            new_update = None
            while time.monotonic() < deadline:
                found = [j for j in api('list') if j['name'] == name and j['operation'] == 'update' and j['id'] != update['id']]
                if found:
                    # The restored form must submit one new edit attempt.
                    assert len(found) == 1
                    new_update = found[0]
                    break
                time.sleep(.25)
            assert new_update, 'Editor Back retry did not submit'
            wait_state(new_update['id'], 'complete')
            assert api('status', {'job': update['id']})['state'] == 'failed'
            print('PASS: hardware edit retries after its configuration conflict is corrected', flush=True)
            # Image import failure is corrected at the source while its form is
            # restored.
            navigate('/server-manager/images.cgi')
            wait('document.querySelector("#cloudmin-image-form") && window.cloudminSubmissionReady')
            source = work / 'retry.qcow2'
            source.write_text('invalid disk image')
            source.chmod(0o644)
            evaluate('window.im=document.querySelector("#cloudmin-image-form"); im.elements.install_type.value="local"; im.elements.install_type.dispatchEvent(new Event("change",{bubbles:true})); im.elements.path.value=' + json.dumps(str(source)) + '; im.requestSubmit(im.querySelector("[type=submit]"))')
            wait('location.href.includes("setup_image.cgi") && document.body.innerText.includes("failed")')
            records = Path('/var/webmin/modules/server-manager/image-jobs')
            # imports() selects only image jobs for this fixture's source path.
            def imports():
                return [json.loads(p.read_text()) for p in records.glob('*.json') if json.loads(p.read_text()).get('path') == str(source)]
            previous = imports()
            fixture_images.extend(j['id'] for j in previous)
            assert len(previous) == 1 and previous[0]['state'] == 'failed'
            source.unlink()
            subprocess.run(['qemu-img', 'create', '-q', '-f', 'qcow2', str(source), '64M'], check=True)
            source.chmod(0o644)
            evaluate('history.back()')
            wait('document.querySelector("#cloudmin-image-form")')
            evaluate('window.im=document.querySelector("#cloudmin-image-form"); im.elements.install_type.value="local"; im.elements.install_type.dispatchEvent(new Event("change",{bubbles:true})); im.elements.path.value=' + json.dumps(str(source)) + '; im.requestSubmit(im.querySelector("[type=submit]"))')
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                found = imports()
                fixture_images[:] = list(set(fixture_images + [j['id'] for j in found]))
                if any(j['state'] == 'ready' for j in found):
                    # Stop once the corrected source has been imported
                    # successfully.
                    break
                time.sleep(.25)
            assert len(found) == 2 and any(j['state'] == 'ready' for j in found), [(j['state'], j.get('error')) for j in found]
            print('PASS: Back retry imports a corrected image and retains failed history', flush=True)
        finally:
            (work / 'release').touch()
            if gate and gate.poll() is None:
                # Release a waiting worker before removing fixture resources.
                gate.wait(timeout=15)
            if collision:
                # A failed assertion may leave the deliberate name conflict
                # behind.
                subprocess.run(['virsh', 'undefine', collision], check=True, stdout=subprocess.DEVNULL)
            # Close only the browser connection created by this fixture.
            if cdp:
                cdp.close()
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Bound teardown if this fixture browser stops responding.
                chrome.kill(); chrome.wait()


try:
    # Use a temporary administrator account for the real browser submissions.
    subprocess.run(['perl', str(helper), 'create', 'authentic-theme', user], input=password + '\n', text=True, check=True)
    created = True
    request('/session_login.cgi')
    request('/session_login.cgi', {'user': user, 'pass': password, 'page': '/server-manager/index.cgi'})
    browser_check()
finally:
    # Teardown is restricted to IDs recorded during this test run.
    for ident in reversed(fixture_jobs):
        subprocess.run(['perl', str(here / 'machine_fixture.pl'), 'cleanup', ident], check=True)
    for ident in fixture_images:
        subprocess.run(['perl', str(here / 'image-volume.pl'), 'cleanup', ident], check=True)
    if created:
        # Do not delete an account unless this fixture successfully created it.
        subprocess.run(['perl', str(helper), 'delete', 'authentic-theme', user], check=True)
