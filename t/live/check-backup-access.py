#!/usr/bin/python3
"""Check backup and restore forms, CSRF and delegated access on a test host."""

import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid

# Fixture accounts and guest inspection belong only on the Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt

connection = libvirt.open('qemu:///system')
directory = pool = guest = None
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
base = 'https://127.0.0.1:10000'
users = []


class Fields(HTMLParser):
    # __init__(self, html, [base]) collects form fields and resolves help links.
    def __init__(self, html, base='/server-manager/'):
        super().__init__()
        self.base = base
        self.names = set()
        self.values = {}
        self.options = {}
        self.help_topics = set()
        self.select = None
        self.feed(html)

    # handle_starttag(self, tag, attrs) records controls, choices and
    # help links.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Resolve both module links and relative cross-links between
        # help topics.
        if tag == 'a':
            path = urllib.parse.urlparse(
                urllib.parse.urljoin(self.base, attrs.get('href', ''))
            ).path
            # Follow only help for this module, not general navigation.
            if path.startswith('/help.cgi/server-manager/'):
                self.help_topics.add(path)
        if tag in ('input', 'select', 'textarea') and attrs.get('name'):
            # Field names prove the public form contract without exposing XML.
            self.names.add(attrs['name'])
            self.values[attrs['name']] = attrs.get('value', '')
        # Associate option values with the enclosing destination selector.
        if tag == 'select':
            self.select = attrs.get('name')
            self.options[self.select] = []
        # Ignore options outside a named selector.
        elif tag == 'option' and self.select:
            self.options[self.select].append(attrs.get('value', ''))

    # handle_endtag(self, tag) keeps nested destination selectors separate.
    def handle_endtag(self, tag):
        # Later options cannot append to a selector that has already closed.
        if tag == 'select':
            self.select = None


# account(mode, grants, [theme]) creates a login with an in-memory password.
# Apply grants before opening the session with the selected theme.
def account(mode, grants, theme="authentic-theme"):
    name = 'cloudmin-spa-check-' + secrets.token_hex(4)
    password = secrets.token_urlsafe(40)
    subprocess.run(
        ['perl', str(helper), mode, theme, name],
        input=password + '\n',
        text=True,
        check=True,
        capture_output=True,
    )
    users.append(name)
    # Apply the requested permissions, then keep the login cookie in memory.
    subprocess.run(
        ['perl', str(helper), 'acl', '', name],
        input=json.dumps(grants),
        text=True,
        check=True,
        capture_output=True,
    )
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )

    # page(path, [fields], [headers]) returns bounded HTML or JSON responses.
    def page(path, fields=None, headers=None):
        # JSON requests exercise the API's nested destination object.
        data = (
            fields
            if isinstance(fields, bytes)
            else urllib.parse.urlencode(fields).encode()
            if fields is not None
            else None
        )
        request = urllib.request.Request(
            base + path,
            data=data,
            headers={'Referer': base + '/', **(headers or {})},
        )
        try:
            response = opener.open(request, timeout=60)
        except urllib.error.HTTPError as error:
            # Denial pages are expected results in the permission cases.
            response = error
        with response:
            body = response.read(2 * 1024**2).decode()
        assert 'Error - Perl execution failed' not in body, 'CGI crashed'
        return body

    page(
        '/session_login.cgi',
        {'user': name, 'pass': password},
        {'Cookie': 'testing=1'},
    )
    page.cookies = jar
    return page


try:
    # A stopped, private guest reaches destination validation without depending
    # on another job's source, guest agent, firmware or installed OS.
    fixture_uuid = str(uuid.uuid4())
    directory = Path(
        tempfile.mkdtemp(
            prefix='cloudmin-backup-access-', dir='/var/lib/libvirt/images'
        )
    )
    pool = connection.storagePoolDefineXML(
        '<pool type="dir"><name>cloudmin-backup-access-'
        + fixture_uuid
        + '</name><target><path>'
        + str(directory)
        + '</path></target></pool>',
        0,
    )
    pool.create(0)
    volume = pool.createXML(
        '<volume><name>fixture.raw</name><capacity>1048576</capacity>'
        '<target><format type="raw"/></target></volume>',
        0,
    )
    arch = connection.getInfo()[0]
    guest = connection.defineXML(f'''<domain type="kvm"><name>cloudmin-backup-access-{fixture_uuid}</name>
        <uuid>{fixture_uuid}</uuid><memory unit="MiB">256</memory><vcpu>1</vcpu>
        <os><type arch="{arch}" machine="{'virt' if arch == 'aarch64' else 'q35'}">hvm</type></os>
        <devices><disk type="file" device="disk"><driver name="qemu" type="raw"/>
        <source file="{volume.path()}"/><target dev="vda" bus="virtio"/></disk></devices></domain>''')
    # Check the public field contract through authenticated HTTP, not stubs.
    admin = account('create', {'admin': 1})
    backup = Fields(admin('/server-manager/backup_form.cgi'))
    assert {
        'all',
        'guests',
        'dest0_mode',
        'dest0_local_path',
        'compression',
        'shutdown',
        'token',
    } <= backup.names
    assert len(backup.values['attempt']) == 32
    restore = Fields(admin('/server-manager/restore_form.cgi'))
    assert {'src_mode', 'filename', 'token'} <= restore.names
    schedule = Fields(admin('/server-manager/backup_form.cgi?new=1'))
    assert {
        'frequency',
        'schedule_daily_hour',
        'schedule_hourly_minute',
        'schedule_weekly_weekday',
        'schedule_monthly_day',
        'schedule_yearly_month',
        'purge',
        'enabled',
    } <= schedule.names
    assert 'Error -' not in admin('/server-manager/backups.cgi')
    # The same edition boundary applies to backup, restore and schedule forms.
    pro = (module / 'pro/BackupCloud.pm').is_file()
    assert not (
        '--gpl' in sys.argv and pro or '--pro' in sys.argv and not pro
    ), 'Unexpected installed edition'
    modes = ['local', 'ssh', 's3'] + (
        ['gcs', 'azure', 'bb', 'dropbox', 'drive'] if pro else []
    )
    help_topics = set()
    for endpoint in (
        'backup_form.cgi',
        'restore_form.cgi',
        'backup_form.cgi?new=1',
    ):
        html = admin('/server-manager/' + endpoint)
        assert (
            Fields(html).options[
                'src_mode' if endpoint == 'restore_form.cgi' else 'dest0_mode'
            ]
            == modes
        )
        assert 'experimental' not in html.lower()
        assert (
            'Guest-agent preparation keeps' not in html
            and 'Full backups need extra space' not in html
        )
        help_topics.update(Fields(html).help_topics)
    # Follow contextual links through the real help renderer,
    # including cross-links.
    checked = set()
    while help_topics - checked:
        path = sorted(help_topics - checked)[0]
        body = admin(path)
        topic = path.rsplit('/', 1)[1]
        source = (module / 'help' / (topic + '.html')).read_text()
        heading = source.split('<header>', 1)[1].split('</header>', 1)[0]
        assert heading in body and 'Help file not found' not in body, topic
        checked.add(path)
        parser = Fields(body, path)
        help_topics.update(parser.help_topics)
    assert len(checked) >= 18, 'Contextual help links missing from forms'
    print('PASS: ' + str(len(checked)) + ' contextual help pages')
    if not pro:
        # Crafted API and schedule requests must fail before any
        # cloud connection.
        for mode in ('gcs', 'azure', 'bb', 'dropbox', 'drive'):
            body = json.dumps(
                {
                    'action': 'backup_inspect',
                    'token': backup.values['token'],
                    'attempt': secrets.token_hex(16),
                    'target': {'mode': mode},
                    'filename': 'fixture.tar',
                }
            ).encode()
            result = json.loads(
                admin(
                    '/server-manager/api.cgi',
                    body,
                    {'Content-Type': 'application/json'},
                )
            )
            assert 'requires Cloudmin Pro' in result.get('error', ''), result
            html = admin(
                '/server-manager/backup_sched.cgi',
                {'token': backup.values['token'], 'dest0_mode': mode},
            )
            assert 'requires Cloudmin Pro' in html
    print(
        ('Pro' if pro else 'GPL')
        + ': destination availability and edition enforcement passed'
    )
    # Valid tokens must not bypass read-only mode or host-administrator grants.
    readonly = account('create-readonly', {'admin': 1})
    delegated = account('create', {'admin': 0})
    for action in ('backup', 'backup_inspect', 'restore'):
        for page, reason in (
            (readonly, 'read-only'),
            (delegated, 'Access denied'),
        ):
            result = json.loads(
                page(
                    '/server-manager/api.cgi',
                    {'action': action, 'token': backup.values['token']},
                )
            )
            assert reason in result.get('error', ''), result
        result = json.loads(admin('/server-manager/api.cgi?action=' + action))
        assert 'Use POST' in result.get('error', ''), result
        result = json.loads(
            admin(
                '/server-manager/api.cgi',
                {'action': action, 'token': 'invalid'},
            )
        )
        assert 'expired' in result.get('error', '').lower(), result
    for endpoint in ('backup_form.cgi', 'restore_form.cgi', 'backups.cgi'):
        assert 'Access denied' in delegated('/server-manager/' + endpoint)
    # Host probing and trust changes enforce the same administrator boundaries.
    for page, reason in ((readonly, 'read-only'), (delegated, 'Access denied')):
        result = json.loads(
            page(
                '/server-manager/backup-host-key.cgi',
                {'action': 'check', 'token': backup.values['token']},
            )
        )
        assert reason in result.get('error', ''), result
    assert 'POST' in json.loads(
        admin('/server-manager/backup-host-key.cgi')
    ).get('error', '')
    assert (
        'expired'
        in json.loads(
            admin(
                '/server-manager/backup-host-key.cgi',
                {'action': 'trust', 'token': 'invalid'},
            )
        )
        .get('error', '')
        .lower()
    )
    # Every provider uses error(); retries keep the signed token and attempt.
    # Both submissions fail validation before any job, transfer or
    # schedule save.
    for endpoint, prefix in [
        ('backup.cgi', 'dest0'),
        ('backup_sched.cgi', 'dest0'),
        ('restore.cgi', 'src'),
    ]:
        for mode in modes:
            # Select only this test's guest; unrelated guests may be reserved.
            # Invalid destinations prevent jobs, transfers and schedule saves.
            fields = {
                'token': backup.values['token'],
                'attempt': secrets.token_hex(16),
                'all': 0,
                'guests': fixture_uuid,
                prefix + '_mode': mode,
                prefix + '_local_path': 'relative-path',
                prefix + '_ssh_host': '',
                prefix + '_ssh_path': '/var/tmp',
                prefix + '_ssh_authentication': 'key',
                prefix + '_ssh_key_file': '/nonexistent-fixture-key',
                'filename': 'fixture.tar',
            }
            # Each provider must fail on its own required destination fields.
            expected = (
                'Enter an absolute backup directory'
                if mode == 'local'
                else 'Enter a valid SSH server, username and port'
                if mode == 'ssh'
                else 'Enter a bucket or container name'
                if mode in ('s3', 'gcs', 'azure', 'bb')
                else 'Enter the cloud account'
            )
            html = admin('/server-manager/' + endpoint, fields)
            assert expected in html, (
                endpoint + ': ' + mode,
                re.findall(r'<tt>(.*?)</tt>', html, re.S)[-1:],
            )
            assert 'data-fatal-error-text' in html, (
                'Validation did not use error(): ' + endpoint + ': ' + mode
            )
            # Reuse the token and attempt with another invalid destination.
            fields.update(
                {prefix + '_mode': 'ssh', prefix + '_ssh_path': 'relative-path'}
            )
            html = admin('/server-manager/' + endpoint, fields)
            assert 'Enter an absolute backup directory' in html, (
                'Retry did not reach destination validation: '
                + endpoint
                + ': '
                + mode
            )
            assert 'data-fatal-error-text' in html
    print(
        'PASS: all '
        + str(len(modes))
        + ' destinations use error pages and accept retries in backup, schedule and restore'
    )
    # Optional browser tests exercise both themes with a real SSH approval flow.
    if '--browser' in sys.argv:
        from backup_browser import check_forms
        from backup_ssh_fixture import SSHFixture

        with SSHFixture(module) as ssh:
            check_forms(
                admin.cookies, 'authentic-theme', fixture_uuid, ssh, admin
            )
            ssh.reset()
            gray = account('create', {'admin': 1}, 'gray-theme')
            check_forms(gray.cookies, 'gray-theme', fixture_uuid, ssh, gray)
    print(
        'PASS: backup, restore and schedule forms; host-only access; read-only; CSRF; POST checks'
    )
# Remove every fixture login even when an assertion fails.
finally:
    for user in users:
        subprocess.run(
            ['perl', str(helper), 'delete', '', user],
            check=True,
            capture_output=True,
        )
    # These checks never start a VM. Remove only the objects created above.
    if guest:
        assert not guest.isActive(), (
            'Unexpected fixture startup; preserve it for inspection'
        )
        guest.undefine()
    if pool:
        # A partially created pool may never have reached its active state.
        if pool.isActive():
            pool.destroy()
        pool.undefine()
    if directory:
        # The private directory contains only this test's stopped guest disk.
        shutil.rmtree(directory)
    connection.close()
