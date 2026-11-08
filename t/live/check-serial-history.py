#!/usr/bin/python3
"""
Test serial replay with a diskless x86-64 guest in both navigation layouts.
"""

import base64
import html
import http.cookiejar
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

import libvirt
import websocket

# Boot only an isolated diskless guest on a compatible Linux test host.
assert os.uname().sysname == 'Linux' and os.geteuid() == 0, (
    'Run on a Linux test host as root'
)
assert os.uname().machine == 'x86_64', (
    'This diskless fixture requires an x86-64 host'
)
here = Path(__file__).resolve().parent
# Give the domain, recordings and account grants unique identities for cleanup.
module = here.parent.parent
webmin = module.parent
identifier = str(uuid.uuid4())
name = 'cloudmin-serial-history-' + identifier[:8]
log = Path('/var/log/libvirt/qemu/cloudmin-' + identifier + '-serial.log')
base = 'https://127.0.0.1:10000'
accounts = []
conn = libvirt.open('qemu:///system')
guest = sock = None


# timeout(signum, frame) lets finally release only this run's fixtures.
def timeout(signum, frame):
    raise TimeoutError('Serial history fixture timed out')


signal.signal(signal.SIGALRM, timeout)
signal.alarm(240)


# adapter(action, [xml]) exercises production definition, start and cleanup
# hooks. Supply xml for define; start and remove use this run's fixed
# guest UUID.
def adapter(action, xml=''):
    code = '''
use Cloudmin::Libvirt;
use Cloudmin::SerialLog;
my ($action, $uuid) = @ARGV;
my $logs = Cloudmin::SerialLog->new();
my $adapter = Cloudmin::Libvirt->new(readonly => 0, serial_log => $logs);
# Exercise creation with the supplied diskless domain definition.
if ($action eq 'define') { local $/; $adapter->define_guest(<STDIN>); }
# Enable logging on existing definitions through the cold-start hook.
elsif ($action eq 'start') { $adapter->start_domain($uuid); }
# Removal verifies that the production hook deletes managed recordings.
elsif ($action eq 'remove') { $adapter->removed_guest($uuid); }
# Refuse a mistyped fixture action without touching the hypervisor.
else { die "Unknown fixture action"; }
'''
    subprocess.run(
        [
            'perl',
            '-I' + str(webmin),
            '-I' + str(module / 'lib'),
            '-e',
            code,
            action,
            identifier,
        ],
        input=xml,
        text=True,
        check=True,
        timeout=30,
    )


# user(action, theme, name, [data]) supplies optional private input to the
# helper. Passwords stay in the test process and its pipe rather than
# command arguments.
def user(action, theme, name, data=None):
    subprocess.run(
        ['perl', str(here / 'webmin-user.pl'), action, theme, name],
        input=data,
        text=True,
        check=True,
        timeout=30,
    )


# request(opener, path, [values]) sends forms with the UI's origin and referrer.
# Omitted values use GET; supplied values become a form POST.
def request(opener, path, values=None):
    body = (
        urllib.parse.urlencode(values).encode() if values is not None else None
    )
    headers = {'Referer': base + '/server-manager/remote_access.cgi'}
    # Native login requires the browser's cookie-support probe.
    if path == '/session_login.cgi':
        headers['Cookie'] = 'testing=1'
    req = urllib.request.Request(base + path, data=body, headers=headers)
    with opener.open(req, timeout=30) as response:
        return response.read().decode()


# account(theme) grants a temporary user console access to this fixture only.
def account(theme):
    name = 'cloudmin-ui-check-' + secrets.token_hex(4)
    password = secrets.token_urlsafe(36)
    user('create', theme, name, password + '\n')
    accounts.append((theme, name))
    user(
        'acl', theme, name, json.dumps(dict(admin=0, vms=identifier, console=1))
    )
    # Keep each account's cookies in a separate in-memory jar.
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
        urllib.request.HTTPCookieProcessor(jar),
    )
    request(opener, '/session_login.cgi', {'user': name, 'pass': password})
    return opener, jar


# attach(opener, jar) returns a real proxied socket and its bounded replay.
def attach(opener, jar):
    # Use the real page's signed configuration rather than constructing a token.
    page = request(
        opener,
        '/server-manager/remote_access.cgi?id=' + identifier + '&tab=serial',
    )
    match = re.search(r'data-console-config="([^"]+)"', page)
    assert match, 'Serial page has no connection configuration'
    config = json.loads(html.unescape(match[1]))
    result = json.loads(
        request(
            opener,
            config['endpoint'],
            dict(id=identifier, token=config['token'], mode='serial'),
        )
    )
    assert result.get('socket_url'), result.get('error', 'Missing serial route')
    # Attach with the same session and origin that authorized the console POST.
    socket = websocket.create_connection(
        result['socket_url'],
        origin=base,
        cookie='; '.join(c.name + '=' + c.value for c in jar),
        sslopt={'cert_reqs': ssl.CERT_NONE},
        timeout=20,
    )
    data = socket.recv()
    # Assemble the prefix and replay across WebSocket frames.
    while len(data) < 4:
        data += socket.recv()
    size = struct.unpack('!I', data[:4])[0]
    assert 0 < size <= 65536, 'Replay is absent or exceeds its bound'
    data = data[4:]
    while len(data) < size:
        data += socket.recv()
    assert len(data) == size, 'Idle guest unexpectedly produced live output'
    return socket, data, result['socket_url']


# detach(socket, route) waits for the exclusive stream to be released.
def detach(socket, route):
    socket.close()
    port = re.search(r'/ws-(\d+)', route)[1]
    deadline = time.monotonic() + 15
    while (
        'websockets_/server-manager/ws-' + port + '='
        in Path('/etc/webmin/miniserv.conf').read_text()
    ):
        assert time.monotonic() < deadline, (
            'Closed serial route was not removed'
        )
        time.sleep(.1)


# receive(socket, size) joins frames without assuming one frame per keystroke.
def receive(socket, size):
    output = b''
    while len(output) < size:
        chunk = socket.recv()
        assert chunk, 'Console closed before returning input'
        output += chunk
    return output


# browser_check(theme, jar) checks the actual page and xterm without
# guest input.
def browser_check(theme, jar):
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required'
    parent = (
        Path('/root/snap/chromium/common')
        if browser.startswith('/snap/')
        else None
    )
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-serial-browser-', dir=parent
    ) as profile:
        chrome = subprocess.Popen(
            [
                browser,
                '--headless',
                '--no-sandbox',
                '--disable-gpu',
                '--remote-debugging-port=0',
                '--ignore-certificate-errors',
                '--no-first-run',
                '--no-default-browser-check',
                '--disable-background-networking',
                '--disable-sync',
                '--window-size=1400,900',
                '--user-data-dir=' + profile,
                'about:blank',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cdp = None
        try:
            # Discover only this isolated browser's private debugging endpoint.
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists():
                assert chrome.poll() is None and time.monotonic() < deadline, (
                    'Chromium did not start'
                )
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection(
                'ws://127.0.0.1:' + port + route,
                timeout=30,
                suppress_origin=True,
            )
            sequence, session = 0, None
            sent = []

            # call(method, [params]) waits for a CDP reply and captures
            # guest input.
            def call(method, params=None):
                nonlocal sequence
                sequence += 1
                command = dict(id=sequence, method=method, params=params or {})
                # Page commands need a session after target attachment.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Record any input sent during console startup.
                    if reply.get('method') == 'Network.webSocketFrameSent':
                        frame = reply['params']['response']
                        # Only binary frames carry guest input.
                        if frame['opcode'] == 2:
                            sent.append(base64.b64decode(frame['payloadData']))
                    # Wait for this command's reply.
                    if reply.get('id') == sequence:
                        assert 'error' not in reply, reply.get('error')
                        return reply.get('result', {})

            # Observe a fresh page before loading the actual serial client.
            target = call('Target.createTarget', {'url': 'about:blank'})[
                'targetId'
            ]
            session = call(
                'Target.attachToTarget', {'targetId': target, 'flatten': True}
            )['sessionId']
            call('Page.enable')
            call('Network.enable')
            # Capture xterm's actual display buffer without replacing
            # its renderer.
            call(
                'Page.addScriptToEvaluateOnNewDocument',
                {
                    'source': '''
                let terminal;
                Object.defineProperty(window, 'Terminal', {configurable: true,
                  get() { return terminal; }, set(value) {
                    terminal = class extends value { constructor(options) {
                      super(options); window.serialTestTerminal = this;
                    }};
                  }});
            '''
                },
            )
            # Transfer only this fixture account's cookies into the browser.
            for cookie in jar:
                call(
                    'Network.setCookie',
                    dict(
                        name=cookie.name,
                        value=cookie.value,
                        url=base,
                        secure=True,
                        httpOnly=True,
                    ),
                )
            call(
                'Page.navigate',
                {
                    'url': base
                    + '/server-manager/remote_access.cgi?id='
                    + identifier
                    + '&tab=serial',
                    'referrer': base + '/',
                },
            )
            deadline = time.monotonic() + 30
            # Read the cursor's rendered line only after replay enables input.
            while True:
                result = call(
                    'Runtime.evaluate',
                    {
                        'expression': '''(() => {
                    const w = window.frames.right || window;
                    const t = w.serialTestTerminal;
                    if (!t || t.options.disableStdin) return null;
                    const b = t.buffer.active;
                    return b.getLine(b.baseY + b.cursorY)?.translateToString(true);
                })()''',
                        'returnByValue': True,
                    },
                )
                line = result.get('result', {}).get('value')
                # The pending username must remain unsubmitted.
                if line == 'login: tester':
                    break
                # Report page state if replay never reaches the expected prompt.
                if time.monotonic() >= deadline:
                    detail = call(
                        'Runtime.evaluate',
                        {
                            'expression': '''(() => {
                        const w = window.frames.right || window, d = w.document;
                        return {path: w.location.pathname, title: d.title,
                          status: d.querySelector('[data-console-status]')?.textContent,
                          terminal: typeof w.Terminal, captured: !!w.serialTestTerminal,
                          disabled: w.serialTestTerminal?.options.disableStdin,
                          error: d.querySelector('.err-body')?.textContent};
                    })()''',
                            'returnByValue': True,
                        },
                    )
                    raise AssertionError(
                        'Initial prompt was not restored: '
                        + str(line)
                        + '; '
                        + str(detail.get('result', {}).get('value'))
                    )
                time.sleep(.1)
            assert not sent, 'Initial page load sent input to the guest'
            print(
                'PASS:',
                theme,
                'shows the pending login on first load without input',
                flush=True,
            )
            call('Browser.close')
        finally:
            # Close the private browser before its temporary profile is removed.
            if cdp:
                cdp.close()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # A hung fixture browser must not survive test cleanup.
                chrome.kill()
                chrome.wait()


try:
    with tempfile.TemporaryDirectory(prefix='cloudmin-serial-history-') as temp:
        folder = Path(temp)
        folder.chmod(0o755)
        root = folder / 'root'
        # Build a minimal initramfs with agetty and only its required libraries.
        for item in ('bin', 'sbin', 'dev', 'proc', 'sys', 'etc'):
            (root / item).mkdir(parents=True)
        shutil.copy('/usr/bin/busybox', root / 'bin/busybox')
        (root / 'bin/sh').symlink_to('busybox')
        shutil.copy('/usr/sbin/agetty', root / 'sbin/agetty')
        for library in re.findall(
            r'(/\S+)',
            subprocess.check_output(['ldd', '/usr/sbin/agetty'], text=True),
        ):
            dest = root / library.lstrip('/')
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(library, dest)
        (root / 'etc/issue').write_text('Serial history fixture\n')
        # Submitting the fixture username emits enough output to rotate the log.
        (root / 'bin/login').write_text('''#!/bin/sh
printf 'LOGIN:%s\nBULK_BEGIN' "$1"
/bin/busybox head -c 3145728 /dev/zero | /bin/busybox tr '\\000' x
printf 'BULK_END\nROTATED\n'
''')
        (root / 'bin/login').chmod(0o755)
        # Restart agetty after each test login to leave a prompt.
        (root / 'init').write_text('''#!/bin/sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
while true; do
  /sbin/agetty -f /etc/issue -N -L -8 -J --nohostname --login-program=/bin/login --login-options='\\u' ttyS0 115200 vt100
done
''')
        (root / 'init').chmod(0o755)
        # Boot the host's kernel with this initramfs and no guest disk.
        entries = (
            b'\0'.join(
                str(p.relative_to(root)).encode() for p in root.rglob('*')
            )
            + b'\0'
        )
        with (folder / 'initrd').open('wb') as out:
            subprocess.run(
                ['cpio', '--null', '-o', '--format=newc', '--quiet'],
                input=entries,
                cwd=root,
                stdout=out,
                check=True,
            )
        shutil.copy('/boot/vmlinuz-' + os.uname().release, folder / 'kernel')
        xml = f'''<domain type='kvm'><name>{name}</name><uuid>{identifier}</uuid>
          <memory unit='MiB'>256</memory><vcpu>1</vcpu>
          <os><type arch='x86_64'>hvm</type><kernel>{folder}/kernel</kernel>
            <initrd>{folder}/initrd</initrd><cmdline>console=ttyS0 quiet rdinit=/init</cmdline></os>
          <devices><serial type='pty'><target port='0'/></serial>
            <console type='pty'><target type='serial' port='0'/></console>
            <memballoon model='none'/></devices></domain>'''
        # Production define/start hooks must enable private native recording.
        adapter('define', xml)
        guest = conn.lookupByUUIDString(identifier)
        adapter('start')
        deadline = time.monotonic() + 30
        while not log.exists() or not log.read_bytes().endswith(b'login: '):
            assert time.monotonic() < deadline, (
                'Linux fixture did not reach agetty'
            )
            time.sleep(.1)
        assert (
            stat.S_IMODE(log.stat().st_mode) == 0o600 and log.stat().st_uid == 0
        ), 'Serial log is not private'
        # Connecting to an idle prompt must replay output without waking agetty.
        opener, jar = account('authentic-theme')
        sock, history, route = attach(opener, jar)
        assert history.endswith(b'login: '), (
            'Existing login prompt was not replayed'
        )
        size = log.stat().st_size
        time.sleep(.3)
        assert log.stat().st_size == size, 'Connecting generated guest input'
        # Leave a username partly entered and confirm reconnection preserves it.
        sock.send_binary(b'tester')
        assert receive(sock, 6) == b'tester', (
            'Typed username was lost or duplicated'
        )
        detach(sock, route)
        sock, history, route = attach(opener, jar)
        assert history.endswith(b'login: tester'), (
            'Reconnection lost the pending username'
        )
        print(
            'PASS: login replay and pending input survived reconnect',
            flush=True,
        )
        # Optionally submit the fixture login to force native log rotation.
        if '--skip-rotation' not in sys.argv:
            sock.send_binary(b'\r')
            output = b''
            while not output.endswith(b'login: '):
                output += sock.recv()
                assert len(output) < 4 * 1024 * 1024, (
                    'Live output was duplicated'
                )
            assert (
                b'LOGIN:tester' in output
                and b'BULK_BEGIN' + b'x' * 3145728 + b'BULK_END' in output
            ), 'Rotation lost guest bytes: ' + repr(
                (len(output), output[:100], output[-100:])
            )
            assert output.count(b'BULK_BEGIN') == 1, (
                'Rotation duplicated the bulk output'
            )
            assert Path(str(log) + '.0').exists(), (
                'Native virtlogd rotation did not occur'
            )
            # The serial input path must still work after output switches files.
            sock.send_binary(b'tester')
            assert receive(sock, 6) == b'tester', (
                'Console stopped accepting input after rotation'
            )
            print('PASS: native rotation preserves live output', flush=True)
        detach(sock, route)
        sock = None
        print(
            'PASS: native recording, private mode, bounded replay, live input and reconnect',
            flush=True,
        )
        # Each layout must show the pending username on its first browser load.
        for theme in ('authentic-theme', 'gray-theme'):
            opener, jar = account(theme)
            browser_check(theme, jar)
            time.sleep(.5)
        # An older definition gains logging on cold start, with no old output.
        guest.destroy()
        conn.defineXML(xml)
        adapter('start')
        deadline = time.monotonic() + 30
        while not log.read_bytes().endswith(b'login: '):
            assert time.monotonic() < deadline, (
                'Cold start did not reach agetty'
            )
            time.sleep(.1)
        assert b'tester' not in log.read_bytes(), (
            'Previous boot recording survived a cold start'
        )
        assert not Path(str(log) + '.0').exists(), (
            'Previous rotations survived a cold start'
        )
        print(
            'PASS: cold start enables logging on an existing definition and clears old output',
            flush=True,
        )
finally:
    # Release the console before removing this run's diskless guest.
    if sock:
        sock.close()
    if guest:
        # Stop the test guest before removing its definition.
        if guest.isActive():
            guest.destroy()
        guest.undefine()
        adapter('remove')
        assert not log.exists(), 'Guest deletion left its serial history behind'
        Path('/var/log/libvirt/qemu/' + name + '.log').unlink(missing_ok=True)
    conn.close()
    # Remove test accounts and any saved display preferences.
    for theme, name in accounts:
        user('delete', theme, name)
        for suffix in ('', '.js'):
            (
                Path('/etc/webmin') / theme / ('settings-' + name + suffix)
            ).unlink(missing_ok=True)
