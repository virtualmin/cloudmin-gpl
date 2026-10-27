#!/usr/bin/python3
"""Check console frames under backpressure with a simulated guest socket."""
import base64
import os
from pathlib import Path
import pwd
import secrets
import signal
import socket
import subprocess
import tempfile
import threading
import time

import websocket

# The fixture needs Linux setpriv and root only to launch the relay as nobody.
if os.geteuid() != 0 or not Path('/proc').is_dir():
    raise SystemExit('Run on a Linux test host as root')
module = Path(__file__).resolve().parents[2]
identity = pwd.getpwnam('nobody')


# expired(signum, frame) bounds the fixture while still running its cleanup.
def expired(signum, frame):
    raise TimeoutError('Console framing test timed out')


signal.signal(signal.SIGALRM, expired)
signal.alarm(90)
process = client = writer = None
with tempfile.TemporaryDirectory(prefix='cloudmin-relay-framing-') as directory:
    # This synthetic session grants no Webmin access and is removed afterward.
    root = Path(directory)
    root.chmod(0o755)
    session = secrets.token_hex(8)
    credential = root / 'session'
    credential.write_text(session)
    credential.chmod(0o644)
    # Keep guest traffic and browser traffic on separate fixture sockets.
    listener = socket.socket()
    guest, channel = socket.socketpair()
    try:
        # A small send buffer forces queuing while the client stops reading.
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        # Pass the listener and guest socket as stdin/stdout. Stderr reports
        # readiness and failures; the relay runs as an unprivileged user.
        process = subprocess.Popen(['setpriv', '--reuid', str(identity.pw_uid),
            '--regid', str(identity.pw_gid), '--clear-groups', 'perl',
            '-I' + str(module.parent / 'vendor_perl'), str(module / 'console-relay.pl'),
            'graphical'], stdin=listener, stdout=channel, stderr=subprocess.PIPE,
            env={'PATH': '/usr/bin:/bin', 'CREDENTIALS_DIRECTORY': directory})
        channel.close()
        listener.close()
        assert process.stderr.readline() == b'Cloudmin relay ready\n', 'Relay failed to start'
        # Supply the same session-key header that miniserv normally rewrites.
        client = websocket.create_connection('ws://127.0.0.1:' + str(port), timeout=10,
            header={'Sec-WebSocket-Key': base64.b64encode(session.encode()).decode()})
        payload = bytes(range(256)) * 8192
        failures = []

        # send_output() fills the relay queue while the browser stops reading.
        def send_output():
            try:
                guest.sendall(payload)
            except OSError as error:
                # Report thread failures through the main test's assertions.
                failures.append(error)

        writer = threading.Thread(target=send_output)
        writer.start()
        # The first ping is queued while a binary frame is only partly written.
        time.sleep(17)
        received = bytearray()
        ping = False
        while len(received) < len(payload) or not ping:
            opcode, frame = client.recv_data_frame(True)
            if opcode == websocket.ABNF.OPCODE_BINARY:
                # Reassemble guest bytes across arbitrary WebSocket boundaries.
                received.extend(frame.data)
            elif opcode == websocket.ABNF.OPCODE_PING:
                # websocket-client sends a protocol pong automatically.
                ping = True
            else:
                # Closure or another frame type would invalidate the transfer.
                raise AssertionError('Unexpected console frame')
        # Check the complete output after the writer has stopped.
        writer.join(timeout=5)
        assert not writer.is_alive() and not failures, 'Guest output did not finish'
        assert received == payload, 'Keepalive corrupted the guest byte stream'
        # Pong replies must not reach the guest socket.
        guest.settimeout(.3)
        try:
            assert not guest.recv(1024), 'Keepalive reached the guest as input'
        except socket.timeout:
            # A pong reply should leave the guest socket silent.
            pass
        # Actual binary input must still reach the guest byte for byte.
        client.send_binary(b'echo fixture\r')
        guest.settimeout(5)
        received_input = bytearray()
        while len(received_input) < len(b'echo fixture\r'):
            chunk = guest.recv(1024)
            assert chunk, 'Relay closed before forwarding input'
            received_input.extend(chunk)
        assert received_input == b'echo fixture\r', 'Guest received unexpected input'
        # Closing the browser must stop the relay without waiting for its alarm.
        client.close()
        assert process.wait(timeout=5) == 0, 'Relay survived browser disconnect'
        print('PASS: queued pings preserve partial binary frames; pong replies never reach the guest')
    finally:
        if client:
            # Startup can fail before the client exists.
            client.close()
        if process and process.poll() is None:
            # Stop only this fixture's child if a failure left it running.
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Kill a stuck relay so fixture cleanup can finish.
                process.kill()
                process.wait()
        # Release both ends so a blocked writer can leave sendall().
        guest.close()
        channel.close()
        listener.close()
        if writer:
            # There is no writer thread when setup fails before the transfer.
            writer.join(timeout=5)
