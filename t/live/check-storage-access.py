"""Exercise storage access checks using temporary module-only Webmin users."""

import http.cookiejar
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request

assert os.uname().sysname == 'Linux' and os.geteuid() == 0
helper = str(Path(__file__).with_name('webmin-user.pl'))
base = 'https://127.0.0.1:10000'
for mode in ('create', 'create-readonly', 'create-other'):
    password = secrets.token_urlsafe(36)
    created = False
    try:
        subprocess.run(
            ['perl', helper, mode, 'gray-theme'],
            input=password + '\n',
            text=True,
            check=True,
        )
        created = True
        time.sleep(1)
        cookies = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cookies),
            urllib.request.HTTPSHandler(
                context=ssl._create_unverified_context()
            ),
        )
        opener.open(base + '/session_login.cgi', timeout=20).read()
        login = urllib.parse.urlencode(
            {'user': 'cloudmin-ui-check', 'pass': password, 'page': '/'}
        ).encode()
        opener.open(base + '/session_login.cgi', login, timeout=20).read()
        opener.addheaders = [('Referer', base + '/server-manager/index.cgi')]

        # page(path, [data]) retains expected access-denied response bodies.
        def page(path, data=None):
            try:
                return (
                    opener.open(base + path, data, timeout=20).read().decode()
                )
            except urllib.error.HTTPError as error:
                return error.read().decode()

        url = '/server-manager/storage.cgi'
        html = page(url)
        # An account without Cloudmin access must not receive storage inventory.
        if mode == 'create-other':
            assert 'cloudmin-storage-page' not in html, (
                'Unrelated module user saw storage inventory'
            )
            print('Module access boundary: PASS')
            continue
        assert 'cloudmin-storage-page' in html, re.sub('<[^>]+>', '', html)[
            -1000:
        ]
        fields = urllib.parse.urlencode(
            {
                'action': 'create',
                'name': 'cm-storage-denied',
                'path': '/var/lib/libvirt/cm-storage-denied',
                'token': 'invalid',
            }
        ).encode()
        result = page(url, fields)
        # Read-only inventory must omit controls and reject a forged write.
        if mode == 'create-readonly':
            assert 'name="action"' not in html, (
                'Read-only page offers mutation forms'
            )
            assert 'disabled in read-only mode' in result
            print('Read-only inventory and write refusal: PASS')
        # Writers still need a valid token and POST before changing storage.
        else:
            assert 'This form has expired' in result, re.sub(
                '<[^>]+>', '', result
            )[-1000:]
            result = page(
                url
                + '?action=create&name=cm-storage-denied&path=/var/lib/libvirt/cm-storage-denied'
            )
            assert 'Use the Storage form' in result
            print('Form token and POST requirements: PASS')
        # Both the selection review and deletion check access before lookup.
        for action in ('review_volumes', 'delete_volumes'):
            result = page(
                url,
                urllib.parse.urlencode(
                    {
                        'action': action,
                        'tab': 'volumes',
                        'volume': 'invalid/fixture.raw',
                        'revision': 'stale',
                        'confirm': '1',
                        'token': 'invalid',
                    }
                ).encode(),
            )
            assert (
                'disabled in read-only mode'
                if mode == 'create-readonly'
                else 'This form has expired'
            ) in result
            result = page(url + '?action=' + action + '&tab=volumes&confirm=1')
            assert 'Use the Storage form' in result
        print(
            'Volume review and deletion access, token and POST requirements: PASS'
        )
    finally:
        # Remove only the account created in this iteration.
        if created:
            subprocess.run(['perl', helper, 'delete'], check=True)
