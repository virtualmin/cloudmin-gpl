"""Exercise networking access checks using temporary module-only Webmin users."""
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
        subprocess.run(['perl', helper, mode, 'gray-theme'], input=password+'\n', text=True, check=True)
        created = True
        time.sleep(1)
        cookies = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cookies),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
        opener.open(base+'/session_login.cgi', timeout=20).read()
        login = urllib.parse.urlencode({'user':'cloudmin-ui-check', 'pass':password, 'page':'/'}).encode()
        opener.open(base+'/session_login.cgi', login, timeout=20).read()
        opener.addheaders = [('Referer', base+'/server-manager/index.cgi')]
        # page(path, [data]) retains expected access-denied response bodies.
        def page(path, data=None):
            try:
                return opener.open(base+path, data, timeout=20).read().decode()
            except urllib.error.HTTPError as error:
                return error.read().decode()
        url = '/server-manager/networks.cgi'
        html = page(url)
        # An account without Cloudmin access must not receive inventory.
        if mode == 'create-other':
            assert 'cloudmin-network-page' not in html, 'Unrelated module user saw host networking'
            print('Module access boundary: PASS')
            continue
        assert 'cloudmin-network-page' in html, re.sub('<[^>]+>', '', html)[-1000:]
        fields = urllib.parse.urlencode({'action':'bridge_review', 'name':'cmtestbr',
                                        'source':'enp0s1', 'token':'invalid'}).encode()
        result = page(url, fields)
        # Read-only access must omit controls and reject forged writes.
        if mode == 'create-readonly':
            assert 'name="action"' not in html, 'Read-only page offers mutation forms'
            assert 'disabled in read-only mode' in result
            print('Read-only inventory and write refusal: PASS')
        # Writers still need a valid token and POST before changing networks.
        else:
            assert 'This form has expired' in result, re.sub('<[^>]+>', '', result)[-1000:]
            result = page(url+'?action=bridge_review&name=cmtestbr&source=enp0s1')
            assert 'Use the Networking form' in result
            print('Form token and POST requirements: PASS')
        status = json.loads(page(url+'?status=1&previous=changed'))
        assert not any(key in status for key in ('files', 'saved', 'defs'))
        assert 'content' not in status or isinstance(status['content'], str)
    finally:
        # Remove the account only if this iteration created it.
        if created:
            subprocess.run(['perl', helper, 'delete'], check=True)
