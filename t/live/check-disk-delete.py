#!/usr/bin/python3
"""
Check confirmed disk deletion and expanded labels using a stopped fixture VM.
"""

import argparse
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

# Guest and volume mutations belong on the authorized Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')

import libvirt
from management_browser import edit_guest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--theme', action='append', help='Installed theme to check; may be repeated'
)
args = parser.parse_args()
module = Path(__file__).resolve().parent.parent.parent
helper = module / 't/live/webmin-user.pl'
base = 'https://127.0.0.1:10000'
connection = libvirt.open('qemu:///system')
guest = None
created_user = False
volumes = set()


class HiddenInputs(HTMLParser):
    # __init__(self, page) captures the signed confirmation fields from the
    # real CGI.
    def __init__(self, page):
        super().__init__()
        self.fields = {}
        self.feed(page)

    # handle_starttag(self, tag, attrs) collects hidden inputs without
    # inventing tokens.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Keep signed hidden fields without selecting disk-removal controls.
        if (
            tag == 'input'
            and attrs.get('type') == 'hidden'
            and attrs.get('name')
        ):
            self.fields[attrs['name']] = attrs.get('value', '')


# cli(action, [fields]) uses the installed management controller as root.
def cli(action, fields=None):
    result = subprocess.check_output(
        ['perl', str(module / 'api.pl'), action],
        input=json.dumps(fields or {}),
        text=True,
        stderr=subprocess.PIPE,
        timeout=120,
    )
    return json.loads(result)['result']


# change(action, fields) waits for one revision-bound fixture operation.
def change(action, fields):
    current = cli('settings', {'id': ident})
    job = cli(action, {'id': ident, 'revision': current['revision'], **fields})
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        result = cli('status', {'job': job['id']})
        # A terminal failure must fail the check rather than exhaust the poll.
        if result['state'] in ('complete', 'failed', 'cancelled'):
            assert result['state'] == 'complete', result.get('error')
            return
        time.sleep(.2)
    raise AssertionError('Fixture operation timed out')


# request(path, [fields]) keeps authentication inside the test machine.
def request(path, fields=None):
    data = None if fields is None else urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        base + path,
        data=data,
        headers={'Referer': base + '/server-manager/index.cgi'},
    )
    return opener.open(req, timeout=120).read().decode()


# add_disk() records each new libvirt volume for cleanup even after a
# failed check.
def add_disk():
    change('add_disk', {'pool': pool.UUIDString(), 'disk_gib': .125})
    disks = cli('settings', {'id': ident})['disks']
    disk = next(d for d in disks if d['volume_info']['name'] not in volumes)
    volumes.add(disk['volume_info']['name'])
    return disk


try:
    # The fixture stays stopped and uses tiny empty volumes, with no
    # imported image.
    ident = str(uuid.uuid4())
    name = 'cloudmin-disk-check-' + ident[:8]
    arch = connection.getInfo()[0]
    machine = 'virt' if arch == 'aarch64' else 'q35'
    guest = connection.defineXML(
        f"<domain type='kvm'><name>{name}</name><uuid>{ident}</uuid>"
        "<memory unit='MiB'>256</memory><vcpu>1</vcpu>"
        "<cpu mode='host-passthrough'/><os firmware='efi'>"
        f"<type arch='{arch}' machine='{machine}'>hvm</type></os>"
        "<features><acpi/></features><devices/></domain>"
    )
    pool = connection.storagePoolLookupByName('default')
    keeper = add_disk()
    for theme in args.theme or ('authentic-theme', 'gray-theme'):
        disk = add_disk()
        volume = disk['volume_info']
        password = secrets.token_urlsafe(36)
        subprocess.run(
            ['perl', str(helper), 'create', theme],
            input=password + '\n',
            text=True,
            check=True,
            timeout=30,
        )
        created_user = True
        time.sleep(1)
        cookies = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cookies),
            urllib.request.HTTPSHandler(
                context=ssl._create_unverified_context()
            ),
        )
        request('/session_login.cgi')
        request(
            '/session_login.cgi',
            {'user': 'cloudmin-ui-check', 'pass': password, 'page': '/'},
        )
        # Detachment through the collapsed panel must keep data
        # for reattachment.
        edit_guest(
            cookies,
            ident,
            action='detach_disk',
            disk={'target': disk['target'], 'name': volume['name']},
        )
        assert pool.storageVolLookupByName(volume['name'])
        change(
            'attach_disk', {'pool': volume['pool'], 'volume': volume['name']}
        )
        disk = next(
            d
            for d in cli('settings', {'id': ident})['disks']
            if d['volume_info']['name'] == volume['name']
        )
        path = '/server-manager/edit_machine.cgi?' + urllib.parse.urlencode(
            {
                'id': ident,
                'delete_disk': disk['target'],
                'vm_edit_tabs': 'disks',
            }
        )
        form = HiddenInputs(request(path)).fields
        before = guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)
        # Removing the typing step must retain signed POST validation.
        rejected = request(
            '/server-manager/edit_machine.cgi', {**form, 'token': 'invalid'}
        )
        assert 'This form has expired' in rejected, rejected[:300]
        assert guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE) == before
        edit_guest(
            cookies,
            ident,
            action='delete_disk',
            disk={'target': disk['target'], 'name': volume['name']},
        )
        remaining = cli('settings', {'id': ident})['disks']
        assert [d['volume_info']['name'] for d in remaining] == [
            keeper['volume_info']['name']
        ]
        assert volume['name'] not in [v.name() for v in pool.listAllVolumes()]
        assert not guest.isActive()
        print(
            'PASS: '
            + theme
            + ' opens both disk panels, saves detachment from a closed panel, confirms deletion in edit_machine.cgi, and keeps navigation, the VM and other disk',
            flush=True,
        )
        subprocess.run(['perl', str(helper), 'delete'], check=True, timeout=30)
        created_user = False
finally:
    # Cleanup is limited to the UUID, volume names and account created above.
    try:
        # Remove only the stopped domain allocated by this run.
        if guest:
            assert guest.name().startswith('cloudmin-disk-check-')
            assert not guest.isActive()
            guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
        # An early failure may precede allocation of any disk.
        if volumes:
            for volume in pool.listAllVolumes():
                # Keep every pool volume whose name was not recorded by
                # this fixture.
                if volume.name() in volumes:
                    volume.delete(0)
    finally:
        try:
            # Revoke the temporary account only after successful creation.
            if created_user:
                subprocess.run(
                    ['perl', str(helper), 'delete'], check=True, timeout=30
                )
        finally:
            connection.close()
