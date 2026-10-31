#!/usr/bin/python3
"""Check Create and Clone stream progress before their disk work can finish."""
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

# This fixture creates host accounts and VMs only on the Linux test machine.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
base = 'https://127.0.0.1:10000'
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
prefix = 'cloudmin-stream-check-' + secrets.token_hex(4)
password = secrets.token_urlsafe(36)
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
created = False


class Form(HTMLParser):
    # __init__(self, html, ident) captures the requested form's submission URL.
    def __init__(self, html, ident):
        super().__init__()
        self.ident, self.action, self.shadows_action = ident, None, False
        self.feed(html)

    # handle_starttag(self, tag, attrs) finds the URL and action-shadowing inputs.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'form' and attrs.get('id') == self.ident:
            # Unrelated forms must not replace the requested submission URL.
            self.action = attrs.get('action')
        if tag == 'input' and attrs.get('name') == 'action':
            # A named action input hides form.action from the theme's JavaScript.
            self.shadows_action = True


# request(path, [fields], [stream]) uses only this fixture's local Webmin login.
def request(path, fields=None, stream=False):
    headers = {'Referer': base + '/server-manager/machine_form.cgi',
               'X-Requested-With': 'XMLHttpRequest'}
    data = None if fields is None else urllib.parse.urlencode(fields).encode()
    response = opener.open(urllib.request.Request(base + path, data=data, headers=headers), timeout=15)
    if stream:
        # Leave the response open so the test can inspect the first arriving bytes.
        return response
    with response:
        return response.read().decode()


# api(action, [fields]) retains the production ACL and token checks.
def api(action, fields=None):
    result = json.loads(request('/server-manager/api.cgi' +
        ('?action=' + action if fields is None else ''),
        None if fields is None else dict(fields, action=action)))
    assert 'result' in result, result.get('error', 'Missing API result')
    return result['result']


# wait_job(id) bounds fixture work and preserves its useful failure message.
def wait_job(ident):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        job = api('status', {'job': ident})
        if job['state'] in ('complete', 'failed', 'cancelled'):
            # Let callers assert the expected outcome after polling stops.
            return job
        time.sleep(.25)
    raise RuntimeError('Fixture job did not finish')


# submit(page, ident, fields) holds disk work until HTTP progress has arrived.
def submit(page, ident, fields):
    form = Form(request(page), ident)
    assert form.action == ('clone_machine.cgi' if ident == 'vm-clone-form' else 'setup_machine.cgi'), 'Form does not select theme streaming'
    assert not form.shadows_action, 'A named control hides the form URL from the theme'
    with tempfile.TemporaryDirectory(prefix='cloudmin-retry-', dir='/tmp') as directory:
        # Hold the disk-work lock to prove progress precedes worker completion.
        gate = Path(directory)
        holder = subprocess.Popen(['perl', str(module / 't/live/submission-gate.pl'), directory],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        response = None
        try:
            deadline = time.monotonic() + 10
            while not (gate / 'locked').exists():
                assert holder.poll() is None, 'Disk queue fixture failed'
                assert time.monotonic() < deadline, 'Disk queue fixture did not lock'
                time.sleep(.1)
            started = time.monotonic()
            # Read one chunk instead of waiting for the streamed page to close.
            response = request('/server-manager/' + form.action, fields, stream=True)
            first = response.read1(65536)
            assert first and time.monotonic() - started < 10, 'Progress waited for disk work'
            assert response.geturl().endswith(form.action), 'Submission redirected into buffered progress'
            job = next(j for j in api('list') if j['name'] == fields['name'])
            assert job['state'] == 'queued', 'Fixture finished before the streaming assertion'
            print('PASS: ' + fields['vm_operation'] + ' returned progress while disk work was blocked', flush=True)
        finally:
            # Release the queued worker even when the streaming assertion fails.
            (gate / 'release').touch()
            if response:
                # Close only a response that successfully opened.
                response.close()
            holder.communicate(timeout=10)
            assert holder.returncode == 0, 'Disk queue fixture failed'
    job = wait_job(job['id'])
    assert job['state'] == 'complete', job.get('error')
    return job


try:
    subprocess.run(['perl', str(helper), 'create', 'authentic-theme', user],
                   input=password + '\n', text=True, check=True, capture_output=True)
    created = True
    opener.addheaders = [('Cookie', 'testing=1')]
    request('/session_login.cgi', {'user': user, 'pass': password})
    opener.addheaders = []
    options = api('options')
    # Reuse an existing verified image; this test does not change the catalogue.
    image = next(i for i in options['images'] if i.get('architecture') ==
                 options['capabilities']['architecture'] and i.get('cloud_init'))
    pool = next(p for p in options['pools'] if p['id'] == image['pool'])
    token = options['token']
    fields = dict(vm_operation='create', token=token, attempt=secrets.token_hex(16),
        name=prefix, image=image['id'], install_source='cloud', pool=pool['id'],
        network=options['networks'][0]['key'], cpus=1, memory_mib=512,
        disk_gib=20, username='cloudmin', auth_type='password',
        password=secrets.token_urlsafe(32), start=1, autostart=0)
    source = submit('/server-manager/machine_form.cgi', 'vm-create-form', fields)
    # A first boot creates UEFI variables; stop only our disposable source.
    api('force_off', {'id': source['uuid'], 'token': token, 'confirm': 1})
    choices = api('clone_options', {'id': source['uuid']})
    submit('/server-manager/clone_machine_form.cgi?id=' + source['uuid'], 'vm-clone-form',
        dict(vm_operation='clone', token=token, attempt=secrets.token_hex(16),
             id=source['uuid'], revision=choices['revision'], name=prefix + '-copy',
             clone_mode='unchanged', confirm_unchanged=1, start=0, autostart=0,
             pool=pool['id'], nvram_mode='fresh'))
    # An invalid token must never start work through the new submission path.
    body = request('/server-manager/setup_machine.cgi', dict(fields, token='invalid'))
    assert 'expired' in body.lower(), 'Invalid token was not rejected'
    body = request('/server-manager/setup_machine.cgi?vm_operation=create')
    assert 'Use POST' in body, 'GET submitted a creation job'
    print('PASS: submitted jobs completed; invalid token and GET mutations were rejected', flush=True)
finally:
    if created:
        # Recover only this run's jobs if a request failed after submission.
        owned = [j for j in api('list') if j['name'] in (prefix, prefix + '-copy')]
        for job in reversed(owned):
            if job['state'] not in ('complete', 'failed', 'cancelled'):
                # Cancel unfinished fixture work before attempting guest deletion.
                api('cancel', {'job': job['id'], 'token': api('options')['token']})
                wait_job(job['id'])
        # Delete fixture guests through the normal journalled operation.
        for vm in api('options')['domains']:
            if vm['name'] in (prefix, prefix + '-copy'):
                # Match exact generated names to avoid touching existing machines.
                if vm['active']:
                    # Only this fixture's guests may be forced off for cleanup.
                    api('force_off', {'id': vm['uuid'], 'token': api('options')['token'], 'confirm': 1})
                settings = api('settings', {'id': vm['uuid']})
                deleted = api('delete', {'id': vm['uuid'], 'token': api('options')['token'],
                                        'revision': settings['revision'], 'confirm_name': vm['name'],
                                        'disks': ','.join(d['target'] for d in settings['disks']
                                                         if d.get('volume_info') and not d.get('imported')),
                                        'attempt': secrets.token_hex(16)})
                result = wait_job(deleted['id'])
                assert result['state'] == 'complete', result.get('error')
        subprocess.run(['perl', str(helper), 'delete', '', user], check=True, capture_output=True)
