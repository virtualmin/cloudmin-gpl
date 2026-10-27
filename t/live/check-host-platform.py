#!/usr/bin/python3
"""Provision on NAT and a private bridge, then verify guest autostart after reboot.

Run prepare WORKDIR IMAGE_ID, reboot the disposable host, run verify WORKDIR,
then cleanup WORKDIR. WORKDIR is a private fixture directory on the Linux host.
"""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

# This fixture creates guests and a bridge on the disposable Linux host.
if sys.platform != 'linux' or os.getuid() != 0:
    raise SystemExit('Disposable Linux host as root only')
here = Path(__file__).resolve().parent
module = here.parent.parent
action, directory, *args = sys.argv[1:]
work = Path(directory).resolve()
assert str(work).startswith(('/tmp/cloudmin-', '/var/tmp/cloudmin-'))
record = work / 'platform.json'


# run(argv..., [**kwargs]) captures output and raises on failure.
# Keyword arguments go to subprocess.run; timeout defaults to 120 seconds.
def run(*argv, **kwargs):
    """Run bounded VM-local fixture commands; never print private keys."""
    return subprocess.run(argv, check=True, text=True, capture_output=True,
                          timeout=kwargs.pop('timeout', 120), **kwargs).stdout


# api(action, [fields]) returns the controller result for an optional JSON body.
def api(action, fields=None):
    """Use the same versioned controller as the web UI."""
    return json.loads(run('perl', str(module/'api.pl'), action,
                          input=json.dumps(fields or {})))['result']


# inspect(job) reads the resources owned by this fixture's creation job ID.
def inspect(job):
    """Get only sanitized fixture state from the independent libvirt adapter."""
    return json.loads(run('perl', str(here/'machine_fixture.pl'), 'inspect', job))


# save() records this run's ownership and reboot state for later cleanup.
def save():
    """Persist ownership before the next mutation so cleanup can resume."""
    record.write_text(json.dumps(state))
    record.chmod(0o600)


# ssh(guest, command, [wait]) allows up to 600 seconds for guest login.
def ssh(guest, command, wait=600):
    """Wait for first boot or reboot using the fixture key stored on this VM."""
    deadline = time.monotonic() + wait
    error = 'No guest address'
    while time.monotonic() < deadline:
        address = guest.get('address')
        # NAT guests get their address from libvirt after boot.
        if not address:
            addresses = inspect(guest['job'])['vm']['addresses']
            address = next((a['address'] for a in addresses
                            if a['address'].startswith('192.168.122.')), None)
        # Attempt SSH only after the static or discovered address is known.
        if address:
            try:
                output = run('ssh', '-F', '/dev/null', '-i', str(work/'identity'),
                    '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                    '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=no',
                    '-o', 'UserKnownHostsFile='+str(work/'known_hosts'),
                    'vmfixture@'+address, command, timeout=90)
                guest['address'] = address
                save()
                return output
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
                error = str(exc)
        time.sleep(3)
    raise AssertionError(error)


# create(kind, image) provisions the imported image ID on NAT or cmtestbr0.
def create(kind, image):
    """Create a native EFI guest through the actual Cloudmin provisioning worker."""
    options = api('options')
    pool = next(p for p in options['pools'] if p['name'] == 'default')
    net = next(n for n in options['networks'] if n['key'] == 'bridge:cmtestbr0') if kind == 'bridge' else next(n for n in options['networks'] if n['name'] == 'default')
    fields = dict(name='cloudmin-create-check-platform-'+kind+'-'+secrets.token_hex(3),
        image=image, pool=pool['id'], network=net['key'], cpus=2, memory_mib=1024,
        disk_gib=12, username='vmfixture', ssh_keys=(work/'identity.pub').read_text(),
        start=1, autostart=int(kind == 'nat'), address_mode='dhcp', token=options['token'])
    # The private bridge has no DHCP server; give its guest a fixture address.
    if kind == 'bridge':
        fields.update(address_mode='static', ipv4='192.0.2.2/24')
    job = api('create', fields)
    guest = dict(job=job['id'], kind=kind)
    # Save the static address before waiting for SSH or resuming cleanup.
    if kind == 'bridge': guest['address'] = '192.0.2.2'
    state['guests'].append(guest)
    save()
    deadline = time.monotonic()+360
    while job['state'] not in ('complete', 'failed', 'cancelled') and time.monotonic() < deadline:
        time.sleep(2)
        job = api('status', {'job':guest['job']})
    assert job['state'] == 'complete', job
    # Record actual allocated paths and confirm native, versioned EFI hardware.
    info = inspect(guest['job'])
    guest['uuid'] = info['vm']['uuid']
    xml = ET.fromstring(run('virsh','dumpxml',guest['uuid']))
    guest['nvram'] = xml.findtext('os/nvram')
    guest['volumes'] = [v['path'] for v in info['resources'].values() if isinstance(v,dict) and 'path' in v]
    assert xml.findtext('os/loader') and xml.find('os/type').get('machine') not in ('virt','q35')
    assert xml.find('devices/interface').get('type') == ('bridge' if kind == 'bridge' else 'network')
    save()
    output = ssh(guest, 'sudo -n cloud-init status --wait; id -un')
    assert 'status: done' in output and 'vmfixture' in output, output
    # NAT must support outbound traffic as well as host-to-guest SSH.
    if kind == 'nat':
        assert '200' in ssh(guest, 'python3 -c "import urllib.request; print(urllib.request.urlopen(\'http://deb.debian.org/debian/\', timeout=15).status)"')
    print(kind.upper()+' creation, cloud-init and SSH passed', flush=True)
    return guest


# remove(guest) deletes owned resources and updates the persistent fixture
# state.
def remove(guest):
    """Use Cloudmin cleanup, then independently check disks and NVRAM are gone."""
    run('perl',str(here/'machine_fixture.pl'),'cleanup',guest['job'])
    # An EFI guest's variable store is separate from its libvirt disk volumes.
    if guest.get('nvram'): assert not Path(guest['nvram']).exists()
    for path in guest.get('volumes',[]): assert not Path(path).exists(), path
    state['guests'].remove(guest)
    save()


# Start a fresh fixture, leaving only its NAT guest for the reboot check.
if action == 'prepare':
    work.mkdir(mode=0o700, exist_ok=True)
    assert not record.exists(), 'Fixture already exists; verify or clean it first'
    state = {'boot':Path('/proc/sys/kernel/random/boot_id').read_text(), 'guests':[], 'bridge':False}
    save()
    run('ssh-keygen','-q','-t','ed25519','-N','','-f',str(work/'identity'))
    # Never bridge the host's management interface or change its routes.
    run('ip','link','add','cmtestbr0','type','bridge')
    state['bridge'] = True
    save()
    run('ip','addr','add','192.0.2.1/24','dev','cmtestbr0')
    run('ip','link','set','cmtestbr0','up')
    bridge = create('bridge', args[0])
    remove(bridge)
    run('ip','link','del','cmtestbr0')
    state['bridge'] = False
    save()
    create('nat', args[0])
    print('Reboot the host, then run verify with the same directory', flush=True)
# Verification and cleanup must resume the previously recorded fixture.
else:
    state = json.loads(record.read_text())
    # Require a changed host boot ID so a same-boot run cannot pass autostart.
    if action == 'verify':
        assert state['boot'] != Path('/proc/sys/kernel/random/boot_id').read_text(), 'Host has not rebooted'
        for guest in state['guests']:
            info = inspect(guest['job'])['vm']
            assert info['active'] and info['autostart'], info
            assert 'vmfixture' in ssh(guest,'id -un')
            assert '200' in ssh(guest, 'python3 -c "import urllib.request; print(urllib.request.urlopen(\'http://deb.debian.org/debian/\', timeout=15).status)"')
        print('Guest autostart, SSH and NAT work after host reboot', flush=True)
    # Remove only resources listed in this fixture's ownership record.
    elif action == 'cleanup':
        for guest in list(state['guests']): remove(guest)
        # Preparation may have failed before removing its private bridge.
        if state['bridge']:
            run('ip','link','del','cmtestbr0')
        for name in ('identity','identity.pub','known_hosts','platform.json'):
            (work/name).unlink(missing_ok=True)
        print('Fixture guests, disks, NVRAM, seed files and keys removed', flush=True)
    # Reject unknown commands instead of treating them as cleanup requests.
    else:
        raise SystemExit('Choose prepare, verify or cleanup')
