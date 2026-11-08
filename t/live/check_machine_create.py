#!/usr/bin/python3
"""Create, boot and remove one guest on a disposable Cloudmin host."""

import argparse
import hashlib
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shlex
import ssl
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

# VM creation and account setup belong on the disposable Linux VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')

# Select an imported image and optional guest setup for this creation fixture.
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--virtualmin',
    action='store_true',
    help='Install Virtualmin GPL in the test virtual machine',
)
parser.add_argument(
    '--virtualmin-bundle', choices=('LAMP', 'LEMP'), default='LAMP'
)
parser.add_argument(
    '--virtualmin-type', choices=('full', 'mini'), default='mini'
)
parser.add_argument('--virtualmin-postgres', action='store_true')
parser.add_argument(
    '--keep-on-failure',
    action='store_true',
    help='Keep the test virtual machine for diagnosis after failure',
)
parser.add_argument(
    '--software-test',
    choices=('packages', 'scripts', 'files', 'failure'),
    help='Exercise Pro guest scripts and optional package installation (requires Cloudmin Pro)',
)
parser.add_argument(
    '--memory-mib', type=int, default=1024, help='Fixture guest memory'
)
parser.add_argument(
    '--disk-gib', type=int, default=12, help='Fixture system disk capacity'
)
parser.add_argument('--image-id', help='Imported image job ID to test')
parser.add_argument('--pool-id', help='Storage destination UUID to test')
parser.add_argument(
    '--lvm-operations',
    action='store_true',
    help='Exercise native snapshots and clones after boot',
)
parser.add_argument(
    '--ssh-timeout',
    type=int,
    default=600,
    help='Seconds to wait for guest SSH (default: 600)',
)
for flag in (
    'alma',
    'password',
    'both',
    'root',
    'static',
    'form',
    'guest-agent',
    'terminal',
    'terminal-browser',
    'host-key',
    'lifecycle',
):
    parser.add_argument('--' + flag, action='store_true')
args = parser.parse_args()
# Every software-test variant uses scripts, including the package-order check.
if (
    args.software_test
    and not (
        Path(__file__).resolve().parents[2] / 'pro/SetupScripts.pm'
    ).is_file()
):
    parser.error('--software-test requires the Cloudmin Pro script extension')
# Bound the SSH wait with a positive timeout supplied by the caller.
if args.ssh_timeout <= 0:
    parser.error('--ssh-timeout must be positive')

here = Path(__file__).resolve().parent
base = 'https://127.0.0.1:10000'
cookies = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(cookies),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)


class Inputs(HTMLParser):
    """Read submitted values from real Webmin form markup."""

    # __init__(self, page)
    # Parse form controls and short page messages.
    def __init__(self, page):
        super().__init__()
        self.fields = {}
        self.messages = []
        self.feed(page)

    # handle_starttag(self, tag, attrs)
    # Capture named controls used when submitting the creation form.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Capture form actions, tokens and other named controls.
        if tag in ('input', 'button') and attrs.get('name'):
            self.fields[attrs['name']] = attrs.get('value', '')

    # handle_data(self, data)
    # Collect short page messages for validation assertions.
    def handle_data(self, data):
        # Bound diagnostic snippets; this is not an HTML content sanitizer.
        if data.strip() and len(data) < 300:
            self.messages.append(data.strip())


# request(path, [fields], [as_json])
def request(path, fields=None, as_json=False):
    """
    Send same-origin requests and retain HTTP errors for explicit assertions.
    """
    data = None
    headers = {'Referer': base + '/server-manager/machine_form.cgi'}
    # Encode POST fields using the requested public API or form format.
    if fields is not None:
        data = (
            json.dumps(fields) if as_json else urllib.parse.urlencode(fields)
        ).encode()
        headers['Content-Type'] = (
            'application/json'
            if as_json
            else 'application/x-www-form-urlencoded'
        )
    try:
        response = opener.open(
            urllib.request.Request(base + path, data=data, headers=headers),
            timeout=60,
        )
    except urllib.error.HTTPError as error:
        response = error
    with response:
        page = response.read().decode()
        assert 'Error - Perl execution failed' not in page, path + ' crashed'
        return response.status, page


# api(action, [fields])
def api(action, fields=None):
    """Submit jobs and read their state through the public HTTP API."""
    # Read-only API calls can use a GET without a request body.
    if fields is None:
        status, page = request('/server-manager/api.cgi?action=' + action)
    # Submissions send JSON fields through the same public endpoint.
    else:
        status, page = request(
            '/server-manager/api.cgi', {'action': action, **fields}, True
        )
    result = json.loads(page)
    assert status == 200 and 'result' in result, result.get(
        'error', 'API failed'
    )
    return result['result']


# inspect(job)
def inspect(job):
    """
    Read fixture-owned libvirt state without returning private provisioning
    data.
    """
    return json.loads(
        subprocess.check_output(
            ['perl', str(here / 'machine_fixture.pl'), 'inspect', job]
        )
    )


# digest(path)
def digest(path):
    """
    Check the complete reusable source image, not only its size or timestamp.
    """
    with open(path, 'rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


# guest_ssh(arguments, command, [password], [timeout])
def guest_ssh(arguments, command, password=None, timeout=30):
    """
    Keep fixture passwords in a pipe, outside command arguments and diagnostics.
    """
    # Key-based SSH needs no password pipe.
    if password is None:
        return subprocess.run(
            arguments + [command],
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, (password + '\n').encode())
        os.close(write_fd)
        write_fd = None
        return subprocess.run(
            ['sshpass', '-d', str(read_fd)] + arguments + [command],
            pass_fds=(read_fd,),
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    finally:
        os.close(read_fd)
        # Close the write end here only if setup did not already close it.
        if write_fd is not None:
            os.close(write_fd)


created = False
job_id = None
guest_password = None
root_session = None
try:
    password = secrets.token_urlsafe(36)
    subprocess.run(
        ['perl', str(here / 'webmin-user.pl'), 'create'],
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
            'page': '/server-manager/machine_form.cgi',
        },
    )
    if args.virtualmin:
        # Registration is root-only. Use a private temporary session without
        # changing the administrator's password or granting the fixture root.
        root_session = json.loads(
            subprocess.check_output(
                ['perl', str(here / 'webmin-user.pl'), 'root-session'],
                text=True,
            )
        )['sid']
        cookies.set_cookie(
            http.cookiejar.Cookie(
                0,
                'sid',
                root_session,
                None,
                False,
                '127.0.0.1',
                False,
                False,
                '/',
                True,
                True,
                None,
                True,
                None,
                None,
                {},
            )
        )
    status, form = request('/server-manager/machine_form.cgi')
    assert (
        status == 200
        and 'Create Virtual Machine' in form
        and 'SSH public keys' in form
    )
    assert (
        Inputs(form).fields['vm_operation'] == 'create'
        and 'Review VM settings' not in form
    )
    assert (
        'name="host_ssh_key"' not in form
        and 'name="machine_host_ssh_key"' not in form
    )
    print('Creation form rendered without host-key controls', flush=True)
    options = api('options')
    distro = 'AlmaLinux' if '--alma' in sys.argv else 'Ubuntu'
    # An explicit image ID makes the fixture independent of catalogue order.
    if args.image_id:
        image = next(
            image for image in options['images'] if image['id'] == args.image_id
        )
    # Otherwise choose an available image from the requested distribution.
    else:
        image = next(
            image
            for image in options['images']
            if image['name'].startswith(distro)
        )
    print('Testing image: ' + image['name'], flush=True)
    # LVM fixtures choose their private pool; ordinary checks keep
    # using default.
    pool = (
        next(pool for pool in options['pools'] if pool['id'] == args.pool_id)
        if args.pool_id
        else next(
            pool for pool in options['pools'] if pool['name'] == 'default'
        )
    )
    network = next(
        network
        for network in options['networks']
        if network['name'] == 'default'
    )
    source_before = digest(image['volume_path'])
    with tempfile.TemporaryDirectory(prefix='cloudmin-create-key-') as work:
        key = Path(work) / 'identity'
        subprocess.run(
            ['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)],
            check=True,
        )
        fields = {
            'name': 'cloudmin-create-check-' + secrets.token_hex(4),
            'image': image['id'],
            'pool': pool['id'],
            'network': network['key'],
            'cpus': 1,
            'memory_mib': args.memory_mib,
            'disk_gib': args.disk_gib,
            'username': 'vmfixture',
            'ssh_keys': key.with_suffix('.pub').read_text(),
            'start': 1,
            'autostart': 0,
            'address_mode': 'dhcp',
            'token': options['token'],
        }
        if args.virtualmin:
            # Mark root-owned installation fixtures for the cleanup helper.
            fields['name'] = (
                'cloudmin-create-check-virtualmin-' + secrets.token_hex(4)
            )
            # Give the bundled GPL template enough memory and disk space.
            fields.update(
                template='0' * 31 + '2',
                memory_mib=1024 if args.virtualmin_type == 'mini' else 2048,
                disk_gib=20,
                hostname=fields['name'] + '.example.test',
                virtualmin_type=args.virtualmin_type,
                virtualmin_ssl='0',
                virtualmin_postgres='1' if args.virtualmin_postgres else '0',
                virtualmin_bundle=args.virtualmin_bundle,
            )
        if args.software_test:
            # Scripts record their order without requiring Virtualmin.
            fields.update(
                software='none',
                packages='jq' if args.software_test == 'packages' else '',
                before_script='test "$(id -u)" = 0\ntest "$CLOUDMIN_GUEST_USER" = vmfixture\n'
                              'echo before >> /var/lib/cloudmin-install/order\n'
                + ('false\n' if args.software_test == 'failure' else ''),
                after_script='test "$(cat /var/lib/cloudmin-install/order)" = before\n'
                + ('jq --version\n' if args.software_test == 'packages' else '')
                + 'echo after >> /var/lib/cloudmin-install/order\n',
            )
            if args.software_test == 'files':
                # The chooser and API share restricted access to this
                # fixture directory.
                Path(work).chmod(0o755)
                subprocess.run(
                    ['perl', str(here / 'webmin-user.pl'), 'files'],
                    input=work + '\n',
                    text=True,
                    check=True,
                )
                for script in ('before_script', 'after_script'):
                    path = Path(work) / (script + '.sh')
                    path.write_text(fields.pop(script))
                    path.chmod(0o644)
                    fields[script + '_mode'] = 'file'
                    fields[script + '_path'] = str(path)
                # A manually entered path must obey the same ACL as the chooser.
                _, denied = request(
                    '/server-manager/api.cgi',
                    {
                        **fields,
                        'action': 'review',
                        'before_script_path': '/etc/hostname',
                    },
                    True,
                )
                assert 'allowed host directories' in json.loads(denied).get(
                    'error', ''
                ), denied
                before_path = Path(fields['before_script_path'])
                before_path.chmod(0o600)
                _, denied = request(
                    '/server-manager/api.cgi',
                    {**fields, 'action': 'review'},
                    True,
                )
                assert 'Cannot open the guest script file' in json.loads(
                    denied
                ).get('error', ''), denied
                before_path.chmod(0o644)
                reviewed = api('review', fields)
                assert (
                    'echo before' in reviewed['before_script']
                    and reviewed['before_script_path'] == ''
                )
                print(
                    'Script paths honor Webmin directory and Unix permissions',
                    flush=True,
                )
        fields['mac'] = '52:54:00:' + ':'.join(
            secrets.token_hex(1) for _ in range(3)
        )
        if '--password' in sys.argv or '--both' in sys.argv:
            # Include form-sensitive characters to catch password
            # encoding changes.
            guest_password = 'p+' + secrets.token_hex(2) + '&='
            fields.update(
                auth_type='both' if '--both' in sys.argv else 'password',
                password=guest_password,
            )
            # Password-only creation must not rely on the generated SSH key.
            if fields['auth_type'] == 'password':
                fields.pop('ssh_keys')
        # Exercise direct root login only when requested.
        if '--root' in sys.argv:
            fields['username'] = 'root'
        if '--static' in sys.argv:
            # Refuse a fixture address already leased on this disposable
            # NAT network.
            assert network['address'] == '192.168.122.1', (
                'Fixture requires the default test subnet'
            )
            leases = subprocess.check_output(
                ['virsh', 'net-dhcp-leases', 'default'], text=True
            )
            assert '192.168.122.250' not in leases, (
                'Static fixture address is already leased'
            )
            fields.update(
                address_mode='static',
                ipv4='192.168.122.250/32',
                gateway4=network['address'],
                dns=network['address'],
            )
        # Check password validation and redaction before submitting a real VM.
        if guest_password:
            _, invalid = request(
                '/server-manager/setup_machine.cgi',
                {**fields, 'vm_operation': 'create', 'name': ''},
            )
            assert (
                'Enter a virtual machine name' in invalid
                and 'Cannot create virtual machine' in invalid
            )
            assert (
                'token' not in Inputs(invalid).fields
                and guest_password not in invalid
            )
            # The optional API check can still reuse an identity-bound hash.
            retained = {
                key: value for key, value in fields.items() if key != 'password'
            }
            reviewed = api('review', retained)
            assert reviewed['password_set'] and 'password_hash' not in reviewed
            for changed in (
                {'username': 'different'},
                {'token': api('options')['token']},
            ):
                _, rejected = request(
                    '/server-manager/api.cgi',
                    {'action': 'review', **retained, **changed},
                    True,
                )
                assert 'Enter an initial password' in json.loads(rejected).get(
                    'error', ''
                )
            print(
                'Validation retains only a private, identity-bound hash',
                flush=True,
            )
        # Use a fresh form token so creation cannot depend on a preceding
        # validation call.
        _, fresh_form = request('/server-manager/machine_form.cgi')
        fields['token'] = Inputs(fresh_form).fields['token']
        status, invalid = request(
            '/server-manager/api.cgi',
            {'action': 'create', **fields, 'token': 'invalid'},
            True,
        )
        assert status == 200 and 'error' in json.loads(invalid), (
            'Missing CSRF validation'
        )
        # Exercise the browser form when requested, including its signed token.
        if '--form' in sys.argv:
            status, page = request(
                '/server-manager/setup_machine.cgi',
                {
                    **fields,
                    'vm_operation': Inputs(fresh_form).fields['vm_operation'],
                },
            )
            assert status == 200 and 'Return to view virtual machine' in page, (
                'Creation form did not complete'
            )
            job = next(
                job for job in api('list') if job['name'] == fields['name']
            )
        # Otherwise create through the public JSON API.
        else:
            job = api('create', fields)
        job_id = job['id']
        (here / 'last-vm-job').write_text(job_id)
        if args.software_test == 'files':
            # Workers and duplicate submissions must use the submitted contents.
            for script in ('before_script', 'after_script'):
                Path(fields[script + '_path']).unlink()
        assert api('create', fields)['id'] == job_id, (
            'Duplicate submission created a second job'
        )
        # A reused form must reject a different VM instead of returning
        # this job.
        _, reused = request(
            '/server-manager/api.cgi',
            {'action': 'create', **fields, 'name': fields['name'] + '-other'},
            True,
        )
        assert 'Reload the page' in json.loads(reused).get('error', '')
        print('Submission is idempotent; waiting for creation', flush=True)
        deadline = time.monotonic() + (
            8200
            if args.virtualmin
            else 1800
            if args.lvm_operations
            else 1200
            if args.software_test
            else 180
        )
        previous_phase = None
        while time.monotonic() < deadline:
            status, body = request(
                '/server-manager/api.cgi?action=status&job=' + job_id
            )
            job = json.loads(body)['result']
            if (args.virtualmin or args.software_test) and job[
                'phase'
            ] != previous_phase:
                # Report phase changes without repeating each poll.
                print('Installation phase: ' + job['phase'], flush=True)
                previous_phase = job['phase']
            # Wait for a terminal job state before inspecting libvirt resources.
            if job['state'] in ('complete', 'failed', 'cancelled'):
                break
            time.sleep(1)
        if (
            (args.virtualmin or args.software_test)
            and job['state'] == 'failed'
            and job.get('vm_created')
        ):
            # Capture generic or GPL setup diagnostics before fixture teardown.
            failed = inspect(job_id)
            address = next(
                a['address']
                for a in failed['vm']['addresses']
                if ':' not in a['address']
            )
            result = guest_ssh(
                [
                    'ssh',
                    '-F',
                    '/dev/null',
                    '-i',
                    str(key),
                    '-o',
                    'BatchMode=yes',
                    '-o',
                    'ConnectTimeout=10',
                    '-o',
                    'StrictHostKeyChecking=no',
                    '-o',
                    'UserKnownHostsFile=' + work + '/known_hosts',
                    fields['username'] + '@' + address,
                ],
                'sudo tail -n 20 /var/lib/cloudmin-install/install.log',
                timeout=30,
            )
            print(
                'Guest installer diagnostics: ' + result.stdout[-4000:],
                flush=True,
            )
        if args.software_test == 'failure':
            # A failed script must leave the created guest available.
            assert job['state'] == 'failed' and job.get('vm_created'), job
            assert 'Preparation script failed' in job['error'], job['error']
        else:
            # All other fixture modes require a successful terminal job state.
            assert job['state'] == 'complete', job.get('error') or job['state']
        assert inspect(job_id)['vm'].get('qemu_uid', 0) > 0, (
            'Libvirt started QEMU as root'
        )
        print(
            'Libvirt runs the new QEMU guest under an unprivileged UID',
            flush=True,
        )
        # Check stored job data for accidental plaintext password persistence.
        if guest_password:
            with sqlite3.connect(
                '/var/webmin/modules/server-manager/vm-jobs/jobs.sqlite'
            ) as db:
                record = db.execute(
                    'SELECT record FROM jobs WHERE id = ?', (job_id,)
                ).fetchone()[0]
                assert 'password_hash' not in json.loads(record)['request']
                assert guest_password not in record
                assert (
                    db.execute(
                        'SELECT count(*) FROM credentials WHERE id = ?',
                        (job_id,),
                    ).fetchone()[0]
                    == 0
                )
        assert api('create', fields)['id'] == job_id, (
            'Completed retry was not idempotent'
        )
        assert 'console_password' not in job and 'ssh_keys' not in job, (
            'Public status leaked inputs'
        )
        status, progress = request('/server-manager/progress.cgi?job=' + job_id)
        assert (
            status == 200
            and 'Return to view virtual machine' in progress
            and '.. done' in progress
        )
        state = inspect(job_id)
        vm = state['vm']
        assert vm['active'] and vm['firmware'] == 'efi'
        assert state['mac'] == fields['mac'], (
            'Submitted MAC address changed during creation'
        )
        assert (
            state['resources']['disk']['capacity']
            == fields['disk_gib'] * 1024**3
        )
        # Provisioning media containing a password hash must remain private.
        if guest_password:
            assert (
                os.stat(state['resources']['seed']['path']).st_mode & 0o077 == 0
            ), 'Seed must be private'
        assert all(
            disk.get('source', {}).get('file') != image['volume_path']
            for disk in vm['disks']
        )
        status, details = request(
            '/server-manager/machine.cgi?id=' + vm['uuid']
        )
        assert status == 200 and 'Virtual Machine Details' in details
        assert not Path(
            '/var/webmin/modules/server-manager/vm-jobs', job_id
        ).exists(), 'Provisioning files remain'
        print(
            'Independent disk, UEFI configuration, progress and VM details passed',
            flush=True,
        )
        ssh_base = [
            'ssh',
            '-i',
            str(key),
            '-o',
            'BatchMode=yes',
            '-o',
            'ConnectTimeout=15',
            '-o',
            'StrictHostKeyChecking=no',
            '-o',
            'UserKnownHostsFile=' + work + '/known_hosts',
        ]
        key_ssh = list(ssh_base)
        # Disable key fallback so password login proves the password works.
        if guest_password:
            ssh_base = [
                'ssh',
                '-o',
                'PubkeyAuthentication=no',
                '-o',
                'PreferredAuthentications=password',
                '-o',
                'NumberOfPasswordPrompts=1',
                '-o',
                'ConnectTimeout=15',
                '-o',
                'StrictHostKeyChecking=no',
                '-o',
                'UserKnownHostsFile=' + work + '/known_hosts',
            ]
        # Nested guests can boot slowly while another guest uses the same host.
        deadline = time.monotonic() + args.ssh_timeout
        ready = None
        address = '192.168.122.250' if '--static' in sys.argv else None
        while time.monotonic() < deadline:
            # Keep querying libvirt until the guest reports an address.
            if address is None:
                addresses = inspect(job_id)['vm']['addresses']
                address = next(
                    (
                        entry['address']
                        for entry in addresses
                        if entry['address'].startswith('192.168.122.')
                    ),
                    None,
                )
            # SSH checks can start only after an address is known.
            if address:
                try:
                    ready = guest_ssh(
                        ssh_base + [fields['username'] + '@' + address],
                        'id -un',
                        guest_password,
                    )
                    # A successful SSH command means the guest is ready for
                    # further checks.
                    if ready.returncode == 0:
                        break
                except subprocess.TimeoutExpired:
                    # sshd may accept connections before first-boot PAM
                    # work finishes.
                    ready = None
            time.sleep(2)
        assert ready and ready.returncode == 0, (
            'Guest SSH did not become ready: '
            + (ready.stderr if ready else 'no address')
        )
        assert ready.stdout.strip() == fields['username']
        print(
            'Initial user SSH login passed: ' + fields['username'], flush=True
        )
        # When both methods are requested, prove key login works independently.
        if '--both' in sys.argv:
            key_result = guest_ssh(
                key_ssh + [fields['username'] + '@' + address], 'id -un'
            )
            assert (
                key_result.returncode == 0
                and key_result.stdout.strip() == fields['username']
            )
            print('Both password and SSH-key login passed', flush=True)
        prefix = '' if fields['username'] == 'root' else 'sudo -n '
        checks = (
            prefix
            + 'cloud-init status --wait && '
            + prefix
            + 'id -u && findmnt -bno SIZE / && ip -4 route show default'
        )
        # A second connection can race first-boot service reloads; retry once.
        for attempt in range(2):
            try:
                result = guest_ssh(
                    ssh_base + [fields['username'] + '@' + address],
                    checks,
                    guest_password,
                    180,
                )
                # Retry only an SSH transport failure, and only once.
                if result.returncode != 255 or attempt:
                    break
            except subprocess.TimeoutExpired:
                # A second timeout must fail rather than silently skip
                # guest checks.
                if attempt:
                    raise
            time.sleep(2)
        assert result.returncode == 0 and 'status: done' in result.stdout, (
            result.stdout + result.stderr
        )
        lines = result.stdout.splitlines()
        assert '0' in lines and any(
            line.isdigit() and int(line) > 8 * 1024**3 for line in lines
        ), result.stdout
        assert 'default via 192.168.122.1' in result.stdout, result.stdout
        # A reachable guest can still have invalid generated cloud-init data.
        result = guest_ssh(
            ssh_base + [fields['username'] + '@' + address],
            prefix + 'cloud-init schema --system',
            guest_password,
            90,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        print(
            'Generated user and network data pass cloud-init schema validation',
            flush=True,
        )
        # Plain cloud-image creation must install and start the agent itself.
        agent = json.loads(
            subprocess.check_output(
                [
                    'virsh',
                    'qemu-agent-command',
                    vm['uuid'],
                    '{"execute":"guest-get-osinfo"}',
                ],
                text=True,
            )
        )['return']
        assert agent.get('name') and agent.get('version-id'), agent
        print(
            'Guest agent reports ' + agent['name'] + ' ' + agent['version-id'],
            flush=True,
        )
        if args.software_test:
            # A second service start must not repeat scripts, even
            # after failure.
            result = guest_ssh(
                ssh_base + [fields['username'] + '@' + address],
                prefix
                + 'systemctl start cloudmin-software.service && '
                + prefix
                + 'cat /var/lib/cloudmin-install/order',
                timeout=60,
            )
            assert result.returncode == 0, result.stderr
            assert result.stdout.strip() == (
                'before' if args.software_test == 'failure' else 'before\nafter'
            ), result.stdout
            result = guest_ssh(
                ssh_base + [fields['username'] + '@' + address],
                prefix + 'cat /var/lib/cloudmin-install/status.json',
                timeout=30,
            )
            journal = json.loads(result.stdout)
            assert journal['stage'] == (
                'failed' if args.software_test == 'failure' else 'complete'
            )
            assert not job.get('software_url'), (
                'Generic setup offered a Virtualmin link'
            )
            print(
                'Guest root scripts, package ordering, durable outcome and no replay passed',
                flush=True,
            )
        if args.virtualmin:
            # Check the installed service and cleanup of temporary files.
            result = guest_ssh(
                ssh_base + [fields['username'] + '@' + address],
                prefix
                + 'test -f /etc/webmin/virtual-server/config && '
                + prefix
                + 'systemctl is-active webmin && '
                + prefix
                + 'test ! -f /var/lib/cloudmin-install/request.json && '
                + prefix
                + 'test ! -f /var/lib/cloudmin-install/installer.sh',
                guest_password,
                timeout=60,
            )
            assert result.returncode == 0, result.stderr
            assert (
                urllib.parse.unquote(job['software_url'])
                == 'remote_access.cgi?id=' + vm['uuid'] + '&tab=webmin'
            )
            assert not job.get('webmin_warning'), job.get('webmin_warning')
            # The native record must reuse the original login and
            # remain private.
            entries = []
            for path in Path('/etc/webmin/servers').glob('*.serv'):
                values = dict(
                    line.split('=', 1)
                    for line in path.read_text().splitlines()
                    if '=' in line
                )
                if values.get('cloudmin_uuid') == vm['uuid']:
                    # Check only this creation's registration, leaving
                    # others alone.
                    assert path.stat().st_mode & 0o077 == 0, (
                        'Servers Index login is not private'
                    )
                    entries.append(values)
            assert len(entries) == 1, 'Expected exactly one guest registration'
            assert entries[0]['user'] == fields['username'], (
                'Registration did not reuse the guest username'
            )
            assert entries[0]['pass'] == guest_password, (
                'Registration did not reuse the initial password'
            )
            # This assertion expects automatic embedding, not the
            # default choices.
            status, access = request('/server-manager/' + job['software_url'])
            assert (
                status == 200
                and 'Open in new tab' in access
                and '<iframe' in access
            )
            proxy = re.search(
                r'src=["\']([^"\']*/servers/link.cgi/[0-9]+/)["\']', access
            )
            assert proxy, 'Guest Webmin proxy missing'
            status, proxied = request(proxy.group(1))
            assert status == 200 and 'session_login.cgi' not in proxied, (
                'Proxy did not sign in'
            )
            assert 'Virtualmin' in proxied, (
                'Proxy did not render the guest Webmin'
            )
            print(
                'Servers Index registration, automatic login and embedded Webmin passed',
                flush=True,
            )
            from webmin_browser import check_webmin_browser

            check_webmin_browser(vm['uuid'])
            if args.virtualmin_postgres:
                # The optional database flag must reach the guest installer.
                result = guest_ssh(
                    ssh_base + [fields['username'] + '@' + address],
                    'psql --version',
                    guest_password,
                    timeout=30,
                )
                assert result.returncode == 0 and 'PostgreSQL' in result.stdout
            print(
                'Virtualmin GPL installed; private request and installer removed',
                flush=True,
            )
        # Agent-only addresses arrive through the shared live channel.
        if args.guest_agent:
            setup = (
                'ip address add 192.0.2.77/32 dev "$(ip -4 route show default | '
                     "awk 'NR == 1 {print $5}')\""
            )
            result = guest_ssh(
                ssh_base + [fields['username'] + '@' + address],
                prefix + 'sh -ec ' + shlex.quote(setup),
                guest_password,
                300,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            import websocket

            _, channel = request('/server-manager/machine_status.cgi')
            sock = websocket.create_connection(
                json.loads(channel)['socket_url'],
                cookie='; '.join(c.name + '=' + c.value for c in cookies),
                origin=base,
                sslopt={'cert_reqs': ssl.CERT_NONE},
                timeout=45,
            )
            try:
                for identity in (vm['uuid'], 'overview'):
                    sock.send(json.dumps({'id': identity, 'paused': False}))
                    deadline = time.monotonic() + 45
                    while time.monotonic() < deadline:
                        sock.settimeout(max(0.1, deadline - time.monotonic()))
                        update = json.loads(sock.recv())
                        record = update.get('changed', {}).get(vm['uuid'], {})
                        addresses = record.get('vm', {}).get('addresses', [])
                        # The synthetic address proves this subscription
                        # received agent data.
                        if any(a['address'] == '192.0.2.77' for a in addresses):
                            break
                    # Exhausting the poll loop means no agent-only address
                    # reached the page.
                    else:
                        raise AssertionError(
                            'Agent address missing from ' + identity
                        )
            finally:
                sock.close()
            print(
                'Guest-agent-only address reaches detail and overview subscriptions',
                flush=True,
            )
        # Prove the managed host key works independently of
        # user-supplied keys/passwords.
        if args.host_key:
            host_key = Path(
                '/var/webmin/modules/server-manager/vm-ssh-keys'
            ) / (vm['uuid'] + '-' + job_id)
            assert host_key.exists() and host_key.stat().st_mode & 0o077 == 0
            assert host_key.stat().st_uid == 0
            host_login = [
                'ssh',
                '-F',
                '/dev/null',
                '-i',
                str(host_key),
                '-o',
                'IdentitiesOnly=yes',
                '-o',
                'BatchMode=yes',
                '-o',
                'ConnectTimeout=15',
                '-o',
                'StrictHostKeyChecking=no',
                '-o',
                'UserKnownHostsFile=' + work + '/known_hosts',
            ]
            host_result = guest_ssh(
                host_login + [fields['username'] + '@' + address], 'id -un'
            )
            assert (
                host_result.returncode == 0
                and host_result.stdout.strip() == fields['username']
            ), 'Managed key login failed'
            assert 'PRIVATE KEY' not in json.dumps(job)
            print(
                'Root-owned private VM key and independent host-key login passed',
                flush=True,
            )
        # Exercise browser SSH against this disposable guest before removing it.
        if args.terminal:
            assert guest_password, '--terminal requires --password or --both'
            from terminal_client import check_terminal

            check_terminal(
                opener,
                base,
                inspect(job_id)['vm'],
                fields['username'],
                guest_password,
                host_key=args.host_key,
            )
        # Reuse the guest for SSH browser checks in both themes, with a separate
        # account so the parent creation test keeps its Webmin session.
        if args.terminal_browser:
            for theme in ('authentic-theme', 'gray-theme'):
                subprocess.run(
                    [
                        'python3',
                        str(here / 'check-terminal-browser.py'),
                        '--guest-id',
                        vm['uuid'],
                        '--theme',
                        theme,
                    ],
                    check=True,
                    env={
                        **os.environ,
                        'CLOUDMIN_TEST_USER': 'cloudmin-terminal-check',
                    },
                )
        if args.lifecycle:
            # The terminal check ends with a Webmin logout; sign the fixture
            # in again.
            if args.terminal:
                request('/session_login.cgi')
                request(
                    '/session_login.cgi',
                    {
                        'user': 'cloudmin-ui-check',
                        'pass': password,
                        'page': '/server-manager/index.cgi',
                    },
                )
            # Reuse this disposable guest to test real dashboard power controls.
            from lifecycle_client import check_lifecycle

            check_lifecycle(
                opener,
                base,
                vm['uuid'],
                lambda: inspect(job_id)['vm'],
                lambda: guest_ssh(
                    ssh_base + [fields['username'] + '@' + address],
                    'cat /proc/sys/kernel/random/boot_id',
                    guest_password,
                    20,
                ),
            )
        if args.lvm_operations:
            # Reuse this booted guest and its private key for storage
            # lifecycle checks.
            from lvm_operations import check_operations

            check_operations(vm['uuid'], fields, key)
        assert digest(image['volume_path']) == source_before, (
            'Reusable source image changed'
        )
        print(
            'Guest SSH, sudo, cloud-init, root disk expansion and '
            + fields['address_mode']
            + ' networking passed',
            flush=True,
        )
        print('Reusable source image SHA-256 unchanged', flush=True)
finally:
    try:
        # Retain a failed fixture only when explicitly requested for diagnosis.
        if job_id and args.keep_on_failure and sys.exc_info()[0]:
            print('Retained fixture job for diagnosis: ' + job_id, flush=True)
        elif job_id:
            # Clean only the guest and volumes belonging to this test job.
            subprocess.run(
                ['perl', str(here / 'machine_fixture.pl'), 'cleanup', job_id],
                check=True,
            )
    finally:
        # Remove the temporary root session even when keeping the test guest.
        if root_session:
            subprocess.run(
                ['perl', str(here / 'webmin-user.pl'), 'delete-root-session'],
                input=root_session + '\n',
                text=True,
                check=True,
            )
        # Remove account-related state only after fixture setup succeeded.
        if created:
            try:
                # Clear password-test drafts before removing the account.
                if guest_password:
                    subprocess.run(
                        [
                            'perl',
                            str(here / 'machine_fixture.pl'),
                            'forget-passwords',
                        ],
                        check=True,
                    )
            finally:
                subprocess.run(
                    ['perl', str(here / 'webmin-user.pl'), 'delete'], check=True
                )
