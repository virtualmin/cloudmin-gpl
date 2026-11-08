#!/usr/bin/python3
"""Check the image-size setting through Webmin on a disposable Linux host."""

import http.cookiejar
from html.parser import HTMLParser
import os
from pathlib import Path
import platform
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request

# Configuration and account changes belong on the disposable guest.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')


class Form(HTMLParser):
    """
    Collect the native configuration form without changing unrelated fields.
    """

    # __init__(self)
    # Start outside the configuration form with no collected fields.
    def __init__(self):
        super().__init__()
        self.active = False
        self.select = None
        self.fields = {}

    # handle_starttag(self, tag, attrs)
    # Keep enabled controls and the selected radio values from config_save.cgi.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Select the native settings form rather than unrelated page forms.
        if tag == 'form':
            self.active = attrs.get('action') == 'config_save.cgi'
        # Keep enabled, named inputs from the selected form only.
        if (
            self.active
            and tag == 'input'
            and attrs.get('name')
            and 'disabled' not in attrs
        ):
            kind = attrs.get('type')
            # Match browser submission rules for buttons and checkable controls.
            if kind not in ('submit', 'button') and (
                kind not in ('radio', 'checkbox') or 'checked' in attrs
            ):
                self.fields[attrs['name']] = attrs.get('value', '')
        # Preserve select settings now grouped with the import limit.
        elif self.active and tag == 'select':
            self.select = attrs.get('name')
        # Keep other General settings when submitting only an
        # import-limit change.
        elif self.active and tag == 'option' and self.select:
            # Browser defaults to the first option unless one is selected.
            if self.select not in self.fields or 'selected' in attrs:
                self.fields[self.select] = attrs.get('value', '')

    # handle_endtag(self, tag)
    # Exclude inputs belonging to later page content.
    def handle_endtag(self, tag):
        # Stop collecting controls at the end of the selected form.
        if tag == 'form':
            self.active = False
        # End option collection when its owning selector closes.
        elif tag == 'select':
            self.select = None


helper = Path(__file__).with_name('webmin-user.pl')
config = Path('/etc/webmin/server-manager/config')
original = config.read_bytes()
password = secrets.token_urlsafe(36)
subprocess.run(
    ['perl', str(helper), 'create'],
    input=password + '\n',
    text=True,
    check=True,
)
try:
    time.sleep(1)
    base = 'https://127.0.0.1:10000'
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )

    # request(path, [fields])
    # Use the temporary account for real same-origin Webmin requests.
    def request(path, fields=None):
        body = (
            urllib.parse.urlencode(fields).encode()
            if fields is not None
            else None
        )
        req = urllib.request.Request(
            base + path,
            data=body,
            headers={
                'Referer': base
                + '/config.cgi?module=server-manager&section=line6'
            },
        )
        with opener.open(req, timeout=60) as response:
            page = response.read().decode()
        assert 'Error - Perl execution failed' not in page, (
            'CGI execution failed'
        )
        return page

    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {
            'user': 'cloudmin-ui-check',
            'pass': password,
            'page': '/server-manager/images.cgi',
        },
    )
    # The import limit must render in the category that owns the image settings.
    editor = Form()
    editor.feed(request('/config.cgi?module=server-manager&section=line6'))
    assert 'image_max_size_def' in editor.fields, (
        'Import limit configuration is missing'
    )
    print(
        'PASS: native configuration renders the optional image-size limit',
        flush=True,
    )

    # Saving through Webmin must update controller configuration and
    # browser data.
    fields = editor.fields | {
        'image_max_size_def': '0',
        'image_max_size': '32',
        'save': 'Save',
    }
    request('/config_save.cgi', fields)
    assert b'image_max_size=32\n' in config.read_bytes(), (
        'Configured cap was not saved'
    )
    page = request('/server-manager/images.cgi')
    assert 'data-max-bytes="34359738368"' in page, (
        'Browser does not receive the configured cap'
    )
    assert 'Maximum image file size: 32 GiB.' in page, (
        'Configured cap is not explained'
    )
    print(
        'PASS: saved 32 GiB cap reaches the import form and browser validation',
        flush=True,
    )

    # Available-space mode removes the fixed cap from both storage and
    # UI settings.
    request('/config_save.cgi', fields | {'image_max_size_def': '1'})
    assert b'image_max_size=0\n' in config.read_bytes(), (
        'Available-space mode was not saved'
    )
    page = request('/server-manager/images.cgi')
    assert 'data-max-bytes="0"' in page, 'Browser retains a fixed cap'
    assert 'Image size is limited by available space' in page, (
        'Available-space mode is not explained'
    )
    print(
        'PASS: available-space mode removes the fixed browser cap', flush=True
    )
finally:
    # Restore the administrator's exact settings and delete the
    # temporary account.
    config.write_bytes(original)
    subprocess.run(['perl', str(helper), 'delete'], check=True)
