#!/usr/bin/python3
"""Check normal Webmin CGI execution and write permissions on a disposable VM."""
import http.cookiejar
import json
import os
from pathlib import Path
import platform
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

# Account and configuration changes belong on the disposable Linux VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
here = Path(__file__).resolve().parent
module = here.parent.parent
helper = here / 'webmin-user.pl'
probe = module / ('cgi_check_' + secrets.token_hex(8) + '.cgi')
base = 'https://127.0.0.1:10000'
created = False
entry_key = None


class Inputs(HTMLParser):
    """Read generated form fields without relying on HTML attribute order."""

    # __init__(self, page)
    # Parse input values from an HTML page.
    def __init__(self, page):
        super().__init__()
        self.values = {}
        self.feed(page)

    # handle_starttag(self, tag, attrs)
    # Index input values by name for subsequent form submissions.
    def handle_starttag(self, tag, attrs):
        # Extract tokens and hidden fields without treating page text as inputs.
        if tag == 'input':
            attrs = dict(attrs)
            self.values[attrs.get('name')] = attrs.get('value', '')


# session()
def session():
    """Create a browser session with cookies kept only in this VM process."""
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))


# request(path, [fields])
def request(path, fields=None):
    """Send a real HTTP request and retain Webmin error pages for assertions."""
    body = urllib.parse.urlencode(fields).encode() if fields is not None else None
    req = urllib.request.Request(base + path, data=body, headers={
        'Referer': base + '/server-manager/images.cgi'})
    try:
        response = opener.open(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        text = response.read().decode()
    assert 'Error - Perl execution failed' not in text, path + ' crashed'
    return text


# login([readonly])
def login(readonly=False):
    """Create a module-only account; never print or save its password."""
    global opener, created
    password = secrets.token_urlsafe(36)
    subprocess.run(['perl', str(helper), 'create-readonly' if readonly else 'create'],
                   input=password + '\n', text=True, check=True)
    created = True
    time.sleep(1)
    opener = session()
    request('/session_login.cgi')
    request('/session_login.cgi', {'user': 'cloudmin-ui-check', 'pass': password,
                                  'page': '/server-manager/images.cgi'})


# delete_entry()
def delete_entry():
    """Remove only the catalogue record created by this test."""
    global entry_key
    # Skip deletion until this run has created a catalogue entry.
    if entry_key:
        token = Inputs(request('/server-manager/images.cgi?mode=catalogue')).values['token']
        request('/server-manager/catalogue.cgi', {
            'action': 'delete', 'key': entry_key, 'confirm': '1', 'token': token})
        assert 'Catalogue entry no longer exists' in request(
            '/server-manager/edit_catalog_image.cgi?' + urllib.parse.urlencode({'key': entry_key}))
        entry_key = None


# This temporary endpoint uses the production module initialization unchanged.
with probe.open('x') as stream:
    stream.write('''#!/usr/bin/perl
require './server-manager-lib.pl';
die "Fixture access denied" if ($remote_user ne 'cloudmin-ui-check');
print_json({uid => 0 + $<, euid => 0 + $>, user => $remote_user,
    config => $config_directory}, 0, 1);
''')
probe.chmod(0o755)
try:
    opener = session()
    assert '"uid"' not in request('/server-manager/' + probe.name), 'Anonymous CGI access'
    login()
    context = json.loads(request('/server-manager/' + probe.name))
    assert context == {'uid': 0, 'euid': 0, 'user': 'cloudmin-ui-check', 'config': '/etc/webmin'}
    print('CGI uses the authenticated Webmin user, root UID and normal configuration: PASS')

    # Write endpoints must require POST and valid form tokens.
    for endpoint, context, message in (
            ('image.cgi', 'Cannot import an image', 'Use the Images form to start an import'),
            ('catalogue.cgi', 'Cannot update image catalogue', 'Use the catalogue form to submit changes'),
            ('save_catalog_image.cgi', 'Cannot save catalogue entry', 'Use the catalogue form to submit changes'),
            ('delete_images.cgi', 'Cannot delete images', 'Use Image Manager to select images for deletion')):
        page = request('/server-manager/' + endpoint)
        assert message in page, endpoint + ' accepts GET'
        assert context in page, endpoint + ' lacks error context'
    # Failed page loads name the operation before showing the underlying cause.
    for path, context in (
            ('machine.cgi?id=invalid', 'Cannot show virtual machine details'),
            ('edit_machine.cgi?id=invalid', 'Cannot edit virtual machine'),
            ('edit_machine.cgi?id=invalid&delete=1', 'Cannot delete virtual machine'),
            ('progress.cgi?job=invalid', 'Cannot show virtual machine progress'),
            ('setup_image.cgi?job=invalid', 'Cannot show image progress'),
            ('edit_catalog_image.cgi?key=missing', 'Cannot open catalogue entry')):
        assert context in request('/server-manager/' + path), path + ' lacks error context'
    assert 'Cannot manage virtual machine jobs' in request('/server-manager/machine_jobs.cgi',
                                                         {'action': 'invalid'})
    rejected = json.loads(request('/server-manager/api.cgi?action=create'))
    assert 'POST' in rejected['error']
    endpoints = ('image.cgi', 'setup_image.cgi', 'catalogue.cgi', 'save_catalog_image.cgi',
                 'delete_images.cgi', 'setup_machine.cgi', 'clone_machine.cgi', 'api.cgi')
    for endpoint in endpoints:
        for token in ('', 'invalid'):
            page = request('/server-manager/' + endpoint, {
                'action': 'create', 'vm_operation': 'clone' if endpoint == 'clone_machine.cgi' else 'create',
                'install_type': 'download', 'token': token,
                'job': 'f' * 32, 'ajax': '1'})
            assert 'This form has expired' in page, endpoint + ' did not reject the token'
    print('GET changes and missing or invalid form tokens are rejected: PASS')

    # A valid form must still reach the backend and survive a normal redirect.
    fields = Inputs(request('/server-manager/edit_catalog_image.cgi?new=1')).values
    fields.update(name='CGI fixture', vendor='Test', os='Linux', release='1',
                  url='https://example.test/fixture.qcow2', checksum_url='https://example.test/SHA256SUMS',
                  checksum_algorithm='sha256', format='qcow2',
                  status='supported', min_disk_gib='0', cloud_init='1')
    entry_key = fields['id'] + ':' + fields['architecture']
    page = request('/server-manager/save_catalog_image.cgi', fields)
    assert 'CGI fixture' in page and 'Image Manager' in page
    assert 'Catalogue entry no longer exists' not in request(
        '/server-manager/edit_catalog_image.cgi?' + urllib.parse.urlencode({'key': entry_key})), 'Catalogue creation was rejected'
    delete_entry()
    print('Valid catalogue creation, redirect and deletion: PASS')

    # Read-only users retain module access, but each mutation must refuse them.
    subprocess.run(['perl', str(helper), 'delete'], check=True)
    created = False
    login(readonly=True)
    for endpoint in endpoints + ('image-upload.cgi',):
        page = request('/server-manager/' + endpoint, {'action': 'create', 'vm_operation': 'clone' if endpoint == 'clone_machine.cgi' else 'create',
                'token': fields['token']})
        assert 'read-only' in page, endpoint
    print('Read-only requests cannot change images, catalogue entries or virtual machines: PASS')
finally:
    try:
        # Only remove the fixture account after successful account setup.
        if created:
            try:
                delete_entry()
            finally:
                subprocess.run(['perl', str(helper), 'delete'], check=True)
    finally:
        probe.unlink()
