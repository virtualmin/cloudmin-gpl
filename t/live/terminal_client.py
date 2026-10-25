"""Exercise the actual Cloudmin terminal through an authenticated WebSocket."""
import hashlib
import html
import http.cookiejar
import json
import re
import ssl
import subprocess
import shlex
import time
import urllib.parse
import urllib.request
import websocket
from pathlib import Path


# TerminalConfig reads Webmin's standard terminal configuration object.
class TerminalConfig:
    # __init__(self, page) extracts the terminal config, or None on an error
    # page.
    def __init__(self, page):
        match = re.search(r'var xterm_argv = (\{[^\n]+\});', page)
        self.config = json.loads(match[1]) if match else None


# check_terminal(opener, base, vm, username, password, [host_key])
# Reuses the VM fixture's local-only account and guest; credentials stay on the VM.
# host_key defaults to false; true tests the guest's managed login key first.
def check_terminal(opener, base, vm, username, password, host_key=False):
    # page(path, [values]) fetches or submits a form with the fixture session.
    def page(path, values=None):
        body = urllib.parse.urlencode(values).encode() if values is not None else None
        req = urllib.request.Request(base + path, data=body,
                                     headers={'Referer': base + '/server-manager/remote_access.cgi'})
        with opener.open(req, timeout=60) as response:
            result = response.read().decode()
            assert 'Error - Perl execution failed' not in result, 'Terminal CGI crashed'
            return result

    path = '/server-manager/remote_access.cgi?id=' + vm['uuid']
    form = page(path)
    assert 'Connect' in form and 'name="username"' in form, 'SSH form missing'
    token = html.unescape(re.search(r'name="token"[^>]*value="([^"]+)"', form)[1])
    address = next(row['address'] for row in vm['addresses'] if row['address'].startswith('192.168.122.'))
    values = dict(id=vm['uuid'], username=username, address=address, port=22, connect=1, token=token,
                  auth='key' if host_key else 'password')
    # The managed key must be offered as the default when it is available.
    if host_key:
        assert re.search(r'<option[^>]*value="key"[^>]*selected', form), 'Host key is not the terminal default'
    # Unsafe requests must fail before a WebSocket backend is allocated.
    for override in ({'token': 'invalid'}, {'address': '127.0.0.1'}, {'username': '-oProxyCommand=sh'}, {'port': '65536'}, {'auth': 'agent'}):
        rejected = page('/server-manager/remote_access.cgi', {**values, **override})
        assert 'Cannot open SSH terminal' in rejected and TerminalConfig(rejected).config is None
        assert 'Virtual machine not found' not in rejected, 'Invalid request missed its guest'
    rejected = page('/server-manager/remote_access.cgi?' + urllib.parse.urlencode(values))
    assert 'Cannot open SSH terminal' in rejected and TerminalConfig(rejected).config is None
    print('Terminal form, POST, CSRF and destination validation passed', flush=True)

    # The same account can read xterm assets without gaining a host-shell ACL.
    for asset in ('xterm.js', 'xterm-addon-attach.js', 'xterm-addon-fit.js', 'xterm.css'):
        with opener.open(base + '/xterm/' + asset, timeout=30) as response:
            assert response.status == 200
    navigation = json.loads(page('/xhr.cgi?type=nav&action=get&subtype=cloudmin&sid=' + vm['uuid']))['menu']
    assert html.escape(vm['name']) in navigation and 'remote_access.cgi?id=' in navigation
    assert navigation.index('remote_access.cgi?id=') < navigation.index('menu-separator') < navigation.index('/server-manager/images.cgi')
    assert '/server-manager/machine.cgi?id=' in navigation
    print('Guest selection, terminal assets and global menu order passed', flush=True)

    cookie = '; '.join(c.name + '=' + c.value for h in opener.handlers
                       if isinstance(h, urllib.request.HTTPCookieProcessor) for c in h.cookiejar)
    first = page('/server-manager/remote_access.cgi', values)
    config = TerminalConfig(first).config
    assert config, 'Connect did not create a terminal'
    url = config['socket_url']
    # An unauthenticated WebSocket cannot use another user's terminal route.
    try:
        bad = websocket.create_connection(url, sslopt={'cert_reqs': ssl.CERT_NONE},
                                          origin=base, subprotocols=['binary'], timeout=5)
    except (websocket.WebSocketException, OSError):
        pass
    else:
        # Acceptance without a Webmin session is a failure even if no data arrived.
        bad.close()
        raise AssertionError('Unauthenticated terminal connection was accepted')

    sock = websocket.create_connection(url, cookie=cookie, sslopt={'cert_reqs': ssl.CERT_NONE},
                                       origin=base, subprotocols=['binary'], timeout=15)
    output = ''
    # until(expected, [seconds]) accumulates frames until the marker arrives.
    # The default wait is 60 seconds; output stays in this VM process.
    def until(expected, seconds=60):
        nonlocal output
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                data = sock.recv()
            except websocket.WebSocketTimeoutException:
                continue
            assert data, 'Terminal closed unexpectedly'
            output += data.decode(errors='replace') if isinstance(data, bytes) else data
            # A marker can span frames, so match against the accumulated output.
            if expected in output:
                return
        raise AssertionError('Terminal did not reach the expected prompt or result')

    try:
        until('Are you sure you want to continue connecting')
        sock.send('yes\n')
        # Key authentication must succeed without a guest password prompt.
        if not host_key:
            until('password:')
            output = ''
            sock.send(password + '\n')
        until('#' if username == 'root' else '$')
        assert not host_key or 'password:' not in output, 'Key login unexpectedly requested a password'
        assert password not in output, 'Guest password echoed in terminal output'
        sock.send("printf '__CLOUDMIN_GUEST__'; hostname\n")
        until('__CLOUDMIN_GUEST__' + vm['name'])
        # OpenSSH must forward the local PTY resize to the remote guest's PTY.
        sock.send('\\033[8;(37);(101)t')
        time.sleep(1)
        output = ''
        sock.send('stty size\n')
        until('37 101')
        # A paste larger than a PTY buffer must not deadlock the input relay.
        script = ('import os,termios,tty; old=termios.tcgetattr(0); tty.setraw(0); '
                  'print("PASTE_READY",flush=True); n=0\n'
                  'while n<196608: n+=len(os.read(0,min(8192,196608-n)))\n'
                  'termios.tcsetattr(0,termios.TCSADRAIN,old); print("PASTE_OK_"+str(n),flush=True)')
        output = ''
        sock.send('python3 -c ' + shlex.quote(script) + '\n')
        until('PASTE_READY\n')
        output = ''
        sock.send('x' * 196608)
        until('PASTE_OK_196608')
        # Check that output frames remain complete while the browser catches up.
        output = ''
        sock.send("python3 -c \"print('Z'*262144); print('OUTPUT_OK')\"\n")
        time.sleep(1)
        until('\r\nOUTPUT_OK\r\n')
        assert 'Z' * 262144 in output, 'Terminal output was truncated'
        # Use the route's port to find its relay when several sessions are open.
        from relay_safety import check_relay
        unit, pid, uid = check_relay('terminal', re.search(r'/ws-(\d+)', url)[1])
        # The WebSocket relay owns a PTY worker, which in turn owns OpenSSH.
        children = Path('/proc/' + pid + '/task/' + pid + '/children').read_text().split()
        assert len(children) == 1
        worker = children[0]
        assert b'terminal-worker.pl' in Path('/proc/' + worker + '/cmdline').read_bytes()
        ssh = Path('/proc/' + worker + '/task/' + worker + '/children').read_text().split()
        assert len(ssh) == 1 and Path('/proc/' + ssh[0] + '/comm').read_text().strip() == 'ssh'
        for child in (worker, ssh[0]):
            child_status = Path('/proc/' + child + '/status').read_text()
            assert int(re.search(r'^Uid:\s+(\d+)', child_status, re.M)[1]) == uid
        # SELinux hosts must retain enforcement throughout the terminal test.
        enforce = Path('/sys/fs/selinux/enforce')
        # Verify enforcement only on a host with SELinux enabled.
        if enforce.exists():
            assert enforce.read_text().strip() == '1', 'SELinux is not enforcing'
        if host_key:
            # Inspect access inside the exact service mount namespace and UID.
            probe = ('import os; from pathlib import Path; '
                     'p=Path("/run/credentials/' + unit + '/ssh-key"); '
                     'assert p.is_file() and os.access(p,os.R_OK); '
                     'assert not os.access("/var/webmin",os.R_OK); '
                     'assert not os.access("/etc/webmin",os.R_OK); '
                     'assert not os.access("/run/libvirt/libvirt-sock",os.R_OK)')
            subprocess.run(['nsenter','-t',pid,'-m','--','setpriv','--reuid',str(uid),
                            '--regid',str(uid),'--clear-groups','python3','-c',probe], check=True)
            print('Terminal can read only its supplied key, with Webmin and libvirt access blocked', flush=True)
        print('Real WebSocket SSH login, guest identity, resize, large paste/output and non-root SSH passed', flush=True)
    finally:
        sock.close()
    # Closing the WebSocket must stop SSH and remove the route.
    port = re.search(r'/ws-(\d+)',url)[1]
    for _ in range(30):
        state = subprocess.run(['systemctl','is-active',unit],capture_output=True,text=True).stdout.strip()
        # The supervisor removes the route after systemd finishes teardown.
        route_exists = 'websockets_/server-manager/ws-' + port + '=' in Path('/etc/webmin/miniserv.conf').read_text()
        # Both the service and its proxy registration must finish cleanup.
        if state not in ('active','deactivating') and not route_exists:
            break
        time.sleep(1)
    assert state not in ('active','deactivating'), 'Terminal service survived disconnect'
    assert not route_exists, 'Terminal proxy route survived disconnect'
    print('Terminal disconnect removed the SSH service and proxy route', flush=True)

    # A new connection remembers this user's accepted host key. Logging out of
    # Webmin must terminate the proxy even if its terminal tab stays open.
    second = TerminalConfig(page('/server-manager/remote_access.cgi', {**values, 'auth': 'password'})).config
    assert second, 'Reconnect failed'
    sock = websocket.create_connection(second['socket_url'], cookie=cookie,
                                      sslopt={'cert_reqs': ssl.CERT_NONE}, origin=base,
                                      subprotocols=['binary'], timeout=5)
    output = ''
    try:
        until('password:')
        assert 'Are you sure you want to continue connecting' not in output, 'SSH host key was not retained'
        output = ''
        sock.send(password + '\n')
        until('#' if username == 'root' else '$')
        sock.send("printf '__PASSWORD_LOGIN__'; id -un\n")
        until('__PASSWORD_LOGIN__' + username)
        print('Switching to password authentication and the chosen username passed', flush=True)
        page('/session_login.cgi?logout=1')
        closed = False
        end = time.monotonic() + 30
        while time.monotonic() < end:
            try:
                # EOF is a successful revocation of the logged-out session.
                if not sock.recv():
                    closed = True
                    break
            except websocket.WebSocketTimeoutException:
                continue
            except (websocket.WebSocketConnectionClosedException, ConnectionResetError):
                closed = True
                break
        assert closed, 'Webmin logout left the terminal connected'
    finally:
        sock.close()
    print('SSH host key retained; Webmin logout closed the terminal', flush=True)

    # Remove only this disposable guest's accepted host keys.
    identity = hashlib.sha256(('cloudmin-ui-check:' + vm['uuid']).encode()).hexdigest()[:24]
    import shutil
    shutil.rmtree('/var/lib/private/cloudmin-ssh/' + identity, ignore_errors=True)
