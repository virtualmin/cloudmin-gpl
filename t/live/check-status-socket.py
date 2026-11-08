#!/usr/bin/python3
"""Exercise the shared status channel on a disposable Cloudmin host."""

import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request
import uuid
import libvirt
import websocket
import signal

# Interrupted live checks still remove their own fixtures.
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(1)))

# Account creation and libvirt mutations belong on the disposable Webmin host.
if os.geteuid() != 0 or not Path('/etc/webmin').is_dir():
    raise SystemExit('Run on a disposable Webmin Linux VM as root')
helper = Path(__file__).resolve().with_name('webmin-user.pl')
base = 'https://127.0.0.1:10000'
users = []
sockets = []
conn = libvirt.open('qemu:///system')
fixture = None
image_record = None
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--restart-libvirt',
    action='store_true',
    help='Also restart the native daemon to test live reconnection',
)
options = parser.parse_args()


# login(name, theme, [access]) keeps fixture credentials in memory.
# Access is the helper action: create, create-readonly or create-other.
def login(name, theme, access='create'):
    password = secrets.token_urlsafe(36)
    subprocess.run(
        ['perl', str(helper), access, theme, name],
        input=password + '\n',
        text=True,
        check=True,
    )
    users.append((name, theme))
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )

    # page(path, [fields]) sends requests with this account's private cookies.
    def page(path, fields=None):
        data = urllib.parse.urlencode(fields).encode() if fields else None
        headers = {'Referer': base + '/'}
        # Satisfy Webmin's cookie check on the initial login POST.
        if path == '/session_login.cgi' and fields and 'pass' in fields:
            headers['Cookie'] = 'testing=1'
        with opener.open(
            urllib.request.Request(base + path, data=data, headers=headers),
            timeout=20,
        ) as reply:
            return reply.read().decode()

    time.sleep(0.5)
    page('/session_login.cgi', {'user': name, 'pass': password})
    return page, jar


# channel(page, jar, [identity]) subscribes through MiniServ's proxy.
# The default identity requests the overview inventory.
def channel(page, jar, identity='overview'):
    result = json.loads(page('/server-manager/machine_status.cgi'))
    assert 'socket_url' in result, result.get('error', 'No socket URL')
    sock = websocket.create_connection(
        result['socket_url'],
        cookie='; '.join(c.name + '=' + c.value for c in jar),
        origin=base,
        sslopt={'cert_reqs': ssl.CERT_NONE},
        timeout=15,
    )
    sockets.append(sock)
    sock.send(json.dumps({'id': identity, 'paused': False}))
    return sock, result['socket_url']


# receive(sock, predicate, [timeout]) waits up to 15 seconds for a
# matching update.
def receive(sock, predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sock.settimeout(max(0.1, deadline - time.monotonic()))
        msg = json.loads(sock.recv())
        assert msg.get('type') != 'error', 'Collector reported an error'
        # Ignore heartbeats and updates unrelated to this assertion.
        if predicate(msg):
            return msg
    raise AssertionError('Expected update did not arrive')


try:
    page1, jar1 = login(
        'cloudmin-spa-check-' + secrets.token_hex(4), 'authentic-theme'
    )
    page2, jar2 = login('cloudmin-frame-check', 'gray-theme')
    ws1, url1 = channel(page1, jar1)
    first = receive(ws1, lambda m: m.get('full'))
    ws2, url2 = channel(page2, jar2)
    second = receive(ws2, lambda m: m.get('full'))
    assert url1 == url2, 'Users started separate collectors'
    assert {k: v['vm'] for k, v in first['changed'].items()} == {
        k: v['vm'] for k, v in second['changed'].items()
    }, 'Shared inventory differs across users'
    assert first['changed'], 'Expected existing guests'
    state = json.loads(
        Path(
            '/var/webmin/modules/server-manager/status-server.json'
        ).read_text()
    )
    assert state['pid'] > 0
    # Resource samples may change between handshakes; only actual deltas belong
    # on the wire.
    previous = dict(first['changed'])
    ws1.settimeout(3)
    try:
        while True:
            msg = json.loads(ws1.recv())
            # Compare each changed record with the last version this user saw.
            if msg['type'] == 'status':
                for identity, value in msg.get('changed', {}).items():
                    assert previous.get(identity) != value, (
                        'Unchanged inventory was retransmitted'
                    )
                    previous[identity] = value
            # An otherwise idle channel may still send transport heartbeats.
            else:
                assert msg['type'] == 'heartbeat'
    except websocket.WebSocketTimeoutException:
        pass
    print(
        'PASS: two users, one collector, shared snapshot, no unchanged broadcasts'
    )

    # Image jobs use atomic JSON replacement, independently of the VM database.
    # Publish a fixture record without downloading data or allocating a volume.
    image_id = secrets.token_hex(16)
    image_record = Path('/var/webmin/modules/server-manager/image-jobs') / (
        image_id + '.json'
    )
    image_job = dict(
        id=image_id,
        owner='cloudmin-ui-check',
        name='Status fixture',
        state='queued',
        pid=os.getpid(),
        created=int(time.time()),
        updated=int(time.time()),
    )
    image_record.write_text(json.dumps(image_job))
    image_record.chmod(0o600)
    for ws, initial in ((ws1, first), (ws2, second)):
        receive(ws, lambda m: m.get('jobs') == initial['jobs'] + 1)
    image_job['state'] = 'ready'
    replacement = image_record.with_suffix('.new')
    replacement.write_text(json.dumps(image_job))
    replacement.chmod(0o600)
    replacement.replace(image_record)
    for ws, initial in ((ws1, first), (ws2, second)):
        receive(ws, lambda m: m.get('jobs') == initial['jobs'])
    image_record.unlink()
    print(
        'PASS: image-only submission and completion update both live job counts'
    )

    # A quiet collector outlives libvirt's keepalive deadline. Reopening before
    # its own idle exit must reuse a healthy connection, not report an outage.
    ws1.close()
    ws2.close()
    time.sleep(35)
    ws1, idle_url1 = channel(page1, jar1)
    receive(ws1, lambda m: m.get('full'))
    ws2, idle_url2 = channel(page2, jar2)
    receive(ws2, lambda m: m.get('full'))
    assert idle_url1 == idle_url2 == url1, 'Idle collector was replaced'
    assert (
        json.loads(
            Path(
                '/var/webmin/modules/server-manager/status-server.json'
            ).read_text()
        )['pid']
        == state['pid']
    )
    print(
        'PASS: idle collector services libvirt keepalives between subscribers'
    )

    # A diskless stopped fixture produces real libvirt
    # define/update/remove events.
    ident = str(uuid.uuid4())
    name = 'cloudmin-status-Čačak-' + ident[:8]
    machine = 'virt' if conn.getInfo()[0] == 'aarch64' else 'q35'
    xml = (
        f"<domain type='kvm'><name>{name}</name><uuid>{ident}</uuid><memory unit='MiB'>64</memory><vcpu>1</vcpu>"
           f"<os><type arch='{conn.getInfo()[0]}' machine='{machine}'>hvm</type></os></domain>"
    )
    fixture = conn.defineXML(xml)
    for ws in (ws1, ws2):
        update = receive(ws, lambda m: ident in m.get('changed', {}))
        assert update['changed'][ident]['vm']['state'] == 'shutoff'
        assert update['changed'][ident]['vm']['name'] == name, (
            'Guest name was encoded twice'
        )
        assert not update.get('full'), 'Event rebuilt the full snapshot'
    ws2.send(json.dumps({'id': 'overview', 'paused': True}))
    time.sleep(1)
    conn.defineXML(
        xml.replace('</os>', '</os><description>updated</description>')
    )
    fixture.undefine()
    fixture = None
    receive(ws1, lambda m: ident in m.get('removed', []))
    ws2.settimeout(2)
    try:
        while True:
            assert json.loads(ws2.recv())['type'] == 'heartbeat', (
                'Hidden subscriber received inventory'
            )
    except websocket.WebSocketTimeoutException:
        pass
    ws2.send(json.dumps({'id': 'overview', 'paused': False}))
    receive(ws2, lambda m: ident in m.get('removed', []))
    assert (
        json.loads(
            Path(
                '/var/webmin/modules/server-manager/status-server.json'
            ).read_text()
        )['pid']
        == state['pid']
    )
    print(
        'PASS: libvirt events, targeted deltas, hidden-tab pause and cached resume'
    )

    running = next(
        id
        for id, r in first['changed'].items()
        if r['vm']['state'] == 'running'
    )
    ws1.send(json.dumps({'id': running, 'paused': False}))
    health = receive(
        ws1,
        lambda m: m.get('changed', {}).get(running, {}).get('health')
        is not None,
    )
    assert health['changed'][running]['health']['ssh'] == 'responding'
    assert health['changed'][running]['health']['console_available']
    # A second detail subscriber receives the already-collected
    # result immediately.
    ws2.send(json.dumps({'id': running, 'paused': False}))
    cached = receive(ws2, lambda m: m.get('full'))
    assert (
        cached['changed'][running]['health']
        == health['changed'][running]['health']
    )
    print(
        'PASS: real guest SSH banner and console capability, reused across users'
    )

    # A daemon restart must recover the same browser stream and collector.
    if options.restart_libvirt:
        webmin = helper.parents[3]
        unit = (
            'virtqemud.service'
            if Path('/usr/sbin/virtqemud').exists()
            else 'libvirtd.service'
        )
        script = '''BEGIN {
    $ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
    $ENV{'WEBMIN_VAR'} = '/var/webmin';
    $ENV{'REMOTE_USER'} = 'root';
    $0 = "$ARGV[1]/systemd/cloudmin-reconnect.pl";
}
use WebminCore;
init_config();
foreign_require('systemd', 'systemd-lib.pl');
my ($ok, $out) = systemd::restart_unit($ARGV[0]);
die "Cannot restart libvirt: $out" if (!$ok);
'''
        subprocess.run(
            ['perl', '-I', str(webmin), '-e', script, unit, str(webmin)],
            cwd=webmin / 'systemd',
            check=True,
            timeout=60,
        )
        deadline = time.monotonic() + 25
        recovered = False
        while time.monotonic() < deadline:
            ws1.settimeout(max(0.1, deadline - time.monotonic()))
            update = json.loads(ws1.recv())
            # A full inventory containing the guest proves
            # reconnection succeeded.
            if update.get('full') and running in update.get('changed', {}):
                recovered = True
                break
        assert recovered, 'Collector did not recover after restarting libvirt'
        assert (
            json.loads(
                Path(
                    '/var/webmin/modules/server-manager/status-server.json'
                ).read_text()
            )['pid']
            == state['pid']
        )
        # The test's own libvirt connection also needs reopening.
        conn.close()
        conn = libvirt.open('qemu:///system')
        print(
            'PASS: existing status connection recovers after native daemon restart'
        )

    for page in (page1, page2):
        overview = page('/server-manager/index.cgi')
        assert (
            'id="cloudmin-vm-status"' in overview
            and 'machine_status.js' in overview
        )
        assert 'data-vm-id=' in overview
        assert 'Error - Perl execution failed' not in overview
    import importlib.util

    browser_spec = importlib.util.spec_from_file_location(
        "status_browser", Path(__file__).with_name("status_browser.py")
    )
    # Run browser assertions when the companion fixture is installed.
    if browser_spec.origin and Path(browser_spec.origin).exists():
        browser = importlib.util.module_from_spec(browser_spec)
        browser_spec.loader.exec_module(browser)
        browser.check_browser(jar1, "authentic-theme", conn)
        browser.check_browser(jar2, "gray-theme", conn)
    # Read-only module users receive inventory; unrelated module users do not.
    for access in ('create-readonly', 'create-other'):
        restricted_page, restricted = login(
            'cloudmin-ui-check', 'gray-theme', access=access
        )
        # Read-only sessions must reuse the collector and still
        # receive inventory.
        if access == 'create-readonly':
            readonly_socket, readonly_url = channel(restricted_page, restricted)
            assert readonly_url == url1, (
                'Read-only viewer started a separate collector'
            )
            inventory = receive(readonly_socket, lambda m: m.get('full'))
            assert running in inventory['changed'], (
                'Read-only viewer received no inventory'
            )
            readonly_socket.close()
            subprocess.run(
                ['perl', str(helper), 'delete', '', 'cloudmin-ui-check'],
                check=True,
            )
            users.remove(('cloudmin-ui-check', 'gray-theme'))
            continue
        try:
            denied = websocket.create_connection(
                url1,
                cookie='; '.join(c.name + '=' + c.value for c in restricted),
                origin=base,
                sslopt={'cert_reqs': ssl.CERT_NONE},
                timeout=10,
            )
            sockets.append(denied)
            denied.send(json.dumps({'id': 'overview'}))
            assert not denied.recv(), access + ' user received shared inventory'
        except (
            websocket.WebSocketBadStatusException,
            websocket.WebSocketConnectionClosedException,
            ConnectionResetError,
        ):
            pass
        # Free the fixture name for the next restricted account.
        subprocess.run(
            ['perl', str(helper), 'delete', '', 'cloudmin-ui-check'], check=True
        )
        users.remove(('cloudmin-ui-check', 'gray-theme'))
    print(
        'PASS: shared route admits read-only viewers and rejects module-less sessions'
    )
    ws2.close()
    ws2, url3 = channel(page2, jar2, running)
    assert url3 == url1
    receive(ws2, lambda m: m.get('full'))
    # Logging out invalidates an existing stream without browser cooperation.
    page2('/session_login.cgi', {'logout': 1})
    ws2.settimeout(20)
    disconnected = False
    deadline = time.monotonic() + 25
    try:
        while time.monotonic() < deadline:
            # A clean close is also evidence that logout revoked this stream.
            if not ws2.recv():
                disconnected = True
                break
    except (websocket.WebSocketConnectionClosedException, ConnectionResetError):
        disconnected = True
    assert disconnected, 'Logged-out user retained the stream'
    print('PASS: markup in all themes, reconnect reuse, logout revocation')
finally:
    # Remove only this run's synthetic image record, including failed checks.
    if image_record is not None:
        image_record.unlink(missing_ok=True)
        image_record.with_suffix('.new').unlink(missing_ok=True)
    for sock in sockets:
        sock.close()
    # A failed assertion can leave the stopped fixture defined.
    if fixture is not None:
        fixture.undefine()
    conn.close()
    for user, theme in users:
        subprocess.run(['perl', str(helper), 'delete', '', user], check=True)
        for suffix in ('', '.js'):
            (
                Path('/etc/webmin') / theme / ('settings-' + user + suffix)
            ).unlink(missing_ok=True)
