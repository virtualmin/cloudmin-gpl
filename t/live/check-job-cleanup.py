#!/usr/bin/python3
"""Verify direct job controls with a tiny owned guest on an authorized test host."""
from contextlib import ExitStack
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from job_actions_browser import job_actions_browser

assert os.geteuid() == 0 and os.uname().sysname == 'Linux'
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/job-cleanup-fixture.pl'
user_helper = module / 't/live/webmin-user.pl'
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
name = 'cloudmin-cleanup-check-' + secrets.token_hex(4)
id = secrets.token_hex(16)
guest = str(uuid.uuid4())
base = 'https://127.0.0.1:10000'
cookies = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(cookies),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))


def run(*args, **kwargs):
    """run(*args, **kwargs) limits runtime and captures fixture output."""
    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=60, **kwargs)


def request(path, fields=None):
    """request(path, [fields]) sends GET or POST and retains error pages."""
    body = urllib.parse.urlencode(fields).encode() if fields is not None else None
    req = urllib.request.Request(base + path, data=body, headers={'Referer': base + '/server-manager/jobs.cgi'})
    try:
        response = opener.open(req, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        page = response.read().decode()
    assert 'Error - Perl execution failed' not in page, 'CGI crashed'
    return page


class Inputs(HTMLParser):
    """Read only the fixture's selected action form, leaving other jobs alone."""
    def __init__(self, page, action):
        """__init__(self, page, action) selects this job's action form."""
        super().__init__()
        self.fields = {}
        self.current = None
        self.action = action
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        """handle_starttag(self, tag, attrs) collects form inputs."""
        attrs = dict(attrs)
        # Reset at every form so another job cannot supply this job's fields.
        if tag == 'form':
            self.current = {}
        # Only named controls inside the current form are submitted values.
        if tag == 'input' and attrs.get('name') and self.current is not None:
            self.current[attrs['name']] = attrs.get('value', '')

    def handle_endtag(self, tag):
        """handle_endtag(self, tag) retains this job's matching form."""
        # Wait for a complete form before comparing its hidden action fields.
        if tag == 'form' and self.current is not None:
            # Ignore controls belonging to real jobs on the same page.
            if self.current.get('job') == id and self.current.get('action') == self.action:
                self.fields = self.current
            self.current = None


def fixture(action, **fields):
    """fixture(action, **fields) sends this job's ID and action parameters."""
    return run('perl', str(helper), action, input=json.dumps({'id': id, **fields})).stdout


account = journal = defined = False
shared = None
volumes = []
before = set(run('virsh', 'list', '--uuid').stdout.split())
browser = ExitStack()
try:
    # Create a temporary login without changing an administrator's credentials.
    password = secrets.token_urlsafe(36)
    run('perl', str(user_helper), 'create', 'authentic-theme', user, input=password + '\n')
    account = True
    time.sleep(1)
    request('/session_login.cgi')
    request('/session_login.cgi', {'user': user, 'pass': password, 'page': '/server-manager/jobs.cgi'})
    # Keep one owned disk and one extra disk to test deletion boundaries.
    pool = run('virsh', 'pool-uuid', 'default').stdout.strip()
    disk = name + '.qcow2'
    unrelated = name + '-unrelated.qcow2'
    for volume in (disk, unrelated):
        run('virsh', 'vol-create-as', 'default', volume, '64M', '--format', 'qcow2')
        volumes.append(volume)
    path = run('virsh', 'vol-path', '--pool', 'default', disk).stdout.strip()
    key = run('virsh', 'vol-key', '--pool', 'default', disk).stdout.strip()
    arch = os.uname().machine
    machine = 'virt' if arch == 'aarch64' else 'q35'
    # Boot an empty fixture with the ownership marker used by real creation.
    xml = f'''<domain type="kvm"><name>{name}</name><uuid>{guest}</uuid>
      <memory unit="MiB">256</memory><vcpu>1</vcpu><cpu mode="host-passthrough"/>
      <metadata><cloudmin:vm xmlns:cloudmin="urn:cloudmin:vm:1"><cloudmin:job>{id}</cloudmin:job></cloudmin:vm></metadata>
      <os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type></os><features><acpi/></features>
      <devices><disk type="file" device="disk"><driver name="qemu" type="qcow2"/>
      <source file="{path}"/><target dev="vda" bus="virtio"/></disk></devices></domain>'''
    run('virsh', 'define', '/dev/stdin', input=xml)
    defined = True
    run('virsh', 'start', guest)
    fixture('create', name=name, uuid=guest, pool=pool, disk=disk, key=key)
    journal = True
    # GET and forged POST requests must leave the running fixture untouched.
    page = request('/server-manager/jobs.cgi')
    assert 'Cancel and clean up' in page and name in page, 'Active Jobs has no cleanup control'
    query = urllib.parse.urlencode({'type': 'vm', 'job': id, 'action': 'cancel_cleanup'})
    denied = request('/server-manager/jobs.cgi?' + query)
    assert 'Use POST for job changes' in denied
    fields = Inputs(page, 'cancel_cleanup').fields
    assert fields.get('confirm') == '1' and fields.get('job') == id
    assert json.loads(fixture('status'))['state'] == 'running', 'GET changed the job'
    denied = request('/server-manager/jobs.cgi', {**fields, 'token': 'invalid'})
    assert 'This form has expired' in denied
    assert json.loads(fixture('status'))['state'] == 'running', 'Bad token changed the job'
    # Opening the page and letting it refresh must not submit an action.
    click = browser.enter_context(job_actions_browser(cookies, id))
    assert json.loads(fixture('status'))['state'] == 'running', 'Navigation changed the job'
    # Persistent disk changes must prevent removal entirely.
    extra = run('virsh', 'vol-path', '--pool', 'default', unrelated).stdout.strip()
    run('virsh', 'attach-disk', guest, extra, 'vdb', '--config', '--subdriver', 'qcow2')
    click('cancel_cleanup')
    for _ in range(150):
        status = json.loads(fixture('status'))
        if status['state'] == 'failed':
            # Inspect the failure after the worker records it.
            break
        time.sleep(.2)
    assert status['state'] == 'failed' and status['cleanup_pending'], status.get('error')
    assert 'disks changed' in status['error'], status['error']
    assert guest in run('virsh', 'list', '--uuid').stdout.split(), 'Refused cleanup stopped the guest'
    run('virsh', 'detach-disk', guest, 'vdb', '--config')
    # Another guest adopting this disk must block cleanup before power-off.
    shared = str(uuid.uuid4())
    run('virsh', 'define', '/dev/stdin', input=xml.replace('<name>' + name + '</name>', '<name>' + name + '-shared</name>').replace(guest, shared))
    click('recover')
    for _ in range(150):
        status = json.loads(fixture('status'))
        # Continue once the worker records its expected shared-disk refusal.
        if status['state'] == 'failed':
            break
        time.sleep(.2)
    assert status['state'] == 'failed' and status['cleanup_pending'], status.get('error')
    assert guest in run('virsh', 'list', '--uuid').stdout.split(), 'Shared-disk refusal stopped the guest'
    assert shared in run('virsh', 'list', '--all', '--uuid').stdout.split(), 'Shared guest was removed'
    run('virsh', 'undefine', shared, '--nvram')
    shared = None
    # With both conflicts removed, recovery may delete only the owned guest.
    click('recover')
    for _ in range(150):
        status = json.loads(fixture('status'))
        # Require both a terminal state and completed cleanup before inspecting
        # resources.
        if status['state'] in ('cancelled', 'failed') and not status['cleanup_pending']:
            break
        time.sleep(.2)
    assert status['state'] == 'cancelled' and not status['cleanup_pending'], status.get('error')
    assert guest not in run('virsh', 'list', '--all', '--uuid').stdout.split()
    assert not Path(path).exists(), 'Owned disk remains'
    assert not status['vm_created'], 'Deleted guest still exposed as created'
    assert Path(extra).exists(), 'Unrelated volume was deleted'
    assert before == set(run('virsh', 'list', '--uuid').stdout.split()), 'Other running guests changed'
    replay = request('/server-manager/jobs.cgi', fields)
    assert 'already finished' in replay
    print('Active Jobs browser clicks, GET/token rejection, changed/shared-disk refusal, retry and owned cleanup passed')
finally:
    browser.close()
    # Drop the fixture's extra reference before asking guarded cleanup to run.
    if shared:
        run('virsh', 'undefine', shared, '--nvram')
    if journal:
        # The helper checks ownership and refuses to race an active worker.
        fixture('forget')
    elif defined:
        # Submission never made a journal; clean the directly defined fixture.
        subprocess.run(['virsh', 'destroy', guest], capture_output=True)
        subprocess.run(['virsh', 'undefine', guest, '--nvram'], capture_output=True)
    for volume in volumes:
        subprocess.run(['virsh', 'vol-delete', '--pool', 'default', volume], capture_output=True)
    if account:
        # Remove the temporary Webmin account even when a scenario failed.
        run('perl', str(user_helper), 'delete', 'authentic-theme', user)
