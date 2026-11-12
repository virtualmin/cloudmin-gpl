#!/usr/bin/python3
"""Test SMTP and HTTPS delivery on Linux.

Takes the module directory and a task directory. --delivery-only omits the
guest fixture.
"""
import http.server
from email import policy
from email.parser import BytesParser
import shutil
import json
import os
from pathlib import Path
import socketserver
import ssl
import subprocess
import sys
import threading

# Run only as root on Linux, with the module and task directories.
assert os.geteuid() == 0 and sys.platform.startswith('linux')
module, task = map(Path, sys.argv[1:3])
(task / 'delivery').mkdir(mode=0o700)
# Messages and webhook requests the sinks received.
mail = []
requests = []


class SMTP(socketserver.StreamRequestHandler):
    """Capture fixture mail without forwarding it."""

    def handle(self):
        """handle(self) captures mail with a 15-second socket timeout."""
        self.connection.settimeout(15)
        self.wfile.write(b'220 fixture ESMTP\r\n')
        while line := self.rfile.readline():
            command = line.decode().strip()
            if not command:
                # Ignore blank lines between SMTP commands.
                continue
            if command.upper().startswith(('EHLO', 'HELO')):
                # Advertise only the simple SMTP conversation used by the test.
                self.wfile.write(b'250 fixture\r\n')
            elif command.upper().startswith('MAIL FROM:'):
                # Check that the sender names the fixture domain.
                assert 'example.invalid' in command, 'Unexpected sender'
                self.wfile.write(b'250 OK\r\n')
            elif command.upper().startswith('RCPT TO:'):
                # Check for the expected fixture mailbox.
                assert 'sink@example.invalid' in command, 'Unexpected recipient'
                self.wfile.write(b'250 OK\r\n')
            elif command.upper() == 'DATA':
                # Retain the message body without delivering it anywhere.
                self.wfile.write(b'354 Continue\r\n')
                body = []
                while (line := self.rfile.readline()) not in (b'.\r\n', b''):
                    body.append(line)
                mail.append(b''.join(body))
                self.wfile.write(b'250 Accepted\r\n')
            elif command.upper() == 'QUIT':
                # Let the sender close its accepted SMTP session normally.
                self.wfile.write(b'221 Bye\r\n')
                return
            else:
                # Unexpected commands must fail rather than pass unnoticed.
                self.wfile.write(b'500 Unknown command\r\n')


class Webhook(http.server.BaseHTTPRequestHandler):
    """Record JSON and reject the first request to the retry fixture."""

    def do_POST(self):
        """do_POST(self) records JSON and rejects the first retry request."""
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        previous = sum(item[0] == self.path for item in requests)
        requests.append((self.path, body, self.headers['Idempotency-Key']))
        self.send_response(503 if self.path == '/retry' and not previous else 204)
        self.end_headers()

    def log_message(self, *_args):
        """log_message(self, *args) keeps request details out of test output."""


# Requests the chat provider fixture received.
provider_requests = []


class Provider(http.server.BaseHTTPRequestHandler):
    """Capture chat requests on HTTPS without contacting any chat service."""

    def do_POST(self):
        """do_POST(self) simulates accepted and rejected provider requests."""
        raw = self.rfile.read(int(self.headers['Content-Length']))
        body = raw.decode('utf-8') if self.path == '/ntfy' else json.loads(raw)
        previous = sum(item[0] == self.path for item in provider_requests)
        provider_requests.append((self.path, body, dict(self.headers)))
        if self.path == '/slack':
            # HTTP success alone does not prove Slack accepted the message.
            code, response = 200, b'ok' if previous else b'invalid_payload'
        elif self.path.startswith('/discord'):
            # A rate-limited request must retain its original event on retry.
            code = 200 if previous else 429
            response = b'{"id":"fixture-message"}' if previous else b'{}'
        elif self.path.startswith('/teams'):
            # Workflows acknowledge the request before posting the card.
            code, response = 202, b''
        elif self.path.startswith('/bot'):
            # Telegram may reject a request even when HTTP reports success.
            code = 200
            response = (b'{"ok":true,"result":{"message_id":42}}' if previous else
                        b'{"ok":false,"description":"123456:fixture_Telegram-token"}')
        elif self.path == '/1/messages.json':
            # Separate permanent rejections from a temporary server failure.
            rejected = {'b' * 30: 400, 'q' * 30: 429, 'r' * 30: 200}
            if body['user'] in rejected:
                # These requests must not be sent a second time.
                code = rejected[body['user']]
                response = json.dumps({'status': 0, 'errors': ['a' * 30]}).encode()
            else:
                # A server failure may return status 0 and still needs retry.
                code = 200 if previous else 503
                response = b'{"status":1}' if previous else b'{"status":0}'
        elif self.path == '/gotify/message':
            # Gotify returns the saved message, including its numeric ID.
            code, response = 200, json.dumps({'id': 42, **body}).encode()
        elif self.path == '/ntfy':
            # ntfy returns a JSON receipt for a plain-text publication.
            code, response = 200, b'{"id":"fixture-message"}'
        else:
            # A new endpoint must have an explicit fixture response.
            raise AssertionError('Unexpected provider path')
        self.send_response(code)
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_args):
        """log_message(self, *args) omits private request URLs from logs."""


# The certificate and its private key exist only on the test host.
cert, key = task / 'provider-cert.pem', task / 'provider-key.pem'
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-keyout', str(key), '-out', str(cert), '-days', '1',
                '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1'],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
key.chmod(0o600)

# Route test deliveries to local SMTP and HTTP sinks on dynamic ports.
with socketserver.ThreadingTCPServer(('127.0.0.1', 0), SMTP) as smtp, \
        http.server.ThreadingHTTPServer(('127.0.0.1', 0), Webhook) as hook, \
        http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider) as provider:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    provider.socket = context.wrap_socket(provider.socket, server_side=True)
    for server in (smtp, hook, provider):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run(['perl', str(module / 't/live/check-notification-delivery.pl'),
                        str(module), str(task / 'delivery'),
                        str(smtp.server_address[1]), str(hook.server_port)], check=True)
        # Check the received payload, not just the sender's acceptance result.
        assert len(mail) == 1, 'One real SMTP message'
        message = BytesParser(policy=policy.default).parsebytes(mail[0])
        body = message.get_body(preferencelist=('plain',)) or message
        assert 'Event ID:' in body.get_content(), 'Mail contains the event ID'
        assert 'Severity: Notice' in body.get_content(), 'Mail includes severity'
        # Retries retain both the JSON event and its idempotency key.
        retried = [item for item in requests if item[0] == '/retry']
        assert len(retried) == 2 and retried[0][1:] == retried[1][1:]
        assert all(item[1]['instance'] and item[1]['host'] for item in requests)
        print('PASS loopback SMTP, JSON webhook, stable retry IDs, worker and recovery')

        # Exercise each chat format over HTTPS and mail through the same sink.
        subprocess.run(['perl', str(module / 't/live/check-notification-providers.pl'),
                        str(module), str(task / 'providers'),
                        str(smtp.server_address[1]), str(provider.server_port), str(cert)],
                       check=True)
        # The mail keeps Unicode, shows readable units and links to the
        # saved Webmin address, never to a host from request headers.
        assert len(mail) == 2, 'Real rule sends an additional email'
        readable = BytesParser(policy=policy.default).parsebytes(mail[-1])
        plain = readable.get_body(preferencelist=('plain',)) or readable
        content = plain.get_content()
        assert 'Свободно място' in str(readable['Subject']), 'Mail subject preserves Unicode'
        assert 'Reading: 8.5 GiB' in content and 'At or below 10 GiB' in content
        assert 'https://cloudmin.example.invalid:10000/server-manager/notifications.cgi' in content
        assert 'untrusted.example.invalid' not in content
        # Inspect what each receiver got, including formatting and credentials.
        for path, body, headers in provider_requests:
            assert headers['Idempotency-Key'].startswith('cloudmin-')
            if path == '/slack':
                # Slack must receive literal text with readable units.
                assert body['blocks'][0]['text']['type'] == 'plain_text'
                assert '8.5 GiB' in body['blocks'][0]['text']['text']
            elif path.startswith('/discord'):
                # Preserve the thread and request confirmation without mentions.
                assert 'wait=true' in path and 'wait=false' not in path
                assert 'thread_id=123' in path and body['allowed_mentions']['parse'] == []
            elif path.startswith('/teams'):
                # Teams needs the card attachment format.
                assert body['attachments'][0]['content']['type'] == 'AdaptiveCard'
            elif path.startswith('/bot'):
                # Telegram authenticates in the URL and gets an exact chat ID.
                assert path == '/bot123456:fixture_Telegram-token/sendMessage'
                assert body['chat_id'] == -1001234567890 and isinstance(body['chat_id'], int)
                assert '8.5 GiB' in body['text'] and len(body['text']) <= 4096
                assert 'parse_mode' not in body and body['link_preview_options']['is_disabled']
                assert 'Authorization' not in headers
            elif path == '/1/messages.json':
                # Pushover accepts application and recipient keys in JSON.
                assert body['token'] == 'a' * 30
                assert len(body['message']) <= 1024
                assert body['priority'] == 0 and 'Authorization' not in headers
                if body['user'] == 'u' * 30:
                    # The real alert keeps its reading and units.
                    assert '8.5 GiB' in body['message']
                else:
                    # Dummy recipients select the permanent rejection cases.
                    assert body['user'] in ('b' * 30, 'q' * 30, 'r' * 30)
            elif path == '/gotify/message':
                # Gotify keeps its application token in the dedicated header.
                assert headers['X-Gotify-Key'] == 'fixture-Gotify-token'
                assert 'Authorization' not in headers and 'token' not in body
                assert '8.5 GiB' in body['message'] and body['priority'] == 5
            else:
                # ntfy gets plain text with its bearer token in the header.
                assert '8.5 GiB' in body and headers['Authorization'] == 'Bearer fixture-bearer'
        # Retryable rejections must reuse the original body and headers.
        for prefix in ('/slack', '/discord', '/bot'):
            attempts = [item for item in provider_requests if item[0].startswith(prefix)]
            assert len(attempts) == 2 and attempts[0][1:] == attempts[1][1:]
        pushover = [item for item in provider_requests if item[0] == '/1/messages.json']
        attempts = [item for item in pushover if item[1]['user'] == 'u' * 30]
        assert len(attempts) == 2 and attempts[0][1:] == attempts[1][1:]
        for user in ('b' * 30, 'q' * 30, 'r' * 30):
            # HTTP 400, quota 429 and API rejection each get just one request.
            assert sum(item[1]['user'] == user for item in pushover) == 1
        print('PASS Pushover permanent rejections stop and server failures retry')
        print('PASS readable Unicode mail, HTTPS chat payloads, rejection handling and stable retries')
        if '--delivery-only' not in sys.argv:
            # The optional lifecycle fixture runs a temporary native guest.
            subprocess.run(['perl', str(module / 't/live/check-notification-lifecycle.pl'),
                            str(module), str(task / 'lifecycle'),
                            str(hook.server_port)], check=True)
            print('PASS real guest lifecycle, planned stops and recovery')
    finally:
        # Stop the fixture servers and remove private stores after failures too.
        smtp.shutdown()
        hook.shutdown()
        provider.shutdown()
        cert.unlink(missing_ok=True)
        key.unlink(missing_ok=True)
        shutil.rmtree(task / 'providers', ignore_errors=True)
        shutil.rmtree(task / 'delivery')
        shutil.rmtree(task / 'lifecycle', ignore_errors=True)
