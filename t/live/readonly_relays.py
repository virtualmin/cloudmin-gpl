"""Exercise real WebSocket relays with read-only and revoked fixture sessions."""
import base64
import hashlib
import json
from pathlib import Path
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import time

import websocket

from relay_safety import check_relay


# cookie(jar) formats this fixture's session without printing its credentials.
def cookie(jar):
    return '; '.join(c.name + '=' + c.value for c in jar)


# session(jar) returns the login cookie used by miniserv's backend handshake.
def session(jar):
    return next(c.value for c in jar if c.name == 'sid')


# reject(url, [missing], **options) requires refusal or a closed transport.
# missing also accepts miniserv's absent-route error after cleanup.
# A timeout or unrelated network error cannot count as an authorization success.
def reject(url, missing=False, **options):
    sock = None
    try:
        sock = websocket.create_connection(url, timeout=5,
            sslopt={'cert_reqs': ssl.CERT_NONE}, **options)
        assert not sock.recv(), 'Read-only session received interactive data'
    except websocket.WebSocketBadStatusException as error:
        # Miniserv reports its explicit route-owner refusal as HTTP 500.
        denied = error.status_code == 500 and \
            'Invalid user for Websockets connection' in str(error)
        removed = missing and error.status_code == 400 and \
            'Unknown websocket path' in str(error)
        assert denied or removed or error.status_code in ((403, 404) if missing else (403,)), \
            'Unexpected WebSocket HTTP failure'
    except (websocket.WebSocketConnectionClosedException, ConnectionResetError):
        # Backends can refuse a handshake by closing without an HTTP response.
        pass
    finally:
        # Close the test WebSocket even when its authorization check fails.
        if sock is not None:
            sock.close()


# check_relays(module, identity, login, rojar) uses isolated accounts.
# Graphical uses a real paused VM; SSH uses an inventory fixture and local listener.
# login owns account cleanup. Each relay and SSH state directory is removed here.
def check_relays(module, identity, login, rojar):
    helper = module / 't/live/webmin-user.pl'
    launcher = module / 't/live/readonly-terminal-fixture.pl'
    user = 'cloudmin-terminal-check-' + secrets.token_hex(4)
    page, jar = login(user, 'create')
    data = Path('/var/webmin/modules/server-manager')
    base = 'https://127.0.0.1:10000'
    # Keep the SSH endpoint on this host without changing its network settings.
    links = json.loads(subprocess.check_output(['ip', '-j', 'address', 'show'], text=True))
    address = next(a['local'] for link in links for a in link.get('addr_info', [])
                   if a['family'] == 'inet' and a['scope'] == 'global')
    target = socket.socket()
    target.bind((address, 0))
    target.listen(1)
    target.settimeout(10)
    payload = dict(user=user, session=session(jar), uuid=identity,
                   address=address, port=target.getsockname()[1])
    ssh_home = hashlib.sha256((user + ':' + identity).encode()).hexdigest()[:24]
    state = Path('/var/lib/private/cloudmin-ssh') / ssh_home
    public_state = Path('/var/lib/cloudmin-ssh') / ssh_home
    assert not state.exists() and not public_state.exists(), 'SSH fixture state already exists'

    # readonly_flag(value) changes only the temporary user's global ACL.
    def readonly_flag(value):
        subprocess.run(['perl', str(helper), 'readonly', '', user],
                       input=str(value) + '\n', text=True, check=True)

    try:
        for kind in ('console', 'terminal'):
            sock = peer = process = None
            unit = port = None
            readonly_flag(0)
            try:
                if kind == 'console':
                    # Use the normal CGI, supervisor and libvirt VNC descriptor.
                    token = json.loads(page('/server-manager/api.cgi?action=options'))['result']['token']
                    result = json.loads(page('/server-manager/console-connect.cgi',
                                             {'id': identity, 'token': token}))
                    assert 'socket_url' in result, 'Writable console failed to start'
                else:
                    # Only guest inventory is synthetic; the SSH supervisor is real.
                    process = subprocess.Popen(['perl', str(launcher)], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    output, errors = process.communicate(json.dumps(payload), timeout=40)
                    assert process.returncode == 0, 'SSH fixture launcher failed: ' + errors
                    result = json.loads(output)
                url = result['socket_url']
                port = int(re.search(r'/ws-(\d+)', url)[1])
                unit, _, _ = check_relay(kind, port)
                # A read-only login cannot borrow a writer's valid route or session.
                reject(url, cookie=cookie(rojar), origin=base, subprotocols=['binary'])
                # Reach the relay itself with the read-only proxy identity too.
                reject('ws://127.0.0.1:' + str(port) + '/',
                       header={'Sec-WebSocket-Key': base64.b64encode(session(rojar).encode()).decode()},
                       origin=base, subprotocols=['binary'])
                sock = websocket.create_connection(url, cookie=cookie(jar), origin=base,
                    subprotocols=['binary'], sslopt={'cert_reqs': ssl.CERT_NONE}, timeout=15)
                if kind == 'console':
                    # Positive control: denied clients must not consume the VNC stream.
                    assert sock.recv().startswith(b'RFB '), 'Writable console received no VNC greeting'
                else:
                    # Hold SSH before key exchange; no credentials or commands are sent.
                    peer, _ = target.accept()
                    peer.settimeout(5)
                    assert peer.recv(512).startswith(b'SSH-2.0-'), 'Writable terminal did not start SSH'
                readonly_flag(1)
                assert 'token' not in json.loads(page('/server-manager/api.cgi?action=options'))['result'], \
                    'Converted read-only session retained an action token'
                try:
                    assert not sock.recv(), 'Existing relay survived read-only revocation'
                except websocket.WebSocketConnectionClosedException:
                    pass
                log = data / (kind + '-' + str(port) + '.log')
                deadline = time.monotonic() + 15
                route = 'websockets_/server-manager/ws-' + str(port) + '='
                # The supervisor logs revocation after removing its route.
                while time.monotonic() < deadline and (
                        route in Path('/etc/webmin/miniserv.conf').read_text() or
                        'Interactive access has been revoked' not in log.read_text()):
                    time.sleep(0.2)
                assert 'Interactive access has been revoked' in log.read_text(), \
                    'Relay closed for a reason other than read-only revocation: ' + str(log)
                assert route not in Path('/etc/webmin/miniserv.conf').read_text(), 'Revoked route remains'
                status = subprocess.run(['systemctl', 'is-active', unit], capture_output=True, text=True)
                assert status.stdout.strip() not in ('active', 'activating', 'deactivating'), 'Revoked relay remains active'
                reject(url, missing=True, cookie=cookie(jar), origin=base, subprotocols=['binary'])
                print('PASS: ' + kind + ' proxy and relay reject read-only sessions; active revocation stops service and removes route', flush=True)
            finally:
                # Close only this test's endpoints, including on assertion failures.
                if sock is not None:
                    sock.close()
                # Release the fake relay peer if the connection was established.
                if peer is not None:
                    peer.close()
                # Stop only the transient unit created by this test.
                if unit is not None:
                    subprocess.run(['systemctl', 'stop', unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                # Terminate a fixture listener that is still running.
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
        # The detached SSH controller must refuse read-only launch before lookup.
        probe = subprocess.run(['perl', str(launcher)], input=json.dumps({**payload, 'probe': True}),
                               text=True, capture_output=True, timeout=20)
        assert probe.returncode != 0 and 'Access denied by Cloudmin permissions' in probe.stderr, \
            'Read-only SSH supervisor did not refuse access'
        print('PASS: read-only SSH supervisor rejects direct startup', flush=True)
    finally:
        target.close()
        # DynamicUser stores are specific to this randomly named user and VM.
        if public_state.is_symlink():
            public_state.unlink()
        shutil.rmtree(state, ignore_errors=True)
