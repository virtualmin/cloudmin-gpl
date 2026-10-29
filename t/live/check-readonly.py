#!/usr/bin/python3
"""Check read-only pages, mutations and first-viewer status on a disposable host.

Requires an idle Cloudmin job queue. Existing job and size-cache directories are
moved aside for the fresh-store checks and restored in finally. Other browser
sessions must stay closed so they cannot restart the collector during the test.
"""
import hashlib
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import sqlite3
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

import libvirt
import websocket

# Run host-state isolation only on a privileged Linux test guest.
if os.uname().sysname != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Webmin Linux VM as root')
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(1)))
module = Path(__file__).resolve().parents[2]
helper = Path(__file__).with_name('webmin-user.pl')
data = Path('/var/webmin/modules/server-manager')
state_file = data / 'status-server.json'
base = 'https://127.0.0.1:10000'
users, sockets, moved = [], [], []
fixture = None
backup = None
conn = libvirt.open('qemu:///system')


class PageFields(HTMLParser):
    """Find action tokens in forms and JSON, including embedded row templates."""

    # __init__(self, html) collects fields from a response.
    def __init__(self, html):
        super().__init__()
        self.tokens = []
        self.embedded_tokens = []
        self.json_script = None
        self.feed(html)

    # json_tokens(value) walks JSON fields and HTML used by live page updates.
    @staticmethod
    def json_tokens(value):
        if isinstance(value, dict):
            # Tokens may be direct properties or nested inside configuration.
            return [v for k, v in value.items() if k == 'token'] + [
                token for v in value.values() for token in PageFields.json_tokens(v)]
        # Walk nested arrays as well as objects when finding embedded forms.
        if isinstance(value, list):
            return [token for v in value for token in PageFields.json_tokens(v)]
        if isinstance(value, str) and '<' in value:
            # Overview state templates contain escaped forms inside JSON strings.
            return PageFields(value).tokens
        return []

    # handle_starttag(self, tag, attrs) reads forms and decoded data attributes.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Include ordinary hidden form tokens in the submission checks.
        if tag == 'input' and attrs.get('name') == 'token':
            self.tokens.append(attrs.get('value', ''))
        for key, value in attrs.items():
            if key.startswith('data-') and value:
                # Non-JSON attributes carry labels, IDs and endpoints.
                if value.lstrip().startswith(('{', '[')):
                    found = self.json_tokens(json.loads(value))
                    self.embedded_tokens.extend(found)
                    self.tokens.extend(found)
                # A plain data-token attribute does not need JSON decoding.
                elif key == 'data-token':
                    self.embedded_tokens.append(value)
                    self.tokens.append(value)
        # Collect inert JSON scripts for a separate token scan.
        if tag == 'script' and attrs.get('type') == 'application/json':
            self.json_script = ''

    # handle_data(self, value) accumulates a JSON script without executing it.
    def handle_data(self, value):
        # Keep script fragments together until the closing tag arrives.
        if self.json_script is not None:
            self.json_script += value

    # handle_endtag(self, tag) checks complete JSON script contents.
    def handle_endtag(self, tag):
        # Inspect complete JSON so split text callbacks cannot hide tokens.
        if tag == 'script' and self.json_script is not None:
            found = self.json_tokens(json.loads(self.json_script))
            self.embedded_tokens.extend(found)
            self.tokens.extend(found)
            self.json_script = None


# login(name, mode) creates a temporary account; secrets stay in this process.
def login(name, mode):
    password = secrets.token_urlsafe(36)
    subprocess.run(['perl', str(helper), mode, 'gray-theme', name],
                   input=password + '\n', text=True, check=True)
    users.append(name)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))

    # page(path, [fields], [headers]) retains denied response bodies for checks.
    def page(path, fields=None, headers=None):
        body = urllib.parse.urlencode(fields).encode() if fields is not None else None
        request = urllib.request.Request(base + path, data=body,
            headers={'Referer': base + '/', **(headers or {})})
        try:
            response = opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            text = response.read().decode()
        assert 'Error - Perl execution failed' not in text, path + ' crashed'
        return text

    page('/session_login.cgi')
    page('/session_login.cgi', {'user': name, 'pass': password}, {'Cookie': 'testing=1'})
    return page, jar


# channel(page, jar, [delay]) connects through the authenticated miniserv proxy.
# A delay tests subscription after the collector has processed another tick.
def channel(page, jar, delay=0):
    result = json.loads(page('/server-manager/machine_status.cgi'))
    assert 'socket_url' in result, result.get('error', 'Missing status URL')
    sock = websocket.create_connection(result['socket_url'],
        cookie='; '.join(c.name + '=' + c.value for c in jar), origin=base,
        sslopt={'cert_reqs': ssl.CERT_NONE}, timeout=15)
    sockets.append(sock)
    time.sleep(delay)
    sock.send(json.dumps({'id': 'overview'}))
    while True:
        message = json.loads(sock.recv())
        assert message.get('type') != 'error', 'Status collection failed'
        # Wait for the initial inventory before testing later status changes.
        if message.get('full'):
            return sock, message


# stop_collector() stops only the process recorded as Cloudmin's collector.
def stop_collector():
    # There is no collector to stop if it has not published state.
    if not state_file.exists():
        return
    state = json.loads(state_file.read_text())
    process = Path('/proc') / str(state['pid']) / 'cmdline'
    # Verify process ownership before signalling a recorded PID.
    if process.exists():
        assert b'status-server.pl' in process.read_bytes(), 'Collector PID changed owner'
        os.kill(state['pid'], signal.SIGTERM)
    deadline = time.monotonic() + 15
    while state_file.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    assert not state_file.exists(), 'Collector did not remove its state'


# inventory() records configuration and power state without guest probes.
def inventory():
    return {
        'vms': {d.UUIDString(): (d.ID(), d.isActive(), d.autostart(), d.XMLDesc(),
            d.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)) for d in conn.listAllDomains()},
        'networks': {n.UUIDString(): (n.isActive(), n.autostart(), n.XMLDesc())
                     for n in conn.listAllNetworks()},
        'pools': {p.UUIDString(): (p.isActive(), p.autostart(), p.XMLDesc(),
            sorted(p.listVolumes()) if p.isActive() else []) for p in conn.listAllStoragePools()}}


# files() hashes task-relevant data, excluding the collector's own bookkeeping.
def files():
    roots = [data / name for name in ('image-jobs', 'image-sizes', 'vm-jobs')]
    roots.append(Path('/etc/webmin/server-manager'))
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for root in roots for p in root.rglob('*') if p.is_file()}


# balloon_period() treats libvirt's omitted stats element as disabled reporting.
def balloon_period():
    stats = ET.fromstring(fixture.XMLDesc()).find('./devices/memballoon/stats')
    return int(stats.get('period', '0')) if stats is not None else 0


try:
    # Refuse to hide state from active workers, even on a disposable test host.
    dbfile = data / 'vm-jobs/jobs.sqlite'
    # Refuse to isolate job state while real VM jobs are active.
    if dbfile.exists():
        with sqlite3.connect(f'file:{dbfile}?mode=ro', uri=True) as db:
            assert not db.execute("SELECT 1 FROM jobs WHERE state NOT IN "
                "('complete','failed','cancelled') LIMIT 1").fetchone(), 'VM jobs are active'
    for path in (data / 'image-jobs').glob('*.json'):
        job = json.loads(path.read_text())
        assert job['state'] in ('ready', 'failed', 'deleted', 'cancelled') or \
            time.time() - job.get('updated', 0) > 3700, 'Image jobs are active'
    stop_collector()
    backup = Path(tempfile.mkdtemp(prefix='cloudmin-readonly-stores-', dir='/var/tmp'))
    for name in ('image-jobs', 'image-sizes', 'vm-jobs'):
        path = data / name
        # Preserve existing host state; absent paths need no backup.
        if path.exists():
            path.rename(backup / name)
        moved.append(name)

    # A diskless paused guest tests live balloon setup without booting an OS.
    identity = str(uuid.uuid4())
    fixture = conn.defineXML(f"""<domain type='kvm'>
      <name>cloudmin-readonly-check-{identity}</name><uuid>{identity}</uuid>
      <memory unit='MiB'>128</memory><vcpu>1</vcpu><cpu mode='host-passthrough'/>
      <os firmware='efi'><type>hvm</type></os>
      <features><acpi/></features>
      <devices><memballoon model='virtio'><stats period='0'/></memballoon>
      <graphics type='vnc' autoport='yes' listen='127.0.0.1'/>
      <video><model type='virtio'/></video></devices>
      </domain>""")
    fixture.createWithFlags(libvirt.VIR_DOMAIN_START_PAUSED)
    readonly, rojar = login('cloudmin-ui-check', 'create-readonly')
    paths = ['index.cgi', 'images.cgi', 'image_form.cgi',
             'images.cgi?mode=catalogue', 'storage.cgi', 'storage.cgi?tab=volumes',
             'networks.cgi', 'jobs.cgi', 'machine_jobs.cgi', 'snapshots.cgi',
             'snapshots.cgi?id=' + identity, 'machine.cgi?id=' + identity]
    paths.extend('networks.cgi?tab=' + tab for tab in ('networks', 'bridges', 'interfaces'))
    paths.append('edit_catalog_image.cgi?' + urllib.parse.urlencode(
        {'key': 'almalinux-10:' + conn.getInfo()[0]}))
    for path in paths:
        html = readonly('/server-manager/' + path)
        assert 'file locking' not in html and 'not allowed to use' not in html, path
        assert not any(PageFields(html).tokens), path + ' issued a token'
        assert not re.search(r'<h[1-6]\b[^>]*>\s*Error\s*</h', html), path + ' returned an error page'
    # Force each polling response to rebuild its HTML, even with no bridge job.
    for tab in ('overview', 'networks', 'bridges', 'interfaces'):
        poll = json.loads(readonly('/server-manager/networks.cgi?' +
            urllib.parse.urlencode({'status': 1, 'previous': 'fixture', 'tab': tab})))
        assert 'html' in poll and 'remaining' in poll, 'Network poll did not rebuild HTML'
        assert not any(PageFields(poll['html']).tokens), 'Network poll issued a token'
        unchanged = json.loads(readonly('/server-manager/networks.cgi?' +
            urllib.parse.urlencode({'status': 1, 'previous': poll['state'], 'tab': tab})))
        assert 'html' not in unchanged, 'Unchanged network poll unnecessarily rebuilt HTML'
    estimate = json.loads(readonly('/server-manager/image-size.cgi?id=almalinux-10'))
    assert 'bytes' in estimate and estimate['checked'] == 0, 'Read-only size lookup started a probe'
    assert not any((data / name).exists() for name in moved), 'Read-only pages created a store'
    options = json.loads(readonly('/server-manager/api.cgi?action=options'))
    assert 'result' in options and 'token' not in options['result'], 'Read-only options failed or issued a token'
    for action in ('settings', 'snapshots', 'list'):
        reply = json.loads(readonly('/server-manager/api.cgi?' +
            urllib.parse.urlencode({'action': action, 'id': identity})))
        assert 'result' in reply, action + ': ' + reply.get('error', '')
    print('PASS: fresh-store pages and API reads work without tokens or data directories', flush=True)

    rosocket, initial = channel(readonly, rojar)
    assert identity in initial['changed'], 'Read-only viewer received no inventory'
    state = json.loads(state_file.read_text())
    readonly('/server-manager/machine_status.cgi')
    assert json.loads(state_file.read_text())['pid'] == state['pid'], 'Duplicate collector'
    assert balloon_period() == 0, 'Read-only viewer changed balloon reporting'
    rosocket.close()
    # Waiting happens inside this bounded live test; the caller can poll its log.
    deadline = time.monotonic() + 75
    route = f'websockets_/server-manager/ws-{state["port"]}='
    # END unlinks the state before taking miniserv's lock to remove the route.
    while (state_file.exists() or route in Path('/etc/webmin/miniserv.conf').read_text()) and time.monotonic() < deadline:
        time.sleep(1)
    assert not state_file.exists(), 'Idle collector retained state after 75 seconds'
    assert route not in Path('/etc/webmin/miniserv.conf').read_text(), 'Idle collector retained its proxy route'
    print('PASS: read-only first viewer writes state, reuses collector and cleans up after idle timeout', flush=True)

    # Keep both roles connected, then verify that page loads do not recover work.
    rosocket, _ = channel(readonly, rojar)
    admin, adminjar = login('cloudmin-frame-check', 'create')
    token = json.loads(admin('/server-manager/api.cgi?action=options'))['result']['token']
    # A writer's live row templates prove the scanner can detect embedded tokens.
    assert any(re.fullmatch(r'\d+\.[a-f0-9]{64}\.[a-f0-9]{64}', value or '')
               for value in PageFields(admin('/server-manager/index.cgi')).embedded_tokens), \
        'Token scanner missed the writer\'s embedded action forms'
    adminsocket, _ = channel(admin, adminjar, delay=1)
    deadline = time.monotonic() + 10
    while balloon_period() != 10:
        assert time.monotonic() < deadline, 'Writable viewer no longer enables reporting'
        time.sleep(0.2)
    (data / 'vm-jobs').mkdir(exist_ok=True)
    jobid = secrets.token_hex(16)
    record = {'id': jobid, 'owner': 'cloudmin-ui-check', 'state': 'queued',
        'created': int(time.time()), 'updated': int(time.time()), 'resources': {},
        'events': [], 'request': {'operation': 'readonly_fixture', 'name': 'Read-only fixture', 'uuid': identity}}
    with sqlite3.connect(dbfile) as db:
        db.execute('CREATE TABLE jobs (id TEXT PRIMARY KEY, owner TEXT, resource TEXT, state TEXT, created INTEGER, updated INTEGER, record TEXT)')
        db.execute('INSERT INTO jobs VALUES (?, ?, ?, ?, ?, ?, ?)',
            (jobid, record['owner'], 'guest:' + identity, record['state'],
             record['created'], record['updated'], json.dumps(record)))
        complete_id = secrets.token_hex(16)
        complete = {**record, 'id': complete_id, 'state': 'complete',
                    'request': {**record['request'], 'operation': 'update'}}
        db.execute('INSERT INTO jobs VALUES (?, ?, ?, ?, ?, ?, ?)',
            (complete_id, complete['owner'], 'guest:' + identity, 'complete',
             complete['created'], complete['updated'], json.dumps(complete)))
    image_id = secrets.token_hex(16)
    image = {'id': image_id, 'owner': 'cloudmin-ui-check', 'state': 'failed',
             'created': int(time.time()), 'updated': int(time.time()),
             'name': 'Read-only image fixture', 'source': 'upload', 'format': 'iso',
             'pool_name': 'fixture', 'error': 'Fixture import failed'}
    (data / 'image-jobs' / (image_id + '.json')).write_text(json.dumps(image))
    before_files, before_inventory = files(), inventory()
    for path in paths:
        assert not any(PageFields(readonly('/server-manager/' + path)).tokens), \
            path + ' issued a token with an administrator connected'
    status = json.loads(readonly('/server-manager/api.cgi?action=status&job=' + jobid))
    assert status['result']['state'] == 'queued', 'Read-only page recovered a job'
    image_status = json.loads(readonly('/server-manager/image-status.cgi?job=' + image_id))
    assert image_status['state'] == 'failed', 'Read-only image status is unavailable'
    progress = readonly('/server-manager/setup_image.cgi?job=' + image_id)
    assert image['error'] in progress, 'Read-only image progress is unavailable'
    progress = readonly('/server-manager/progress.cgi?job=' + complete_id)
    assert 'edit_machine.cgi?' not in progress, 'Read-only progress offers the editor'
    assert 'machine.cgi?id=' + identity in progress, 'Read-only progress lacks the details link'
    assert files() == before_files, 'Read-only page changed job or catalogue files'

    # Every mutation is denied with both an absent token and a writer's token.
    actions = ('review create cancel recover discard start shutdown reboot suspend resume reset force_off reset_password autostart '
        'power_cycle update delete delete_disk grow_disk add_disk attach_disk detach_disk add_interface '
        'update_interface remove_interface change_media snapshot_create snapshot_restore snapshot_delete').split()
    endpoints = {
        'api.cgi': actions,
        'index.cgi': 'start shutdown reboot suspend resume autostart'.split(),
        'machine.cgi': 'start shutdown reboot suspend resume reset force_off power_cycle'.split(),
        'edit_machine.cgi': 'update delete delete_disk start shutdown reset_password'.split(),
        'setup_machine.cgi': ['create'], 'clone_machine.cgi': ['clone'], 'machine_jobs.cgi': 'cancel recover discard'.split(),
        'snapshots.cgi': 'snapshot_create snapshot_restore snapshot_delete'.split(),
        'catalogue.cgi': 'enable disable delete'.split(), 'save_catalog_image.cgi': ['save'],
        'image.cgi': ['create'], 'setup_image.cgi': ['create'],
        'delete_images.cgi': ['delete'], 'image-upload.cgi': ['upload'],
        'networks.cgi': 'bridge_review delete_review create bridge confirm rollback start stop delete autostart'.split(),
        'storage.cgi': 'create start stop delete autostart review_volumes delete_volumes'.split(),
        'console-connect.cgi': ['connect'], 'remote_access.cgi': ['connect']}
    count = 0
    for value in ('', token):
        for endpoint, choices in endpoints.items():
            for action in choices:
                fields = {'action': action, 'vm_operation': action, 'id': identity, 'job': jobid, 'token': value,
                          'install_type': 'upload', 'confirm': '1', 'enabled': '1'}
                reply = readonly('/server-manager/' + endpoint, fields,
                                 {'X-Cloudmin-Token': value})
                assert 'read-only' in reply, endpoint + ':' + action + ' lacks read-only refusal'
                count += 1
    # Opening an interactive page must fail even without submitting an action.
    for endpoint in ('remote_access.cgi', 'edit_machine.cgi', 'machine_form.cgi'):
        assert 'read-only' in readonly('/server-manager/' + endpoint + '?id=' + identity), endpoint
    assert 'read-only' in readonly('/server-manager/edit_catalog_image.cgi?new=1'), \
        'Read-only user can open the new catalogue entry form'
    assert inventory() == before_inventory, 'Denied request changed libvirt state'
    assert files() == before_files, 'Denied request changed files or job rows'
    print(f'PASS: {count} denied mutations, simultaneous sessions, no recovery or data changes', flush=True)
    # Exercise WebSocket authorization after the no-mutation assertions above.
    from readonly_relays import check_relays
    check_relays(module, identity, login, rojar)
finally:
    # A collector or libvirt cleanup failure must not prevent store restoration.
    try:
        for sock in sockets:
            sock.close()
        # Stop any collector started against the temporary state before
        # restoring it.
        if backup is not None:
            stop_collector()
    finally:
        try:
            # Remove the fixture guest only if definition succeeded.
            if fixture is not None:
                # Stop the disposable guest before undefining it.
                if fixture.isActive():
                    fixture.destroy()
                fixture.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
        finally:
            try:
                for name in moved:
                    shutil.rmtree(data / name, ignore_errors=True)
                    # Restore only paths that existed before this test.
                    if (backup / name).exists():
                        (backup / name).rename(data / name)
                # Remove the now-empty backup directory after restoration.
                if backup is not None:
                    backup.rmdir()
            finally:
                for name in users:
                    subprocess.run(['perl', str(helper), 'delete', '', name], check=True)
                conn.close()
