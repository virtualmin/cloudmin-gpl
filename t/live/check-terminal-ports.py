#!/usr/bin/python3
"""
Verify SSH preferences and login outcomes through the real isolated client.
"""

# Usage: check-terminal-ports.py <test-host-address>
# The Linux test host needs paramiko, websocket-client and a working terminal.
import hashlib
import http.cookiejar
import json
import logging
import os
import re
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid

import paramiko
import websocket

assert sys.platform == 'linux' and os.geteuid() == 0, (
    'Run on a Linux test host as root'
)
# Use a unique account and guest identity; keep generated credentials in memory.
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
launcher = module / 't/live/readonly-terminal-fixture.pl'
identity = str(uuid.uuid4())
user = 'cloudmin-terminal-check-' + secrets.token_hex(4)
password = secrets.token_urlsafe(32)
base = 'https://127.0.0.1:10000'
address = sys.argv[1]
# Match production's UUID port key and per-account login and host-key storage.
store = Path('/var/webmin/modules/server-manager/ssh-ports')
key = identity
home = hashlib.sha256((user + ':' + identity).encode()).hexdigest()[:24]
login_store = store.parent / (
    'ssh-login-' + identity + '-' + user.replace('-', '%2D')
)
created = False
# All ordinary attempts share a host key; one case deliberately changes it.
host_key = paramiko.RSAKey.generate(2048)
logging.getLogger('paramiko').setLevel(logging.CRITICAL)


# saved() returns this fixture's saved port, defaulting to 22.
def saved():
    values = (
        dict(line.split('=', 1) for line in store.read_text().splitlines())
        if store.exists()
        else {}
    )
    return int(values.get(key, '22'))


# wait_saved(port) allows the worker and supervisor to deliver the login event.
def wait_saved(port):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and saved() != port:
        time.sleep(0.1)
    assert saved() == port, 'Successful authentication did not save the port'


# outcome(attempt) reads the same authenticated endpoint as the browser.
def outcome(attempt):
    url = (
        base
        + '/server-manager/terminal-status.cgi?'
        + urllib.parse.urlencode({'id': identity, 'attempt': attempt})
    )
    request = urllib.request.Request(
        url, headers={'Referer': base + '/server-manager/remote_access.cgi'}
    )
    with client.open(request, timeout=10) as reply:
        body = reply.read().decode()
        try:
            result = json.loads(body)
        except json.JSONDecodeError:
            # Limit error details to the response type and page title.
            title = re.search(r'<title>([^<]*)</title>', body)
            raise AssertionError(
                'Status returned '
                + reply.headers.get('Content-Type', '')
                + ': '
                + (title[1] if title else 'no page title')
            ) from None
    assert 'error' not in result, 'Cannot read login outcome'
    assert set(result) == {'state'}, (
        'Status endpoint exposed connection settings'
    )
    return result['state']


# wait_outcome(attempt, state) waits for the supervisor to record the
# SSH result.
def wait_outcome(attempt, state):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        # Stop waiting once the endpoint exposes the expected state.
        if outcome(attempt) == state:
            return
        time.sleep(0.2)
    raise AssertionError('Supervisor did not record ' + state)


# Peer accepts one test password and sends a fake event before authentication.
class Peer(paramiko.ServerInterface):
    # get_banner(self) tries to spoof the worker's event before authentication.
    def get_banner(self):
        return ('Cloudmin SSH authenticated\n', 'en')

    # get_allowed_auths(self, username) keeps the fixture on password login.
    def get_allowed_auths(self, username):
        return 'password'

    # check_auth_password(self, username, candidate) validates the test login.
    def check_auth_password(self, username, candidate):
        return (
            paramiko.AUTH_SUCCESSFUL
            if username == 'cloudmin' and candidate == password
            else paramiko.AUTH_FAILED
        )

    # check_channel_request(self, kind, channel_id) allows only a shell session.
    def check_channel_request(self, kind, channel_id):
        return (
            paramiko.OPEN_SUCCEEDED
            if kind == 'session'
            else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        )

    # check_channel_pty_request(self, *args) accepts Paramiko's PTY parameters.
    def check_channel_pty_request(self, *args):
        return True

    # check_channel_shell_request(self, channel) marks an authenticated shell.
    def check_channel_shell_request(self, channel):
        channel.send(b'PORT TEST READY\r\n')
        return True


# attempt(session, cookie, succeed, [reject_key]) runs a real isolated terminal.
# session and cookie belong to the fixture account.
# succeed chooses whether to send the correct password.
# reject_key defaults to false; true changes the key for the same guest UUID.
def attempt(session, cookie, succeed, reject_key=False):
    # Listen on a free test-host port without changing the host's SSH service.
    listener = socket.socket()
    listener.bind((address, 0))
    listener.listen(1)
    listener.settimeout(30)
    port = listener.getsockname()[1]
    stop = threading.Event()
    errors = []

    # serve() keeps all protocol bytes and passwords private to the test.
    def serve():
        try:
            connection, _ = listener.accept()
            with paramiko.Transport(connection) as transport:
                transport.add_server_key(
                    paramiko.RSAKey.generate(2048) if reject_key else host_key
                )
                transport.start_server(server=Peer())
                while transport.is_active() and not stop.wait(0.1):
                    pass
        except (EOFError, paramiko.SSHException):
            pass  # Failed authentication and rejected host keys close SSH.
        except Exception as error:
            # Report only the exception type, keeping protocol data private.
            errors.append(type(error).__name__)

    # Run the fixture independently while driving its browser WebSocket client.
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    sock = None
    previous = saved()
    try:
        # Launch through the real supervisor, keeping session data in memory.
        payload = dict(
            user=user,
            session=session,
            uuid=identity,
            address=address,
            port=port,
            startup_diagnostic=True,
        )
        result = subprocess.run(
            ['perl', str(launcher)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            timeout=40,
        )
        assert result.returncode == 0, (
            'Supervisor launch failed: ' + result.stderr
        )
        route = json.loads(result.stdout)
        # Status belongs to this attempt, not any other browser connection.
        assert outcome(route['attempt']) == 'pending', (
            'New login was not pending'
        )
        assert outcome('0' * 32) == 'gone', (
            'Another attempt inherited the result'
        )
        sock = websocket.create_connection(
            route['socket_url'],
            cookie=cookie,
            sslopt={'cert_reqs': ssl.CERT_NONE},
            origin=base,
            subprotocols=['binary'],
            timeout=2,
        )
        pending = ''
        deadline = time.monotonic() + 20
        authenticated = False
        # Answer only expected SSH prompts; terminal output never reaches logs.
        while time.monotonic() < deadline:
            try:
                data = sock.recv()
            except websocket.WebSocketTimeoutException:
                # Allow more time for worker startup or a guest reply.
                continue
            except websocket.WebSocketConnectionClosedException:
                # Failed login or a rejected host key may close the relay.
                break
            if not data:
                # An empty receive also marks the end of this connection.
                break
            pending += (
                data.decode(errors='replace')
                if isinstance(data, bytes)
                else data
            )
            if 'REMOTE HOST IDENTIFICATION HAS CHANGED' in pending:
                # The changed-key case must stop before accepting a guest login.
                assert reject_key, 'Unexpected host-key change'
                break
            if 'continue connecting' in pending:
                # Accept a new key; changed keys stop in the branch above.
                sock.send('yes\n')
                pending = ''
            elif 'password:' in pending:
                # The spoofed banner must not save a port before login succeeds.
                assert saved() == previous, (
                    'Guest banner was mistaken for successful login'
                )
                assert outcome(route['attempt']) == 'pending', (
                    'Guest banner cleared automatic login pause'
                )
                sock.send(
                    (password if succeed else 'incorrect-fixture-password')
                    + '\n'
                )
                pending = ''
            elif 'PORT TEST READY' in pending:
                # The shell marker confirms that authentication succeeded.
                authenticated = True
                wait_saved(port)
                break
        # Check both the user-visible outcome and the shared remembered port.
        assert authenticated == succeed, 'Unexpected SSH authentication outcome'
        wait_outcome(route['attempt'], 'connected' if succeed else 'failed')
        if not succeed:
            # Failed authentication must leave the saved port unchanged.
            assert saved() == previous, 'Failed login replaced the saved port'
        assert not errors, 'SSH fixture failed: ' + ', '.join(errors)
        # A diagnostic before readiness must not swallow the later login event.
        log = store.parent / ('terminal-' + str(route['port']) + '.log')
        assert log.read_text().startswith(
            'Cloudmin fixture startup diagnostic\n'
        ), 'Startup diagnostic was not exercised'
        print(
            'PASS: '
            + (
                'successful login saves port'
                if succeed
                else 'changed host key keeps port'
                if reject_key
                else 'failed password and guest banner keep port'
            ),
            flush=True,
        )
        return port
    finally:
        # A launch failure may leave no browser socket to close.
        if sock:
            sock.close()
        # Stop the fixture peer and allow the supervisor to release its service.
        stop.set()
        listener.close()
        thread.join(5)
        time.sleep(1)


try:
    # The temporary Webmin account exercises real browser-session authorization.
    assert saved() == 22
    result = subprocess.run(
        ['perl', str(helper), 'create', 'authentic-theme', user],
        input=password + '\n',
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert result.returncode == 0, 'Fixture account creation failed'
    created = True
    # Log in over loopback using only the generated test credentials.
    jar = http.cookiejar.CookieJar()
    client = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )
    client.open(base + '/session_login.cgi', timeout=30).close()
    client.open(
        base + '/session_login.cgi',
        data=urllib.parse.urlencode({'user': user, 'pass': password}).encode(),
        timeout=30,
    ).close()
    session = next(item.value for item in jar if item.name == 'sid')
    cookie = '; '.join(item.name + '=' + item.value for item in jar)
    # Failures retain the first successful port; the next success replaces it.
    first = attempt(session, cookie, True)
    attempt(session, cookie, False)
    attempt(session, cookie, False, reject_key=True)
    second = attempt(session, cookie, True)
    assert second != first and saved() == second
    assert store.stat().st_mode & 0o777 == 0o600
    assert login_store.stat().st_mode & 0o777 == 0o600
    print(
        'PASS: failures pause automatic login; authenticated success clears it; status is private',
        flush=True,
    )
    print(
        'PASS: latest successful port replaces the previous value; saved state is private',
        flush=True,
    )
    print(
        'PASS: startup diagnostics preserve the authenticated event boundary',
        flush=True,
    )
finally:
    # Remove this fixture's login state and account, even if a test failed.
    login_store.unlink(missing_ok=True)
    if created:
        # Remove the account only after this run successfully created it.
        subprocess.run(
            ['perl', str(helper), 'delete', '', user],
            check=True,
            capture_output=True,
            timeout=30,
        )
    # Use the same lock as production and remove only this test's UUID entry.
    cleanup = '''use WebminCore; our $error_must_die = 1; my $file = shift; my $key = shift;
        lock_file($file); my %ports; read_file($file, \\%ports);
        delete $ports{$key}; write_file($file, \\%ports); unlock_file($file);'''
    env = {
        **os.environ,
        'WEBMIN_CONFIG': '/etc/webmin',
        'WEBMIN_VAR': '/var/webmin',
    }
    if store.exists():
        # Preserve entries written by real users while this test was running.
        result = subprocess.run(
            ['perl', '-I' + str(module.parent), '-e', cleanup, str(store), key],
            cwd=module.parent,
            env=env,
            capture_output=True,
            timeout=30,
        )
        assert result.returncode == 0, (
            'Fixture port cleanup failed: ' + result.stderr
        )
    for state in (
        Path('/var/lib/cloudmin-ssh') / home,
        Path('/var/lib/private/cloudmin-ssh') / home,
    ):
        if state.is_symlink():
            # Unlink the service's public path without following its target.
            state.unlink()
        elif state.exists():
            # Remove this account's private host-key directory.
            shutil.rmtree(state)
