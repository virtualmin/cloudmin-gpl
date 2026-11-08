#!/usr/bin/python3
"""Check VM page navigation and form validation on a disposable Cloudmin VM."""

from html.parser import HTMLParser
from html import unescape
import http.cookiejar
import json
import os
from pathlib import Path
import platform
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

# Account setup belongs on the disposable guest, never the workstation.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')

helper = Path(__file__).resolve().with_name('webmin-user.pl')
base = 'https://127.0.0.1:10000'
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)


class Inputs(HTMLParser):
    """Read Webmin's form fields without depending on attribute order."""

    # __init__(self, page)
    def __init__(self, page):
        """Parse page and retain input and button values."""
        super().__init__()
        self.fields = {}
        self.options = {}
        self.select = None
        self.feed(page)

    # handle_starttag(self, tag, attrs)
    def handle_starttag(self, tag, attrs):
        """Collect named controls from each opening tag."""
        attrs = dict(attrs)
        if tag in ('input', 'button') and attrs.get('name'):
            # Hidden inputs carry the form action and its CSRF token.
            self.fields[attrs['name']] = attrs.get('value', '')
        elif tag == 'select':
            # Unit choices are normal Webmin select controls.
            self.select = attrs.get('name')
            self.options[self.select] = []
        elif tag == 'option' and self.select:
            # Browsers use the first option unless one is explicitly selected.
            value = attrs.get('value', '')
            self.options[self.select].append(value)
            # An explicit selection overrides the first option default.
            if self.select not in self.fields or 'selected' in attrs:
                self.fields[self.select] = value

    # handle_endtag(self, tag)
    def handle_endtag(self, tag):
        """Stop collecting options when a select closes."""
        # Do not attach later options to the preceding select.
        if tag == 'select':
            self.select = None


# request(path, [fields])
def request(path, fields=None):
    """Send GET or form POST with the theme's same-origin navigation headers."""
    data = None if fields is None else urllib.parse.urlencode(fields).encode()
    headers = {
        'Referer': base + '/server-manager/index.cgi',
        'X-Requested-With': 'XMLHttpRequest',
    }
    try:
        response = opener.open(
            urllib.request.Request(base + path, data=data, headers=headers),
            timeout=30,
        )
    except urllib.error.HTTPError as error:
        # Validation errors are page content that the caller must inspect.
        response = error
    with response:
        page = response.read().decode('utf-8')
        assert 'Error - Perl execution failed' not in page, path + ' crashed'
        return page


# api(action, [fields])
def api(action, fields=None):
    """Read state or validate settings without creating a job."""
    result = json.loads(
        request('/server-manager/api.cgi?action=' + action)
        if fields is None
        else request('/server-manager/api.cgi', dict(fields, action=action))
    )
    assert 'result' in result, result.get('error', 'API failed')
    return result['result']


created = False
try:
    # Keep the temporary account password in memory and delete its
    # sessions later.
    password = secrets.token_urlsafe(36)
    subprocess.run(
        ['perl', str(helper), 'create'],
        input=password + '\n',
        text=True,
        check=True,
    )
    created = True
    time.sleep(1)
    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {
            'user': 'cloudmin-ui-check',
            'pass': password,
            'page': '/server-manager/index.cgi',
        },
    )
    before = api('list')
    # Without an imported image the creation page shows an empty state instead
    # of the form, so this check has nothing to exercise.
    if not api('options')['images']:
        raise SystemExit('Import at least one image before running this check')

    # Ordinary links, empty POSTs and theme navigation must all open
    # clean pages.
    pages = []
    for path, expected in (
        ('machine_form.cgi', 'Create Virtual Machine'),
        ('machine_jobs.cgi', 'Active Jobs'),
    ):
        for fields in (None, {}, {'navigation': 1}):
            page = request('/server-manager/' + path + '?navigation=1', fields)
            assert expected in page, path + ' did not open'
            assert 'This form has expired' not in page, (
                path + ' treated navigation as submission'
            )
            if path == 'machine_form.cgi':
                # The form must post directly to a streaming submission URL.
                assert re.search(
                    r'<form[^>]*action=["\']setup_machine\.cgi["\']', page
                ), 'Creation form does not use its streaming endpoint'
            pages.append(page)
    for page in pages:
        assert 'Return to Return to' not in page, 'Duplicate return label'
        assert '\u00e2\u0080' not in page and '\u00e2\u20ac' not in page, (
            'Broken punctuation encoding'
        )
    # Completed history stays in the action log; this page lists work to finish.
    active = [
        job
        for job in before
        if job.get('cleanup_pending')
        or job['state'] not in ('complete', 'failed', 'cancelled')
    ]
    # The shared view can also contain image imports when no VM work is pending.
    if not active:
        assert 'No active jobs' in pages[-1] or 'Image import' in pages[-1], (
            'Missing shared jobs view'
        )
    for job in before:
        assert ('job=' + job['id'] in pages[-1]) == (job in active), (
            'Wrong job visibility'
        )
    navigation = json.loads(
        request('/xhr.cgi?type=nav&action=get&subtype=cloudmin')
    )['menu']
    assert (
        'machine_form.cgi' in navigation
        and 'machine_jobs.cgi' not in navigation
    ), 'Unexpected sidebar links'
    print('GET and theme POST navigation: PASS', flush=True)

    # Fault-injection runs can leave a completed job with an audit warning.
    if '--audit-warning' in sys.argv:
        warned = next((job for job in before if job.get('audit_warning')), None)
        assert warned is not None, (
            'Run check_machine_rollback.pl to create an audit warning fixture'
        )
        progress = request('/server-manager/progress.cgi?job=' + warned['id'])
        assert warned['audit_warning'] in unescape(progress), (
            'Completion audit warning is hidden'
        )
        assert warned['state'] == 'complete', (
            'Audit warning changed the completed state'
        )
        print(
            'Completed job audit warning in API and progress: PASS', flush=True
        )

    # A real form action still needs its original token, even during navigation.
    for token in (None, 'invalid'):
        for action in ('create',):
            fields = {
                'vm_operation': action,
                'navigation': 1,
                'name': 'navigation-check',
            }
            if token is not None:
                # Cover both an omitted token and a supplied invalid token.
                fields['token'] = token
            page = request(
                '/server-manager/setup_machine.cgi?navigation=1', fields
            )
            assert 'This form has expired' in page, (
                action + ' accepted an invalid token'
            )
        for action in ('cancel', 'recover'):
            # A nonexistent job prevents this fixture from touching real jobs.
            fields = {'action': action, 'navigation': 1, 'job': '0' * 32}
            if token is not None:
                # Exercise a supplied invalid token as well as an omitted one.
                fields['token'] = token
            page = request(
                '/server-manager/machine_jobs.cgi?navigation=1', fields
            )
            assert 'This form has expired' in page, (
                action + ' accepted an invalid token'
            )
    print('Explicit submissions still require valid tokens: PASS', flush=True)

    # Form validation rejects bad input; the optional API check
    # normalizes units.
    options = api('options')
    image = next(item for item in options['images'] if item.get('cloud_init'))
    pool = next(item for item in options['pools'] if item['name'] == 'default')
    network = next(
        item for item in options['networks'] if item['name'] == 'default'
    )
    with tempfile.TemporaryDirectory(prefix='cloudmin-navigation-key-') as work:
        key = Path(work) / 'identity'
        subprocess.run(
            ['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)],
            check=True,
        )
        minimum = max(
            int(image.get('virtual_size') or 0),
            int(image.get('min_disk_bytes') or 0),
        )
        form = request('/server-manager/machine_form.cgi?navigation=1', {})
        controls = Inputs(form)
        assert {str(1024**2), str(1024**3)} <= set(
            controls.options['memory_mib_units']
        )
        assert controls.fields['disk_gib_units'] == str(1024**3), (
            'Disk must default to GiB'
        )
        assert 'Virtual machine name' in form, 'Machine name label is stale'
        disk_mib = max(1, (minimum + 1024**3 - 1) // 1024**3) * 1024 + 512
        assert (
            controls.fields['vm_operation'] == 'create'
            and 'Review VM settings' not in form
        )
        # Mix display units to catch conversions while keeping
        # creation disabled.
        fields = {
            'vm_operation': 'create',
            'token': Inputs(form).fields['token'],
            'name': 'navigation-check-' + secrets.token_hex(4),
            'image': image['id'],
            'pool': pool['id'],
            'network': network['key'],
            'username': 'cloudmin',
            'ssh_keys': key.with_suffix('.pub').read_text(),
            'cpus': 1,
            'memory_mib': 1.5,
            'memory_mib_units': 1024**3,
            'disk_gib': disk_mib,
            'disk_gib_units': 1024**2,
            'address_mode': 'dhcp',
            'start': 0,
            'autostart': 0,
        }
        # Invalid input uses Webmin's error page instead of redisplaying
        # the form.
        invalid = request(
            '/server-manager/setup_machine.cgi', {**fields, 'name': ''}
        )
        assert (
            'Enter a virtual machine name' in invalid
            and 'This form has expired' not in invalid
        )
        assert (
            'Cannot create virtual machine' in invalid
            and 'Return to previous page' in invalid
        )
        assert 'token' not in Inputs(invalid).fields, (
            'Validation redisplayed the creation form'
        )
        # The optional validation API remains, but the old form action
        # must fail.
        stale = request(
            '/server-manager/setup_machine.cgi',
            dict(fields, vm_operation='review'),
        )
        assert 'Unknown virtual machine form action' in stale, (
            'An old review button could create a VM'
        )
        values = api('review', fields)
        assert float(values['memory_mib']) == 1536, (
            'Validation changed the memory size'
        )
        assert float(values['disk_gib']) * 1024 == disk_mib, (
            'Validation changed the disk size'
        )
    assert api('list') == before, 'Navigation or validation created a job'
    print('Navigation and validation without creating a VM: PASS', flush=True)
finally:
    if created:
        # Webmin removes both the fixture account and its
        # authenticated sessions.
        subprocess.run(['perl', str(helper), 'delete'], check=True)
