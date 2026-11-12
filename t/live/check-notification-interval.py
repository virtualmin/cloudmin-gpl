#!/usr/bin/python3
"""Check interval saves and unattended runs on an authorized Cloudmin host."""
from html.parser import HTMLParser
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import sqlite3
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

# This fixture changes module configuration on a Linux test host only.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
# Preserve the original settings before creating the private test account.
module, task = map(Path, sys.argv[1:])
helper = module / 't/live/webmin-user.pl'
config = Path('/etc/webmin/server-manager/config')
original = config.read_bytes()
backup = task / 'config-before-test'
backup.write_bytes(original)
backup.chmod(0o600)
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
password = secrets.token_urlsafe(36)
# Keep authentication and requests on this test host's loopback interface.
base = 'https://127.0.0.1:10000'
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)


class Form(HTMLParser):
    """Collect the notification category's hidden and numeric fields."""

    def __init__(self, page):
        """__init__(self, page) parses a configuration page into form fields."""
        super().__init__()
        self.active = False
        self.fields = {}
        self.inputs = {}
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        """handle_starttag(self, tag, attrs) reads the config save form."""
        attrs = dict(attrs)
        if tag == 'form':
            # Exclude login, search and other forms in the surrounding page.
            self.active = attrs.get('action', '').endswith('config_save.cgi')
        elif tag == 'input' and self.active and attrs.get('name'):
            # Capture the real form tokens and numeric setting attributes.
            name = attrs['name']
            self.inputs[name] = attrs
            if attrs.get('type') not in ('submit', 'button'):
                # Buttons are not part of this programmatic submission.
                self.fields[name] = attrs.get('value', '')

    def handle_endtag(self, tag):
        """handle_endtag(self, tag) stops collecting at the end of the form."""
        if tag == 'form':
            # Following page controls must not enter the saved form.
            self.active = False


def request(path, fields=None):
    """request(path, [fields]) sends GET, or POST when fields is supplied."""
    body = None if fields is None else urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        base + path, data=body,
        headers={'Referer': base + '/config.cgi?module=server-manager'},
    )
    with opener.open(req, timeout=30) as response:
        page = response.read().decode('utf-8', errors='replace')
    assert 'Error - Perl execution failed' not in page, 'CGI execution failed'
    return page


def schedule():
    """schedule() returns the registered notification callback's settings."""
    matches = []
    for path in Path('/etc/webmin/webmincron/crons').glob('*.cron'):
        fields = dict(line.split('=', 1) for line in path.read_text().splitlines()
                      if '=' in line)
        if fields.get('module') == 'server-manager' and fields.get('func') == 'run_cloudmin_notifications':
            # Select the registered notification function, not another timer.
            fields['id'] = path.stem
            matches.append(fields)
    assert len(matches) == 1, 'Expected exactly one notification callback'
    return matches[0]


def save(value):
    """save(value) submits the interval through its configuration form."""
    page = request('/config.cgi?module=server-manager&section=line10')
    assert 'Notification check interval in seconds' in page
    form = Form(page)
    field = form.inputs['notifications_interval']
    assert field['type'] == 'number' and field['min'] == '10' and field['max'] == '3600'
    form.fields['notifications_interval'] = str(value)
    request('/config_save.cgi', form.fields)


# Write the helper that registers the timer again once the original
# settings are back.
reschedule = task / 'reschedule.pl'
reschedule.write_text('''use strict;
use warnings;
$ENV{WEBMIN_CONFIG} = '/etc/webmin';
$ENV{WEBMIN_VAR} = '/var/webmin';
$ENV{REMOTE_USER} = 'root';
my $module = shift;
chdir($module) or die $!;
$0 = "$module/api.pl";
require './server-manager-lib.pl';
ensure_notification_schedule();
''')
created = False
try:
    # The fixture account and password exist only inside this test host.
    subprocess.run(['perl', str(helper), 'create', 'authentic-theme', user],
                   input=password + '\n', text=True, check=True)
    created = True
    subprocess.run(['perl', str(helper), 'acl', 'authentic-theme', user],
                   input=json.dumps({'admin': 1}) + '\n', text=True, check=True)
    time.sleep(1)
    # Sign in and keep the session cookie.
    request('/session_login.cgi')
    request('/session_login.cgi', {'user': user, 'pass': password,
                                  'page': '/server-manager/index.cgi'})
    # Longer intervals must leave no calendar fields,
    # which would run every minute.
    save(300)
    cron = schedule()
    assert cron.get('interval') == '300'
    assert not any(cron.get(k) for k in ('mins', 'hours', 'days', 'months', 'weekdays', 'special'))
    saved_id = cron.get('id')
    print('PASS configuration form saves a five-minute timer', flush=True)
    # A shorter interval updates the same timer; invalid input changes nothing.
    save(10)
    assert schedule().get('interval') == '10'
    assert schedule()['id'] == saved_id, 'Rescheduling replaced the callback'
    saved_config = config.read_bytes()
    save(0)
    assert config.read_bytes() == saved_config, 'Invalid interval changed configuration'
    assert schedule().get('interval') == '10'
    print('PASS ten-second timer and invalid-input rejection', flush=True)
    # Observe real scheduled worker completions without creating any alerts.
    db = '/var/webmin/modules/server-manager/notifications/notifications.sqlite'
    started = time.time()
    deadline = time.monotonic() + 50
    checks = []
    while time.monotonic() < deadline and len(checks) < 3:
        with sqlite3.connect('file:' + db + '?mode=ro', uri=True) as connection:
            row = connection.execute("SELECT value FROM metadata WHERE key = 'worker'").fetchone()
        if row:
            # A stored completion may predate this observation window.
            worker = json.loads(row[0])
            at = worker.get('checked_at', 0)
            if at >= started and at not in checks:
                # Count each successful completion only once.
                assert not worker.get('error'), worker.get('error')
                checks.append(at)
        time.sleep(0.5)
    # Three checks must arrive, each at most 25 seconds after the last.
    assert len(checks) >= 3, 'Did not observe three unattended checks within fifty seconds'
    gaps = [b - a for a, b in zip(checks, checks[1:])]
    assert all(0 < gap <= 25 for gap in gaps), gaps
    print('PASS unattended check spacing: ' + ', '.join(map(str, gaps)) + ' seconds', flush=True)
finally:
    # Preserve unrelated settings and leave no fixture account or session.
    config.write_bytes(original)
    subprocess.run(['perl', str(reschedule), str(module)], check=True)
    if created:
        # Remove only the account successfully created by this run.
        subprocess.run(['perl', str(helper), 'delete', 'authentic-theme', user], check=True)
    print('Restored original interval and removed fixture account', flush=True)
