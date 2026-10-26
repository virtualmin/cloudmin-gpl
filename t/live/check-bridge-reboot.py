#!/usr/bin/python3
"""Test a guest on an existing physical bridge before and after a host reboot.

Run prepare WORKDIR BRIDGE, reboot the authorized Linux test host, then run
verify WORKDIR and cleanup WORKDIR. The bridge itself is managed separately.
"""
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

# Keep system-changing tests on the explicitly selected Linux test host.
if sys.platform != 'linux' or os.getuid() != 0:
    raise SystemExit('Authorized Linux test host as root only')
here = Path(__file__).resolve().parent
module = here.parent.parent
action, directory, *args = sys.argv[1:]
work = Path(directory).resolve()
assert str(work).startswith(('/tmp/cloudmin-', '/var/tmp/cloudmin-'))
record = work / 'bridge-guest.json'


# run(*argv, [**kwargs]) captures commands without printing key contents.
# Keyword arguments go to subprocess.run; timeout defaults to 120 seconds.
def run(*argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, capture_output=True,
                          timeout=kwargs.pop('timeout', 120), **kwargs).stdout


# api(action, [fields]) calls the production controller as the local root user.
def api(action, fields=None):
    return json.loads(run('perl', str(module / 'api.pl'), action,
                         input=json.dumps(fields or {})))['result']


# save() records ownership before waiting or changing the fixture again.
def save():
    record.write_text(json.dumps(state))
    record.chmod(0o600)


# inspect() reads sanitized VM state using the creation job's ownership record.
def inspect():
    return json.loads(run('perl', str(here / 'machine_fixture.pl'), 'inspect',
                         state['job']))


# source_hash(path) checks that provisioning and cleanup preserve the image.
def source_hash(path):
    with open(path, 'rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


# ssh(command, [wait]) tries addresses reported for the fixture guest.
# Retry guest login for up to 600 seconds unless the caller supplies wait.
def ssh(command, wait=600):
    deadline = time.monotonic() + wait
    error = 'No guest agent address'
    while time.monotonic() < deadline:
        info = inspect()
        # Use only addresses reported for this VM, never guessed LAN addresses.
        addresses = [a['address'] for a in info['vm']['addresses']
                     if ipaddress.ip_address(a['address']).version == 4]
        for address in addresses:
            try:
                output = run('ssh', '-F', '/dev/null', '-i', str(work / 'identity'),
                    '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                    '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=no',
                    '-o', 'UserKnownHostsFile=' + str(work / 'known_hosts'),
                    'vmfixture@' + address, command, timeout=90)
                state['address'] = address
                save()
                return output
            # First boot and reboot can leave SSH unavailable briefly.
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
                error = str(exc)
        time.sleep(3)
    raise AssertionError(error)


# check_guest() verifies the bridge, completed cloud-init, SSH and outbound HTTPS.
def check_guest():
    info = inspect()
    vm = info['vm']
    assert vm['active'] and vm['autostart'], vm
    xml = ET.fromstring(run('virsh', 'dumpxml', vm['uuid']))
    interfaces = xml.findall('devices/interface')
    assert len(interfaces) == 1 and interfaces[0].get('type') == 'bridge'
    assert interfaces[0].find('source').get('bridge') == state['bridge']
    output = ssh('sudo -n cloud-init status --wait; id -un')
    assert 'status: done' in output and 'vmfixture' in output, output
    assert 'HTTPS_OK' in ssh('curl -fsS -o /dev/null --max-time 30 https://ubuntu.com/ && echo HTTPS_OK')
    state['uuid'] = vm['uuid']
    state['nvram'] = xml.findtext('os/nvram')
    state['volumes'] = [v['path'] for v in info['resources'].values()
                        if isinstance(v, dict) and 'path' in v]
    save()
    print('Bridged guest: cloud-init, DHCP, SSH and HTTPS passed; address=' +
          state['address'], flush=True)


# Preparation creates one autostart guest on the already confirmed test bridge.
if action == 'prepare':
    assert len(args) == 1 and args[0] == 'cmtestbr', 'Use the dedicated test bridge'
    work.mkdir(mode=0o700, exist_ok=True)
    work.chmod(0o700)
    assert not record.exists(), 'Resume or clean up the existing fixture first'
    options = api('options')
    image = next(i for i in options['images'] if i['guest_agent'])
    pool = next(p for p in options['pools'] if p['name'] == 'default')
    network = next(n for n in options['networks'] if n['key'] == 'bridge:' + args[0])
    state = dict(boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                 bridge=args[0], image=image['id'], source=image['volume_path'],
                 source_hash=source_hash(image['volume_path']))
    save()
    run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(work / 'identity'))
    job = api('create', dict(
        name='cloudmin-create-check-platform-bridge-' + secrets.token_hex(3),
        image=image['id'], pool=pool['id'], network=network['key'], cpus=2,
        memory_mib=1024, disk_gib=max(12, math.ceil(max(
            int(image.get('virtual_size') or 0),
            int(image.get('min_disk_bytes') or 0)) / 1024**3)), username='vmfixture',
        ssh_keys=(work / 'identity.pub').read_text(), start=1, autostart=1,
        address_mode='dhcp', token=options['token']))
    state['job'] = job['id']
    save()
    deadline = time.monotonic() + 360
    while job['state'] not in ('complete', 'failed', 'cancelled') and time.monotonic() < deadline:
        time.sleep(2)
        job = api('status', {'job': state['job']})
    assert job['state'] == 'complete', job.get('error', job['state'])
    info = inspect()
    assert info['source'] == state['source']
    assert source_hash(state['source']) == state['source_hash'], 'Source image changed'
    check_guest()
    print('Ready for the authorized host reboot', flush=True)
# Verification and cleanup resume the same ownership journal after reboot.
else:
    state = json.loads(record.read_text())
    # Require a changed host boot ID before testing guest autostart.
    if action == 'verify':
        assert state['boot'] != Path('/proc/sys/kernel/random/boot_id').read_text().strip(), 'Host did not reboot'
        check_guest()
        assert source_hash(state['source']) == state['source_hash'], 'Source image changed'
        print('Guest autostart and physical bridge survived the host reboot', flush=True)
    # Delete only resources belonging to this fixture's creation job.
    elif action == 'cleanup':
        # A failed preparation may not have submitted a creation job.
        if state.get('job'):
            run('perl', str(here / 'machine_fixture.pl'), 'cleanup', state['job'])
        # Check firmware cleanup only when the fixture recorded an NVRAM path.
        if state.get('nvram'):
            assert not Path(state['nvram']).exists(), 'Fixture NVRAM remains'
        for path in state.get('volumes', []):
            assert not Path(path).exists(), path
        # Compare the source again when preparation recorded its original hash.
        if state.get('source_hash'):
            assert source_hash(state['source']) == state['source_hash'], 'Source image changed'
        for name in ('identity', 'identity.pub', 'known_hosts', 'bridge-guest.json'):
            (work / name).unlink(missing_ok=True)
        print('Fixture guest, disks, NVRAM and keys removed; source image unchanged')
    # Refuse misspelled actions instead of implicitly cleaning up.
    else:
        raise SystemExit('Choose prepare, verify or cleanup')
