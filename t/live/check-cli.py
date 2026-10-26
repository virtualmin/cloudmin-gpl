#!/usr/bin/python3
"""Exercise the installed cloudmin command on a disposable Linux Cloudmin host."""
import argparse
import http.cookiejar
import json
import math
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


# run(args, [expected=0], [input=None], [timeout=600]) checks the exit status.
# Returns captured stdout/stderr; input is text stdin and timeout is seconds.
def run(args, expected=0, input=None, timeout=600):
    result = subprocess.run(['/usr/sbin/cloudmin', *args], input=input,
                            text=True, capture_output=True, timeout=timeout)
    assert result.returncode == expected, (args, result.returncode, result.stderr, result.stdout)
    return result


# data(args) reads a named command's JSON envelope and enforces quiet stderr.
def data(args):
    result = run([*args, '--json'])
    value = json.loads(result.stdout)
    assert value['status'] == 'success', value
    assert not result.stderr, result.stderr
    return value['data']


# state(name, wanted, [timeout=180]) waits for host power state, in seconds.
def state(name, wanted, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rows = data(['list-systems', '--name', name])
        # Keep waiting if the guest is not yet listed.
        if rows and rows[0]['state'] == wanted:
            return
        time.sleep(1)
    raise AssertionError(f'{name} did not become {wanted}')


# guest_ready(uuid) waits for an agent or SSH before testing shutdown.
def guest_ready(uuid):
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        result = subprocess.run(['virsh', 'qemu-agent-command', uuid,
                                 '{"execute":"guest-ping"}'], capture_output=True, text=True)
        # A responding guest agent proves the operating system has started.
        if result.returncode == 0:
            return
        # Cloud images can boot normally without a preinstalled guest agent.
        for row in data(['list-systems', '--id', uuid]):
            for address in row['addresses']:
                try:
                    with socket.create_connection((address, 22), timeout=2) as connection:
                        # Require an SSH banner rather than merely an open port.
                        if connection.recv(256).startswith(b'SSH-'):
                            return
                # Addresses and SSH may be unavailable during boot.
                except OSError:
                    pass
        time.sleep(2)
    raise AssertionError('Fixture guest did not expose its agent or SSH service')


# check_access(module) exercises the real GET endpoint with a temporary viewer.
def check_access(module):
    rows = data(['list-systems'])
    assert rows, 'Access checks need one existing guest to read'
    uuid, name = rows[0]['id'], rows[0]['name']
    username = 'cloudmin-ui-check-' + secrets.token_hex(4)
    helper = module / 't/live/webmin-user.pl'
    # Connect to the test host's local Webmin without a proxy.
    base = 'https://127.0.0.1:10000'
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))

    # account(action, [payload=""]) passes setup data to the helper on stdin.
    def account(action, payload=''):
        subprocess.run(['perl', str(helper), action, 'authentic-theme', username],
                       input=payload, text=True, check=True, capture_output=True, timeout=30)

    # request(path, [fields=None]) returns the response body using session
    # cookies. fields selects a form POST; omitted fields select GET.
    def request(path, fields=None):
        body = urllib.parse.urlencode(fields).encode() if fields is not None else None
        req = urllib.request.Request(base + path, data=body,
                                     headers={'Referer': base + '/server-manager/'})
        try:
            response = opener.open(req, timeout=30)
        # API error bodies are part of the assertions, not transport exceptions.
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.read().decode()

    # machines([selector=None]) decodes a token-free inventory response.
    # selector is an exact name or UUID; omission requests the visible list.
    def machines(selector=None):
        query = {'action': 'machines'}
        # Raw inventory accepts an exact name or UUID in the same id field.
        if selector is not None:
            query['id'] = selector
        return json.loads(request('/server-manager/api.cgi?' + urllib.parse.urlencode(query)))

    # Keep the temporary Webmin password in memory and pass it only over stdin.
    password = secrets.token_urlsafe(36)
    account('create', password + '\n')
    try:
        account('acl', json.dumps({'admin': 0, 'vms': uuid}))
        request('/session_login.cgi')
        request('/session_login.cgi', {'user': username, 'pass': password,
                                      'page': '/server-manager/'})
        visible = machines()
        assert visible['version'] == 1 and [r['id'] for r in visible['result']] == [uuid]
        assert machines(name)['result']['id'] == uuid
        assert machines(uuid)['result']['id'] == uuid
        # Read-only policy must preserve permitted inventory reads.
        account('readonly', '1\n')
        assert machines()['result'] == visible['result'], 'Read-only viewers lost inventory access'
        # Check that access revocation takes effect within the same session.
        account('acl', json.dumps({'admin': 0, 'vms': ''}))
        assert machines()['result'] == []
        hidden, missing = machines(uuid), machines('cloudmin-cli-missing-' + secrets.token_hex(8))
        assert hidden['error'] == missing['error'] and 'result' not in hidden
    # Remove the temporary account even if an access assertion fails.
    finally:
        account('delete')
    # Both entry points must refuse an unprivileged shell before initializing
    # the installed module.
    for command in (['/usr/sbin/cloudmin'], ['perl', str(module / 'cli.pl')]):
        result = subprocess.run(['runuser', '-u', 'nobody', '--', *command, 'list-systems'],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 2 and 'root' in result.stderr and not result.stdout
    print('PASS HTTP GET inventory, assigned guests, read-only access, hidden identities and root guards', flush=True)


# check_storage_access(module, pool) tests HTTP storage ACLs on a fixture pool.
def check_storage_access(module, pool):
    helper = module / 't/live/webmin-user.pl'
    username = 'cloudmin-ui-check-' + secrets.token_hex(4)
    password = secrets.token_urlsafe(36)
    base = 'https://127.0.0.1:10000'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))

    # account(action, [payload]) changes only this temporary account.
    def account(action, payload=''):
        subprocess.run(['perl', str(helper), action, 'authentic-theme', username],
            input=payload, text=True, check=True, capture_output=True, timeout=30)

    # request(path, [fields]) uses a local session without printing credentials.
    def request(path, fields=None):
        body = urllib.parse.urlencode(fields).encode() if fields is not None else None
        req = urllib.request.Request(base + path, data=body,
            headers={'Referer': base + '/server-manager/'})
        try:
            response = opener.open(req, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.read().decode()

    # api(action, [fields]) decodes GET inventory or a form POST response.
    def api(action, fields=None):
        if fields is None:
            # Omitting fields deliberately tests the HTTP GET contract.
            return json.loads(request('/server-manager/api.cgi?action=' + action))
        # Supplied fields use POST, including reviews that issue revisions.
        return json.loads(request('/server-manager/api.cgi', {'action': action, **fields}))

    # Use a temporary administrator and keep its credentials inside the fixture.
    account('create', password + '\n')
    try:
        request('/session_login.cgi')
        request('/session_login.cgi', {'user': username, 'pass': password, 'page': '/server-manager/'})
        assert any(p['uuid'] == pool['uuid'] for p in api('storage')['result']['pools'])
        token = api('options')['result']['token']
        # Refuse GET and bad tokens before accepting the same valid mutation.
        fields = {'id': pool['uuid'], 'revision': pool['revision'], 'enabled': 0, 'token': token}
        assert 'error' in api('pool_autostart'), 'HTTP GET must not mutate storage'
        assert 'error' in api('pool_autostart', {**fields, 'token': 'invalid'})
        changed = api('pool_autostart', fields)['result']
        assert not changed['autostart'], changed
        fields['revision'] = changed['revision']
        # Read-only administrators retain inventory but lose reviews and writes.
        account('readonly', '1\n')
        assert 'result' in api('storage')
        for action in ('register_pool', 'pool_start', 'pool_stop', 'pool_autostart',
                       'volume_review', 'delete_volume', 'pool_review', 'unregister_pool'):
            assert 'error' in api(action, fields), action
        # Delegated machine grants never expose the host's storage inventory.
        account('readonly', '0\n')
        account('acl', json.dumps({'admin': 0, 'power': 1, 'vms': '*'}))
        assert 'error' in api('storage')
        for action in ('volume_review', 'pool_review', 'pool_autostart', 'delete_volume', 'unregister_pool'):
            assert 'error' in api(action, fields), action
    finally:
        # Remove the account even when a permission assertion fails.
        account('delete')
    print('PASS HTTP storage inventory, POST/token checks, read-only and delegated refusals', flush=True)


# check_storage(module) exercises synchronous CLI storage commands and cleanup.
def check_storage(module):
    name = 'cloudmin-cli-storage-' + secrets.token_hex(4)
    before = {p['uuid'] for p in data(['list-pools'])}
    with tempfile.TemporaryDirectory(prefix=name + '-', dir='/var/lib/libvirt') as directory:
        path = Path(directory) / 'pool'
        try:
            # Register through the CLI and retain the new pool's native identity.
            pool = data(['create-pool', '--name', name, '--path', str(path), '--no-autostart'])
            assert pool['name'] == name and pool['active'] and not pool['autostart'], pool
            uuid = pool['uuid']
            assert name in run(['list-pools', '--name-only']).stdout.splitlines()
            data(['list-volume-groups'])
            assert data(['set-pool-autostart', '--pool', uuid, '--enabled', 'yes'])['autostart']
            check_storage_access(module, next(p for p in data(['list-pools']) if p['uuid'] == uuid))
            # A raw file needs no OS image and lets the test prove data preservation.
            spare = path / 'spare.raw'
            spare.write_bytes(b'fixture bytes')
            subprocess.run(['virsh', 'pool-refresh', uuid], check=True, capture_output=True)
            volumes = data(['list-volumes', '--pool', name])
            assert any(v['name'] == spare.name and v['pool_id'] == uuid for v in volumes), volumes
            # Reviewing a volume must not delete it or require confirmation.
            review = data(['delete-volume', '--pool', uuid, '--volume', spare.name, '--review'])
            assert not review['usage']['reason'] and review['revision'], review
            assert spare.exists(), 'Review must preserve the disk'
            # Missing confirmation and a stale revision both leave the file alone.
            run(['delete-volume', '--pool', uuid, '--volume', spare.name], expected=2)
            stale = {'pool': uuid, 'volume': spare.name, 'revision': 'stale', 'confirm': 1}
            run(['api', 'delete_volume'], expected=1, input=json.dumps(stale))
            assert spare.exists(), 'Stale review must preserve the disk'
            # Only the confirmed request with a fresh review deletes the file.
            data(['delete-volume', '--pool', name, '--volume', spare.name, '--yes'])
            assert not spare.exists()
            # Without --stop, an active pool is refused; lifecycle changes retain data.
            keep = path / 'keep.raw'
            keep.write_bytes(b'keep this data')
            blocked = data(['unregister-pool', '--pool', uuid, '--review'])
            assert blocked['usage']['reason'], blocked
            run(['unregister-pool', '--pool', uuid, '--yes'], expected=1)
            assert not data(['stop-pool', '--pool', name])['active']
            assert name in run(['list-pools', '--name-only']).stdout.splitlines()
            assert data(['start-pool', '--pool', name])['active']
            assert not data(['stop-pool', '--pool', name])['active']
            review = data(['unregister-pool', '--pool', name, '--review'])
            # Inactive removal still requires confirmation and a current revision.
            assert not review['usage']['reason'], review
            run(['unregister-pool', '--pool', name], expected=2)
            run(['api', 'unregister_pool'], expected=1,
                input=json.dumps({'id': uuid, 'revision': 'stale', 'confirm': 1}))
            data(['unregister-pool', '--pool', uuid, '--yes'])
            assert keep.read_bytes() == b'keep this data', 'Unregistration must preserve data'
            assert {p['uuid'] for p in data(['list-pools'])} == before
            # Explicit stop combines both operations, preserving existing files.
            pool = data(['create-pool', '--name', name, '--path', str(path), '--no-autostart'])
            uuid = pool['uuid']
            review = data(['unregister-pool', '--pool', uuid, '--stop', '--review'])
            assert review['stop_required'] and not review['usage']['reason'], review
            run(['unregister-pool', '--pool', uuid, '--stop'], expected=2)
            data(['unregister-pool', '--pool', uuid, '--stop', '--yes'])
            assert keep.read_bytes() == b'keep this data'
            assert {p['uuid'] for p in data(['list-pools'])} == before
            print('PASS CLI pool registration, inventory, lifecycle, volume deletion and safe unregistration', flush=True)
        finally:
            # Cleanup uses only this test's random pool name, even after failure.
            pools = subprocess.check_output(['virsh', 'pool-list', '--all', '--name'], text=True).splitlines()
            if name in pools:
                # A successful test already removed the registration.
                active = subprocess.check_output(['virsh', 'pool-list', '--name'], text=True).splitlines()
                if name in active:
                    # Stop only this surviving fixture before undefining it.
                    subprocess.run(['virsh', 'pool-destroy', name], check=True, capture_output=True)
                subprocess.run(['virsh', 'pool-undefine', name], check=True, capture_output=True)


# main() runs checks and cleans up its fixture guest and resources.
def main():
    """Create and delete one fixture while exercising reads, mutations and errors."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', help='Ready imported cloud image ID; defaults to the first suitable image')
    parser.add_argument('--access-only', action='store_true', help='Only run HTTP permission and root checks')
    parser.add_argument('--storage-only', action='store_true', help='Only run storage CLI and HTTP checks')
    args = parser.parse_args()
    assert os.uname().sysname == 'Linux' and os.geteuid() == 0, 'Run as root on a disposable Linux host'
    module = Path(__file__).resolve().parents[2]
    # Permission-only mode uses existing inventory without creating a guest.
    if args.access_only:
        check_access(module)
        return
    check_storage(module)
    if args.storage_only:
        # Storage checks need no imported OS image or fixture guest.
        return
    # Use unique fixture names and record existing guests for cleanup checks.
    suffix = secrets.token_hex(4)
    name, username = 'cloudmin-cli-check-' + suffix, 'cmcli' + suffix
    before = {row['id'] for row in data(['list-systems'])}
    assert 'list-systems' in run([]).stdout
    assert 'cloudmin list-systems' in run(['help', 'list-systems']).stdout
    assert 'Name' in run(['list-systems']).stdout
    run(['list-systems', '--multiline'])
    run(['list-systems', '--name-only'])
    run(['list-systems', '--id-only'])
    # Usage and operation failures have distinct exit codes and output streams.
    run(['not-a-command'], expected=2)
    failure = run(['get-system', '--name', name, '--json'], expected=1)
    assert json.loads(failure.stdout)['status'] == 'failure' and not failure.stderr
    assert run(['get-system', '--name', name], expected=1).stderr.strip() == 'Virtual machine not found'
    # Raw dispatch retains its version/result envelope and stdin contract.
    raw = json.loads(run(['api', 'options'], input='').stdout)
    assert raw['version'] == 1 and 'result' in raw
    # Accept an empty options request, but require a body for creation.
    run(['api', 'create'], input='', expected=1)
    assert isinstance(json.loads(run(['api', 'machines'], input='').stdout)['result'], list)
    # Use an imported image and available storage/network from this host only.
    options = raw['result']
    images = [i for i in options['images'] if i.get('format') != 'iso' and
              (not args.image or i['id'] == args.image)]
    assert images, 'Import a compatible cloud image before running this fixture'
    image = images[0]
    pools = options['pools']
    networks = [n for n in options['networks'] if n.get('type') == 'network']
    assert pools and networks, 'Fixture needs an active file pool and virtual network'
    # Prefer the image pool and never create a disk below its required capacity.
    pool = next((p for p in pools if p['id'] == image.get('pool')), pools[0])
    disk = max(10, math.ceil(int(image.get('virtual_size') or image.get('min_disk_bytes') or 0) / 1024**3))
    print('PASS command list, help, inventory formats, raw API and error exits', flush=True)
    # Keep fixture credentials private and remove them on exit.
    with tempfile.TemporaryDirectory(prefix='cloudmin-cli-check-') as work:
        password = Path(work) / 'password'
        password.write_text(secrets.token_urlsafe(32) + '\n')
        password.chmod(0o600)
        creation = ['create-system', '--name', name, '--image', image['id'],
                    '--pool', pool['id'], '--network', networks[0]['key'], '--cpus', '1',
                    '--memory', '1G', '--disk', str(disk), '--username', username,
                    '--auth-type', 'password', '--password-file', str(password), '--no-start']
        # Verify that review creates no guest and creation waits for its job.
        try:
            review = data([*creation, '--review'])
            assert review['name'] == name and review['password_set']
            assert not data(['list-systems', '--name', name])
            created = data(creation)
            assert created['state'] == 'complete', created
            guest = data(['get-system', '--name', name])
            uuid = guest['id']
            assert guest['summary']['name'] == name and guest['summary']['disk_gib'] == disk
            assert data(['get-system', '--id', uuid])['id'] == uuid
            assert data(['get-job', '--job', created['id']])['state'] == 'complete'
            assert password.read_text().strip() not in json.dumps(guest)
            print('PASS creation review, secret-file input, job following and machine lookup', flush=True)
            # Exercise guest-scoped and host-wide read commands after creation.
            for command in ['list-disks', 'list-interfaces', 'list-snapshots']:
                assert isinstance(data([command, '--name', name]), list)
            for command in ['list-images', 'list-pools', 'list-networks', 'list-backups', 'list-bridges', 'list-jobs']:
                assert isinstance(data([command]), list)
            assert data(['get-host'])['architecture']
            data(['get-bridge-status'])
            print('PASS disk, interface, snapshot, backup, image, pool, network, job and bridge reads', flush=True)
            # Wait for the guest to boot before testing clean shutdown.
            run(['start-system', '--name', name])
            state(name, 'running')
            guest_ready(uuid)
            run(['pause-system', '--id', uuid])
            state(name, 'paused')
            run(['unpause-system', '--name', name])
            state(name, 'running')
            run(['shutdown-system', '--id', uuid])
            state(name, 'stopped')
            print('PASS start, pause, resume and clean shutdown with state polling', flush=True)
            # Check that --no-wait power requests reach the requested state.
            run(['start-system', '--id', uuid, '--no-wait'])
            state(name, 'running')
            guest_ready(uuid)
            run(['shutdown-system', '--name', name, '--no-wait'])
            state(name, 'stopped')
            print('PASS asynchronous start and clean shutdown', flush=True)
            # Test hardware edits with a real revision and background job.
            edited = data(['modify-system', '--name', name, '--desc', 'CLI fixture', '--memory', '768M'])
            assert edited['state'] == 'complete'
            assert data(['get-system', '--id', uuid])['memory_mib'] == 768
            run(['modify-system', '--id', uuid, '--autostart', 'yes'])
            assert data(['list-systems', '--id', uuid])[0]['autostart'] is True
            run(['modify-system', '--id', uuid, '--autostart', 'no'])
            print('PASS hardware update and automatic startup', flush=True)
            # A clean GPL host must reject capture before allocating an image.
            if not (module / 'pro/VMImages.pm').exists():
                result = run(['create-image', '--id', uuid, '--image-name', 'CLI fixture',
                              '--pool', pool['id'], '--json'], expected=1)
                assert 'requires Cloudmin Pro' in json.loads(result.stdout)['error']
                print('PASS GPL rejects Pro image capture', flush=True)
        # Delete this run's guest and volumes even if an assertion failed.
        finally:
            rows = data(['list-systems', '--name', name])
            # Delete the fixture guest only if creation defined it.
            if rows:
                guest = data(['get-system', '--name', name])
                deletion = ['delete-system', '--name', name, '--yes', '--shutdown']
                for disk_record in guest['disks']:
                    # Select fixture-created disks; preserve imported images.
                    if disk_record.get('volume_info') and not disk_record.get('imported'):
                        deletion.extend(['--disk', disk_record['target']])
                deleted = data(deletion)
                assert deleted['state'] == 'complete', deleted
            # Remove journals only after deleting the fixture guest and volumes.
            subprocess.run(['perl', str(module / 't/live/cli-fixture.pl'), name, username], check=True, timeout=60)
    # Verify unrelated guests remain before running read-only permission checks.
    assert {row['id'] for row in data(['list-systems'])} == before, 'Host inventory changed'
    print('PASS fixture deletion and cleanup; original guests unchanged', flush=True)
    check_access(module)


# Importing the helper must not execute system-changing fixture work.
if __name__ == '__main__':
    main()
