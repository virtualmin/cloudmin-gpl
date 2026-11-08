#!/usr/bin/python3
"""Check clone CGI rendering, CSRF and delegated access on a disposable host."""

import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

# Fixture accounts and guest inspection belong only on the Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt

connection = libvirt.open('qemu:///system')
sources = [
    d
    for d in connection.listAllDomains()
    if d.name().startswith('cloudmin-clone-test-')
]
if not sources:
    # Reuse a live-test fixture instead of inspecting an unrelated guest.
    raise SystemExit('Run while check-clones.py has an active fixture')
source = min(sources, key=lambda domain: len(domain.name())).UUIDString()
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
base = 'https://127.0.0.1:10000'
users = []


class Fields(HTMLParser):
    # __init__(self, html) collects form names and values without
    # printing secrets.
    def __init__(self, html):
        super().__init__()
        self.names = set()
        self.values = {}
        self.feed(html)

    # handle_starttag(self, tag, attrs) records only named form controls.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ('input', 'select', 'textarea') and attrs.get('name'):
            # Field names prove the public form contract without exposing XML.
            self.names.add(attrs['name'])
            self.values[attrs['name']] = attrs.get('value', '')


# account(mode, grants) creates a local fixture login whose password stays
# in RAM.
def account(mode, grants):
    name = 'cloudmin-spa-check-' + secrets.token_hex(4)
    password = secrets.token_urlsafe(40)
    subprocess.run(
        ['perl', str(helper), mode, 'authentic-theme', name],
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
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )

    # page(path, [fields], [headers]) returns bounded HTML or JSON responses.
    def page(path, fields=None, headers=None):
        request = urllib.request.Request(
            base + path,
            data=urllib.parse.urlencode(fields).encode()
            if fields is not None
            else None,
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
    return page


try:
    # Administrators see clone choices without source credentials or secure XML.
    admin = account('create', {'admin': 1})
    form = Fields(admin('/server-manager/clone_machine_form.cgi?id=' + source))
    assert {
        'name',
        'password',
        'template',
        'plan',
        'clone_mode',
        'token',
        'revision',
        'hostname_set',
    } <= form.names
    assert (
        not {'virtualmin_key', 'virtualmin_serial', 'source_xml'} & form.names
    )
    readonly = account('create-readonly', {'admin': 1})
    # Read-only and delegated users cannot inherit an administrator's
    # clone access.
    delegated = account('create', {'admin': 0, 'vms': source, 'power': 1})
    for page, reason in ((readonly, 'read-only'), (delegated, 'Access denied')):
        result = json.loads(
            page(
                '/server-manager/api.cgi',
                {
                    'action': 'clone',
                    'id': source,
                    'token': form.values['token'],
                },
            )
        )
        assert reason in result.get('error', ''), result
    result = json.loads(
        delegated('/server-manager/api.cgi?action=clone_options&id=' + source)
    )
    assert 'Access denied' in result.get('error', ''), result
    assert 'clone_machine_form.cgi' not in delegated(
        '/server-manager/machine.cgi?id=' + source
    )
    result = json.loads(
        admin('/server-manager/api.cgi?action=clone&id=' + source)
    )
    # Mutation requires both POST and a valid signed form token.
    assert 'Use POST' in result.get('error', ''), result
    result = json.loads(
        admin(
            '/server-manager/api.cgi',
            {'action': 'clone', 'id': source, 'token': 'invalid'},
        )
    )
    assert 'expired' in result.get('error', '').lower(), result
    # A valid token does not bypass the source revision or persist a failed job.
    result = json.loads(
        admin(
            '/server-manager/api.cgi',
            {
                'action': 'clone',
                'id': source,
                'token': form.values['token'],
                'revision': 'stale',
                'clone_mode': 'unchanged',
                'confirm_unchanged': 1,
                'name': 'invalid-fixture',
            },
        )
    )
    assert 'changed' in result.get('error', ''), result
    choices = json.loads(
        admin('/server-manager/api.cgi?action=clone_options&id=' + source)
    )['result']
    baseline = {
        'action': 'clone',
        'id': source,
        'token': form.values['token'],
        'revision': choices['revision'],
        'clone_mode': 'unchanged',
        'confirm_unchanged': 1,
        'name': 'invalid-fixture',
        'start': 0,
        'autostart': 0,
        'nvram_mode': 'fresh',
    }
    for changes, message in (
        ({'start': 1}, 'stopped'),
        ({'autostart': 1}, 'stopped'),
        ({'confirm_unchanged': 0}, 'Confirm'),
        ({'clone_mode': 'unprepared'}, 'Select prepared'),
        ({'name': '../escape'}, 'name'),
    ):
        result = json.loads(
            admin('/server-manager/api.cgi', {**baseline, **changes})
        )
        assert message in result.get('error', ''), result
    assert not any(
        job['name'] == 'invalid-fixture'
        for job in json.loads(admin('/server-manager/api.cgi?action=list'))[
            'result'
        ]
    )
    print(
        'PASS: clone form, host-only access, read-only denial, CSRF, POST and stale-source checks'
    )
finally:
    # Remove only accounts allocated by this run, including after an assertion.
    for user in users:
        subprocess.run(
            ['perl', str(helper), 'delete', '', user],
            check=True,
            capture_output=True,
        )
    connection.close()
