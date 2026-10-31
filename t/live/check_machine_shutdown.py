#!/usr/bin/python3
"""Check editor and details power controls with a diskless guest in both layouts."""
import argparse
import http.cookiejar
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

# Power operations belong on the disposable Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on a disposable Linux test host as root')

import libvirt
from management_browser import edit_guest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--theme', action='append', help='Installed theme to check; may be repeated')
parser.add_argument('--screenshot', help='Save the details Start link screenshot on this host')
args = parser.parse_args()
root = Path(next(line.split('=', 1)[1] for line in
                Path('/etc/webmin/miniserv.conf').read_text().splitlines()
                if line.startswith('root=')))
helper = root / 'server-manager/t/live/webmin-user.pl'
base = 'https://127.0.0.1:10000'
username = 'cloudmin-ui-check'
connection = libvirt.open('qemu:///system')
guest = None
created_user = False


# request(opener, path, [fields]) keeps the fixture session inside this VM.
def request(opener, path, fields=None):
    data = None if fields is None else urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(base + path, data=data,
        headers={'Referer': base + '/server-manager/index.cgi'})
    return opener.open(req, timeout=30).read()


# stop_fixture() completes only this test's diskless guest after ACPI is requested.
def stop_fixture():
    assert guest.name().startswith('cloudmin-shutdown-check-')
    assert guest.isActive(), 'The fixture must stay active while feedback is checked'
    guest.destroy()


# active_fixture() verifies that review and cancellation have not stopped the guest.
def active_fixture():
    assert guest.isActive(), 'Unconfirmed emergency power-off changed the guest'


try:
    # EFI supplies ACPI but no operating system will consume the shutdown event.
    # This lets the browser observe the pending state before a controlled stop.
    ident = str(uuid.uuid4())
    name = 'cloudmin-shutdown-check-' + ident[:8]
    arch = connection.getInfo()[0]
    machine = 'virt' if arch == 'aarch64' else 'q35'
    guest = connection.defineXML(
        f"<domain type='kvm'><name>{name}</name><uuid>{ident}</uuid>"
        "<memory unit='MiB'>256</memory><vcpu>1</vcpu>"
        "<cpu mode='host-passthrough'/><os firmware='efi'>"
        f"<type arch='{arch}' machine='{machine}'>hvm</type></os>"
        "<features><acpi/></features></domain>")
    for theme in args.theme or ['authentic-theme', 'gray-theme']:
        # A temporary module-only account keeps production sessions untouched.
        password = secrets.token_urlsafe(36)
        subprocess.run(['perl', str(helper), 'create', theme, username],
                       input=password + '\n', text=True, check=True, timeout=30)
        created_user = True
        time.sleep(1)
        cookies = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cookies),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
        request(opener, '/session_login.cgi')
        request(opener, '/session_login.cgi', {'user': username, 'pass': password,
                                             'page': '/server-manager/index.cgi'})
        edit_guest(cookies, ident, action='save')
        assert 'Saved browser settings' in guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)
        edit_guest(cookies, ident, action='start')
        assert guest.isActive(), 'Start did not activate the guest'
        assert 'Unsaved start check' not in guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)
        edit_guest(cookies, ident, action='shutdown', on_shutdown=stop_fixture)
        assert not guest.isActive()
        edit_guest(cookies, ident, action='details_start', screenshot=args.screenshot)
        assert guest.isActive(), 'The details link did not start the guest'
        edit_guest(cookies, ident, action='details_reboot')
        assert guest.isActive(), 'The reboot request left the fixture inactive'
        edit_guest(cookies, ident, action='details_shutdown', on_shutdown=stop_fixture)
        assert not guest.isActive(), 'The controlled shutdown did not complete'
        # HTTP clients must also confirm, provide a valid token, and use POST.
        guest.create()
        token = json.loads(request(opener, '/server-manager/api.cgi?action=options'))['result']['token']
        for fields, reason in [
            ({'token': token}, 'Confirm force power off'),
            ({'token': token, 'confirm': '0'}, 'Confirm force power off'),
            ({'token': '', 'confirm': '1'}, 'form has expired'),
        ]:
            response = json.loads(request(opener, '/server-manager/api.cgi',
                {'action': 'force_off', 'id': ident, **fields}))
            assert reason.lower() in response.get('error', '').lower(), response
            active_fixture()
        response = json.loads(request(opener, '/server-manager/api.cgi?' +
            urllib.parse.urlencode({'action': 'force_off', 'id': ident, 'confirm': 1, 'token': token})))
        assert 'Use POST' in response.get('error', ''), response
        active_fixture()
        # A diskless firmware guest ignores ACPI shutdown; only confirmation stops it.
        edit_guest(cookies, ident, action='details_force_off', on_confirmation=active_fixture,
                   screenshot=args.screenshot + '.force-off.png' if args.screenshot else None)
        assert not guest.isActive() and guest.isPersistent(), 'Emergency stop removed the saved guest'
        guest.create()
        guest.suspend()
        edit_guest(cookies, ident, action='details_force_off', on_confirmation=active_fixture)
        assert not guest.isActive() and guest.isPersistent(), 'Paused guest did not power off'
        guest.create()
        edit_guest(cookies, ident, action='force_off', on_confirmation=active_fixture)
        assert not guest.isActive() and guest.isPersistent(), 'Editor emergency stop failed'
        response = json.loads(request(opener, '/server-manager/api.cgi',
            {'action': 'force_off', 'id': ident, 'confirm': 1, 'token': token}))
        assert 'already stopped' in response.get('error', ''), response
        print('PASS: ' + theme + ' normal power controls; emergency confirmation/cancellation, pending shutdown, paused guests, editor return, and HTTP validation', flush=True)
        subprocess.run(['perl', str(helper), 'delete', theme, username], check=True, timeout=30)
        created_user = False
finally:
    # Remove only the account and domain allocated by this fixture.
    try:
        # An early failure may precede definition of the fixture guest.
        if guest:
            # Stop the diskless fixture before removing its definition.
            if guest.isActive():
                guest.destroy()
            guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    finally:
        try:
            # Remove the temporary account only after successful creation.
            if created_user:
                subprocess.run(['perl', str(helper), 'delete', 'authentic-theme', username],
                               check=True, timeout=30)
        finally:
            connection.close()
