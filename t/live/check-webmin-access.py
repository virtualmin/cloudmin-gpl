#!/usr/bin/python3
"""
Check Cloudmin's root-only tab and independent native ACLs without changing a
guest.
"""

import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Native ACL fixtures must run on the test host, never the workstation.
assert sys.platform == 'linux' and os.geteuid() == 0, (
    'Run on a Linux test host as root'
)
uuid = sys.argv[1]
here = Path(__file__).resolve().parent
user = 'cloudmin-frame-check-' + secrets.token_hex(4)
identity = str(time.time_ns() // 1000)
base = 'https://127.0.0.1:10000'
created = records = False
root_session = None


# run(name, *args, [data]) invokes a fixture with optional private stdin data.
# Capture its output so temporary sessions and passwords never reach test logs.
def run(name, *args, data=None):
    result = subprocess.run(
        ['perl', str(here / name), *args],
        input=data,
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        'Fixture setup or cleanup failed: ' + result.stderr[-1000:]
    )
    return result.stdout


# client() returns an independent cookie jar for each host identity.
def client():
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )


# request(opener, path, [fields], [session]) makes a same-origin HTTP request.
# Omitted fields use GET; a supplied session overrides the opener's
# login cookie.
def request(opener, path, fields=None, session=None):
    headers = {'Referer': base + '/servers/'}
    # Keep the temporary root session separate from delegated cookies.
    if session:
        headers['Cookie'] = 'sid=' + session
    req = urllib.request.Request(
        base + path,
        data=urllib.parse.urlencode(fields, doseq=True).encode()
        if fields is not None
        else None,
        headers=headers,
    )
    try:
        response = opener.open(req, timeout=30)
    except urllib.error.HTTPError as error:
        # Access refusals are expected responses whose bodies need assertions.
        response = error
    with response:
        page = response.read().decode()
    assert 'Error - Perl execution failed' not in page, 'CGI execution failed'
    return page


try:
    # Give a temporary non-root account broad Cloudmin and native module grants.
    password = secrets.token_urlsafe(36)
    run(
        'webmin-user.pl',
        'create',
        'authentic-theme',
        user,
        data=password + '\n',
    )
    created = True
    run('webmin-access-fixture.pl', 'create', user, identity)
    records = True
    delegated = client()
    request(delegated, '/session_login.cgi')
    request(delegated, '/session_login.cgi', {'user': user, 'pass': password})
    run('webmin-user.pl', 'servers', 'authentic-theme', user)
    run(
        'webmin-user.pl',
        'acl',
        'authentic-theme',
        user,
        data=json.dumps({'admin': 1}),
    )
    # Broad grants must not bypass the root-only tab, including legacy URLs.
    route = '/server-manager/remote_access.cgi?id=' + uuid + '&tab=webmin'
    for suffix in ('', '&standalone=1'):
        page = request(delegated, route + suffix)
        assert '<iframe' not in page and 'permissions' in page, (
            'Non-root wrapper access was allowed'
        )
    page = request(
        delegated,
        '/server-manager/remote_access.cgi',
        {'id': uuid, 'tab': 'webmin', 'register_webmin': 1, 'token': 'forged'},
    )
    assert 'permissions' in page, (
        'Non-root registration did not fail at the permission gate'
    )
    # Keep SSH available while hiding Webmin registration controls.
    page = request(delegated, route.replace('tab=webmin', 'tab=ssh'))
    assert 'SSH terminal' in page and 'tab=webmin' not in page, (
        'Other modes or Webmin tab visibility regressed'
    )
    assert 'name="webmin_register"' not in request(
        delegated, '/server-manager/machine_form.cgi'
    )
    proxy = '/servers/link.cgi/' + identity + '/'
    # Direct access follows the explicitly granted native module permissions.
    page = request(delegated, proxy)
    assert 'name="pass"' in page or "name='pass'" in page, (
        'Native wildcard access was overridden'
    )
    print(
        'PASS: Cloudmin denies non-root Webmin access; SSH and explicitly granted native access remain available',
        flush=True,
    )
    # Narrow native access to one synthetic record and check each exposed route.
    run('webmin-access-fixture.pl', 'restrict', user, identity)
    assert 'not allowed to use this server' in request(delegated, proxy), (
        'Native entry ACL was bypassed'
    )
    assert 'not allowed to edit servers' in request(
        delegated, '/servers/edit_serv.cgi?id=' + identity
    )
    data = json.loads(request(delegated, '/servers/index-json.cgi'))
    assert len(data) == 1 and str(data[0]['id']) == str(int(identity) + 1)
    assert set(data[0]) == {'id', 'host', 'desc'}, (
        'Server list includes private fields'
    )
    # A delete containing a denied record must leave both records intact.
    page = request(
        delegated,
        '/servers/delete_servs.cgi',
        {'d': [str(int(identity) + 1), identity], 'confirm': 1},
    )
    assert 'not allowed to delete servers' in page
    run('webmin-access-fixture.pl', 'check', user, identity)
    print(
        'PASS: native JSON filters credentials and restricted entries; bulk deletion checks every grant',
        flush=True,
    )
    # Root retains access through both native and Cloudmin routes.
    root_session = json.loads(run('webmin-user.pl', 'root-session'))['sid']
    root = client()
    page = request(root, proxy, session=root_session)
    assert 'name="pass"' in page or "name='pass'" in page, (
        'Root cannot reach native login prompt; '
        + (
            'session login'
            if 'session_login.cgi' in page
            else 'permission denial'
            if 'not allowed' in page
            else 'unexpected response'
        )
    )
    page = request(root, route, session=root_session)
    assert '<iframe' not in page and 'data-webmin-direct' in page, (
        'Root cannot open guest Webmin options'
    )
    print(
        'PASS: root can reach the native login prompt and direct guest options',
        flush=True,
    )
finally:
    try:
        # Remove only this run's temporary session and synthetic server records.
        if root_session:
            run(
                'webmin-user.pl',
                'delete-root-session',
                data=root_session + '\n',
            )
        if records:
            # Remove synthetic entries only after their creation succeeded.
            run('webmin-access-fixture.pl', 'delete', user, identity)
    finally:
        # Revoke the fixture account even if native record cleanup fails.
        if created:
            run('webmin-user.pl', 'delete', 'authentic-theme', user)
