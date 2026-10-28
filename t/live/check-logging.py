#!/usr/bin/python3
"""Check Cloudmin's real Webmin action log and menu on a disposable Linux VM."""
import html
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import platform
import re
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request
import uuid
import libvirt

# Account and temporary CGI creation belong on the disposable host.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
here = Path(__file__).resolve().parent
module = here.parent.parent
helper = here / 'webmin-user.pl'
base = 'https://127.0.0.1:10000'
probe = module / ('logging_check_' + secrets.token_hex(8) + '.cgi')
connection = guest = None
guest_id = str(uuid.uuid4())


class Inputs(HTMLParser):
    """Read form fields without exposing tokens in diagnostics."""
    # __init__(self, page) collects the form's input values.
    def __init__(self, page):
        super().__init__()
        self.values = {}
        self.feed(page)

    # handle_starttag(self, tag, attrs) extracts input values.
    def handle_starttag(self, tag, attrs):
        # Tokens and hidden action fields come only from input controls.
        if tag == 'input':
            attrs = dict(attrs)
            self.values[attrs.get('name')] = attrs.get('value', '')


# request(path, [fields]) sends authenticated requests using this fixture's cookie jar.
def request(path, fields=None):
    data = urllib.parse.urlencode(fields).encode() if fields is not None else None
    req = urllib.request.Request(base + path, data=data, headers={'Referer': base + '/server-manager/images.cgi'})
    with opener.open(req, timeout=60) as response:
        page = response.read().decode()
    assert 'Error - Perl execution failed' not in page, 'CGI execution failed'
    return page


# api(action, [fields]) uses the real signed controller and preserves API errors.
def api(action, fields=None):
    result = json.loads(request('/server-manager/api.cgi',
                                {'action': action, **(fields or {})}))
    assert 'result' in result, result.get('error')
    return result['result']


# wait_job(job) follows the fixture's detached worker until its audit is written.
def wait_job(job):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        current = api('status', {'job': job['id']})
        # Terminal failures must stop the test rather than look like a timeout.
        if current['state'] in ('complete', 'failed', 'cancelled'):
            assert current['state'] == 'complete', current.get('error', current['state'])
            assert not current.get('audit_warning'), 'Completion audit failed'
            return
        time.sleep(.2)
    raise AssertionError('Fixture settings job did not finish')


# guest_audits(link) opens the actual Webmin action detail pages for this guest.
def guest_audits(link):
    matches = re.findall(r'href=[\'"]([^\'"]*view\.cgi\?[^\'"]+)', request(link))
    return [request('/webminlog/' + html.unescape(match)) for match in matches]


# delete_entry() deletes only this run's catalogue entry using its signed form.
def delete_entry():
    global entry_key
    # Do nothing until this run has created a catalogue entry.
    if entry_key:
        fields = Inputs(request('/server-manager/images.cgi?mode=catalogue')).values
        request('/server-manager/catalogue.cgi', {
            'action': 'delete', 'key': entry_key, 'confirm': '1', 'token': fields['token']})
        assert 'Catalogue entry no longer exists' in request('/server-manager/edit_catalog_image.cgi?' +
            urllib.parse.urlencode({'key': entry_key})), 'Fixture catalogue entry was not removed'
        entry_key = None


# The probe returns public menu links only, under the normal module initialization.
with probe.open('x') as stream:
    stream.write('''#!/usr/bin/perl
require './webmin_menu.pl';
die "Fixture access denied" if ($remote_user ne 'cloudmin-ui-check');
ReadParse();
print_json([list_webmin_menu({}, \\%in)], 0, 1);
''')
probe.chmod(0o755)
try:
    # A clean host has no guest log link. Define an owned, stopped guest so
    # this test does not depend on an earlier test leaving one behind.
    connection = libvirt.open('qemu:///system')
    architecture = connection.getInfo()[0]
    machine = 'virt' if architecture == 'aarch64' else 'q35'
    guest = connection.defineXML(
        f"<domain type='kvm'><name>cloudmin-log-check-{guest_id[:8]}</name>"
        f"<uuid>{guest_id}</uuid><memory unit='MiB'>256</memory><vcpu>1</vcpu>"
        "<cpu mode='host-passthrough'/><os firmware='efi'>"
        f"<type arch='{architecture}' machine='{machine}'>hvm</type></os>"
        "<features><acpi/></features></domain>")
    for theme in ('authentic-theme', 'gray-theme'):
        created = False
        entry_key = None
        try:
            password = secrets.token_urlsafe(36)
            subprocess.run(['perl', str(helper), 'create', theme, 'cloudmin-ui-check', '1'],
                input=password + '\n', text=True, check=True)
            created = True
            time.sleep(1)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
                urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
            request('/session_login.cgi')
            request('/session_login.cgi', {'user': 'cloudmin-ui-check', 'pass': password, 'page': '/'})
            menu = json.loads(request('/server-manager/' + probe.name + '?sid=' + guest_id))
            links = [item['link'] for item in menu if item.get('link', '').startswith('/webminlog/')]
            assert len(links) == 2, 'Missing guest or global log link'
            guest_log, global_log = links
            assert 'Host Action Log' in request(global_log), 'Global action log cannot be opened'
            guest_page = request(guest_log)
            assert 'Guest Action Log' in guest_page, 'Guest action log cannot be opened'
            # Other jobs may need recovery; only finished jobs without retained
            # resources must be absent from the operations page.
            operations = request('/server-manager/machine_jobs.cgi')
            listed = {urllib.parse.unquote(value) for value in re.findall(
                r'progress\.cgi\?job=([^\s"\'&<>]+)', operations)}
            for job in api('list'):
                # Finished jobs with no remaining cleanup must leave the active
                # list.
                if job['state'] in ('complete', 'failed', 'cancelled') and not job.get('cleanup_pending'):
                    assert job['id'] not in listed, 'Finished job is still listed'

            # Real settings edits attach before/after values to the completion
            # entry, not the earlier submission entry in the parent process.
            settings = api('settings', {'id': guest_id})
            cpus = 2 if settings['cpus'] == 1 else 1
            wait_job(api('update', {
                'id': guest_id, 'revision': settings['revision'],
                'token': api('options')['token'], 'cpus': cpus,
                'memory_mib': 384 if cpus == 2 else 256,
                'description': 'Audit <fixture> ' + theme, 'bootmenu': 1}))
            assert api('settings', {'id': guest_id})['cpus'] == cpus

            # These calls reach libvirt; the diskless EFI guest needs a
            # controlled stop because no guest OS handles its shutdown request.
            for action in ('start', 'reboot', 'shutdown'):
                api(action, {'id': guest_id, 'token': api('options')['token']})
            # The diskless firmware cannot complete a guest OS shutdown.
            if guest.isActive():
                guest.destroy()
            api('autostart', {'id': guest_id, 'enabled': 0,
                              'token': api('options')['token']})

            # Completion is committed just before the log is flushed. Allow
            # that small interval without accepting a missing detail record.
            deadline = time.monotonic() + 10
            while True:
                audit_pages = guest_audits(guest_log)
                definitions = [page for page in audit_pages if
                               'libvirt API: Sys::Virt::define_domain' in page and theme in page]
                # Stop once the audit appears or its flush deadline expires.
                if definitions or time.monotonic() >= deadline:
                    break
                time.sleep(.2)
            assert definitions, 'Settings completion has no libvirt details'
            details = html.unescape(definitions[0])
            for field in ('cpus', 'memory_mib', 'description', 'before', 'after'):
                assert '"' + field + '"' in details, 'Missing settings audit field: ' + field
            assert 'Audit <fixture> ' + theme not in definitions[0], 'Audit values are not HTML escaped'
            assert 'No config file changes were logged' not in definitions[0]
            assert len(re.findall(r'(?:id=[\'\"]hiddendiv_|data-name=[\'\"])diff\d+[\'\"]', definitions[0])) == 1, \
                'Settings details contain an extra empty accordion'
            for method in ('create', 'reboot', 'shutdown', 'set_autostart'):
                assert any('libvirt API: Sys::Virt::Domain::' + method in page
                           for page in audit_pages), 'Missing API audit: ' + method
            print('PASS: ' + theme + ' real libvirt power calls and settings before/after in Webmin action details', flush=True)

            # Real catalogue mutations test Webmin serialization and parser dispatch.
            name = 'Log fixture ' + secrets.token_hex(5) + ' <test>'
            fields = Inputs(request('/server-manager/edit_catalog_image.cgi?new=1')).values
            fields.update(name=name, vendor='Test', os='Linux', release='1',
                url='https://example.test/fixture.qcow2', checksum_url='https://example.test/SHA256SUMS',
                checksum_algorithm='sha256', format='qcow2', status='supported',
                min_disk_gib='0', cloud_init='1')
            entry_key = fields['id'] + ':' + fields['architecture']
            request('/server-manager/save_catalog_image.cgi', fields)
            assert 'Catalogue entry no longer exists' not in request('/server-manager/edit_catalog_image.cgi?' +
                urllib.parse.urlencode({'key': entry_key})), 'Catalogue creation was rejected'
            delete_entry()
            log = request(global_log + '&desc=' + urllib.parse.quote(name.split(' <')[0]))
            assert 'Added <tt>' + html.escape(name) in log, 'Creation lacks its formatted name'
            assert 'Removed <tt>' + html.escape(name) in log, 'Deletion lost its display name'
            assert '<test>' not in log, 'Log message contains unescaped markup'
            assert html.escape(name) not in request(guest_log), 'Guest filter includes unrelated catalogue actions'
            assert 'Logged into Webmin' not in log, 'Cloudmin filter includes global actions'
            matches = re.findall(r'href=[\'"]([^\'"]*view\.cgi\?[^\'"]+)', log)
            assert matches, 'Action details link is missing'
            details = request('/webminlog/' + html.unescape(matches[0]))
            assert html.escape(name) in details, 'Webmin action details cannot use the parser'
            print('PASS: ' + theme + ' log links, real catalogue audit, escaped names, details and guest filtering', flush=True)
        finally:
            # Remove fixture data before revoking the account needed to delete
            # it.
            if created:
                try:
                    delete_entry()
                finally:
                    subprocess.run(['perl', str(helper), 'delete'], check=True)
finally:
    probe.unlink(missing_ok=True)
    # Remove only this run's diskless guest and its firmware variables.
    if guest is not None:
        # Stop the owned firmware guest before removing its definition.
        if guest.isActive():
            guest.destroy()
        guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    # An early failure can precede the libvirt connection.
    if connection is not None:
        connection.close()
