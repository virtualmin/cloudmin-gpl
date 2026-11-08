#!/usr/bin/python3
"""
Check installer policy and network-change notices on a disposable Linux host.
"""

import base64
import http.cookiejar
import json
import math
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

# This test changes libvirt resources and module policy on its Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on a disposable Linux Cloudmin test host as root')

import libvirt

# Preserve the existing policy, including an absent key on older installations.
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
config = Path('/etc/webmin/server-manager/config')
original = config.read_bytes()
original_flag = re.search(rb'^virtualmin_enabled=.*\n?', original, re.M)
# Unique names keep cleanup limited to resources created by this invocation.
suffix = secrets.token_hex(4)
username = 'cloudmin-ui-check-' + suffix
name = 'cloudmin-settings-' + suffix
bridge = 'cmset' + suffix
identity = str(uuid.uuid4())
# Connect to Webmin on the guest, without using workstation proxies or sessions.
base = 'https://127.0.0.1:10000'
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)
connection = libvirt.open('qemu:///system')
guest = network = None
user_created = bridge_created = False


# run(args, [data]) captures output and limits a guest command to two minutes.
# args is an argument list; optional data is text supplied on standard input.
def run(args, data=None):
    return subprocess.check_output(
        args, input=data, text=True, stderr=subprocess.PIPE, timeout=120
    )


# request(path, [fields], [json_body]) uses this fixture's local Webmin session.
# Without fields, send GET; otherwise encode the mapping as form data or JSON.
# json_body defaults to false. path is relative to the guest's Webmin URL.
def request(path, fields=None, json_body=False):
    body = (
        None
        if fields is None
        else (
            json.dumps(fields) if json_body else urllib.parse.urlencode(fields)
        ).encode()
    )
    req = urllib.request.Request(
        base + path,
        data=body,
        headers={
            'Referer': base + '/server-manager/index.cgi',
            'Content-Type': 'application/json'
            if json_body
            else 'application/x-www-form-urlencoded',
        },
    )
    return opener.open(req, timeout=120).read().decode()


# api(action, [fields]) returns the public result or fails on an API error.
# fields defaults to an empty mapping; failures omit the submitted fields.
def api(action, fields=None):
    reply = json.loads(
        request(
            '/server-manager/api.cgi',
            {'action': action, **(fields or {})},
            True,
        )
    )
    assert 'result' in reply, reply.get('error', 'Missing API result')
    return reply['result']


# installer(value) changes only the tested config key, preserving other
# settings. value is a complete configuration line in bytes, or empty bytes to
# remove it.
def installer(value):
    data = re.sub(
        rb'^virtualmin_enabled=.*\n?', b'', config.read_bytes(), flags=re.M
    )
    config.write_bytes(data.rstrip(b'\n') + b'\n' + value)


# settings() reads this fixture's current revision and pending settings.
def settings():
    return api('settings', {'id': identity})


# Keep the backup and review key in a private directory removed after the test.
with tempfile.TemporaryDirectory(prefix='cloudmin-settings-') as directory:
    work = Path(directory)
    (work / 'config.backup').write_bytes(original)
    (work / 'config.backup').chmod(0o600)
    try:
        # Use a temporary Webmin login with its password sent over stdin/HTTP.
        password = secrets.token_urlsafe(36)
        run(
            ['perl', str(helper), 'create', 'authentic-theme', username],
            password + '\n',
        )
        user_created = True
        request('/session_login.cgi')
        request(
            '/session_login.cgi',
            {
                'user': username,
                'pass': password,
                'page': '/server-manager/index.cgi',
            },
        )
        options = api('options')
        token = options['token']

        # Disabling installation hides controls and refuses installer templates.
        installer(b'virtualmin_enabled=0\n')
        for path in (
            'machine_form.cgi',
            'edit_tmpl.cgi?id=' + '0' * 31 + '1&editmode=software',
        ):
            page = request('/server-manager/' + path)
            assert 'name="packages"' in page, 'Software form did not render'
            assert not re.search(
                r'name=[\"\'](?:software|virtualmin_\w+|webmin_register)[\"\']',
                page,
            )
            # Pro and visible previews retain scripts without an orphan divider.
            if 'name="after_script_mode"' in page:
                software = page[
                    page.index('name="packages"') : page.index(
                        'name="after_script_mode"'
                    )
                ]
                assert not re.search(r'<hr\b', software), (
                    'Software divider remains'
                )
        choices = api('options')['presets']['template']
        blocked = [item for item in choices['entries'] if item.get('disabled')]
        assert len(blocked) >= 4 and choices['default'] not in [
            item['id'] for item in blocked
        ]
        # Retain blocked entries in API metadata, but hide them from both lists.
        listing = request('/server-manager/edit_newtmpl.cgi')
        creation = request('/server-manager/machine_form.cgi')
        for item in blocked:
            assert 'edit_tmpl.cgi?id=' + item['id'] not in listing
            assert not re.search(
                r'<option\b[^>]*value=[\"\']' + item['id'], creation
            )
        # Select usable host resources for review without creating image disks.
        image = next(
            item for item in options['images'] if item.get('cloud_init')
        )
        pool = next(
            item for item in options['pools'] if item['name'] == 'default'
        )
        attachment = next(
            item
            for item in options['networks']
            if item['type'] == 'network' and item.get('dhcp')
        )
        key = (
            'ssh-ed25519 '
            + base64.b64encode(
                (11).to_bytes(4, 'big')
                + b'ssh-ed25519'
                + (32).to_bytes(4, 'big')
                + b'A' * 32
            ).decode()
        )
        (work / 'public-key').write_text(key)
        disk = max(20, math.ceil(int(image.get('virtual_size') or 0) / 1024**3))
        # A template cannot bypass policy even when the request
        # overrides software.
        fields = {
            'name': name + '.example.test',
            'image': image['id'],
            'pool': pool['id'],
            'network': attachment['key'],
            'template': '0' * 31 + '3',
            'cpus': 1,
            'memory_mib': 1024,
            'disk_gib': disk,
            'start': 1,
            'username': 'cloudmin',
            'auth_type': 'keys',
            'ssh_keys': key,
            'software': 'virtualmin-pro',
        }
        error = 'Virtualmin installation is disabled in Module Configuration'
        for action in ('review', 'create'):
            # A blank name prevents resource creation even if policy regresses.
            reply = json.loads(
                request(
                    '/server-manager/api.cgi',
                    {
                        **fields,
                        'name': '',
                        'software': 'none',
                        'action': action,
                        'token': token,
                    },
                    True,
                )
            )
            assert error in reply.get('error', ''), reply.get(
                'error', 'Policy was bypassed'
            )
        for path in ('edit_tmpl.cgi?id=', 'machine_form.cgi?template='):
            # Bookmarked editor and creation links must explain the rejection.
            page = request('/server-manager/' + path + fields['template'])
            assert error in page, 'Old template URL did not explain host policy'
        # The named CLI must explain the same restriction for old IDs and names.
        command = [
            'perl',
            str(module / 'cli.pl'),
            'create-system',
            '--review',
            '--json',
            '--name',
            fields['name'],
            '--image',
            image['id'],
            '--pool',
            pool['id'],
            '--network',
            attachment['key'],
            '--cpus',
            '1',
            '--memory',
            '1024',
            '--disk',
            str(disk),
            '--username',
            'cloudmin',
            '--auth-type',
            'keys',
            '--ssh-keys-file',
            str(work / 'public-key'),
            '--software',
            'virtualmin-pro',
        ]
        template = next(
            item for item in blocked if item['id'] == fields['template']
        )
        for selection in (template['id'], template['name']):
            result = subprocess.run(
                command + ['--template', selection],
                text=True,
                capture_output=True,
                timeout=120,
            )
            assert result.returncode and error in result.stdout + result.stderr
        # Explicit requests must fail too, without silently creating a
        # plain guest.
        fields.pop('template')
        for software in ('virtualmin-gpl', 'virtualmin-pro'):
            for action in ('review', 'create'):
                # A blank create name prevents allocation if policy regresses.
                reply = json.loads(
                    request(
                        '/server-manager/api.cgi',
                        {
                            **fields,
                            'software': software,
                            'action': action,
                            'token': token,
                            'name': fields['name']
                            if action == 'review'
                            else '',
                        },
                        True,
                    )
                )
                assert error in reply.get('error', ''), (
                    'Explicit installer request was not rejected'
                )
            result = subprocess.run(
                command[:-1] + [software],
                text=True,
                capture_output=True,
                timeout=120,
            )
            assert result.returncode and error in result.stdout + result.stderr
        # Ordinary guests and package installation remain available.
        reviewed = api('review', {**fields, 'software': 'none', 'token': token})
        assert reviewed.get('software', 'none') == 'none' and not reviewed.get(
            'webmin_register'
        )
        reviewed = api(
            'review',
            {**fields, 'software': 'none', 'packages': 'jq', 'token': token},
        )
        assert reviewed['software'] == 'none' and reviewed['packages'] == 'jq'
        reviewed = json.loads(run(command[:-1] + ['none']))
        assert reviewed['data'].get('software', 'none') == 'none'
        # Re-enabling restores controls, templates and installer requests.
        installer(b'virtualmin_enabled=1\n')
        assert 'name="software"' in request('/server-manager/machine_form.cgi')
        assert not any(
            item.get('disabled')
            for item in api('options')['presets']['template']['entries']
        )
        assert 'name="software"' in request(
            '/server-manager/edit_tmpl.cgi?id='
            + template['id']
            + '&editmode=software'
        )
        for software in ('virtualmin-gpl', 'virtualmin-pro'):
            reviewed = api(
                'review',
                {
                    **fields,
                    'software': software,
                    'virtualmin_type': 'mini',
                    'token': token,
                },
            )
            assert reviewed['software'] == software
        print(
            'Virtualmin controls, dividers, disabled templates, old links and CLI/API policy passed',
            flush=True,
        )

        # Own both isolated attachments; no host uplink or existing guest
        # is changed.
        network = connection.networkCreateXML(
            f'<network><name>{name}</name></network>'
        )
        run(['ip', 'link', 'add', bridge, 'type', 'bridge'])
        bridge_created = True
        run(['ip', 'link', 'set', bridge, 'up'])
        # Use a diskless EFI guest for live NIC changes on ARM64 and x86.
        arch = connection.getInfo()[0]
        machine = 'virt' if arch == 'aarch64' else 'q35'
        guest = connection.defineXML(f'''<domain type="kvm"><name>{name}</name>
          <uuid>{identity}</uuid><memory unit="MiB">256</memory><vcpu>1</vcpu>
          <cpu mode="host-passthrough"/><os firmware="efi">
          <type arch="{arch}" machine="{machine}">hvm</type></os><features><acpi/></features>
          <devices><interface type="network"><source network="{name}"/>
          <model type="virtio"/></interface><memballoon model="virtio"/></devices></domain>''')
        guest.create()
        before = settings()
        assert not before['pending'], (
            'Runtime-only XML differences should not show a warning'
        )
        # Submit the same combined hardware update used by the editor.
        job = api(
            'update',
            {
                'id': identity,
                'token': token,
                'revision': before['revision'],
                'cpus': before['cpus'],
                'memory_mib': before['memory_mib'],
                'changes': [
                    {
                        'action': 'update_interface',
                        'mac': before['interfaces'][0]['mac'],
                        'network': 'bridge:' + bridge,
                    }
                ],
            },
        )
        # Bound asynchronous completion so a stuck worker fails this check.
        deadline = time.monotonic() + 90
        while job['state'] not in ('complete', 'failed', 'cancelled'):
            assert time.monotonic() < deadline, 'Network move did not finish'
            time.sleep(.25)
            job = api('status', {'job': job['id']})
        assert job['state'] == 'complete', job.get(
            'error', 'Network move failed'
        )
        assert job['network_changed'] and job['scope'] == 'live'
        # Follow the editor's redirect so its real completion alert is checked.
        page = request(
            f'/server-manager/edit_machine.cgi?id={identity}&vm_saved={job["id"]}&vm_edit_tabs=interfaces'
        )
        assert (
            'Shut down and start the virtual machine to refresh its network settings'
            in page
        )

        # A persistent-only move must also appear in status and the
        # initial banner.
        saved = guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)
        saved = re.sub(
            r"<interface type=['\"]bridge['\"]>",
            '<interface type="network">',
            saved,
        )
        saved = re.sub(
            r'<source bridge=[^>]+/>', f'<source network="{name}"/>', saved
        )
        connection.defineXML(saved)
        assert 'networks' in settings()['pending']
        page = request(f'/server-manager/edit_machine.cgi?id={identity}')
        assert (
            'Saved. 1 change is waiting for a power cycle' in page
            and bridge in page
        )
        # This diskless fixture has no operating system or data to shut down.
        guest.destroy()
        guest.create()
        assert not settings()['pending'], (
            'Cold start must clear the attachment warning'
        )
        print(
            'Live network moves, saved attachment warning and cold-start clearing passed',
            flush=True,
        )
    finally:
        # Restore only the tested key and remove every fixture-owned resource.
        installer(original_flag.group(0) if original_flag else b'')
        if guest is not None:
            # Remove the fixture's persistent definition and private EFI state.
            if guest.isActive():
                # No guest OS or data needs a clean shutdown in this fixture.
                guest.destroy()
            guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
        if network is not None:
            # Destroying the transient network also removes its definition.
            network.destroy()
        if bridge_created:
            # This separate Linux bridge is not owned by the libvirt network.
            run(['ip', 'link', 'delete', bridge])
        if user_created:
            # Delete only the temporary account created for this HTTP session.
            run(['perl', str(helper), 'delete', 'authentic-theme', username])
        connection.close()
