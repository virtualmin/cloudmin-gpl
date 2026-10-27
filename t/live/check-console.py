#!/usr/bin/python3
"""Test console permissions, VNC transport and browser themes on a disposable host."""
import argparse
import base64
import hashlib
import html
import http.cookiejar
import json
from theme_support import is_spa_theme
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import ssl
import struct
import sys
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

import libvirt
import websocket

# This test creates accounts and a disposable libvirt guest.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
browser = shutil.which('chromium') or shutil.which('chromium-browser')
# timed_out(signum, frame) aborts the fixture without bypassing cleanup.
def timed_out(signum, frame):
    raise TimeoutError('Console fixture timed out')


signal.signal(signal.SIGALRM, timed_out)
# Allow time for the real connection timeouts and browser checks.
signal.alarm(720)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--theme', choices=('authentic-theme', 'gray-theme'), default='authentic-theme')
parser.add_argument('--platform', choices=('linux', 'mac'), default='linux')
parser.add_argument('--serial-console', action='store_true', help='Also test serial transport and switching console modes')
parser.add_argument('--protocol-only', action='store_true', help='Check real VNC and isolation without Chromium')
options = parser.parse_args()
# Protocol-only runs still exercise the relay but need no browser installation.
if not browser and not options.protocol_only:
    raise SystemExit('Chromium is required on the disposable VM')
theme = options.theme
spa = is_spa_theme(theme)
in_frame = False
base = 'https://127.0.0.1:10000'
helper = Path(__file__).resolve().with_name('webmin-user.pl')
users = []
chrome = cdp = guest = profile = None
conn = libvirt.open('qemu:///system')
identifier = str(uuid.uuid4())
name = 'cloudmin-console-check-' + identifier[:8]
errors = []
sent_binary = []
sent_by_socket = {}
serial = 0
session = None


# clear_theme_settings(user) removes preferences belonging to a fixture account.
def clear_theme_settings(user):
    for suffix in ('', '.js'):
        (Path('/etc/webmin') / theme / ('settings-' + user + suffix)).unlink(missing_ok=True)


# saved_zoom(user, [preference]) reads a fixture account's graphical zoom or
# serial font size. preference defaults to console_zoom.
def saved_zoom(user, preference='console_zoom'):
    for suffix in ('', '.js'):
        path = Path('/etc/webmin') / theme / ('settings-' + user + suffix)
        # Either theme settings format can hold the saved preference.
        if path.exists():
            match = re.search(r"config_portable_module_cloudmin_" + re.escape(preference) +
                              r"\s*=\s*['\"]?(\d+)", path.read_text())
            return int(match[1]) if match else None
    return None


# account(user, [readonly]) creates a local login and HTTP session.
# Accounts have module write access unless readonly is true.
def account(user, readonly=False):
    password = secrets.token_urlsafe(36)
    subprocess.run(['perl', str(helper), 'create-readonly' if readonly else 'create',
                    theme, user], input=password + '\n', text=True, check=True)
    users.append(user)
    # Account deletion leaves theme preferences behind; each test starts fresh.
    clear_theme_settings(user)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
                                        urllib.request.HTTPCookieProcessor(jar))
    login = urllib.parse.urlencode(dict(user=user, pass_=password)).replace('pass_=', 'pass=').encode()
    req = urllib.request.Request(base + '/session_login.cgi', data=login, headers={'Cookie':'testing=1'})
    opener.open(req, timeout=30).read()
    return opener, jar, password


# page(opener, path, [values]) fetches HTML or posts form fields privately.
def page(opener, path, values=None):
    body = urllib.parse.urlencode(values).encode() if values is not None else None
    req = urllib.request.Request(base + path, data=body, headers={'Referer':base + '/server-manager/remote_access.cgi'})
    with opener.open(req, timeout=30) as response:
        return response.read().decode()


# connect_config(opener, [mode]) reads the fixture's signed request data.
# mode defaults to graphical; serial uses the same page and authorization path.
def connect_config(opener, mode='graphical'):
    form = page(opener, '/server-manager/remote_access.cgi?id=' + identifier + '&tab=' + mode)
    match = re.search(r'data-console-config="([^"]+)"', form)
    assert match, 'Console configuration missing from the page'
    return json.loads(html.unescape(match[1]))


# route(opener, config) requests a fresh connection in the page's console mode.
def route(opener, config):
    result = json.loads(page(opener, config['endpoint'], dict(id=identifier, token=config['token'], mode=config.get('mode', 'graphical'))))
    assert result.get('socket_url'), result.get('error', 'Console route missing')
    assert set(result) == {'socket_url'}, 'Console response exposes unnecessary data'
    return result['socket_url']


# reject_socket(url, **options) checks that a connection cannot read VNC bytes.
def reject_socket(url, **options):
    sock = None
    try:
        sock = websocket.create_connection(url, timeout=3, sslopt={'cert_reqs':ssl.CERT_NONE}, **options)
        assert not sock.recv(), 'Unauthorized connection received console data'
    except (websocket.WebSocketException, OSError):
        pass
    finally:
        # Close an unexpectedly accepted socket before reporting the failure.
        if sock:
            sock.close()


# call(method, [params]) sends CDP commands, recording errors and guest input.
def call(method, params=None):
    global serial
    serial += 1
    command = dict(id=serial, method=method, params=params or {})
    # Browser-wide setup precedes attachment to the fixture tab.
    if session:
        command['sessionId'] = session
    cdp.send(json.dumps(command))
    while True:
        message = json.loads(cdp.recv())
        # Retain runtime errors without URL query strings that may contain
        # tokens.
        if message.get('method') == 'Runtime.exceptionThrown':
            detail = message['params']['exceptionDetails']
            error = re.sub(r'\?[^\s]+', '?[redacted]',
                           detail.get('exception', {}).get('description', detail.get('text', 'JavaScript error')))
            # Direct module loads hit the page-relative service worker URL.
            if not ('Failed to register a ServiceWorker' in error and
                    base + '/server-manager/service-worker.js' in error and '404' in error):
                errors.append(error)
        # noVNC can report transport errors through the browser console too.
        if message.get('method') == 'Runtime.consoleAPICalled' and message['params']['type'] == 'error':
            errors.extend(re.sub(r'\?[^\s]+', '?[redacted]', str(arg.get('value', '')))
                          for arg in message['params'].get('args', []) if arg.get('type') == 'string')
        # Transport errors can precede the client's generic failure badge.
        if message.get('method') == 'Network.webSocketFrameError':
            errors.append(message['params']['errorMessage'])
        # Capture outgoing VNC or serial bytes for input assertions.
        if message.get('method') == 'Network.webSocketFrameSent':
            frame = message['params']['response']
            # Exclude status-channel text messages from guest input assertions.
            if frame['opcode'] == 2:
                data = base64.b64decode(frame['payloadData'])
                sent_binary.append(data)
                sent_by_socket.setdefault(message['params']['requestId'], []).append(data)
        # Ignore event messages until this command's numbered reply arrives.
        if message.get('id') == serial:
            # A rejected CDP command cannot count as a completed browser action.
            if 'error' in message:
                raise RuntimeError(message['error']['message'])
            return message.get('result', {})


# evaluate(expression, [gesture]) returns results without logging form data.
# gesture requests browser user activation for actions such as fullscreen.
def evaluate(expression, gesture=False):
    # A frame-based theme renders the module inside its right-hand frame.
    if in_frame:
        expression = 'window.frames.right.eval(' + json.dumps(expression) + ')'
    reply = call('Runtime.evaluate', dict(expression=expression, returnByValue=True,
                                         awaitPromise=True, userGesture=gesture))
    # Keep the expression and its possible form values out of diagnostics.
    if reply.get('exceptionDetails'):
        raise RuntimeError('Browser evaluation failed')
    return reply.get('result', {}).get('value')


# wait_for(expression, label, [seconds]) waits up to 30 seconds for page state.
def wait_for(expression, label, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        # Proceed only once the actual document satisfies the condition.
        if evaluate(expression):
            return
        time.sleep(.1)
    raise AssertionError(label)


# wait_saved_zoom(value, [preference]) allows ten seconds for the theme's save
# timer; preference defaults to graphical console_zoom.
def wait_saved_zoom(value, preference='console_zoom'):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        evaluate('true')
        # Check the server file, not only the page's in-memory value.
        if saved_zoom('cloudmin-ui-check', preference) == value:
            return
        time.sleep(.1)
    raise AssertionError('Console zoom was not saved on the server')


# click(selector) sends a real click, including user activation in the frame-based theme's frame.
def click(selector):
    # Wait for the new page when navigation is still in progress.
    wait_for('!!document.querySelector(' + json.dumps(selector) + ')',
             'Click target missing: ' + selector)
    point = evaluate("""(() => {
      const button = document.querySelector(%s);
      button.scrollIntoView({block: 'nearest'});
      const rect = button.getBoundingClientRect();
      const frame = window.frameElement?.getBoundingClientRect();
      return {x: rect.left + rect.width / 2 + (frame?.left || 0),
              y: rect.top + rect.height / 2 + (frame?.top || 0)};
    })()""" % json.dumps(selector))
    for event in ('mousePressed', 'mouseReleased'):
        call('Input.dispatchMouseEvent', dict(type=event, button='left', clickCount=1, **point))


try:
    # Both architectures need interactive UEFI firmware for keyboard assertions.
    arch = conn.getInfo()[0]
    machine = 'virt' if arch == 'aarch64' else 'q35'
    osxml = (f'<os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type>'
             '<firmware><feature enabled="no" name="secure-boot"/>'
             '<feature enabled="no" name="enrolled-keys"/></firmware>'
             '<loader stateless="no"/></os>')
    xml = f'''<domain type="kvm"><name>{name}</name><uuid>{identifier}</uuid>
      <memory unit="MiB">256</memory><vcpu>1</vcpu><cpu mode="host-passthrough"/>{osxml}
      <features><acpi/></features>
      <devices><serial type="pty"/><console type="pty"/><graphics type="vnc" autoport="yes" listen="127.0.0.1" passwd="{secrets.token_hex(4)}"/>
      <video><model type="virtio"/></video><controller type="usb" model="qemu-xhci"/>
      <input type="keyboard" bus="usb"/><input type="tablet" bus="usb"/></devices></domain>'''
    guest = conn.defineXML(xml)
    guest.create()
    opener, jar, password = account('cloudmin-ui-check')
    restricted, restricted_jar, _ = account('cloudmin-frame-check', readonly=True)
    config = connect_config(opener)
    values = dict(id=identifier, token=config['token'])
    endpoint = config['endpoint']
    for override in ({'token':'invalid'}, {'id':'../guest'}, {'id':str(uuid.uuid4())}):
        result = json.loads(page(opener, endpoint, {**values, **override}))
        assert result.get('error') and not result.get('socket_url'), 'Invalid console request accepted'
    assert json.loads(page(opener, endpoint + '?' + urllib.parse.urlencode(values))).get('error'), 'GET opened a console'
    readonly_page = page(restricted, '/server-manager/remote_access.cgi?id=' + identifier)
    assert 'data-console-config' not in readonly_page, 'Read-only page includes an interactive client'
    # Require Cloudmin's read-only refusal, not a generic module-access rejection.
    assert re.search(r'read-only', readonly_page), 'Read-only denial missing'
    # Tokens are user-bound; a read-only account cannot borrow another user's token.
    denied = page(restricted, endpoint, values)
    assert 'socket_url' not in denied and re.search(r'read.?only|permission|not allowed', denied, re.I), 'Read-only POST accepted'
    print('PASS: signed POST, invalid UUID, missing guest and read-only access checks', flush=True)

    url = route(opener, config)
    cookie = '; '.join(c.name + '=' + c.value for c in jar)
    reject_socket(url, origin=base)
    reject_socket(re.sub(r'token=[^&]+', 'token=invalid', url), cookie=cookie, origin=base)
    reject_socket(url, cookie=cookie, origin='https://untrusted.example')
    backend_port = int(re.search(r'/ws-(\d+)', url)[1])
    reject_socket('ws://127.0.0.1:' + str(backend_port), suppress_origin=True)
    sock = websocket.create_connection(url, cookie=cookie, origin=base,
                                       sslopt={'cert_reqs':ssl.CERT_NONE}, timeout=10)
    pending = bytearray()

    # receive(count) assembles VNC messages split across WebSocket frames.
    def receive(count):
        while len(pending) < count:
            data = sock.recv()
            assert isinstance(data, bytes) and data, 'Console closed during VNC handshake'
            pending.extend(data)
        data = bytes(pending[:count])
        del pending[:count]
        return data

    assert receive(12) == b'RFB 003.008\n'
    from relay_safety import check_relay
    relay_unit, _, _ = check_relay('console', backend_port)
    sock.send_binary(b'RFB 003.008\n')
    types = receive(receive(1)[0])
    assert types == b'\x01', 'Authorized libvirt socket unexpectedly requires a VNC password'
    sock.send_binary(b'\x01')
    assert receive(4) == b'\0\0\0\0'
    sock.send_binary(b'\x01')
    init = receive(24)
    width, height = struct.unpack('!HH', init[:4])
    assert width and height
    receive(struct.unpack('!I', init[20:24])[0])
    # A rejected second connection must leave the first console usable.
    reject_socket(url, cookie=cookie, origin=base)
    sock.send_binary(struct.pack('!BBHHHH',3,0,0,0,width,height))
    assert receive(1) == b'\x00', 'No framebuffer update from the guest'
    # Idle browsers answer protocol pings without sending guest keystrokes.
    # Keep this connection past the dead-peer deadline and parse every frame.
    sock.settimeout(1)
    deadline = time.monotonic() + 70
    pings = 0
    while time.monotonic() < deadline:
        try:
            opcode, _ = sock.recv_data_frame(True)
        except websocket.WebSocketTimeoutException:
            # Gaps between pings are expected; silence alone is not failure.
            continue
        assert opcode in (websocket.ABNF.OPCODE_BINARY, websocket.ABNF.OPCODE_PING), 'Unexpected console frame'
        pings += opcode == websocket.ABNF.OPCODE_PING
    assert pings >= 4, 'Idle console missed keepalive pings'
    sock.close()
    print('PASS: authenticated VNC framebuffer, rejected foreign connections and idle browser keepalive', flush=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        # Disconnect cleanup must remove the route allocated for this console.
        if 'websockets_/server-manager/ws-' + str(backend_port) + '=' not in Path('/etc/webmin/miniserv.conf').read_text():
            break
        time.sleep(.1)
    # A route still present at the deadline is a cleanup failure.
    else:
        raise AssertionError('Closed console left a proxy route')

    state = subprocess.run(['systemctl', 'is-active', relay_unit], capture_output=True, text=True).stdout.strip()
    assert state not in ('active', 'deactivating'), 'Console service survived disconnect'

    # A browser that never connects must release its service and private route.
    abandoned = route(opener, config)
    abandoned_port = re.search(r'/ws-(\d+)', abandoned)[1]
    # Identify this fixture's service without depending on other open consoles.
    abandoned_unit, _, _ = check_relay('console', abandoned_port)
    deadline = time.monotonic() + 75
    while time.monotonic() < deadline:
        if 'websockets_/server-manager/ws-' + abandoned_port + '=' not in Path('/etc/webmin/miniserv.conf').read_text():
            # The unconnected relay expired before this test's deadline.
            break
        time.sleep(1)
    else:
        # Retaining the route after expiry would leak a browser connection slot.
        raise AssertionError('Abandoned console left a proxy route')
    state = subprocess.run(['systemctl', 'is-active', abandoned_unit], capture_output=True, text=True).stdout.strip()
    assert state not in ('active', 'activating', 'deactivating'), 'Abandoned relay is still active'
    print('PASS: abandoned console expires and removes its service and route', flush=True)

    # A killed relay must also trigger the root supervisor's cleanup.
    crashed = route(opener, config)
    unit, pid, _ = check_relay('console', re.search(r'/ws-(\d+)', crashed)[1])
    os.kill(int(pid), signal.SIGKILL)
    crashed_port = re.search(r'/ws-(\d+)', crashed)[1]
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if 'websockets_/server-manager/ws-' + crashed_port + '=' not in Path('/etc/webmin/miniserv.conf').read_text():
            # The surviving supervisor noticed relay death and removed the route.
            break
        time.sleep(.2)
    else:
        # A killed relay must not leave a usable or stale route behind.
        raise AssertionError('Crashed console left a proxy route')
    print('PASS: relay crash removes its proxy route', flush=True)

    # Serial shares the console endpoint but needs exclusive port access.
    if options.serial_console:
        # Invalid tokens, unknown modes and read-only users must get no route.
        serial_config = connect_config(opener, 'serial')
        serial_values = dict(id=identifier, token=serial_config['token'], mode='serial')
        for override in ({'token': 'invalid'}, {'mode': 'serial;id'}):
            result = json.loads(page(opener, endpoint, {**serial_values, **override}))
            assert result.get('error') and not result.get('socket_url'), 'Invalid serial request accepted'
        denied = page(restricted, endpoint, serial_values)
        assert 'socket_url' not in denied and 'read-only' in denied, 'Read-only serial POST accepted'
        # Exercise the real stream through the isolated WebSocket relay.
        serial_url = route(opener, serial_config)
        serial_sock = websocket.create_connection(serial_url, cookie=cookie, origin=base,
            sslopt={'cert_reqs': ssl.CERT_NONE}, timeout=20)
        check_relay('console', re.search(r'/ws-(\d+)', serial_url)[1])
        # Libvirt refuses a second attachment, without forcing this one closed.
        busy = json.loads(page(opener, endpoint, serial_values))
        assert busy.get('error') and not busy.get('socket_url'), 'Serial port was taken over'
        # Reset only the diskless fixture to produce fresh firmware output.
        guest.reset(0)
        boot = serial_sock.recv()
        # Consume the replay prefix before asserting firmware output. This
        # externally defined fixture has no managed recording to replay.
        while len(boot) < 4:
            boot += serial_sock.recv()
        assert struct.unpack('!I', boot[:4])[0] == 0, 'Unrecorded fixture unexpectedly has history'
        boot = boot[4:] or serial_sock.recv()
        assert isinstance(boot, bytes) and boot, 'No real firmware output on serial console'
        serial_sock.send_binary(b'\r')
        serial_sock.close()
        # wait_serial_closed(url, [seconds]) waits for proxy route removal.
        # seconds defaults to 15; later reopen checks prove the port is free.
        def wait_serial_closed(url, seconds=15):
            port = re.search(r'/ws-(\d+)', url)[1]
            deadline = time.monotonic() + seconds
            while 'websockets_/server-manager/ws-' + port + '=' in Path('/etc/webmin/miniserv.conf').read_text():
                if time.monotonic() > deadline:
                    # A lingering route means disconnect cleanup did not finish.
                    raise AssertionError('Closed serial console left a proxy route')
                time.sleep(.2)
        # Finish normal disconnect cleanup before testing abandoned startup.
        wait_serial_closed(serial_url)
        # A cancelled page may never open its WebSocket after reserving the port.
        abandoned_serial = route(opener, serial_config)
        abandoned_started = time.monotonic()
        busy = json.loads(page(opener, endpoint, serial_values))
        assert busy.get('error') and not busy.get('socket_url'), 'Reserved serial port was taken over'
        wait_serial_closed(abandoned_serial, 25)
        assert time.monotonic() - abandoned_started < 25, 'Abandoned serial startup retained its port'

        # Keep TCP open but never read frames or answer pings, as after network loss.
        silent_url = route(opener, serial_config)
        silent = websocket.create_connection(silent_url, cookie=cookie, origin=base,
            sslopt={'cert_reqs': ssl.CERT_NONE}, timeout=20)
        try:
            port = re.search(r'/ws-(\d+)', silent_url)[1]
            deadline = time.monotonic() + 75
            while 'websockets_/server-manager/ws-' + port + '=' in Path('/etc/webmin/miniserv.conf').read_text():
                assert time.monotonic() < deadline, 'Unresponsive browser kept its serial port'
                time.sleep(.2)
        finally:
            # Release the fixture's TCP socket even if server cleanup fails.
            silent.close()
        # A fresh connection must succeed after the silent browser expires.
        reopened_url = route(opener, serial_config)
        reopened = websocket.create_connection(reopened_url, cookie=cookie, origin=base,
            sslopt={'cert_reqs': ssl.CERT_NONE}, timeout=20)
        reopened.close()
        wait_serial_closed(reopened_url)
        print('PASS: serial exclusivity, abandoned startup, dead browser expiry and immediate reuse after cleanup', flush=True)

    if options.protocol_only:
        # Skip browser checks while still running the enclosing fixture cleanup.
        print('PASS: console service and proxy route removed after disconnect', flush=True)
        sys.exit(0)

    # Run noVNC in the selected theme, using a fresh VM-only browser profile.
    profile = tempfile.TemporaryDirectory(prefix='cloudmin-console-browser-')
    chrome = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
        '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
        '--no-default-browser-check', '--disable-background-networking', '--disable-sync',
        '--screen-info={1920x1200}', '--window-size=1400,1100',
        '--user-data-dir=' + profile.name, 'about:blank'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    active = Path(profile.name) / 'DevToolsActivePort'
    deadline = time.monotonic() + 30
    while not active.exists() and chrome.poll() is None and time.monotonic() < deadline:
        time.sleep(.1)
    port, path = active.read_text().splitlines()
    cdp = websocket.create_connection('ws://127.0.0.1:' + port + path, timeout=15, suppress_origin=True)
    target = call('Target.createTarget', dict(url='about:blank'))['targetId']
    session = call('Target.attachToTarget', dict(targetId=target, flatten=True))['sessionId']
    for domain in ('Page', 'Runtime', 'Network'):
        call(domain + '.enable')
    # Exercise macOS shortcuts using browser-reported OS information.
    if options.platform == 'mac':
        call('Emulation.setUserAgentOverride', dict(
            userAgent=evaluate('navigator.userAgent'), platform='MacIntel',
            userAgentMetadata=dict(platform='macOS', platformVersion='14.0.0',
                                   architecture='arm', model='', mobile=False)))
    call('Page.navigate', dict(url=base + '/session_login.cgi'))
    wait_for('!!document.querySelector("input[name=user]")', 'Login form missing')
    evaluate('''(() => {
      document.querySelector('[name=user]').value = 'cloudmin-ui-check';
      document.querySelector('[name=pass]').value = %s;
      document.querySelector('[name=user]').form.submit();
    })()''' % json.dumps(password))
    # check_live_status() verifies pushed health and suspend/resume changes.
    def check_live_status():
        wait_for('document.querySelector("#cloudmin-vm-status")?.dataset.power === "running"', 'Live power status missing')
        # Health arrives after the inventory snapshot, once the shared probe has run.
        wait_for('document.querySelector("[data-vm-field=agent]").textContent === "Not responding or not installed"',
                 'Diskless guest invents agent readiness')
        assert evaluate('document.querySelector("[data-vm-field=ssh]").textContent') == 'No IP address reported', 'Diskless guest invents SSH readiness'
        guest.suspend()
        wait_for('document.querySelector("#cloudmin-vm-status")?.dataset.power === "paused"', 'Power status did not refresh after suspend')
        guest.resume()
        wait_for('document.querySelector("#cloudmin-vm-status")?.dataset.power === "running"', 'Power status did not refresh after resume')
        print('PASS: live power/agent/SSH status and automatic suspend/resume updates', flush=True)
    console_link = 'a[href="/server-manager/remote_access.cgi?id=' + identifier.replace('-', '%2D') + '"]'
    # Frame navigation changes the left and right panes separately.
    if not spa:
        wait_for('!!window.frames.right && !!window.frames.left', 'Frame-based frames missing')
        evaluate('window.frames.left.location = ' + json.dumps(base + '/left.cgi?mode=server-manager&sid=' + identifier))
        wait_for('!!window.frames.left.document.querySelector(' + json.dumps(console_link) + ')', 'Frame-based guest menu missing')
        evaluate('window.frames.right.location = ' + json.dumps(base + '/server-manager/machine.cgi?id=' + identifier))
        in_frame = True
        wait_for('document.title.includes("Virtual Machine Details")', 'Frame-based guest page missing')
        check_live_status()
        wait_for('!!parent.frames.left.document.querySelector(' + json.dumps(console_link) + ')', 'Frame-based console link missing')
        evaluate('parent.frames.left.document.querySelector(' + json.dumps(console_link) + ').click()')
    # Select the guest through the sidebar's navigation handlers.
    else:
        wait_for('!!document.querySelector(\'a[href="/server-manager/index.cgi"]\')', 'Cloudmin menu missing')
        # Use the real guest selector, then the resulting sidebar link.
        wait_for('!!jQuery(\'aside select[name="sid"]\').data("select2")', 'Guest selector missing')
        evaluate('void jQuery(\'aside select[name="sid"]\').val(' + json.dumps(identifier) + ').trigger("change").trigger("select2:select")')
        wait_for('document.title.includes("Virtual Machine Details")', "Guest selection did not finish loading")
        check_live_status()
        console_link = 'a[href="/server-manager/remote_access.cgi?id=' + identifier.replace('-', '%2D') + '"]'
        wait_for('!!document.querySelector(' + json.dumps(console_link) + ')', 'Guest console link missing')
        evaluate('document.querySelector(' + json.dumps(console_link) + ').click()')
    connected = 'document.querySelector("[data-console-status]")?.textContent.trim() === "Connected"'
    # The page wraps the standard tab widget in navigation markup.
    if spa:
        wait_for('document.querySelectorAll(".panel-body > .nav.nav-tabs .vm-console-tab-label").length === 3',
                 'Standard console tabs missing')
    click('a:has(.vm-console-tab-label)[href*="tab=graphical"]')
    wait_for(connected, 'Graphical console did not connect')
    assert evaluate('new URL(location.href).searchParams.get("tab")') == 'graphical', 'Selected tab missing from URL'
    # SPA links retain the navigation flag even when their requests omit it.
    if spa:
        assert evaluate('new URL(location.href).searchParams.get("xnavigation")') == '1', 'Tab navigation lost xnavigation'
    # Serial shares the page, but must keep its renderer and raw byte stream.
    if options.serial_console:
        # Mode navigation must replace VNC with xterm without submitting input.
        sent_binary.clear()
        sent_by_socket.clear()
        click('a:has(.vm-console-tab-label)[href*="tab=serial"]')
        wait_for('document.querySelector("#cloudmin-console")?.dataset.consoleMode === "serial" && (' + connected + ')',
                 'Serial page did not connect')
        wait_for('!!document.querySelector(".xterm-helper-textarea")', 'Serial renderer missing')
        assert evaluate('new URL(location.href).searchParams.get("tab")') == 'serial', 'Serial tab missing from URL'
        assert not evaluate('!!document.querySelector("[data-console-screen] [data-console-display]")'), 'Serial uses VNC renderer'
        assert evaluate('document.querySelector("[data-console-keyboard]").hidden'), 'Serial shows VNC-only shortcuts'
        # Ignore final VNC packets sent while the previous tab disconnects.
        assert not any(b'\r' in data for data in sent_by_socket.values()), 'Serial attachment sent Enter'
        assert not evaluate('document.body.textContent.includes("Press Enter to show the login prompt")'), 'Serial hint remains visible'
        # Pause firmware output to avoid filling xterm's buffer while
        # JavaScript is disabled during the idle-connection check.
        guest.suspend()
        time.sleep(.5)
        # Pausing JavaScript must not stop native WebSocket pong replies.
        # Page freezing also enters Chromium's back/forward cache, which closes
        # sockets intentionally and cannot test an idle background connection.
        call('Emulation.setScriptExecutionDisabled', {'value': True})
        try:
            time.sleep(65)
            probe = conn.newStream(0)
            try:
                # The existing browser must still own the exclusive serial port.
                try:
                    guest.openConsole(None, probe, libvirt.VIR_DOMAIN_CONSOLE_SAFE)
                except libvirt.libvirtError as error:
                    # Only the busy-port error proves ownership.
                    assert 'Active console session exists' in str(error), 'Unexpected serial probe failure'
                else:
                    # A successful probe means the idle browser lost its port.
                    raise AssertionError('Idle browser lost its serial connection')
            finally:
                # Release the probe even if it unexpectedly took the port.
                probe.abort()
        finally:
            # Restore both the page and the fixture guest after a failed check.
            call('Emulation.setScriptExecutionDisabled', {'value': False})
            guest.resume()
        time.sleep(.5)
        wait_for(connected, 'Background serial console lost its connection')
        # Native tabs keep their icon labels aligned in both themes.
        assert evaluate('''(() => {
          const labels = [...document.querySelectorAll('.vm-console-tab-label')];
          const boxes = labels.map(label => label.getBoundingClientRect());
          return boxes.length === 3 && Math.abs(boxes[0].top - boxes[1].top) < 1 &&
            Math.abs(boxes[0].height - boxes[1].height) < 1;
        })()'''), 'Console tab labels are not aligned'
        # Capture a keystroke at the actual browser WebSocket boundary.
        sent_binary.clear()
        evaluate('document.querySelector(".xterm-helper-textarea").focus()')
        call('Input.dispatchKeyEvent', dict(type='keyDown', key='Enter', code='Enter', windowsVirtualKeyCode=13, text='\r'))
        call('Input.dispatchKeyEvent', dict(type='keyUp', key='Enter', code='Enter', windowsVirtualKeyCode=13))
        assert b'\r' in sent_binary, 'Serial Enter did not send raw input'
        # Resizing xterm must not inject SSH resize messages into a serial port.
        sent_binary.clear()
        call('Emulation.setDeviceMetricsOverride', dict(width=1100, height=900, deviceScaleFactor=1, mobile=False))
        time.sleep(.3)
        evaluate('true')
        assert not sent_binary, 'Serial resize injected guest input'
        call('Emulation.clearDeviceMetricsOverride')
        # Serial text size is stored per account, separately from the other tabs.
        if spa:
            initial_font = evaluate('Number(document.getElementById("cloudmin-console").dataset.consoleFontSize)')
            other_fonts = evaluate('[config_portable_module_xterm_font_size, config_portable_module_cloudmin_console_zoom]')

            # serial_zoom(key) sends =, - or 0 with the platform's zoom modifier.
            # Assert that the shortcut never becomes serial input.
            def serial_zoom(key):
                code, number = {'=': ('Equal', 187), '-': ('Minus', 189), '0': ('Digit0', 48)}[key]
                evaluate('document.querySelector(".xterm-helper-textarea").focus()')
                for kind in ('keyDown', 'keyUp'):
                    call('Input.dispatchKeyEvent', dict(type=kind, key=key, code=code,
                         windowsVirtualKeyCode=number, modifiers=4 if options.platform == 'mac' else 2))
                assert not sent_binary, 'Serial zoom injected guest input'

            # Navigate without waiting for the save; wait for each new renderer
            # so the test cannot start overlapping connection requests.
            serial_zoom('=')
            click('a:has(.vm-console-tab-label)[href*="tab=graphical"]')
            wait_for('document.querySelector("#cloudmin-console")?.dataset.consoleMode === "graphical" && (' + connected + ')',
                     'Graphical console did not reconnect')
            click('a:has(.vm-console-tab-label)[href*="tab=serial"]')
            wait_for('document.querySelector("#cloudmin-console")?.dataset.consoleMode === "serial" && (' + connected + ')',
                     'Serial did not reconnect after zoom')

            # check_serial_size(size) checks the saved value and actual rendered
            # font after discarding page state with a full reload.
            def check_serial_size(size):
                wait_saved_zoom(size, 'serial_font_size')
                # A full reload must read the server preference, not page memory.
                evaluate('window.consoleReloadPending = true')
                call('Page.reload', dict(ignoreCache=True))
                wait_for('!window.consoleReloadPending && (' + connected + ')',
                         'Serial did not reconnect after reload')
                wait_for('Number(document.querySelector("#cloudmin-console")?.dataset.consoleFontSize) === ' + str(size),
                         'Serial font size was not restored')
                assert evaluate('parseFloat(getComputedStyle(document.querySelector(".xterm-rows")).fontSize)') == size, \
                    'Rendered serial text does not use the saved size'
                # Font changes must not overwrite SSH or graphical preferences.
                assert evaluate('[config_portable_module_xterm_font_size, config_portable_module_cloudmin_console_zoom]') == other_fonts, \
                    'Serial zoom changed SSH or graphical preferences'
                sent_binary.clear()

            # Check a larger size, a smaller size, and the configured reset value.
            wait_for('Number(document.querySelector("#cloudmin-console")?.dataset.consoleFontSize) === ' + str(initial_font + 1),
                     'Serial tab reopen did not restore font size')
            check_serial_size(initial_font + 1)
            serial_zoom('-')
            serial_zoom('-')
            check_serial_size(initial_font - 1)
            serial_zoom('0')
            check_serial_size(initial_font)
            print('PASS: serial zoom saved per account, tab return, full reload and reset', flush=True)
        # Allow UI delivery after the supervisor's five-second access check.
        subprocess.run(['perl', str(helper), 'acl', theme, 'cloudmin-ui-check'],
            input=json.dumps(dict(admin=0, vms=identifier, console=0)), text=True, check=True)
        wait_for('!document.querySelector("[data-console-status]") || !(' + connected + ')',
                 'Revoked serial console remained connected', seconds=15)
        # Revocation can reload the page. Wait for its new document before
        # restoring access and inserting a navigation link.
        wait_for('document.readyState === "complete" && !!document.body',
                 'Revoked console page did not finish loading')
        subprocess.run(['perl', str(helper), 'acl', theme, 'cloudmin-ui-check'],
            input=json.dumps(dict(admin=1)), text=True, check=True)
        # Reopen through the same page, then return to the graphical display.
        evaluate('''(() => {const link=document.createElement('a');
          link.href=''' + json.dumps(base + '/server-manager/remote_access.cgi?id=' + identifier + '&tab=serial') + ''';
          document.body.append(link); link.click(); link.remove();})()''')
        wait_for('document.querySelector("#cloudmin-console")?.dataset.consoleMode === "serial" && (' + connected + ')',
                 'Serial page failed to reopen')
        # A stopped guest must retain serial mode and reconnect after starting.
        guest.destroy()
        wait_for('!(' + connected + ')', 'Stopped guest still shows serial connected')
        evaluate('location.reload()')
        wait_for('JSON.parse(document.querySelector("#cloudmin-vm-status")?.dataset.config || "{}").reopen === "serial"',
                 'Stopped serial page lost its selected mode')
        guest.create()
        wait_for('document.querySelector("#cloudmin-console")?.dataset.consoleMode === "serial" && (' + connected + ')',
                 'Serial page did not reopen after start')
        # Switching back must start VNC again without browser exceptions.
        click('a:has(.vm-console-tab-label)[href*="tab=graphical"]')
        wait_for('document.querySelector("#cloudmin-console")?.dataset.consoleMode === "graphical" && (' + connected + ')',
                 'Graphical page did not reconnect after serial')
        assert not errors, 'Serial console raised browser errors'
        print('PASS: graphical/serial switch, xterm input, resize without input and live revocation', flush=True)

    # The theme moves controls only after the client has captured their nodes.
    placement = """(() => {
      const status = document.querySelector('[data-console-status]');
      const bounds = status.getBoundingClientRect();
      const keyboard = document.querySelector('[data-console-action=keys]').getBoundingClientRect();
      const fullscreen = document.querySelector('[data-console-action=fullscreen]').getBoundingClientRect();
      const screen = document.querySelector('[data-console-screen]').getBoundingClientRect();
      const badge = status.querySelector('.ui_badge_success.ui_badge_small');
      const style = badge && getComputedStyle(badge);
      // The connection badge must remain visible above the guest screen.
      if (style?.display !== 'inline-flex' || parseFloat(style.borderRadius) <= 10 ||
          style.backgroundColor === 'rgba(0, 0, 0, 0)' || bounds.bottom >= screen.top) return false;
      const header = document.querySelector('.panel-heading');
      // Check the console controls mounted in the page header.
      if (header) {
        const help = document.querySelector('.panel-heading a[href*="help.cgi"]').getBoundingClientRect();
        return !!status.closest('[data-sub_title]') &&
               header.contains(document.querySelector('[data-console-keyboard]')) &&
               Math.abs(fullscreen.height - help.height) < 1 &&
               Math.abs(keyboard.height - help.height) < 1 &&
               Math.abs(fullscreen.width - help.width) < 1 &&
               Math.abs(keyboard.width - help.width) < 1 &&
               Math.abs(keyboard.top - help.top) < 1 &&
               keyboard.right <= help.left + 2 &&
               document.querySelector('[data-console-toolbar]').getBoundingClientRect().height === 0;
      }
      return keyboard.left > bounds.right &&
             Math.abs(bounds.top + bounds.height / 2 - keyboard.top - keyboard.height / 2) < 2;
    })()"""
    wait_for(placement, 'Console controls are misplaced or differ from the Help button size')
    # The original toolbar is hidden before its relocation script runs.
    if spa:
        assert evaluate('''(() => {
          const toolbar = document.querySelector('[data-console-toolbar]');
          return !toolbar.hidden && getComputedStyle(toolbar).display === 'none';
        })()'''), 'Original toolbar must be hidden by CSS, without waiting for JavaScript'
    assert not evaluate('!!document.querySelector("[data-console-action=reconnect]")'), 'Reconnect button still exists'
    # The header Help popup must still work beside the relocated controls.
    if spa:
        click('.panel-heading a[href*="help.cgi"]')
        # Verify the open help's title and body without coupling to its prose.
        wait_for('document.querySelector(".popover.in .popover-title span")?.textContent.trim() === "Remote Access" && '
                 '!!document.querySelector(".popover.in .popover-content p")?.textContent.trim()', 'Help popup did not load')
        assert not evaluate('document.body.textContent.includes("Missing <header>")'), 'Help header missing'
        click('.popover .close-popover-trigger')
        wait_for('!document.querySelector(".popover.in")', 'Help popup did not close')
    wait_for('document.querySelector("[data-console-screen] canvas")?.width > 0', 'noVNC canvas missing')
    wait_for('''(() => {
      const c = document.querySelector('[data-console-screen] canvas');
      return c && c.getContext('2d').getImageData(0, 0, c.width, c.height).data.some((v,i) => i % 4 !== 3 && v > 32);
    })()''', 'Guest screen stayed blank')
    assert not evaluate('!!document.getElementById("noVNC_control_bar")'), 'Standalone noVNC UI loaded'
    # The client and its dependencies must come from the Cloudmin package.
    assets = evaluate('performance.getEntriesByType("resource").map(entry => new URL(entry.name).pathname)')
    assert '/server-manager/console.js' in assets, 'Cloudmin console client was not loaded'
    assert '/server-manager/novnc/core/rfb.js' in assets, 'Cloudmin noVNC library was not loaded'
    assert not any('/' + theme + '/extensions/console/novnc/' in asset or
                   asset.endswith('/' + theme + '/extensions/console/console.js') for asset in assets), \
        'Console still loads its client from the theme'
    # The console fills the available height without a return button.
    page_filled = '''(() => {
      const content = document.getElementById('content');
      const bounds = content.getBoundingClientRect();
      const screen = document.querySelector('[data-console-screen]').getBoundingClientRect();
      return content.scrollHeight <= content.clientHeight + 1 &&
             !content.querySelector('.page-footer-actions a') &&
             screen.bottom <= bounds.bottom && bounds.bottom - screen.bottom < 50;
    })()'''
    # The module panel fills the viewport.
    if spa:
        wait_for(page_filled, 'Console does not fill the page below the tabs')
    # A second canvas frame after a key proves the browser is sending guest input.
    time.sleep(3)
    evaluate('document.querySelector("[data-console-screen] canvas").focus()')
    call('Input.dispatchKeyEvent', dict(type='keyDown', key='Escape', code='Escape', windowsVirtualKeyCode=27))
    call('Input.dispatchKeyEvent', dict(type='keyUp', key='Escape', code='Escape', windowsVirtualKeyCode=27))
    time.sleep(1)
    before = evaluate('document.querySelector("[data-console-screen] canvas").toDataURL()')
    call('Input.dispatchKeyEvent', dict(type='keyDown', key='ArrowDown', code='ArrowDown', windowsVirtualKeyCode=40))
    call('Input.dispatchKeyEvent', dict(type='keyUp', key='ArrowDown', code='ArrowDown', windowsVirtualKeyCode=40))
    time.sleep(1)
    after = evaluate('document.querySelector("[data-console-screen] canvas").toDataURL()')
    if before == after:
        # Some firmware opens an empty UEFI shell instead of a menu. Down has
        # no effect there; a printable character must still reach the guest.
        for kind in ('keyDown', 'keyUp'):
            call('Input.dispatchKeyEvent', dict(type=kind, key='x', code='KeyX', windowsVirtualKeyCode=88))
        time.sleep(1)
        after = evaluate('document.querySelector("[data-console-screen] canvas").toDataURL()')
    Path('/var/tmp/cloudmin-console-browser.png').write_bytes(base64.b64decode(call('Page.captureScreenshot')['data']))
    assert before != after, 'Guest display did not respond to keyboard input'
    print('PASS: real browser displays guest firmware and sends keyboard input', flush=True)

    # Test actual canvas scaling as the display grows and shrinks, not just the
    # fullscreen flag. A larger virtual monitor reproduces a real desktop.
    fitted = '''(() => {
      const viewport = document.querySelector('[data-console-screen]');
      const screen = viewport.getBoundingClientRect();
      const style = getComputedStyle(viewport);
      const padding = parseFloat(style.paddingLeft);
      const top = parseFloat(style.paddingTop);
      const width = screen.width - padding - parseFloat(style.paddingRight);
      const height = screen.height - top - parseFloat(style.paddingBottom);
      const canvas = document.querySelector('[data-console-screen] canvas');
      const rect = canvas.getBoundingClientRect();
      const scale = Math.min(width / canvas.width, height / canvas.height);
      return padding >= 6 && Math.abs(rect.width - canvas.width * scale) < 2 &&
             Math.abs(rect.height - canvas.height * scale) < 2 &&
             Math.abs(rect.left - screen.left - padding) < 1 &&
             Math.abs(rect.top - screen.top - top) < 1 &&
             rect.left >= screen.left - 1 && rect.right <= screen.right + 1 &&
             rect.top >= screen.top - 1 && rect.bottom <= screen.bottom + 1;
    })()'''
    wait_for(fitted, 'Initial canvas does not fit')
    # zoom_shortcut(key, code, number, [shift], [opposite], [focus]) sends keys.
    # number is the virtual key code; flags add Shift, invert the OS modifier,
    # or control canvas focus. Defaults are false, false and true respectively.
    def zoom_shortcut(key, code, number, shift=False, opposite=False, focus=True):
        mac = options.platform == 'mac'
        # The other OS modifier must remain guest input, not local zoom.
        if opposite:
            mac = not mac
        modifier = ('Meta', 'MetaLeft', 91, 4) if mac else ('Control', 'ControlLeft', 17, 2)
        # Leave header focus intact when testing shortcuts outside the canvas.
        if focus:
            evaluate('document.querySelector("[data-console-screen] canvas").focus({preventScroll:true})')
        call('Input.dispatchKeyEvent', dict(type='keyDown', key=modifier[0], code=modifier[1],
                                           windowsVirtualKeyCode=modifier[2], modifiers=modifier[3]))
        # Some layouts need Shift to type the plus key.
        if shift:
            call('Input.dispatchKeyEvent', dict(type='keyDown', key='Shift', code='ShiftLeft',
                                               windowsVirtualKeyCode=16, modifiers=modifier[3] | 8))
        for kind in ('keyDown', 'keyUp'):
            call('Input.dispatchKeyEvent', dict(type=kind, key=key, code=code,
                                               windowsVirtualKeyCode=number,
                                               modifiers=modifier[3] | (8 if shift else 0)))
        # Release Shift before releasing the platform modifier.
        if shift:
            call('Input.dispatchKeyEvent', dict(type='keyUp', key='Shift', code='ShiftLeft',
                                               windowsVirtualKeyCode=16, modifiers=modifier[3]))
        call('Input.dispatchKeyEvent', dict(type='keyUp', key=modifier[0], code=modifier[1],
                                           windowsVirtualKeyCode=modifier[2], modifiers=0))

    # Test zoom on the VNC wire too: shortcuts must not reach the guest, and
    # mouse coordinates must still match the framebuffer after scrolling.
    expected_modifier = 'metaKey' if options.platform == 'mac' else 'ctrlKey'
    # Verify the page's zoom shortcut uses the same OS modifier as the console client.
    if spa:
        assert evaluate('theme_modifier_control_key()') == expected_modifier, 'Wrong platform modifier'
    page_scale = evaluate('[devicePixelRatio, visualViewport.scale, innerWidth, innerHeight]')
    sent_binary.clear()
    for key, code, number, shift in [('=', 'Equal', 187, False), ('+', 'Equal', 187, True),
                                      ('+', 'NumpadAdd', 107, False), ('-', 'Minus', 189, False)]:
        zoom_shortcut(key, code, number, shift)
    wait_for('document.getElementById("cloudmin-console").dataset.consoleZoom === "120"',
             'Zoom shortcuts did not adjust the display in 10% steps')
    assert evaluate('[devicePixelRatio, visualViewport.scale, innerWidth, innerHeight]') == page_scale, \
        'Console shortcut zoomed the browser page'
    # Every modifier sent to the guest must be released; +, -, = stay local.
    held = set()
    for data in sent_binary:
        # Decode standard and extended VNC key events, ignoring other frames.
        if data and data[0] in (4, 255):
            size = 8 if data[0] == 4 else 12
            for offset in range(0, len(data), size):
                event = data[offset:offset + size]
                down = event[1] if size == 8 else struct.unpack('!H', event[2:4])[0]
                keysym = struct.unpack('!I', event[4:8])[0]
                assert keysym not in (ord('='), ord('+'), ord('-')), 'Zoom key reached the guest'
                # Track pressed keysyms until their matching release arrives.
                if down:
                    held.add(keysym)
                # Released keys must not remain held in the guest.
                else:
                    held.discard(keysym)
    assert not held, 'Zoom left a guest modifier held'
    # The other platform's modifier still belongs to the guest.
    zoom_shortcut('=', 'Equal', 187, opposite=True)
    assert evaluate('document.getElementById("cloudmin-console").dataset.consoleZoom') == '120', \
        'Wrong platform modifier changed the zoom'
    # Header focus leaves browser zoom alone; only the guest canvas zooms locally.
    evaluate('document.querySelector("[data-console-action=keys]").focus()')
    zoom_shortcut('=', 'Equal', 187, focus=False)
    assert evaluate('document.getElementById("cloudmin-console").dataset.consoleZoom') == '120', \
        'A shortcut outside the canvas changed console zoom'
    for attempt in range(4):
        zoom_shortcut('=', 'Equal', 187)
    wait_for('document.getElementById("cloudmin-console").dataset.consoleZoom === "160"',
             'Focused console did not reach 160% zoom')
    zoom_fitted = '''(() => {
      const v = document.querySelector('[data-console-screen]');
      const d = v.querySelector('[data-console-display]').getBoundingClientRect();
      const c = v.querySelector('canvas');
      const r = c.getBoundingClientRect();
      const style = getComputedStyle(v);
      const padding = parseFloat(style.paddingLeft);
      const top = parseFloat(style.paddingTop);
      const right = parseFloat(style.paddingRight);
      const bottom = parseFloat(style.paddingBottom);
      const factor = Math.min((v.clientWidth - padding - right) / c.width,
                              (v.clientHeight - top - bottom) / c.height) * 1.6;
      return Math.abs(r.width - c.width * factor) < 2 &&
             Math.abs(r.height - c.height * factor) < 2 &&
             Math.abs(d.width - r.width) < 1 && Math.abs(d.height - r.height) < 1 &&
             Math.abs(v.scrollWidth - Math.max(v.clientWidth, r.width + padding)) < 2 &&
             Math.abs(v.scrollHeight - Math.max(v.clientHeight, r.height + top)) < 2;
    })()'''
    for expanded in ((False, True, False) if evaluate('document.fullscreenEnabled') else (False,)):
        # Toggle fullscreen only when the current state differs from the case.
        if evaluate('!!document.fullscreenElement') != expanded:
            click('[data-console-action=fullscreen]')
        wait_for('!!document.fullscreenElement === ' + str(expanded).lower(), 'Zoom fullscreen failed')
        wait_for(zoom_fitted, 'Zoomed canvas did not resize with fullscreen')
        for edge in (0, 100000):
            evaluate('document.querySelector("[data-console-screen]").scrollTo(%d,%d)' % (edge, edge))
            # At the far scroll edge, require content without extra blank
            # margins.
            if edge:
                assert evaluate('''(() => {
                  const v = document.querySelector('[data-console-screen]');
                  const b = v.getBoundingClientRect(), r = v.querySelector('canvas').getBoundingClientRect();
                  return r.right <= b.left + v.clientWidth + 1 && r.bottom <= b.top + v.clientHeight + 1 &&
                         (!v.scrollLeft || Math.abs(r.right - b.left - v.clientWidth) < 2) &&
                         (!v.scrollTop || Math.abs(r.bottom - b.top - v.clientHeight) < 2);
                })()'''), 'Zoomed right/bottom edge is clipped or has a blank scrollable margin'
            point = evaluate('''(() => {
              const v = document.querySelector('[data-console-screen]');
              const b = v.getBoundingClientRect();
              const c = v.querySelector('canvas');
              const r = c.getBoundingClientRect();
              const x = Math.floor((Math.max(r.left, b.left + 8) + Math.min(r.right, b.right - 20)) / 2);
              const y = Math.floor((Math.max(r.top, b.top) + Math.min(r.bottom, b.bottom - 20)) / 2);
              return {x, y, guestX:Math.floor((x-r.left)*c.width/r.width),
                      guestY:Math.floor((y-r.top)*c.height/r.height), scroll:[v.scrollLeft,v.scrollTop]};
            })()''')
            sent_binary.clear()
            # CDP uses top-level coordinates even when the theme renders in a
            # frame.
            if in_frame:
                offset = evaluate('(() => { const r = parent.document.querySelector(\"frame[name=right]\").getBoundingClientRect(); return [r.x,r.y]; })()')
                point['x'] += offset[0]
                point['y'] += offset[1]
            for kind in ('mousePressed', 'mouseReleased'):
                call('Input.dispatchMouseEvent', dict(type=kind, x=point['x'], y=point['y'],
                                                      button='left', clickCount=1))
            evaluate('true')
            positions = [struct.unpack('!BBHH', data)[2:] for data in sent_binary
                         if len(data) == 6 and data[0] == 5 and data[1] == 1]
            # VNC uses integer pixels; fractional CSS sizes can round an edge
            # into the adjacent pixel without displacing the pointer.
            assert positions and all(abs(x-point['guestX']) <= 1 and abs(y-point['guestY']) <= 1
                                     for x, y in positions), ('Zoom or scrolling displaced guest clicks', positions, point)
            assert evaluate('''(() => {const v=document.querySelector('[data-console-screen]');
                return [v.scrollLeft,v.scrollTop];})()''') == point['scroll'], 'Focus moved the zoomed view'
    zoom_shortcut('0', 'Digit0', 48)
    wait_for(fitted, 'Reset shortcut did not restore the original fit')
    zoom_shortcut('-', 'Minus', 189)
    assert evaluate('document.getElementById("cloudmin-console").dataset.consoleZoom') == '90', 'Zoom out failed'
    zoom_shortcut('0', 'Digit0', 48)
    wait_for(fitted, 'Reset after zoom out failed')
    print('PASS: ' + options.platform + ' zoom shortcuts, guest key isolation, reset and mouse accuracy', flush=True)
    # Menus must stay inside the viewport, including fullscreen and narrow pages.
    menu_fits = '''(() => {
      const menu = document.getElementById('cloudmin-console-keys');
      const r = menu.getBoundingClientRect();
      const keys = document.querySelector('[data-console-action=keys]');
      return !menu.hidden && keys.getAttribute('aria-expanded') === 'true' &&
             getComputedStyle(menu.firstElementChild).textAlign === 'left' &&
             r.width > 100 && r.left >= 0 && r.right <= innerWidth && r.bottom <= innerHeight;
    })()'''
    click('[data-console-action=keys]')
    wait_for(menu_fits, 'Keyboard menu is not visible within the page')
    # Opening with the mouse must not leave a focus ring on the first menu item.
    assert evaluate('''[...document.querySelectorAll('[data-console-key]')].every(item => {
      const style = getComputedStyle(item);
      return style.outlineStyle === 'none' && style.boxShadow === 'none' &&
             parseFloat(style.borderTopWidth) === 0;
    })'''), 'Mouse-opened menu shows a focus ring or item border'
    hover = evaluate('''(() => {
      const r = document.querySelectorAll('[data-console-key]')[1].getBoundingClientRect();
      const frame = window.frameElement?.getBoundingClientRect();
      return {x:r.left+r.width/2+(frame?.left||0), y:r.top+r.height/2+(frame?.top||0)};
    })()''')
    call('Input.dispatchMouseEvent', dict(type='mouseMoved', **hover))
    assert evaluate('''(() => {
      const style = getComputedStyle(document.querySelectorAll('[data-console-key]')[1]);
      return style.outlineStyle === 'none' && style.boxShadow === 'none' &&
             style.backgroundColor !== 'rgba(0, 0, 0, 0)';
    })()'''), 'Menu hover must show a background without a focus ring'
    Path('/var/tmp/cloudmin-console-menu.png').write_bytes(base64.b64decode(call('Page.captureScreenshot')['data']))
    sent_binary.clear()
    for key, code, number in [('ArrowDown', 'ArrowDown', 40), ('End', 'End', 35),
                              ('Home', 'Home', 36), ('Escape', 'Escape', 27)]:
        call('Input.dispatchKeyEvent', dict(type='keyDown', key=key, code=code, windowsVirtualKeyCode=number))
        call('Input.dispatchKeyEvent', dict(type='keyUp', key=key, code=code, windowsVirtualKeyCode=number))
        # Navigation keys keep visible focus; Escape closes the menu instead.
        if key != 'Escape':
            assert evaluate("document.activeElement.matches('[data-console-key]:focus-visible') && parseFloat(getComputedStyle(document.activeElement).outlineWidth) >= 2"), 'Keyboard menu navigation has no visible focus outline'
    assert evaluate('document.getElementById("cloudmin-console-keys").hidden'), 'Escape left the menu open'
    assert evaluate('document.activeElement.dataset.consoleAction === "keys"'), 'Escape lost keyboard focus'
    assert not any(data and data[0] in (4, 255) for data in sent_binary), 'Menu navigation sent guest keystrokes'
    click('[data-console-action=keys]')
    click('[data-console-screen]')
    assert evaluate('document.getElementById("cloudmin-console-keys").hidden'), 'Outside click left the menu open'

    normal = evaluate('''(() => {
      const r = document.querySelector('[data-console-screen]').getBoundingClientRect();
      return [r.width, r.height];
    })()''')
    fullscreen_enabled = evaluate('document.fullscreenEnabled')
    # Repeat enter/exit cycles only where browser fullscreen is supported.
    if fullscreen_enabled:
        for attempt in range(3):
            click('[data-console-action=fullscreen]')
            wait_for('document.fullscreenElement?.id === "cloudmin-console"', 'Fullscreen did not open')
            wait_for(fitted, 'Fullscreen canvas does not fit')
            # Check that fullscreen restores the toolbar inside the console.
            if spa:
                wait_for('''(() => {
                  const rect = selector => document.querySelector(selector).getBoundingClientRect();
                  const toolbar = rect('[data-console-toolbar]');
                  const status = rect('[data-console-status]');
                  const full = rect('[data-console-action=fullscreen]');
                  const icon = rect('[data-console-action=fullscreen] svg');
                  const keys = rect('[data-console-action=keys]');
                  return Math.abs(status.left - toolbar.left) < 1 &&
                         Math.abs(keys.right - toolbar.right) < 1 &&
                         Math.abs(full.right - keys.left) <= 1 &&
                         Math.abs(full.top - keys.top) < 1 &&
                         Math.abs(full.width - keys.width) < 1 &&
                         Math.abs(full.height - keys.height) < 1 &&
                         Math.abs(full.top + full.height / 2 - icon.top - icon.height / 2) < 1;
                })()''', 'Fullscreen icons must be joined, equally sized and centered')
            click('[data-console-action=keys]')
            wait_for(menu_fits, 'Fullscreen keyboard menu is clipped')
            if attempt == 1:
                # Browser-initiated exit must resize too, without clicking our button.
                evaluate('document.exitFullscreen()')
            # Other cycles exercise the module button as the exit path.
            else:
                click('[data-console-action=fullscreen]')
            wait_for('!document.fullscreenElement', 'Fullscreen did not close')
            wait_for(fitted, 'Canvas did not resize after leaving fullscreen')
            wait_for('''(() => {
              const r = document.querySelector('[data-console-screen]').getBoundingClientRect();
              return Math.abs(r.width - %s) < 2 && Math.abs(r.height - %s) < 2;
            })()''' % tuple(normal), 'Normal viewport size was not restored')
            # Leaving fullscreen must return the controls to the page header.
            if spa:
                wait_for(page_filled, 'Page height was not restored after fullscreen')
                wait_for(placement, 'Header controls were not restored after fullscreen')
    # Browsers that forbid fullscreen must not show an unusable button.
    else:
        assert evaluate('document.querySelector("[data-console-action=fullscreen]").hidden'), 'Unavailable fullscreen control is visible'
    # Changing the window after fullscreen must fit both wide and narrow pages.
    window = call('Browser.getWindowForTarget', dict(targetId=target))
    for width, height in ((1000, 750), (600, 650), (1920, 1200), (1400, 1100)):
        call('Browser.setWindowBounds', dict(windowId=window['windowId'],
             bounds=dict(width=width, height=height)))
        wait_for('window.outerWidth === %d && window.outerHeight === %d' % (width, height),
                 'Browser window size did not change')
        wait_for(fitted, 'Canvas did not fit the resized browser window')
        click('[data-console-action=keys]')
        wait_for(menu_fits, 'Keyboard menu is clipped after resizing')
        click('[data-console-action=keys]')
        # Resizing must preserve the available panel height.
        if spa:
            wait_for(page_filled, 'Console does not fill the resized page')
    # Check every shortcut on the wire, including reverse-order key releases.
    symbols = {'ControlLeft':(0xffe3,0x1d), 'AltLeft':(0xffe9,0x38),
               'Delete':(0xffff,0xd3), 'Backspace':(0xff08,0x0e), 'End':(0xff57,0xcf),
               'Tab':(0xff09,0x0f), 'Enter':(0xff0d,0x1c), 'Escape':(0xff1b,0x01),
               'PrintScreen':(0xff61,0x54), 'Pause':(0xff13,0xc6)}
    for n, scan in enumerate([*range(0x3b,0x45),0x57,0x58],1):
        symbols['F'+str(n)] = (0xffbd+n,scan)
    shortcuts = evaluate('[...document.querySelectorAll("[data-console-key]")].map(e=>e.dataset.consoleKey)')
    assert len(shortcuts) == 22, 'Keyboard menu is missing shortcuts'
    for shortcut in shortcuts:
        click('[data-console-action=keys]')
        selector = '[data-console-key="' + shortcut + '"]'
        sent_binary.clear()
        click(selector)
        key_events = [(symbols[code][0], symbols[code][1], down)
                      for down, codes in ((1,shortcut.split()),(0,list(reversed(shortcut.split()))))
                      for code in codes]
        expected_keys = [
            b''.join(struct.pack('!BBHI',4,down,0,key) for key,code,down in key_events),
            b''.join(struct.pack('!BBHII',255,0,down,key,code) for key,code,down in key_events)
        ]
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            evaluate('true')
            # Accept either negotiated VNC key encoding, with every release
            # present.
            if any(sequence in b''.join(sent_binary) for sequence in expected_keys):
                break
            time.sleep(.1)
        # No complete sequence by the deadline means guest input was lost.
        else:
            raise AssertionError('Incomplete key presses or releases: ' + shortcut)
        assert evaluate('document.getElementById("cloudmin-console-keys").hidden'), 'Selection left the menu open'
        assert evaluate('document.activeElement.tagName === "CANVAS"'), 'Shortcut did not restore guest focus'
    print('PASS: menu placement, keyboard navigation, dismissal and all 22 guest shortcuts', flush=True)

    navigation = 'parent.frames.left.document' if in_frame else 'document'
    # reopen() uses the shared sidebar link, then selects Graphical console.
    def reopen():
        evaluate('document.getElementById("cloudmin-console")?.setAttribute("data-test-old", "1")')
        evaluate(navigation + '.querySelector(' + json.dumps(console_link) + ').click()')
        wait_for('!document.querySelector("#cloudmin-console[data-test-old]")', 'Sidebar did not replace the console')
        click('a:has(.vm-console-tab-label)[href*="tab=graphical"]')

    # Only the SPA theme persists zoom preferences on the host.
    if spa:
        # reload_console() waits for a new document and its live VNC connection.
        def reload_console():
            evaluate('window.consoleReloadPending = true')
            call('Page.reload', dict(ignoreCache=True))
            wait_for('!window.consoleReloadPending && (' + connected + ')',
                     'Console did not reconnect after full reload')

        other_zoom = saved_zoom('cloudmin-frame-check')
        zoom_shortcut('=', 'Equal', 187)
        # Navigate immediately; the theme's debounce must survive page replacement.
        reopen()
        wait_for(connected, 'Saved-zoom console did not reconnect')
        wait_for('document.getElementById("cloudmin-console").dataset.consoleZoom === "110"',
                 'Sidebar reopen did not restore zoom')
        wait_saved_zoom(110)
        # Reload discards all JavaScript state and reads the server's preference.
        reload_console()
        wait_for('document.getElementById("cloudmin-console").dataset.consoleZoom === "110"',
                 'Full reload did not restore server-side zoom')
        assert evaluate('Number(config_portable_module_cloudmin_console_zoom)') == 110
        assert saved_zoom('cloudmin-frame-check') == other_zoom, 'Zoom changed another user preference'
        for attempt in range(5):
            zoom_shortcut('=', 'Equal', 187)
        wait_saved_zoom(160)
        reload_console()
        wait_for(zoom_fitted, 'Saved 160% zoom has incorrect image or scroll bounds on initial load')
        wait_for(page_filled, 'Initial load with saved zoom does not fill the page')
        zoom_shortcut('0', 'Digit0', 48)
        wait_saved_zoom(100)
        reload_console()
        wait_for(fitted, 'Reset did not persist after full reload')
        print('PASS: per-user server-side zoom, immediate reopen, full reload and saved reset', flush=True)

    for attempt in range(2):
        reopen()
        wait_for(connected, 'Sidebar reconnect failed')
        wait_for(placement, 'Reopened console header controls missing')
        evaluate(navigation + '.querySelector(\'a[href="/server-manager/index.cgi"]\').click()')
        wait_for('!document.getElementById("cloudmin-console")', 'Console not removed on navigation')
        assert not evaluate('!!document.querySelector("[data-console-status], [data-console-keyboard]")'), 'Console controls left behind on navigation'
        evaluate(navigation + '.querySelector(' + json.dumps(console_link) + ').click()')
        click('a:has(.vm-console-tab-label)[href*="tab=graphical"]')
        wait_for(connected, 'Sidebar return did not reconnect')
    assert not errors, 'Browser raised JavaScript errors'
    print('PASS: Help, sidebar reconnect and repeated ' + theme + ' navigation', flush=True)
    guest.destroy()
    wait_for('document.querySelector("[data-console-status]")?.textContent.trim() !== "Connected"', 'Stopped guest still shows Connected')
    assert evaluate('document.querySelector("[data-console-action=keys]").disabled'), 'Stopped guest has an active keyboard menu'
    reopen()
    wait_for('document.body.textContent.includes("Start the virtual machine")', 'Stopped guest error missing')
    guest.create()
    # The unavailable page should reopen itself as soon as the guest starts.
    wait_for(connected, 'Stopped console warning did not reopen automatically')
    assert not errors, 'Guest restart raised JavaScript errors'
    print('PASS: guest power-off, useful error and connection after restart', flush=True)
    if not spa:
        # Chrome disables fullscreen in legacy <frame> documents. The same
        # console must support it when opened as a normal page.
        in_frame = False
        call('Page.navigate', dict(url=base + '/server-manager/remote_access.cgi?id=' + identifier + '&tab=graphical',
                                   referrer=base + '/server-manager/index.cgi'))
        wait_for(connected, 'Standalone frame-based console did not connect')
        wait_for(fitted, 'Standalone frame-based canvas does not fit')
        assert evaluate('document.fullscreenEnabled'), 'Standalone fullscreen unavailable'
        click('[data-console-action=fullscreen]')
        wait_for('document.fullscreenElement?.id === "cloudmin-console"', 'Standalone fullscreen did not open')
        wait_for(fitted, 'Standalone fullscreen canvas does not fit')
        evaluate('document.exitFullscreen()')
        wait_for('!document.fullscreenElement', 'Standalone fullscreen did not close')
        wait_for(fitted, 'Standalone canvas did not resize after fullscreen')
        assert not errors, 'Frame-based standalone console raised JavaScript errors'
        print('PASS: standalone frame-based console and fullscreen resizing', flush=True)

except Exception:
    print('Browser errors:', errors, flush=True)
    # Query diagnostic DOM state only after DevTools connected.
    if cdp:
        print('Console state:', evaluate('''({
          status: document.querySelector('[data-console-status]')?.textContent,
          controls: [...document.querySelectorAll('.panel-heading [data-console-action], .panel-heading a[href*="help.cgi"], [data-console-toolbar]')].map(e=>({
            html: e.outerHTML.slice(0, 500), bounds: e.getBoundingClientRect().toJSON(),
            display: getComputedStyle(e).display, padding: getComputedStyle(e).padding,
            font: getComputedStyle(e).font, hidden: e.hidden
          })),
          menu: document.querySelector('#cloudmin-console-keys')?.outerHTML.slice(0, 300),
          active: document.activeElement?.outerHTML.slice(0, 250),
          ancestors: (() => {const a=[]; let e=document.querySelector('[data-console-keyboard]'); while(e){
            const s=getComputedStyle(e);a.push([e.tagName,e.id,e.className,s.overflow,s.display,s.position]);e=e.parentElement;}return a;})(),
          container: !!document.getElementById('cloudmin-console'),
          started: document.getElementById('cloudmin-console')?.dataset.consoleStarted,
          canvas: !!document.querySelector('[data-console-screen] canvas'),
          fullscreenEnabled: document.fullscreenEnabled,
          title: document.title,
          path: location.pathname,
          frames: window.frames.length,
          error: document.querySelector('.err-body')?.textContent,
          fatal: document.querySelector('[data-fatal-error-text]')?.textContent
        })'''), flush=True)
        print('Client load:', evaluate('''(async () => {
          const container = document.getElementById('cloudmin-console');
          // Navigation may already have removed the console container.
          if (!container) return 'No console page';
          const config = JSON.parse(container.dataset.consoleConfig);
          try {
            await import('/server-manager/console.js?' + config.client_version);
            return 'Loaded';
          } catch (error) { return error.message; }
        })()'''), flush=True)
        Path('/var/tmp/cloudmin-console-browser.png').write_bytes(base64.b64decode(call('Page.captureScreenshot')['data']))
    raise
finally:
    if cdp:
        # Ask Chrome to finish writing its profile before removing the directory.
        try:
            call('Browser.close')
        except (websocket.WebSocketException, OSError):
            pass
        cdp.close()
    # Wait for Chrome to finish profile writes before cleanup.
    if chrome:
        try:
            chrome.wait(timeout=10)
        except subprocess.TimeoutExpired:
            chrome.kill()
            chrome.wait()
    # Remove only this test's domain and its EFI variable store.
    if guest:
        # A failure before the power-off test may leave the fixture running.
        if guest.isActive():
            guest.destroy()
        guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    conn.close()
    for user in users:
        subprocess.run(['perl', str(helper), 'delete', '', user], check=True)
        clear_theme_settings(user)

    # An early failure may precede creation of the temporary profile.
    if profile:
        profile.cleanup()
