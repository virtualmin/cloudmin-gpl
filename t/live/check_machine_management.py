#!/usr/bin/python3
"""Exercise VM editing and deletion through HTTPS and CLI on a Linux test host.

Creates its own cloud-image guest and removes only its recorded resources.
Run after importing at least one compatible image into Cloudmin.
"""
import argparse
import hashlib
from html.parser import HTMLParser
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

# Guest creation and storage edits belong on the authorized Linux host.
if sys.platform != 'linux' or os.getuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--browser', action='store_true')
parser.add_argument('--offline-only', action='store_true', help='Run only the offline editing checks')
parser.add_argument('--delete-only', action='store_true', help='Test running-guest deletion and shutdown timeout')
parser.add_argument('--keep-system-disk', action='store_true', help='Keep the writable disk in the deletion-only test')
parser.add_argument('--expect-no-cpu-hotplug', action='store_true',
                    help='Verify a host that explicitly rejects live CPU changes')
parser.add_argument('--theme', default='authentic-theme')
parser.add_argument('--screenshot', help='Save the editor screenshot on this host')
args = parser.parse_args()
here = Path(__file__).resolve().parent
module = here.parent.parent
base = 'https://127.0.0.1:10000'
created_user = False
creation = None
network_fixture = None


class HiddenInputs(HTMLParser):
    # __init__(self, page, [form_id]) captures signed fields from the chosen form.
    def __init__(self, page, form_id=None):
        super().__init__()
        self.fields = {}
        self.form_id = form_id
        self.in_form = form_id is None
        self.feed(page)

    # handle_starttag(self, tag, attrs) leaves disk checkboxes unchecked.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Restrict hidden inputs to the requested management form.
        if tag == 'form' and self.form_id:
            self.in_form = attrs.get('id') == self.form_id
        # Copy signed hidden fields without selecting any disks for deletion.
        if self.in_form and tag == 'input' and attrs.get('type') == 'hidden' and attrs.get('name'):
            self.fields[attrs['name']] = attrs.get('value', '')

    # handle_endtag(self, tag) excludes controls belonging to other forms.
    def handle_endtag(self, tag):
        # Do not collect fields from forms after the selected one.
        if tag == 'form' and self.form_id:
            self.in_form = False


# run(argv, [data], [timeout]) executes bounded commands on the test host.
def run(argv, data=None, timeout=120):
    return subprocess.check_output(argv, input=data, text=True, stderr=subprocess.PIPE,
                                   timeout=timeout)


# cli(action, [fields]) exercises the installed public CLI.
def cli(action, fields=None):
    return json.loads(run(['perl', str(module/'api.pl'), action],
                         json.dumps(fields or {})))['result']


# request(path, [fields], [json_body]) uses a fixture Webmin HTTPS session.
def request(path, fields=None, json_body=False):
    data = None
    headers = {'Referer': base+'/server-manager/index.cgi'}
    # Encode POST bodies explicitly; GET requests carry no body.
    if fields is not None:
        data = (json.dumps(fields) if json_body else urllib.parse.urlencode(fields, doseq=True)).encode()
        headers['Content-Type'] = 'application/json' if json_body else 'application/x-www-form-urlencoded'
    return opener.open(urllib.request.Request(base+path, data=data, headers=headers),
                       timeout=200).read().decode()


# api(action, fields) validates the public HTTPS result envelope.
def api(action, fields):
    body = json.loads(request('/server-manager/api.cgi', {'action': action, **fields}, True))
    assert 'result' in body, body.get('error')
    return body['result']


# wait(job) waits for a durable job and reports only its public error.
def wait(job):
    deadline = time.monotonic()+240
    while time.monotonic() < deadline:
        current = cli('status', {'job': job['id']})
        # CLI submissions are owned by root and followed through the same CLI.
        if current['state'] in ('complete', 'failed', 'cancelled'):
            assert current['state'] == 'complete', current.get('error', current)
            return current
        time.sleep(.25)
    raise AssertionError('Job did not finish')


# wait_http(job) follows jobs owned by the fixture Webmin account.
def wait_http(job):
    deadline = time.monotonic()+240
    while time.monotonic() < deadline:
        current = api('status', {'job': job['id']})
        # Stop on a terminal state and surface any worker failure.
        if current['state'] in ('complete', 'failed', 'cancelled'):
            assert current['state'] == 'complete', current.get('error', current)
            return current
        time.sleep(.25)
    raise AssertionError('HTTP job did not finish')


# settings() obtains a fresh configuration revision for this test's guest.
def settings():
    return api('settings', {'id': uuid})


# change(action, fields) submits one revision-bound edit and waits for it.
def change(action, fields):
    current = settings()
    data = {'id': uuid, 'revision': current['revision'],
            'token': api('options', {})['token'], **fields}
    job = api(action, data)
    result = wait_http(job)
    # Identical submissions return the same job, even when the VM was deleted.
    assert api(action, data)['id'] == job['id']
    return result


# stopped() waits for a clean guest shutdown, without force-stopping it.
def stopped():
    deadline = time.monotonic()+90
    while time.monotonic() < deadline:
        # A native shut-off state confirms that offline editing is safe.
        if run(['virsh', 'domstate', uuid]).strip() == 'shut off':
            return
        time.sleep(1)
    raise AssertionError('Guest did not shut down')


# guest(command, [timeout]) waits for SSH using the fixture's own private key.
def guest(command, timeout=180):
    deadline = time.monotonic()+timeout
    error = 'No DHCP address'
    while time.monotonic() < deadline:
        output = run(['virsh', 'domifaddr', uuid, '--source', 'lease'])
        addresses = [word.split('/')[0] for word in output.split() if word.startswith('192.168.122.')]
        # Try the fixture key only after libvirt reports a DHCP address.
        if addresses:
            try:
                proc = subprocess.run(['ssh', '-i', str(key), '-o', 'IdentitiesOnly=yes',
                                       '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                                       '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes',
                                       'vmfixture@'+addresses[0], command], text=True,
                                      capture_output=True, timeout=min(20, max(1, deadline-time.monotonic())))
            except subprocess.TimeoutExpired:
                # SSH can accept a connection before first-boot setup finishes.
                error = 'SSH command timed out while waiting for the guest'
            else:
                # Return only successful guest output; retry failed SSH attempts.
                if proc.returncode == 0:
                    return proc.stdout.strip()
                error = proc.stderr
        time.sleep(2)
    raise AssertionError('Guest SSH failed: '+error)


# guest_value(command, expected) allows guest udev and hotplug callbacks to finish.
def guest_value(command, expected):
    deadline = time.monotonic()+30
    while True:
        actual = guest(command)
        if actual == expected:
            # Stop polling only after the guest itself reports the new state.
            return
        assert time.monotonic() < deadline, (command, expected, actual,
            guest('cat /sys/devices/system/cpu/present /sys/devices/system/cpu/online'))
        time.sleep(1)


# delete_running_guest(targets, [check_timeout]) removes only this fixture.
# targets names disks to remove; check_timeout defaults to false.
def delete_running_guest(targets, check_timeout=False):
    api('start', {'id': uuid, 'token': api('options', {})['token']})
    guest('test -f /var/lib/cloud/instance/boot-finished')
    before = settings()
    paths = {d['target']: d['path'] for d in before['disks'] if d.get('path')}
    if check_timeout:
        # Prevent this disposable guest from honoring ACPI without pausing QEMU.
        guest('sudo systemctl mask poweroff.target')
        try:
            job = api('delete', {'id': uuid, 'revision': before['revision'],
                'token': api('options', {})['token'], 'confirm_name': before['name'],
                'disks': [], 'shutdown': 1})
            deadline = time.monotonic() + 160
            while job['state'] not in ('complete', 'failed', 'cancelled'):
                assert time.monotonic() < deadline, job
                time.sleep(.5)
                job = api('status', {'job': job['id']})
            assert job['state'] == 'failed' and 'did not shut down' in job['error'], job
            assert not job['cleanup_pending'], job
            assert settings()['active'] and settings()['revision'] == before['revision']
            assert all(Path(path).exists() for path in paths.values())
            print('Shutdown timeout kept the running VM and all disks intact', flush=True)
        finally:
            # Restore the fixture's power handler
            # before the successful deletion.
            guest('sudo systemctl unmask poweroff.target')
    # Opening confirmation must not stop or change the running guest.
    page = request('/server-manager/edit_machine.cgi?delete=1&id='+uuid)
    assert 'data-delete-stop-text' in page and 'Type the virtual machine name' not in page
    assert 'Read-only setup media' in page
    assert settings()['active']
    if args.browser:
        # Exercise checkbox selection and the theme's confirmation navigation.
        from management_browser import edit_guest
        edit_guest(cookies, uuid, action='delete_running',
                   screenshot=args.screenshot,
                   disk={'name': before['name'], 'targets': targets},
                   on_confirmation=lambda: settings()['active'])
    else:
        # Submit the same hidden fields and selected targets through HTTPS.
        fields = HiddenInputs(page).fields
        assert fields['shutdown'] == '1'
        assert fields['confirm_name'] == before['name']
        fields.update(disks=targets)
        page = request('/server-manager/edit_machine.cgi', fields)
        assert 'cloudmin-overview' in page, page[:1000]
    assert subprocess.run(['virsh', 'dominfo', uuid], capture_output=True).returncode != 0
    for target, path in paths.items():
        assert Path(path).exists() == (target not in targets), (target, path)
    print('Deletion stopped the VM and preserved unchecked disks', flush=True)


# Remove all task-owned resources even when an assertion fails.
with tempfile.TemporaryDirectory(prefix='cloudmin-management-') as directory:
    work = Path(directory)
    key = work/'identity'
    run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)])
    cookies = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookies),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    try:
        password = secrets.token_urlsafe(36)
        run(['perl', str(here/'webmin-user.pl'), 'create', args.theme], password+'\n')
        created_user = True
        request('/session_login.cgi')
        request('/session_login.cgi', {'user': 'cloudmin-ui-check', 'pass': password,
                                      'page': '/server-manager/index.cgi'})
        options = api('options', {})
        # The fixture needs cloud-init credentials; installer ISOs cannot supply them.
        images = [image for image in options['images'] if image.get('cloud_init')]
        assert images, 'Import at least one compatible cloud image first'
        image = next((i for i in images if i['name'].startswith('Debian')), images[0])
        pool = next(p for p in options['pools'] if p['name'] == 'default')
        network = next(n for n in options['networks'] if n['source'] == 'default')
        source_hash = hashlib.file_digest(open(image['volume_path'], 'rb'), 'sha256').hexdigest()
        creation = api('create', {'token': options['token'],
            'name': 'cloudmin-create-check-management-'+secrets.token_hex(3),
            'image': image['id'], 'pool': pool['id'], 'network': network['key'],
            'cpus': 1, 'memory_mib': 768, 'disk_gib': 12,
            'username': 'vmfixture', 'ssh_keys': key.with_suffix('.pub').read_text(),
            'start': 0, 'autostart': 0})
        finished = wait_http(creation)
        uuid = finished['uuid']
        initial = settings()
        assert [d['role'] for d in initial['disks'] if d['device'] == 'disk'] == ['system', 'seed']
        assert any(d['device'] == 'cdrom' and not d.get('path') for d in initial['disks'])
        assert all(initial['name'] in Path(d['path']).name for d in initial['disks'] if d.get('path'))
        assert all(v['path'] not in [d['path'] for d in initial['disks']] + [image['volume_path']]
                   for v in initial['attachable_volumes'])
        assert '<domain' not in json.dumps(initial) and 'passwd' not in json.dumps(initial)
        page = request('/server-manager/machine.cgi?id='+uuid)
        assert 'PERL EXECUTION FAILED' not in page
        assert 'edit_machine.cgi?delete=1' not in page
        page = request('/server-manager/edit_machine.cgi?id='+uuid)
        assert 'name="cpus"' in page and 'Create empty disk' in page
        assert 'disabled' not in page.split('name="memory_mib"', 1)[1].split('>', 1)[0]
        print('Creation, HTTPS settings and editor render passed', flush=True)

        if args.delete_only:
            # Keep one disk to exercise the confirmation's unchecked default.
            delete_running_guest(['vdb'] if args.keep_system_disk else ['vda'], check_timeout=True)
            assert hashlib.file_digest(open(image['volume_path'], 'rb'), 'sha256').hexdigest() == source_hash
            print('Running VM deletion checks passed', flush=True)
            sys.exit(0)

        # Reproduce a shared-form save with an explicit socket layout.
        original_xml = run(['virsh', 'dumpxml', uuid, '--inactive', '--security-info'])
        topology_xml = ET.fromstring(original_xml)
        cpu = topology_xml.find('cpu')
        # Bind the maximum to topology while leaving the enabled count editable.
        ET.SubElement(cpu, 'topology', sockets=str(initial['cpu_limit']),
                      dies='1', clusters='1', cores='1', threads='1')
        definition = work/'topology.xml'
        definition.write_text(ET.tostring(topology_xml, encoding='unicode'))
        definition.chmod(0o600)
        run(['virsh', 'define', str(definition)])
        page = request('/server-manager/edit_machine.cgi?id='+uuid)
        assert settings()['resource_locks']['cpu_limit'] == 1
        assert 'existing CPU layout' in page
        fields = HiddenInputs(page, 'vm-edit-form').fields
        # The shared Save must preserve the disabled maximum and its topology.
        fields.update(cpus=2, memory_mib=896, memory_mib_units=1048576,
                      description='Saved with CPU topology')
        saved_page = request('/server-manager/edit_machine.cgi', fields)
        assert 'id="vm-edit-form"' in saved_page and 'Cannot edit virtual machine' not in saved_page
        saved = settings()
        assert saved['cpus'] == 2 and saved['memory_mib'] == 896
        assert saved['description'] == 'Saved with CPU topology'
        saved_xml = ET.fromstring(run(['virsh', 'dumpxml', uuid, '--inactive']))
        assert saved_xml.find('cpu/topology').get('sockets') == str(initial['cpu_limit'])
        # Restore only this fixture's definition before testing maximum changes.
        definition.write_text(original_xml)
        run(['virsh', 'define', str(definition)])
        initial = settings()
        print('Editor form saved CPU, memory and description without changing topology', flush=True)

        # A rejected delete identifies the action and leaves the guest intact.
        fields = HiddenInputs(request('/server-manager/edit_machine.cgi?delete=1&id='+uuid)).fields
        fields['confirm_name'] = 'wrong fixture name'
        page = request('/server-manager/edit_machine.cgi', fields)
        assert 'Cannot delete virtual machine' in page
        assert 'Type the virtual machine name to confirm deletion' in page
        assert settings()['revision'] == initial['revision']

        # Failed authentication, stale revisions and shrinking must not mutate.
        bad = json.loads(request('/server-manager/api.cgi',
            {'action': 'update', 'id': uuid, 'revision': initial['revision'],
             'token': 'bad', 'cpus': 2, 'memory_mib': 1024}, True))
        assert 'error' in bad
        change('update', {'cpus': 2, 'memory_mib': 1024, 'description': '<edited & preserved>',
                          'cpu_limit': 4, 'memory_limit_mib': 1536,
                          'boot': 'disk:vda', 'bootmenu': 1})
        now = settings()
        assert now['cpus'] == 2 and now['memory_mib'] == 1024
        bad = json.loads(request('/server-manager/api.cgi',
            {'action': 'update', 'id': uuid, 'revision': initial['revision'],
             'token': api('options', {})['token'], 'cpus': 1, 'memory_mib': 768}, True))
        assert 'configuration changed' in bad['error']
        secure_xml = run(['virsh', 'dumpxml', uuid, '--inactive', '--security-info'])
        assert ET.fromstring(secure_xml).find('devices/graphics').get('passwd')
        # Exercise the editor Save flow when browser coverage was requested.
        if args.browser:
            from management_browser import edit_guest
            edit_guest(cookies, uuid, screenshot=args.screenshot)
            saved = settings()
            assert saved['description'] == 'Browser edit: <guest & café>'
            assert saved['disks'][0]['volume_info']['capacity'] == 13*1024**3
            assert len(saved['disks']) == 4 and len(saved['interfaces']) == 2
            added = next(d['volume_info'] for d in saved['disks'] if d['target'] == 'vdc')
            assert added['capacity'] == 1024**3
            edit_guest(cookies, uuid, action='remove_devices')
            saved = settings()
            assert len(saved['disks']) == 3 and len(saved['interfaces']) == 1
            assert Path(added['path']).is_file()
            edit_guest(cookies, uuid, action='save')
            assert settings()['description'] == 'Saved browser settings'
            print('One browser Save applied resources, disks and NICs; removal kept disk data: '+args.theme, flush=True)
        print('CPU, RAM, boot, secret preservation and stale form checks passed', flush=True)

        # Clone through libvirt, then detach and reattach the independent volume.
        if args.browser:
            edit_guest(cookies, uuid, action='clone_disk', disk_choice=image['id'])
        # Exercise the same cloning operation through the API without a browser.
        else:
            change('add_disk', {'pool': pool['id'], 'image': image['id']})
        cloned = next(d for d in settings()['disks'] if d['target'] == 'vdc')
        assert initial['name'] in Path(cloned['path']).name
        assert cloned['volume_info']['capacity'] == next(i for i in settings()['images'] if i['id'] == image['id'])['capacity']
        run(['qemu-img', 'compare', image['volume_path'], cloned['path']], timeout=180)
        assert 'backing-filename' not in json.loads(run(['qemu-img', 'info', '--output=json', cloned['path']]))
        change('detach_disk', {'target': 'vdc'})
        available = settings()['attachable_volumes']
        choice = next(v for v in available if v['path'] == cloned['path'])
        assert all(v['path'] != image['volume_path'] for v in available)
        # Use the editor to verify the existing-volume picker and submission.
        if args.browser:
            edit_guest(cookies, uuid, action='attach_disk', disk_choice=choice['pool']+':'+choice['name'])
        # Reattach the selected existing volume through the API-only path.
        else:
            change('attach_disk', {'pool': choice['pool'], 'volume': choice['name']})
        assert next(d for d in settings()['disks'] if d['target'] == 'vdc')['path'] == cloned['path']
        change('detach_disk', {'target': 'vdc'})
        assert hashlib.file_digest(open(image['volume_path'], 'rb'), 'sha256').hexdigest() == source_hash
        print('Independent image clone, filtered picker and reattachment passed', flush=True)

        # New disk, grow, detach and reattach all use actual libvirt volumes.
        job = change('add_disk', {'pool': pool['id'], 'disk_gib': 1})
        new = next(d for d in settings()['disks'] if d['target'] == 'vdc')
        volume = new['volume_info']
        change('grow_disk', {'target': 'vdc', 'disk_gib': 2})
        assert next(d for d in settings()['disks'] if d['target'] == 'vdc')['volume_info']['capacity'] == 2*1024**3
        change('detach_disk', {'target': 'vdc'})
        assert Path(volume['path']).is_file()
        # Use the local root CLI as a separate public entry point.
        s = cli('settings', {'id': uuid})
        wait(cli('attach_disk', {'id': uuid, 'revision': s['revision'],
                                 'pool': pool['id'], 'volume': volume['name']}))
        change('add_interface', {'network': network['key'], 'mac': '52:54:00:aa:ed:01'})
        change('update_interface', {'network': network['key'], 'mac': '52:54:00:aa:ed:01'})
        change('remove_interface', {'mac': '52:54:00:aa:ed:01'})
        print('Disk creation/growth/detach/attach and NIC changes passed', flush=True)

        if args.offline_only:
            # Confirmed deletion also redirects directly, preserving retained disks.
            fields = HiddenInputs(request('/server-manager/edit_machine.cgi?delete=1&id='+uuid)).fields
            fields['confirm_name'] = initial['name']
            page = request('/server-manager/edit_machine.cgi', fields)
            assert 'cloudmin-overview' in page and 'data-second-print' not in page
            assert subprocess.run(['virsh', 'dominfo', uuid], capture_output=True).returncode != 0
            assert Path(volume['path']).exists()
            print('Confirmed deletion returned directly to the overview', flush=True)
            print('Offline VM management checks passed', flush=True)
            sys.exit(0)

        # Boot the edited guest and check hardware from inside the guest OS.
        api('start', {'id': uuid, 'token': api('options', {})['token']})
        assert guest('nproc', 600) == '2'
        assert guest('cat /sys/class/block/vdc/size') == str(2*1024**3//512)
        assert 850000 < int(guest("awk '/MemTotal/ {print $2}' /proc/meminfo")) < 1100000
        page = request('/server-manager/edit_machine.cgi?id='+uuid)
        assert 'vm-edit-form' in page and 'vm-shutdown-form' in page
        assert 'disabled' not in page.split('name="cpus"', 1)[1].split('>', 1)[0]
        assert 'disabled' not in page.split('name="cpu_limit"', 1)[1].split('>', 1)[0]
        # Save a boot CPU reduction while applying supported memory changes now.
        current = settings()
        assert current['live_limits']['min_cpus'] == 2, current['live_limits']
        assert 'data-vm-min="1"' in page.split('name="cpus"', 1)[1].split('>', 1)[0]
        mixed = change('update', {'cpus': 1, 'memory_mib': 896})
        assert mixed['scope'] == 'live' and mixed['deferred_fields'] == ['cpus'], mixed
        assert settings()['pending']['cpus'] == {'running': 2, 'saved': 1}
        assert guest('nproc') == '2'
        page = request('/server-manager/edit_machine.cgi?id='+uuid)
        assert 'Running: 2' in page and 'next start: 1' in page and 'vm-next-start-notice' not in page
        change('update', {'cpus': 1, 'memory_mib': 896, 'description': 'Pending CPU retained'})
        assert settings()['pending']['cpus'] == {'running': 2, 'saved': 1}
        change('update', {'cpus': 2, 'memory_mib': 1024})
        assert 'cpus' not in settings()['pending']
        # Maximums and boot menu are config-only; a full start applies them.
        deferred = change('update', {'cpus': 1, 'cpu_limit': 3, 'memory_mib': 1792,
                                    'memory_limit_mib': 1792, 'bootmenu': 0})
        assert deferred['scope'] == 'config', deferred
        assert settings()['running']['cpus'] == 2
        assert settings()['running']['memory_limit_mib'] == 1536
        # The banner's action uses a durable clean shutdown/start job.
        if args.browser:
            edit_guest(cookies, uuid, action='power_cycle', screenshot='/tmp/cloudmin-pending-banner.jpg')
        else:
            # Without a browser, exercise the same durable power-cycle endpoint.
            cycle = change('power_cycle', {})
            assert [event['step'] for event in cycle['events']] == ['power_cycle_shutdown', 'power_cycle_start']
        assert guest('nproc', 600) == '1'
        assert not settings()['pending'], settings()['pending']
        assert settings()['bootmenu'] == 0
        assert int(guest("awk '/MemTotal/ {print $2}' /proc/meminfo")) > 1600000
        # Restore the baseline allocation before
        # testing native live adjustments.
        api('shutdown', {'id': uuid, 'token': api('options', {})['token']})
        stopped()
        change('update', {'cpus': 2, 'cpu_limit': 4, 'memory_mib': 1024,
                          'memory_limit_mib': 1536, 'bootmenu': 0})
        api('start', {'id': uuid, 'token': api('options', {})['token']})
        assert guest('nproc', 600) == '2'
        print('Deferred CPU, memory and boot settings survive edits and apply on full start', flush=True)
        # Live resource changes persist and are visible from inside the guest.
        if args.expect_no_cpu_hotplug:
            # Unsupported CPU hardware must fail without persisting a new count.
            current = settings()
            refused = api('update', {'id': uuid, 'revision': current['revision'],
                'token': api('options', {})['token'], 'cpus': 3, 'memory_mib': 1024})
            deadline = time.monotonic()+30
            while refused['state'] in ('queued', 'running'):
                assert time.monotonic() < deadline
                time.sleep(.25)
                refused = api('status', {'job': refused['id']})
            assert refused['state'] == 'failed' and 'cpu hotplug is not supported' in refused['error'], refused
            assert not refused['cleanup_pending'] and settings()['revision'] == current['revision']
            assert change('update', {'cpus': 2, 'memory_mib': 896})['scope'] == 'live'
            print('Unsupported CPU hotplug leaves saved hardware unchanged', flush=True)
        else:
            # Supported hosts must expose the added CPU inside the guest OS.
            assert change('update', {'cpus': 3, 'memory_mib': 896})['scope'] == 'live'
            guest_value('cat /sys/devices/system/cpu/present', '0-2')
            # Ubuntu exposes the added CPU but leaves it offline until configured.
            guest('sudo sh -c "echo 1 > /sys/devices/system/cpu/cpu2/online"')
            guest_value('nproc', '3')
            assert settings()['live_limits']['min_cpus'] == 2, 'Hot-added CPU remains removable'
        # Balloon completion is asynchronous even
        # after libvirt accepts the edit.
        deadline = time.monotonic()+30
        while int(guest("awk '/MemTotal/ {print $2}' /proc/meminfo")) > 920000:
            assert time.monotonic() < deadline, 'Guest did not balloon memory'
            time.sleep(.5)
        assert change('update', {'cpus': 2, 'memory_mib': 1024})['scope'] == 'live'
        guest_value('nproc', '2')
        # Grow the open disk, detach it without
        # deletion, then reattach its file.
        assert change('grow_disk', {'target': 'vdc', 'disk_gib': 3})['scope'] == 'live'
        assert guest('cat /sys/class/block/vdc/size') == str(3*1024**3//512)
        assert change('detach_disk', {'target': 'vdc'})['scope'] == 'live'
        assert guest('test ! -e /sys/class/block/vdc && echo removed') == 'removed'
        assert Path(volume['path']).is_file()
        assert change('attach_disk', {'pool': pool['id'], 'volume': volume['name']})['scope'] == 'live'
        assert guest('cat /sys/class/block/vdc/size') == str(3*1024**3//512)
        change('add_disk', {'pool': pool['id'], 'disk_gib': 1})
        assert guest('cat /sys/class/block/vdd/size') == str(1024**3//512)
        change('detach_disk', {'target': 'vdd'})
        # Exercise cable state and both traffic
        # directions on a second interface.
        nic = '52:54:00:aa:ed:02'
        assert change('add_interface', {'network': network['key'], 'mac': nic})['scope'] == 'live'
        assert nic in guest('cat /sys/class/net/*/address')
        change('update_interface', {'mac': nic, 'link': 'down', 'inbound_kib': 512, 'outbound_kib': 256})
        saved_nic = next(n for n in settings()['interfaces'] if n['mac'] == nic)
        assert saved_nic['link'] == 'down' and saved_nic['inbound_kib'] == 512
        change('update_interface', {'mac': nic, 'link': 'up', 'inbound_kib': 0, 'outbound_kib': 0})
        # An isolated fixture network tests source switching without host routing changes.
        network_fixture = 'cloudmin-live-edit-'+secrets.token_hex(4)
        network_xml = work/'network.xml'
        network_xml.write_text('<network><name>'+network_fixture+'</name></network>')
        run(['virsh', 'net-create', str(network_xml)])
        network_id = run(['virsh', 'net-uuid', network_fixture]).strip()
        assert change('update_interface', {'mac': nic, 'network': 'network:'+network_id})['scope'] == 'live'
        assert next(n for n in settings()['interfaces'] if n['mac'] == nic)['source'] == network_fixture
        change('update_interface', {'mac': nic, 'network': network['key']})
        assert change('remove_interface', {'mac': nic})['scope'] == 'live'
        run(['virsh', 'net-destroy', network_fixture])
        network_fixture = None
        assert nic not in guest('cat /sys/class/net/*/address')
        print('Live resource, disk hotplug/growth and network hotplug checks passed', flush=True)

        # The seed ISO exercises media insertion without creating an unrelated file.
        cdrom = next(d for d in settings()['disks'] if d['device'] == 'cdrom')['target']
        seed = next(d['volume_info'] for d in settings()['disks'] if d['role'] == 'seed')
        assert change('change_media', {'target': cdrom, 'pool': seed['pool'], 'volume': seed['name']})['scope'] == 'live'
        assert next(d for d in settings()['disks'] if d['target'] == cdrom)['path'] == seed['path']
        change('change_media', {'target': cdrom, 'volume': ''})
        assert not next(d for d in settings()['disks'] if d['target'] == cdrom).get('path')
        print('Live CD insertion and ejection passed', flush=True)

        # A later live interface edit must preserve a boot choice saved for next start.
        mac = settings()['interfaces'][0]['mac']
        change('update', {'cpus': 2, 'memory_mib': 1024, 'boot': 'nic:'+mac,
                         'changes': [{'action': 'update_interface', 'mac': mac, 'inbound_kib': 512}]})
        live_xml = ET.fromstring(run(['virsh', 'dumpxml', uuid]))
        assert live_xml.find('devices/interface/boot') is None
        assert 'boot' in settings()['pending']
        change('update_interface', {'mac': mac, 'inbound_kib': 0})
        assert ET.fromstring(run(['virsh', 'dumpxml', uuid])).find('devices/interface/boot') is None
        assert 'boot' in settings()['pending']
        change('update', {'cpus': 2, 'memory_mib': 1024, 'boot': 'disk:vda'})
        assert 'boot' not in settings()['pending']
        print('Live interface updates preserve pending boot order', flush=True)
        # Pause retains QEMU state; resume must make the same guest responsive.
        api('suspend', {'id': uuid, 'token': api('options', {})['token']})
        assert run(['virsh', 'domstate', uuid]).strip() == 'paused'
        api('resume', {'id': uuid, 'token': api('options', {})['token']})
        assert guest('echo resumed') == 'resumed'
        print('Pause and resume passed', flush=True)
        # Finish first-boot setup before testing an abrupt hardware reset.
        guest('test -f /var/lib/cloud/instance/boot-finished')
        guest('sudo sync')
        boot_id = guest('cat /proc/sys/kernel/random/boot_id')
        api('reset', {'id': uuid, 'token': api('options', {})['token'], 'confirm': 1})
        time.sleep(3)
        assert guest('cat /proc/sys/kernel/random/boot_id') != boot_id
        print('Live CD insert/eject, pause/resume and confirmed hard reset passed', flush=True)
        if args.browser:
            # The editor's separate shutdown form must not submit resource edits.
            edit_guest(cookies, uuid, action='shutdown')
        # The API-only run requests the same clean shutdown.
        else:
            api('shutdown', {'id': uuid, 'token': api('options', {})['token']})
        stopped()
        # Reproduce an older definition with no free ports or spare CPU slots.
        legacy = ET.fromstring(run(['virsh', 'dumpxml', uuid, '--inactive', '--security-info']))
        used = {int(a.get('bus'), 16) for a in legacy.findall('devices/*/address') if a.get('type') == 'pci'}
        for controller in list(legacy.findall('devices/controller')):
            if controller.get('model') == 'pcie-root-port' and int(controller.get('index')) not in used:
                # Remove only spare ports; retain every bus used by a device.
                legacy.find('devices').remove(controller)
        legacy.find('vcpu').text = '2'
        legacy_file = work/'legacy.xml'
        legacy_file.write_text(ET.tostring(legacy, encoding='unicode'))
        legacy_file.chmod(0o600)
        run(['virsh', 'define', str(legacy_file)])
        api('start', {'id': uuid, 'token': api('options', {})['token']})
        assert guest('nproc') == '2'
        assert settings()['live_limits']['pcie_ports'] == 0
        assert 'Shut down once' in request('/server-manager/edit_machine.cgi?id='+uuid)
        assert change('update', {'cpus': 3, 'memory_mib': 1024})['scope'] == 'config'
        assert settings()['pending']['cpus'] == {'running': 2, 'saved': 3}
        # Device additions without ports must fail
        # before allocating any storage.
        for action, fields in [('add_disk', {'pool': pool['id'], 'disk_gib': 1})]:
            current = settings()
            blocked = api(action, {'id': uuid, 'revision': current['revision'],
                          'token': api('options', {})['token'], **fields})
            deadline = time.monotonic()+30
            while blocked['state'] in ('queued', 'running'):
                assert time.monotonic() < deadline
                time.sleep(.25)
                blocked = api('status', {'job': blocked['id']})
            assert blocked['state'] == 'failed' and blocked['scope'] == 'offline-required', blocked
            assert not blocked['cleanup_pending']
        api('shutdown', {'id': uuid, 'token': api('options', {})['token']})
        stopped()
        assert change('update', {'cpus': 2, 'memory_mib': 1024, 'enable_live': 1})['scope'] == 'config'
        assert settings()['live_limits']['pcie_ports'] > 0
        print('Legacy guest reports offline requirements and gains headroom while stopped', flush=True)
        if args.browser:
            # Delete opens the explicit disk confirmation instead of deleting now.
            edit_guest(cookies, uuid, action='delete')
        print('Edited guest booted with requested CPUs, RAM and disk capacity', flush=True)

        # A second fixture domain sharing the extra disk must prevent deletion.
        shared_name = 'cloudmin-create-check-management-shared-'+secrets.token_hex(3)
        shared_xml = ET.fromstring(run(['virsh', 'dumpxml', uuid, '--inactive', '--security-info']))
        shared_xml.find('name').text = shared_name
        shared_xml.remove(shared_xml.find('uuid'))
        for node in list(shared_xml.find('devices')):
            # The sharing fixture references only the extra disk under test.
            if node.tag == 'disk' and node.find('target').get('dev') != 'vdc':
                shared_xml.find('devices').remove(node)
        nvram = shared_xml.find('os/nvram')
        # Do not share firmware variables between the two fixture domains.
        if nvram is not None:
            shared_xml.find('os').remove(nvram)
        shared_file = work/'shared.xml'
        shared_file.write_text(ET.tostring(shared_xml, encoding='unicode'))
        run(['virsh', 'define', str(shared_file)])
        try:
            s = settings()
            bad = json.loads(request('/server-manager/api.cgi', {
                'action': 'delete', 'id': uuid, 'revision': s['revision'],
                'token': api('options', {})['token'], 'confirm_name': s['name'], 'disks': ['vdc']}, True))
            assert 'used by virtual machine' in bad['error']
            shared_uuid = run(['virsh', 'domuuid', shared_name]).strip()
            page = request('/server-manager/edit_machine.cgi?delete=1&id='+shared_uuid)
            fields = HiddenInputs(page).fields
            fields['confirm_name'] = shared_name
            page = request('/server-manager/edit_machine.cgi', fields)
            assert 'cloudmin-overview' in page and 'data-second-print' not in page
            assert Path(volume['path']).exists(), 'Keep-disks form removed shared data'
        finally:
            exists = subprocess.run(['virsh', 'dominfo', shared_name], capture_output=True)
            # An interrupted assertion may leave the shared fixture defined.
            if exists.returncode == 0:
                run(['virsh', 'undefine', shared_name, '--nvram'])
        print('Shared disk deletion refused without changing either VM', flush=True)

        # Restart, then delete root and seed while retaining the extra disk.
        disk_paths = [d['path'] for d in settings()['disks'] if d['target'] in ('vda', 'vdb')]
        nvram = ET.fromstring(secure_xml).findtext('os/nvram')
        delete_running_guest(['vda', 'vdb'])
        assert all(not Path(p).exists() for p in disk_paths)
        assert not nvram or not Path(nvram).exists()
        assert Path(volume['path']).exists()
        assert hashlib.file_digest(open(image['volume_path'], 'rb'), 'sha256').hexdigest() == source_hash
        print('Deletion removed selected disks and NVRAM, preserved retained disk and source image', flush=True)
    finally:
        try:
            # Clean up only the resources recorded for this creation job.
            if creation:
                subprocess.run(['perl', str(here/'machine_fixture.pl'), 'cleanup', creation['id']], check=True)
        finally:
            # Revoke the account only if fixture login setup succeeded.
            if created_user:
                run(['perl', str(here/'webmin-user.pl'), 'delete'])
            if network_fixture:
                # A failed source-switch check may leave
                # its isolated network active.
                subprocess.run(['virsh', 'net-destroy', network_fixture], check=True)
print('VM management live checks passed', flush=True)
