#!/usr/bin/python3
"""Exercise catalogue forms on a disposable Cloudmin VM; no images are downloaded."""

import html
import hashlib
from html.parser import HTMLParser
import http.cookiejar
import json
import os
from pathlib import Path
import platform
import secrets
import re
import ssl
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

# Account and image fixtures belong on the disposable Linux VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')

helper = Path(__file__).with_name('webmin-user.pl')
root = Path(__file__).resolve().parents[2]
custom_path = Path('/etc/webmin/server-manager/image-catalogue.json')
bundled_before = (root / 'catalog/images.json').read_bytes()
custom_before = json.loads(custom_path.read_text()) if custom_path.exists() else {
    'schema': 1, 'images': [], 'disabled': {}}
base = 'https://127.0.0.1:10000'


class Inputs(HTMLParser):
    """Read actual Webmin input attributes without depending on attribute order."""

    # __init__(self, page)
    # Parse input controls from an HTML page.
    def __init__(self, page):
        super().__init__()
        self.inputs = []
        self.feed(page)

    # handle_starttag(self, tag, attrs)
    # Retain input attributes for token and selection lookups.
    def handle_starttag(self, tag, attrs):
        # Only input controls carry the tokens and keys used by this fixture.
        if tag == 'input':
            self.inputs.append(dict(attrs))

    # value(self, name)
    # Return the value of the first input with the requested name.
    def value(self, name):
        return next(item.get('value', '') for item in self.inputs if item.get('name') == name)

    # choices(self)
    # Return the catalogue entry keys available for selection.
    def choices(self):
        return [item['value'] for item in self.inputs if item.get('name') == 'id_item']


# request(path, [fields])
def request(path, fields=None):
    """Submit normal browser requests with Webmin's expected same-origin referer."""
    data = None if fields is None else urllib.parse.urlencode(fields, doseq=True).encode()
    req = urllib.request.Request(base + path, data=data,
                                 headers={'Referer': base + '/server-manager/images.cgi'})
    with opener.open(req, timeout=30) as response:
        page = response.read().decode('utf-8')
    assert 'Error - Perl execution failed' not in page, path + ' crashed'
    return page


# login([readonly])
def login(readonly=False):
    """Create a local-only test account with a password kept in VM memory."""
    global opener, created
    password = secrets.token_urlsafe(36)
    action = 'create-readonly' if readonly else 'create'
    subprocess.run(['perl', str(helper), action], input=password + '\n', text=True, check=True)
    created = True
    time.sleep(1)
    cookies = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookies),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    request('/session_login.cgi')
    page = request('/session_login.cgi', {'user': 'cloudmin-ui-check', 'pass': password,
                                        'page': '/server-manager/images.cgi'})
    assert any(cookie.name == 'sid' for cookie in cookies), 'Fixture login failed'


# bulk(action, keys, [confirm])
def bulk(action, keys, confirm=False):
    """Use a fresh signed token for each catalogue operation."""
    page = request('/server-manager/images.cgi?mode=catalogue')
    fields = {'token': Inputs(page).value('token'), 'action': action, 'key': keys}
    # Destructive bulk operations require the explicit confirmation field.
    if confirm:
        fields['confirm'] = '1'
    return request('/server-manager/catalogue.cgi', fields)


created = False
key = None
bundle_key = None
bundle_disabled = False
checksum_job = None
try:
    login()
    created = True
    page = request('/server-manager/images.cgi?mode=catalogue')
    assert 'Image Catalogue' in page and 'Source' in page and 'Cloudmin' in page
    assert 'Operating System / Release' not in page
    assert 'Release date' in page and 'End of life' in page
    assert re.search(r'<a\b(?=[^>]*class=["\'][^"\']*\bui_link\b)(?=[^>]*download=)', page)
    assert '/help.cgi/server-manager/images' in page, 'Main Image Manager lost its help'
    assert not custom_path.exists() or json.loads(custom_path.read_text()) == custom_before
    edit = request('/server-manager/edit_catalog_image.cgi?new=1')
    assert '/help.cgi/server-manager/images' not in edit, 'Subpage repeats main help'
    assert '(HTTPS)' not in edit and '(optional)' not in edit and '0 for unspecified' not in edit
    inputs = Inputs(edit)
    image_id, arch = inputs.value('id'), inputs.value('architecture')
    key = image_id + ':' + arch
    name = 'Catalogue fixture <test>'
    fields = dict(token=inputs.value('token'), new='1', id=image_id, architecture=arch,
                  name=name, vendor='Test', os='Linux', release='1', status='supported',
                  url='https://example.test/fixture.qcow2',
                  checksum_url='https://example.test/SHA256SUMS', checksum_algorithm='sha256',
                  source_url='', format='qcow2', firmware='', min_disk_gib='0',
                  release_date='2024-02-29', end_of_life='2030-01-01',
                  cloud_init='1', guest_agent='0')

    # Rejected forms must not create or modify custom entries.
    invalid = request('/server-manager/save_catalog_image.cgi', {**fields, 'token': 'invalid'})
    assert 'This form has expired' in invalid
    invalid = request('/server-manager/save_catalog_image.cgi', {**fields, 'url': 'http://example.test/fixture.qcow2'})
    assert 'Enter a direct HTTPS image URL' in invalid
    assert Inputs(invalid).value('name') == name, 'Validation did not retain submitted fields'
    invalid = request('/server-manager/save_catalog_image.cgi', {**fields, 'release_date': '2025-02-30'})
    assert 'invalid release_date' in invalid and '/help.cgi/server-manager/images' not in invalid
    assert not custom_path.exists() or json.loads(custom_path.read_text()) == custom_before

    # Create, reload and edit a custom record through the actual CGI forms.
    page = request('/server-manager/save_catalog_image.cgi', fields)
    assert image_id in Inputs(page).choices(), 'Custom image missing from download selector'
    assert html.escape(name) in page and '>Custom<' in page
    assert '2024-02-29' in page and '2030-01-01' in page
    assert (custom_path.stat().st_mode & 0o777) == 0o600
    stored = json.loads(custom_path.read_text())
    assert any(item['id'] == image_id for item in stored['images'])
    saved = next(item for item in stored['images'] if item['id'] == image_id)
    assert saved['release_date'] == '2024-02-29' and saved['end_of_life'] == '2030-01-01'
    duplicate = request('/server-manager/save_catalog_image.cgi', fields)
    assert 'Catalogue entry already exists' in duplicate
    fields.update(new='0', name='Catalogue fixture edited')
    page = request('/server-manager/save_catalog_image.cgi', fields)
    assert fields['name'] in page
    print('Create, edit, duplicate submission, validation and source labels: PASS')

    # Disabled entries stay in the catalogue but leave the download selector.
    page = bulk('disable', [key])
    assert image_id not in Inputs(page).choices()
    assert fields['name'] in page and '>Disabled<' in page
    page = bulk('enable', [key])
    assert image_id in Inputs(page).choices()

    # Supplied entries are inspectable and can be disabled, but remain immutable.
    bundled_id = next(value for value in Inputs(page).choices() if not value.startswith('custom-'))
    bundle_key = bundled_id + ':' + arch
    details = request('/server-manager/edit_catalog_image.cgi?' + urllib.parse.urlencode({'key': bundle_key}))
    assert 'Image Details' in details and 'save_catalog_image.cgi' not in details
    assert '/help.cgi/server-manager/images' not in details
    assert '(HTTPS)' not in details and '(optional)' not in details and '0 for unspecified' not in details
    assert re.search(r'<a\b[^>]*href=["\']https://', details), 'Catalogue URLs are not linked'
    invalid = request('/server-manager/save_catalog_image.cgi', {**fields, 'id': bundled_id})
    assert 'Only custom entries can be edited' in invalid
    page = bulk('disable', [bundle_key])
    bundle_disabled = True
    assert bundled_id not in Inputs(page).choices()
    page = bulk('enable', [bundle_key])
    bundle_disabled = False
    assert bundled_id in Inputs(page).choices()
    invalid = bulk('delete', [key, bundle_key], True)
    assert 'Only custom entries can be deleted' in invalid
    assert any(item['id'] == image_id for item in json.loads(custom_path.read_text())['images'])
    print('Enable/disable and supplied-catalogue protection: PASS')

    # Confirmation keeps the entry; deletion and stale resubmission are distinct.
    confirm = bulk('delete', [key])
    assert 'Delete the selected custom catalogue entries?' in confirm
    assert fields['name'] in confirm and 'text-danger' in confirm
    assert any(item['id'] == image_id for item in json.loads(custom_path.read_text())['images'])
    page = bulk('delete', [key], True)
    assert image_id not in Inputs(page).choices()
    stale = bulk('delete', [key], True)
    assert 'Catalogue entry no longer exists' in stale
    key = None
    assert json.loads(custom_path.read_text()) == custom_before, 'Fixture changed existing settings'
    print('Confirmation, deletion and stale resubmission: PASS')

    # A small local import verifies and records an actual digest without vendor downloads.
    with tempfile.TemporaryDirectory(prefix='cloudmin-checksum-ui-') as temporary:
        source = Path(temporary) / 'fixture.qcow2'
        subprocess.run(['qemu-img', 'create', '-q', '-f', 'qcow2', str(source), '32M'], check=True)
        # The image worker must read host files without the test driver's root UID.
        os.chmod(temporary, 0o755)
        os.chmod(source, 0o644)
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        page = request('/server-manager/images.cgi')
        pool = re.search(r'<option[^>]*value=["\']([a-f0-9-]{36})["\'][^>]*>default', page)
        assert pool, 'Default fixture pool is missing'
        result = json.loads(request('/server-manager/image.cgi', {
            'token': Inputs(page).value('token'), 'pool': pool[1], 'ajax': '1',
            'install_type': 'local', 'path': str(source), 'format': 'qcow2', 'sha256': digest}))
        checksum_job = result['id']
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            status = json.loads(request('/server-manager/image-status.cgi?job=' + checksum_job))
            # Stop polling once verification has succeeded or failed.
            if status.get('terminal'):
                break
            time.sleep(1)
        assert status['state'] == 'ready', status
        assert status['checksum'] == 'Passed'
        assert status['checksum_html'] == 'Passed'
        record = json.loads(Path('/var/webmin/modules/server-manager/image-jobs', checksum_job + '.json').read_text())
        assert record['checksum_digest'] == digest, 'Verified digest was not retained'
        page = request('/server-manager/images.cgi')
        assert re.search(r'<span\b[^>]*data-image-checksum="' + re.escape(checksum_job) + r'"[^>]*>Passed</span>', page)
        subprocess.run(['perl', str(helper.with_name('image-volume.pl')), 'cleanup', checksum_job], check=True)
        checksum_job = None
    print('Live checksum verification, digest retention and plain result: PASS')

    # Webmin may deny this module entirely in read-only mode; either gate must block writes.
    subprocess.run(['perl', str(helper), 'delete'], check=True)
    created = False
    login(readonly=True)
    created = True
    page = request('/server-manager/images.cgi?mode=catalogue')
    assert 'Add custom image' not in page and 'Enable selected' not in page
    module_denied = 'not allowed to use the Cloudmin module' in page
    assert module_denied or 'Image Manager' in page
    for path, data in [('/server-manager/edit_catalog_image.cgi?new=1', None),
                       ('/server-manager/save_catalog_image.cgi', fields),
                       ('/server-manager/catalogue.cgi', {'action': 'disable', 'key': bundle_key})]:
        denied = request(path, data)
        expected = ('not allowed to use the Cloudmin module' if module_denied
                    else 'Catalogue changes are disabled in read-only mode')
        assert expected in denied
    assert json.loads(custom_path.read_text()) == custom_before
    print('Read-only changes are rejected: PASS')
finally:
    # Remove only the generated fixture and restore any entry disabled by this run.
    if created:
        try:
            # Remove the checksum-test job and its volume if submission
            # succeeded.
            if checksum_job:
                subprocess.run(['perl', str(helper.with_name('image-volume.pl')), 'cleanup', checksum_job], check=True)
            # Restore the bundled entry disabled by this run.
            if bundle_disabled:
                bulk('enable', [bundle_key])
            # Delete only the custom entry if it still exists.
            if key and custom_path.exists() and any(
                    item['id'] == key.split(':')[0] for item in json.loads(custom_path.read_text())['images']):
                bulk('delete', [key], True)
        finally:
            subprocess.run(['perl', str(helper), 'delete'], check=True)
    assert (root / 'catalog/images.json').read_bytes() == bundled_before, 'Supplied catalogue was changed'
