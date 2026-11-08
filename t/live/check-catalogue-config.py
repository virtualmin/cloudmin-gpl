#!/usr/bin/python3
"""Check catalogue column configuration through Webmin on a disposable VM."""

import http.cookiejar
from html.parser import HTMLParser
import os
from pathlib import Path
import platform
import secrets
import subprocess
import time
import urllib.parse
import urllib.request
import ssl

# Account setup belongs on the disposable Linux VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')


class Form(HTMLParser):
    """
    Collect one Webmin form's submitted fields, headings and selection keys.
    """

    # __init__(self, action)
    # Collect controls and table metadata from the requested form action.
    def __init__(self, action):
        super().__init__()
        self.action = action
        self.active = False
        self.heading = False
        self.fields = {}
        self.inputs = {}
        self.headings = []
        self.keys = []
        self.sizes = []
        self.actions = []
        self.visible = []
        self.silent = False

    # handle_starttag(self, tag, attrs)
    # Track form controls and catalogue columns from opening tags.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Ignore script and style contents when collecting visible messages.
        if tag in ('script', 'style'):
            self.silent = True
        # Remember form actions and select only the requested form.
        if tag == 'form':
            self.actions.append(attrs.get('action'))
            self.active = attrs.get('action') == self.action
        # Leave controls from unrelated forms out of the submission.
        if not self.active:
            return
        # Collect each column heading separately for order assertions.
        if tag == 'th':
            self.heading = True
            self.headings.append('')
        # Keep raw byte counts to verify numeric size sorting.
        if 'data-filesize-bytes' in attrs:
            self.sizes.append(int(attrs['data-filesize-bytes']))
        # Named inputs provide tokens and catalogue selection values.
        if tag == 'input' and attrs.get('name'):
            name = attrs['name']
            self.inputs[name] = attrs
            # Collect every selectable catalogue key, including unchecked rows.
            if name == 'key':
                self.keys.append(attrs.get('value'))
            # Disabled controls and buttons are not ordinary submitted fields.
            if 'disabled' not in attrs and attrs.get('type') not in (
                'submit',
                'button',
            ):
                # Only checked radio buttons and checkboxes contribute values.
                if (
                    attrs.get('type') not in ('checkbox', 'radio')
                    or 'checked' in attrs
                ):
                    self.fields[name] = attrs.get('value', '')

    # handle_endtag(self, tag)
    # End the active form, heading or hidden-text region.
    def handle_endtag(self, tag):
        # Resume visible text after leaving script or style content.
        if tag in ('script', 'style'):
            self.silent = False
        # Do not collect controls beyond the selected form.
        if tag == 'form':
            self.active = False
        # Stop appending text to the current column heading.
        if tag == 'th':
            self.heading = False

    # handle_data(self, data)
    # Collect visible messages and column heading text.
    def handle_data(self, data):
        # Keep readable page text for diagnostics without script contents.
        if not self.silent and data.strip():
            self.visible.append(data.strip())
        # Build headings from all text chunks within the header cell.
        if self.active and self.heading:
            self.headings[-1] += data


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

    # request(path, [fields]) Send a GET or form POST with this session's
    # cookies and same-origin referer.
    def request(path, fields=None):
        payload = (
            urllib.parse.urlencode(fields).encode()
            if fields is not None
            else None
        )
        req = urllib.request.Request(
            base + path,
            data=payload,
            headers={'Referer': base + '/config.cgi?module=server-manager'},
        )
        with opener.open(req, timeout=30) as response:
            page = response.read().decode('utf-8', errors='replace')
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
            'page': '/server-manager/index.cgi',
        },
    )
    # Catalogue columns belong with image download and import settings.
    editor = Form('config_save.cgi')
    config_page = request('/config.cgi?module=server-manager&section=line6')
    editor.feed(config_page)
    assert 'cataloguecol_size' in editor.inputs, (
        'Download size configuration is missing; form actions: '
        + repr(editor.actions)
        + '; page text: '
        + ' '.join(editor.visible)[-2000:]
    )
    assert 'disabled' in editor.inputs['cataloguecol_name'], (
        'Image column can be unchecked'
    )
    print(
        'PASS: native Module Configuration renders selectable catalogue columns'
    )

    # Save a subset through the real parser and check the resulting table.
    fields = {
        key: value
        for key, value in editor.fields.items()
        if not key.startswith('cataloguecol_')
    }
    fields.update(
        cataloguecol_architecture='1', cataloguecol_size='1', save='Save'
    )
    request('/config_save.cgi', fields)
    assert b'catalogue_columns=name,architecture,size' in config.read_bytes(), (
        'Column selection was not saved'
    )
    table = Form('catalogue.cgi')
    table.feed(request('/server-manager/images.cgi?mode=catalogue'))
    assert [label.strip() for label in table.headings] == [
        '',
        'Image',
        'Architecture',
        'Download size',
    ], table.headings
    assert table.keys and len(set(table.keys)) == len(table.keys), (
        'Rows or bulk selection keys changed'
    )
    assert len(set(table.sizes)) > 1 and all(
        size > 0 for size in table.sizes
    ), 'Numeric download sizes are missing'
    print(
        'PASS: saved selection controls the live table and preserves entries, keys and sizes'
    )

    # Reopening the category must preserve both selected and hidden columns.
    reopened = Form('config_save.cgi')
    reopened.feed(request('/config.cgi?module=server-manager&section=line6'))
    assert 'checked' in reopened.inputs['cataloguecol_size'], (
        'Saved size selection did not reload'
    )
    assert 'checked' not in reopened.inputs['cataloguecol_state'], (
        'Hidden column was re-enabled'
    )
    print('PASS: configuration reopens with the saved selection')
finally:
    # Restore the administrator's exact settings and remove the
    # temporary account.
    config.write_bytes(original)
    subprocess.run(['perl', str(helper), 'delete'], check=True)
