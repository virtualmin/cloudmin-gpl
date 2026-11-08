#!/usr/bin/python3
"""Test VM assignments and permissions through Webmin on a disposable host."""

import hashlib
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import secrets
import signal
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import libvirt
import websocket

# This test creates users and guests; never run it on the
# development workstation.
if os.uname().sysname != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
base = 'https://127.0.0.1:10000'
helper = Path(__file__).with_name('webmin-user.pl')
module = helper.parents[2]
conn = libvirt.open('qemu:///system')
users, guests, sockets = [], [], []
editor = None
# Keep a pre-existing browser fixture account untouched.
readonly_user = 'cloudmin-spa-check-' + secrets.token_hex(4)


class ACLForm(HTMLParser):
    """Read the Webmin Users form and its checkbox assignment list."""

    # __init__(self, html) collects fields to submit and all available
    # VM choices.
    def __init__(self, html):
        super().__init__()
        self.active = False
        self.fields = []
        self.vms = set()
        self.feed(html)

    # handle_starttag(self, tag, attrs) reads only the module permissions form.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Ignore search, navigation and other forms on the Users page.
        if tag == 'form':
            self.active = attrs.get('action', '').endswith('save_acl.cgi')
        # Ignore inputs outside the ACL editor form.
        if not self.active:
            return
        # Choices include unselected guests outside the editing user's scope.
        if tag == 'input' and attrs.get('name') == 'vms_item':
            self.vms.add(attrs.get('value', ''))
        # Keep hidden fields and selected radio buttons and checkboxes.
        if tag == 'input' and attrs.get('name'):
            # Browsers omit unchecked controls from form submissions.
            if (
                attrs.get('type') in ('radio', 'checkbox')
                and 'checked' not in attrs
            ):
                return
            # Exclude other buttons so they cannot change the save action.
            if attrs.get('type') not in ('submit', 'reset', 'button'):
                self.fields.append((attrs['name'], attrs.get('value', '')))

    # handle_endtag(self, tag) stops collecting fields at the form boundary.
    def handle_endtag(self, tag):
        # A later form must not append fields to the ACL submission.
        if tag == 'form':
            self.active = False


# expired(signum, frame) interrupts hung tests so the finally block can
# clean up.
def expired(*_):
    raise TimeoutError('ACL live check timed out')


# Timeouts and SIGTERM both run the cleanup block below.
signal.signal(signal.SIGALRM, expired)
signal.signal(signal.SIGTERM, expired)
signal.alarm(300)


# account(name, [mode]) creates a local login; the plaintext password stays in
# RAM. mode defaults to create; helper modes also provide read-only and editor
# users. Returns a page request function and the account's cookie jar.
def account(name, mode='create'):
    password = secrets.token_urlsafe(36)
    subprocess.run(
        ['perl', str(helper), mode, 'gray-theme', name],
        input=password + '\n',
        text=True,
        check=True,
    )
    users.append(name)
    # Keep each role's cookies separate and accept the local test certificate.
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )

    # page(path, [fields], [headers]) returns normal and denied response bodies.
    # Omitted fields use GET; supplied fields use POST. headers defaults
    # to none.
    def page(path, fields=None, headers=None):
        request = urllib.request.Request(
            base + path,
            data=urllib.parse.urlencode(fields).encode()
            if fields is not None
            else None,
            headers={'Referer': base + '/', **(headers or {})},
        )
        try:
            response = opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            # Return HTTP error bodies so tests can check permission refusals.
            response = error
        with response:
            body = response.read().decode()
        assert 'Error - Perl execution failed' not in body, path + ' crashed'
        return body

    # Log in through miniserv without printing or saving the plaintext password.
    page(
        '/session_login.cgi',
        {'user': name, 'pass': password},
        {'Cookie': 'testing=1'},
    )
    return page, jar


# permissions(name, values) submits the real editor for the delegated account.
# Uses the local helper for other roles or before the editor session exists.
def permissions(name, values):
    # Keep Webmin's hidden fields while replacing Cloudmin's grants and
    # VM choices.
    if name == 'cloudmin-ui-check' and editor is not None:
        form = ACLForm(
            editor('/acl/edit_acl.cgi?mod=server-manager&user=' + name)
        )
        assert ('_acl_user', name) in form.fields, (
            'Webmin ACL editor did not open'
        )
        editable = ('admin', 'vms', 'power', 'force', 'console', 'terminal')
        fields = [
            (key, value) for key, value in form.fields if key not in editable
        ]
        fields.extend(
            (key, values.get(key, 0)) for key in editable if key != 'vms'
        )
        fields.append(('vms', '\n'.join(values.get('vms', '').split())))
        # Cloudmin must derive noconfig from the role, even with a forged field.
        fields.append(('noconfig', '0'))
        editor('/acl/save_acl.cgi', fields)
        # Check the saved ACL; an HTTP success alone does not prove it
        # was saved.
        saved = Path('/etc/webmin/server-manager/' + name + '.acl').read_text()
        actual = dict(
            line.split('=', 1) for line in saved.splitlines() if '=' in line
        )
        expected = {
            key: str(values.get(key, 0)) for key in editable if key != 'vms'
        }
        expected['vms'] = ' '.join(
            sorted(set(values.get('vms', '').lower().split()))
        )
        expected['noconfig'] = '0' if values.get('admin') == 1 else '1'
        actual['vms'] = ' '.join(sorted(actual.get('vms', '').split()))
        assert all(
            actual.get(key) == value for key, value in expected.items()
        ), 'Editor saved incorrect permissions'
        return
    # Set up or restore accounts that the restricted editor cannot change.
    subprocess.run(
        ['perl', str(helper), 'acl', '', name],
        input=json.dumps(values),
        text=True,
        check=True,
    )


# api(page, action, [fields]) sends a JSON API request without logging its
# token. Omit fields when the action needs no other parameters.
def api(page, action, fields=None):
    return json.loads(
        page('/server-manager/api.cgi', {'action': action, **(fields or {})})
    )


# socket_for(url, jar) connects through miniserv using the fixture's
# own session.
def socket_for(url, jar):
    sock = websocket.create_connection(
        url,
        cookie='; '.join(c.name + '=' + c.value for c in jar),
        origin=base,
        sslopt={'cert_reqs': ssl.CERT_NONE},
        timeout=20,
    )
    sockets.append(sock)
    return sock


# closed(sock) accepts either a WebSocket close frame or a closed TCP transport.
def closed(sock):
    try:
        return not sock.recv()
    except websocket.WebSocketConnectionClosedException:
        # A revoked transport may close before a WebSocket close frame arrives.
        return True


# status(page, jar, [identity]) requests an authenticated filtered snapshot.
# identity defaults to overview; a UUID requests details for that guest.
def status(page, jar, identity='overview'):
    result = json.loads(page('/server-manager/machine_status.cgi'))
    assert 'socket_url' in result, result.get('error')
    sock = socket_for(result['socket_url'], jar)
    sock.send(json.dumps({'id': identity}))
    return sock


# receive(sock, kind) waits for a message of the requested type,
# ignoring others.
def receive(sock, kind):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        sock.settimeout(max(0.1, deadline - time.monotonic()))
        value = sock.recv()
        assert value, 'Status socket closed before expected message'
        message = json.loads(value)
        assert message.get('type') != 'error', 'Status collector failed'
        # Skip unrelated updates and heartbeats until the expected
        # message arrives.
        if message.get('type') == kind:
            return message
    raise AssertionError('Missing ' + kind)


# state() captures domain identity and persistent state before denied requests.
def state():
    return {
        d.UUIDString(): (
            d.ID(),
            d.autostart(),
            d.XMLDesc(),
            d.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE),
        )
        for d in conn.listAllDomains()
    }


# stores() hashes job and size-cache files to detect changes after
# denied requests.
def stores():
    roots = [
        Path('/var/webmin/modules/server-manager') / n
        for n in ('vm-jobs', 'image-jobs', 'image-sizes')
    ]
    return {
        str(p): hashlib.sha256(p.read_bytes()).hexdigest()
        for root in roots
        for p in root.rglob('*')
        if p.is_file()
    }


try:
    # Two guests let the test detect access beyond the assigned VM.
    for _ in range(2):
        identity = str(uuid.uuid4())
        guest = conn.defineXML(f'''<domain type="kvm"><name>cloudmin-acl-{identity}</name>
          <uuid>{identity}</uuid><memory unit="MiB">256</memory><vcpu>1</vcpu>
          <cpu mode="host-passthrough"/><os firmware="efi"><type>hvm</type></os>
          <features><acpi/></features>
          <devices><graphics type="vnc" autoport="yes" listen="127.0.0.1"/>
          <video><model type="virtio"/></video>
          <memballoon model="virtio"><stats period="10"/></memballoon></devices></domain>''')
        guests.append(guest)
        guest.createWithFlags(libvirt.VIR_DOMAIN_START_PAUSED)
    own, foreign = [g.UUIDString() for g in guests]
    # Keep administrator, delegated and read-only sessions open together.
    admin, adminjar = account('cloudmin-frame-check', 'create-editor')
    page, jar = account('cloudmin-ui-check')
    readonly, rojar = account(readonly_user, 'create-readonly')
    viewer = {'admin': 0, 'vms': own}
    # ACL editors may assign guests they cannot access through
    # Cloudmin themselves.
    permissions('cloudmin-frame-check', viewer)
    editor = admin
    html = admin('/server-manager/index.cgi')
    assert guests[0].name() in html and guests[1].name() not in html, (
        'Editor VM scope was bypassed outside Users'
    )
    form = ACLForm(
        editor('/acl/edit_acl.cgi?mod=server-manager&user=cloudmin-ui-check')
    )
    assert {own, foreign} <= form.vms, (
        'Assignment picker hides guests outside the editor scope'
    )
    # Submit joined, mixed-case UUIDs; check they reload as unique
    # lowercase IDs.
    permissions(
        'cloudmin-ui-check',
        {
            'admin': 0,
            'vms': own.upper() + ' ' + foreign + ' ' + own,
            'power': 1,
            'console': 1,
        },
    )
    form = ACLForm(
        editor('/acl/edit_acl.cgi?mod=server-manager&user=cloudmin-ui-check')
    )
    assert {
        identity
        for key, value in form.fields
        if key == 'vms'
        for identity in value.split()
    } == {own, foreign}, 'Saved VM selection did not reload'
    for grant, value in {
        'admin': '0',
        'power': '1',
        'force': '0',
        'console': '1',
        'terminal': '0',
    }.items():
        assert (grant, value) in form.fields, (
            'Saved permission did not reload: ' + grant
        )
    # Invalid assignments must leave the previously saved ACL untouched.
    saved = Path(
        '/etc/webmin/server-manager/cloudmin-ui-check.acl'
    ).read_bytes()
    invalid = [(key, value) for key, value in form.fields if key != 'vms'] + [
        ('vms', '../host')
    ]
    assert 'Select valid virtual machine IDs' in editor(
        '/acl/save_acl.cgi', invalid
    )
    assert (
        Path('/etc/webmin/server-manager/cloudmin-ui-check.acl').read_bytes()
        == saved
    ), 'Invalid editor request changed permissions'
    permissions('cloudmin-ui-check', viewer)
    # Restore host administrator access for the remaining permission checks.
    permissions('cloudmin-frame-check', {'admin': 1})
    print(
        'PASS: real Webmin Users editor lists all VMs, saves and reloads grants, and rejects invalid assignments',
        flush=True,
    )
    # Global read-only mode blocks action tokens even with explicit VM grants.
    permissions(readonly_user, {**viewer, 'power': 1, 'console': 1})
    hosttoken = api(admin, 'options')['result']['token']
    html = page('/server-manager/index.cgi')
    assert guests[0].name() in html and guests[1].name() not in html, (
        'Inventory scope leaked'
    )
    assert 'machine_form.cgi' not in html and 'jobs.cgi' not in html, (
        'Host controls leaked'
    )
    assert 'token' not in api(page, 'options')['result'], (
        'Viewer received a change token'
    )
    assert 'token' not in api(readonly, 'options')['result'], (
        'Read-only operator received a token'
    )
    assert 'Virtual Machine Details' in page(
        '/server-manager/machine.cgi?id=' + own
    )
    assert 'Cloudmin permissions' in page(
        '/server-manager/machine.cgi?id=' + foreign
    )
    # Webmin itself must refuse module configuration for restricted users.
    config = page('/config.cgi?server-manager')
    assert 'name="libvirt_uri"' not in config and re.search(
        r'not allowed|denied|not permitted', config, re.I
    ), 'Module configuration exposed'
    # Each session must see its own permitted VMs through the shared collector.
    ownsocket = status(page, jar)
    initial = receive(ownsocket, 'status')
    assert set(initial['changed']) == {own}, 'Restricted snapshot leaked VMs'
    adminsocket = status(admin, adminjar)
    assert {own, foreign} <= set(receive(adminsocket, 'status')['changed']), (
        'Admin inventory changed'
    )
    badsocket = status(page, jar, foreign)
    assert closed(badsocket), 'Foreign detail subscription accepted'
    print(
        'PASS: scoped pages, empty viewer token, host configuration denial and simultaneous status filtering',
        flush=True,
    )

    # An explicit power grant works on the assigned VM but grants no
    # forced stop.
    operator = {**viewer, 'power': 1}
    permissions('cloudmin-ui-check', operator)
    receive(ownsocket, 'access_changed')
    token = api(page, 'options')['result']['token']
    assert 'result' in api(
        page, 'autostart', {'id': own, 'enabled': 1, 'token': token}
    )
    assert guests[0].autostart(), 'Allowed action did not reach libvirt'
    assert 'result' in api(
        page, 'autostart', {'id': own, 'enabled': 0, 'token': token}
    )
    # A token belongs to its user and cannot bypass a missing or
    # read-only grant.
    assert 'error' in api(
        page, 'autostart', {'id': own, 'enabled': 1, 'token': hosttoken}
    ), 'Admin token accepted for operator'
    assert 'error' in api(
        page, 'force_off', {'id': own, 'confirm': 1, 'token': token}
    ), 'Power implies force'
    assert (
        'read-only'
        in api(readonly, 'start', {'id': own, 'token': hosttoken})['error']
    )
    # Record VM state and job files before testing every forbidden request.
    before, before_files = state(), stores()
    endpoints = {
        'edit_machine.cgi': ['update', 'delete', 'delete_disk'],
        'setup_machine.cgi': ['create'],
        'clone_machine.cgi': ['clone'],
        'machine_jobs.cgi': ['cancel', 'recover', 'discard'],
        'snapshots.cgi': [
            'snapshot_create',
            'snapshot_restore',
            'snapshot_delete',
        ],
        'catalogue.cgi': ['enable', 'disable', 'delete'],
        'save_catalog_image.cgi': ['save'],
        'setup_image.cgi': ['create'],
        'delete_images.cgi': ['delete'],
        'image-upload.cgi': ['upload'],
        'networks.cgi': ['create', 'bridge', 'rollback', 'stop', 'delete'],
        'storage.cgi': ['create', 'start', 'stop', 'delete', 'delete_volumes'],
    }
    count = 0
    # Missing, owned and borrowed tokens must all fail before any host change.
    for borrowed in ('', token, hosttoken):
        # Even an assigned VM cannot make a delegated user a host administrator.
        for action in (
            'create review update delete delete_disk grow_disk add_disk attach_disk detach_disk '
                       'add_interface update_interface remove_interface change_media snapshot_create '
                       'snapshot_restore snapshot_delete power_cycle cancel recover discard settings snapshots status list'
        ).split():
            result = api(page, action, {'id': own, 'token': borrowed})
            assert 'Cloudmin permissions' in result.get('error', ''), action
            count += 1
        # Power grants never allow access to an unassigned VM.
        for action in 'start shutdown reboot suspend resume reset force_off autostart'.split():
            result = api(
                page,
                action,
                {'id': foreign, 'token': borrowed, 'confirm': 1, 'enabled': 1},
            )
            assert 'Cloudmin permissions' in result.get('error', ''), action
            count += 1
        # Direct form submissions must enforce the same boundary as the API.
        for endpoint, actions in endpoints.items():
            for action in actions:
                result = page(
                    '/server-manager/' + endpoint,
                    {
                        'id': own,
                        'action': action,
                        'vm_operation': action,
                        'token': borrowed,
                        'install_type': 'upload',
                    },
                    {'X-Cloudmin-Token': borrowed},
                )
                assert 'Cloudmin permissions' in result, endpoint
                count += 1
    # Delegated users must not see host inventory or job details.
    for endpoint in (
        'images.cgi',
        'image.cgi',
        'jobs.cgi',
        'image-status.cgi',
        'image-size.cgi',
        'catalogue.cgi',
        'edit_catalog_image.cgi',
        'progress.cgi',
    ):
        assert 'Cloudmin permissions' in page(
            '/server-manager/' + endpoint + '?id=' + own
        ), endpoint
    # Denial text alone is insufficient if a request already changed state.
    assert state() == before, 'Denied requests changed libvirt'
    assert stores() == before_files, 'Denied requests changed stores'
    print(
        f'PASS: assigned power works; {count} denials with absent, own and admin tokens leave VMs and stores unchanged',
        flush=True,
    )

    # A real graphical relay closes when its grant is removed mid-session.
    assert 'Cloudmin permissions' in page(
        '/server-manager/remote_access.cgi?id=' + own + '&tab=graphical'
    )
    assert 'Cloudmin permissions' in page(
        '/server-manager/remote_access.cgi?id=' + own
    )
    permissions('cloudmin-ui-check', {**operator, 'console': 1, 'terminal': 1})
    assert 'Cloudmin permissions' not in page(
        '/server-manager/remote_access.cgi?id=' + own
    )
    result = json.loads(
        page('/server-manager/console-connect.cgi', {'id': own, 'token': token})
    )
    assert 'socket_url' in result, result.get('error')
    console = socket_for(result['socket_url'], jar)
    assert console.recv().startswith(b'RFB '), (
        'Authorized console produced no VNC greeting'
    )
    # Revoke the grant while the authenticated VNC stream is still connected.
    assert 'Cloudmin permissions' in page(
        '/server-manager/remote_access.cgi?id=' + foreign
    )
    permissions('cloudmin-ui-check', operator)
    assert closed(console), 'Revoked graphical console remains open'
    port = re.search(r'ws-(\d+)', result['socket_url']).group(1)
    log = Path('/var/webmin/modules/server-manager') / (
        'console-' + port + '.log'
    )
    deadline = time.monotonic() + 10
    while (
        'Interactive access has been revoked' not in log.read_text()
        and time.monotonic() < deadline
    ):
        time.sleep(0.1)
    assert 'Interactive access has been revoked' in log.read_text(), (
        'Console closed for a reason other than revocation'
    )
    # Allowed ordinary power actions still operate on the assigned guest.
    assert 'result' in api(page, 'resume', {'id': own, 'token': token})
    assert guests[0].state()[0] == libvirt.VIR_DOMAIN_RUNNING
    assert 'result' in api(page, 'suspend', {'id': own, 'token': token})
    assert guests[0].state()[0] == libvirt.VIR_DOMAIN_PAUSED
    # A force-only role can stop the guest but cannot start it again.
    permissions('cloudmin-ui-check', {**viewer, 'force': 1})
    assert 'result' in api(
        page, 'force_off', {'id': own, 'token': token, 'confirm': 1}
    )
    assert not guests[0].isActive()
    assert (
        'Cloudmin permissions'
        in api(page, 'start', {'id': own, 'token': token})['error']
    )
    # Restoring the ordinary grant restores start without replacing the token.
    permissions('cloudmin-ui-check', operator)
    assert 'result' in api(page, 'start', {'id': own, 'token': token})
    assert guests[0].isActive()
    # Removing an assignment also removes inventory and prevents further
    # power calls.
    ownsocket = status(page, jar)
    assert set(receive(ownsocket, 'status')['changed']) == {own}
    permissions('cloudmin-ui-check', {'admin': 0})
    receive(ownsocket, 'access_changed')
    new_socket = status(page, jar)
    assert receive(new_socket, 'status')['changed'] == {}, (
        'Revoked VM remains visible'
    )
    assert (
        'Cloudmin permissions'
        in api(page, 'start', {'id': own, 'token': token})['error']
    )
    print(
        'PASS: console transport, console revocation, assignment revocation and empty assigned inventory',
        flush=True,
    )
finally:
    # Close browser transports before removing only this run's guests and users.
    for sock in sockets:
        sock.close()
    for guest in guests:
        # Only active fixtures need a forced stop before their definitions go.
        if guest.isActive():
            guest.destroy()
        guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    for user in users:
        subprocess.run(['perl', str(helper), 'delete', '', user], check=True)
    # No timeout should outlive cleanup or the libvirt connection.
    conn.close()
    signal.alarm(0)
