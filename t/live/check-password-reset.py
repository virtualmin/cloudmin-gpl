#!/usr/bin/python3
"""Reset a disposable guest account through the real agent, API and Webmin form."""
import argparse
import ctypes
import ctypes.util
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import signal
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
from xml.etree import ElementTree as ET

# Guest and Webmin account changes belong only on the authorized Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt
# error_handler(context, error) suppresses expected libvirt refusals on stderr.
libvirt.registerErrorHandler(lambda context, error: None, None)
# terminate(signum, frame) raises SystemExit so SIGTERM reaches fixture cleanup.
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(1)))
# Require an existing image and active network; leave both unchanged.
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=Path)
parser.add_argument('--network', required=True, help='An existing active fixture network')
options = parser.parse_args()
image = options.image.resolve(strict=True)
connection = libvirt.open('qemu:///system')
network = connection.networkLookupByName(options.network)
assert network.isActive(), 'The selected network must already be active'
# Unique names keep this run's guest, pool and accounts separate from host data.
directory = Path(tempfile.mkdtemp(prefix='cloudmin-password-', dir='/var/lib/libvirt/images'))
directory.chmod(0o755)
identity = str(uuid.uuid4())
name = 'cloudmin-password-' + identity[:8]
guest = pool = None
users = []
passwords = []
base = 'https://127.0.0.1:10000'
started = time.time()
# Verify resets using the guest's salt and algorithm without printing hashes.
crypt = ctypes.CDLL(ctypes.util.find_library('crypt'))
crypt.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
crypt.crypt.restype = ctypes.c_char_p


class Fields(HTMLParser):
    """Read input values, including the form token, without printing them."""

    # __init__(self, page) records each input's name and current value.
    def __init__(self, page):
        super().__init__()
        self.values = {}
        self.feed(page)

    # handle_starttag(self, tag, attrs) ignores non-input markup.
    def handle_starttag(self, tag, attrs):
        # Keep routing fields and the token for a normal form submission.
        if tag == 'input':
            attrs = dict(attrs)
            self.values[attrs.get('name')] = attrs.get('value', '')


# request(opener, path, [fields], [as_json]) sends GET when fields is None.
# Otherwise send a form POST, or JSON when as_json is true (default false).
def request(opener, path, fields=None, as_json=False):
    headers = {'Referer': base + '/server-manager/machine.cgi'}
    body = None
    # Put submitted fields in the request body, never the URL or test output.
    if fields is not None:
        body = json.dumps(fields).encode() if as_json else urllib.parse.urlencode(fields).encode()
        headers['Content-Type'] = 'application/json' if as_json else 'application/x-www-form-urlencoded'
    with opener.open(urllib.request.Request(base + path, data=body, headers=headers), timeout=45) as response:
        page = response.read().decode()
    assert 'Error - Perl execution failed' not in page, 'CGI execution failed'
    return page


# account(theme, [readonly]) creates and logs in a local-only fixture account.
# readonly defaults to false; the caller may restrict its ACL after login.
def account(theme, readonly=False):
    user = 'cloudmin-ui-check-' + secrets.token_hex(4)
    password = secrets.token_urlsafe(36)
    subprocess.run(['perl', str(helper), 'create-readonly' if readonly else 'create', theme, user],
                   input=password + '\n', text=True, check=True)
    users.append(user)
    # Bypass proxies and trust this test host's certificate for local requests.
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    time.sleep(1)
    request(opener, '/session_login.cgi')
    request(opener, '/session_login.cgi', {'user': user, 'pass': password, 'page': '/'})
    return user, opener


# grants(user, **fields) changes only the fixture user's Cloudmin permissions.
def grants(user, **fields):
    subprocess.run(['perl', str(helper), 'acl', 'authentic-theme', user],
                   input=json.dumps(fields), text=True, check=True)


# api(opener, action, **fields) exercises JSON requests without logging bodies.
def api(opener, action, **fields):
    return json.loads(request(opener, '/server-manager/api.cgi', {'action': action, **fields}, True))


# guest_command(command, [timeout]) runs root checks over the fixture's SSH.
# Each SSH attempt has a 30-second default timeout; retry connection failures
# for up to 90 seconds. Initial cloud-init checks use a longer attempt timeout.
def guest_command(command, timeout=30):
    deadline = time.monotonic() + 90
    # Poll only this guest's libvirt lease; no host or subnet probing is needed.
    while time.monotonic() < deadline:
        interfaces = guest.interfaceAddresses(libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0)
        addresses = [addr['addr'] for interface in interfaces.values() for addr in interface['addrs']
                     if addr['type'] == libvirt.VIR_IP_ADDR_TYPE_IPV4]
        # Use the fixture key as soon as DHCP assigns an IPv4 address.
        if addresses:
            result = subprocess.run(['ssh', '-F', '/dev/null', '-i', str(key),
                '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                'passwordfixture@' + addresses[0], 'sudo -n sh -c ' + shlex.quote(command)],
                capture_output=True, text=True, timeout=timeout)
            # Retry SSH failures; report guest command failures at once.
            if result.returncode != 255:
                assert result.returncode == 0, 'Fixture guest command failed'
                return result.stdout.strip()
        time.sleep(2)
    raise AssertionError('Fixture SSH did not become ready')


# verify_password(password) checks the actual guest hash without printing it.
def verify_password(password):
    stored = guest_command('getent shadow passwordfixture').split(':')[1].encode()
    assert crypt.crypt(password.encode(), stored) == stored, 'Guest password was not changed correctly'


# new_password() supplies a unique UTF-8 secret for each real operation.
def new_password():
    value = secrets.token_urlsafe(32) + ' ü space'
    passwords.append(value)
    return value


try:
    # A full copy isolates this fixture from the reusable source image.
    pool = connection.storagePoolDefineXML(
        f'<pool type="dir"><name>{name}</name><target><path>{directory}</path></target></pool>', 0)
    pool.create(0)
    disk, seed, key = directory / 'root.qcow2', directory / 'seed.iso', directory / 'identity'
    subprocess.run(['qemu-img', 'convert', '-O', 'qcow2', str(image), str(disk)], check=True, timeout=120)
    subprocess.run(['qemu-img', 'resize', str(disk), '20G'], check=True, timeout=30)
    pool.refresh(0)
    # A fixture SSH key keeps guest access working across password changes.
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    user_data = {'packages': ['qemu-guest-agent'], 'users': ['default', {
        'name': 'passwordfixture', 'sudo': 'ALL=(ALL) NOPASSWD:ALL',
        'ssh_authorized_keys': [key.with_suffix('.pub').read_text().strip()]}],
        'runcmd': [['systemctl', 'enable', '--now', 'qemu-guest-agent']]}
    # Install and enable the agent through a guest-local cloud-init seed.
    (directory / 'user-data').write_text('#cloud-config\n' + json.dumps(user_data) + '\n')
    (directory / 'meta-data').write_text(f'instance-id: {identity}\nlocal-hostname: password-fixture\n')
    subprocess.run(['xorriso', '-as', 'mkisofs', '-quiet', '-o', str(seed), '-V', 'cidata', '-J', '-r',
                    str(directory / 'user-data'), str(directory / 'meta-data')], check=True, timeout=30)
    # Match the host architecture and provide a channel for the guest agent.
    arch = connection.getInfo()[0]
    machine = 'virt' if arch == 'aarch64' else 'q35'
    source = ET.tostring(ET.Element('source', network=network.name()), encoding='unicode')
    guest = connection.defineXML(f'''<domain type="kvm"><name>{name}</name><uuid>{identity}</uuid>
      <memory unit="MiB">1024</memory><vcpu>2</vcpu><cpu mode="host-passthrough"/>
      <os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type></os><features><acpi/></features><devices>
      <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{disk}"/><target dev="vda" bus="virtio"/></disk>
      <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seed}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
      <interface type="network">{source}<model type="virtio"/></interface>
      <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
      <serial type="pty"/><memballoon model="virtio"/></devices></domain>''')
    guest.create()
    # Wait for cloud-init to start the agent before exercising password resets.
    deadline = time.monotonic() + 240
    while True:
        try:
            # Require an OS reply before submitting a password reset.
            if guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0):
                break
        except libvirt.libvirtError:
            pass  # Cloud-init may still be installing or starting the agent.
        assert time.monotonic() < deadline, 'Fixture agent did not start'
        time.sleep(2)
    guest_command('cloud-init status --wait >/dev/null', timeout=240)
    print('PASS: disposable guest booted with a responding agent', flush=True)
    # Record pre-existing jobs without creating a store on a fresh host.
    database = Path('/var/webmin/modules/server-manager/vm-jobs/jobs.sqlite')
    before_jobs = set()
    # Read existing jobs only if the store has already been created.
    if database.exists():
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
            before_jobs = {row[0] for row in db.execute('SELECT id FROM jobs')}

    # The CLI passes the password on stdin and must omit it from its output.
    password = new_password()
    cli = subprocess.run(['perl', str(module / 'api.pl'), 'reset_password'],
        input=json.dumps({'id': identity, 'username': 'passwordfixture', 'password': password}),
        text=True, capture_output=True, timeout=30)
    assert cli.returncode == 0 and json.loads(cli.stdout)['result']['action'] == 'reset_password', 'CLI reset failed'
    assert password not in cli.stdout + cli.stderr, 'CLI exposed its password'
    verify_password(password)
    print('PASS: CLI reset verified inside the guest', flush=True)

    # Test both themes through HTTP, including delegation and real form POSTs.
    for theme in ('authentic-theme', 'gray-theme'):
        user, opener = account(theme)
        token = api(opener, 'options')['result']['token']
        fields = dict(id=identity, username='passwordfixture', password=new_password(), token=token)
        # Reject missing tokens, power-only grants and foreign VM IDs.
        assert 'expired' in api(opener, 'reset_password', **dict(fields, token=''))['error']
        grants(user, admin=0, vms=identity, power=1)
        assert 'permissions' in api(opener, 'reset_password', **fields)['error']
        grants(user, admin=0, vms=identity, password=1)
        assert 'permissions' in api(opener, 'reset_password', **dict(fields, id=str(uuid.uuid4())))['error']
        # Password-only delegates can reset accounts without power controls.
        options_result = api(opener, 'options')['result']
        assert options_result['permissions']['password'] and not options_result['permissions']['power']
        fields['token'] = options_result['token']
        result = api(opener, 'reset_password', **fields)
        assert result.get('result', {}).get('action') == 'reset_password', 'JSON API reset failed'
        verify_password(fields['password'])
        # Webmin's normal form has blank password input and works in both themes.
        page = request(opener, '/server-manager/edit_machine.cgi?id=' + identity + '&password_reset=1')
        form = Fields(page).values
        assert form.get('action') == 'reset_password' and form.get('password') == ''
        form.update(username='passwordfixture', password=new_password())
        page = request(opener, '/server-manager/edit_machine.cgi', form)
        assert 'The guest password has been reset.' in page, 'Form did not complete'
        verify_password(form['password'])
        # A real native failure must remain safe even for a nonexistent account.
        result = api(opener, 'reset_password', **dict(fields, username='cloudmin_missing_account'))
        assert 'Could not reset the password' in result.get('error', ''), 'Missing-account error is unclear'
        assert not any(p in page or p in json.dumps(result) for p in passwords), 'Response disclosed a password'
        print('PASS:', theme, 'JSON/form resets, real guest hashes, token and delegated ACL checks', flush=True)

    # Read-only mode overrides the password grant and a writer's token.
    reader, readonly = account('authentic-theme', True)
    grants(reader, admin=0, vms=identity, password=1)
    assert 'token' not in api(readonly, 'options')['result']
    for supplied_token in ('', fields['token']):
        assert 'read-only' in api(readonly, 'reset_password', **dict(fields, token=supplied_token))['error']
        page = request(readonly, '/server-manager/edit_machine.cgi', dict(fields, action='reset_password', token=supplied_token))
        assert 'read-only' in page, 'Read-only form submission was not refused'
    assert 'data-vm-password-reset' not in request(readonly, '/server-manager/machine.cgi?id=' + identity)

    # Power and agent changes after loading the form must still be refused.
    guest.suspend()
    assert 'must be running' in api(opener, 'reset_password', **fields)['error']
    guest.resume()
    guest_command('systemctl stop qemu-guest-agent')
    assert 'agent is not responding' in api(opener, 'reset_password', **fields)['error']
    # The editor always offers reset; only submission checks guest readiness.
    grants(user, admin=1)
    for stopped in (False, True):
        # Cover both an active guest with no agent and a powered-off guest.
        if stopped:
            guest.destroy()
        expected = 'must be running' if stopped else 'agent is not responding'
        assert expected in api(opener, 'reset_password', **fields)['error']
        editor = request(opener, '/server-manager/edit_machine.cgi?id=' + identity)
        assert 'vm-password-reset-review-form' in editor, 'Editor hid password reset'
        # Open the form in either state; readiness errors belong on POST.
        page = request(opener, '/server-manager/edit_machine.cgi?id=' + identity + '&password_reset=1')
        assert 'vm-password-reset-form' in page, 'Unavailable guest cannot open reset form'
        form = Fields(page).values
        form.update(username='passwordfixture', password=new_password())
        page = request(opener, '/server-manager/edit_machine.cgi', form)
        assert expected in page, 'Password reset did not report the guest readiness error'
        assert form['password'] not in page, 'Failed reset exposed the password'
    print('PASS: reset stays available; submitting reports a stopped guest or unavailable agent', flush=True)


    # Synchronous resets must not create jobs or leave secrets in Webmin's audit.
    with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
        after_jobs = {row[0] for row in db.execute('SELECT id FROM jobs')}
    assert after_jobs == before_jobs, 'Password reset created a job'
    log = Path('/var/webmin/webmin.log')
    audit = log.read_text(errors='replace')
    assert '"reset_password" "vm" "' + identity + '"' in audit, 'Success was not audited'
    paths = [log, database, *Path('/var/webmin/diffs').rglob('*')]
    for path in paths:
        # Check this run's files for plaintext and escaped Unicode secrets.
        if path.is_file() and path.stat().st_mtime >= started - 1:
            content = path.read_bytes()
            assert not any(p.encode() in content or json.dumps(p)[1:-1].encode() in content for p in passwords), \
                'Password found in a job or audit file'
    print('PASS: read-only, stopped/paused/unresponsive guest refusals; no jobs or logged passwords', flush=True)
finally:
    # Remove only this run's accounts, guest and storage. Keep disks if guest removal fails.
    for user in users:
        subprocess.run(['perl', str(helper), 'delete', 'authentic-theme', user], check=True)
    # Setup may have failed before defining a guest; verify any existing one.
    if guest:
        assert guest.name() == name, 'Fixture identity changed; refusing cleanup'
        # Power off before undefining so no process retains the fixture disks.
        if guest.isActive():
            guest.destroy()
        guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    # Remove the private pool only after guest teardown succeeds.
    if pool:
        # Inactive pools need undefining only, not a second destroy request.
        if pool.isActive():
            pool.destroy()
        pool.undefine()
    shutil.rmtree(directory)
    connection.close()
