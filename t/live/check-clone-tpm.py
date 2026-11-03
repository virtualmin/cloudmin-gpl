#!/usr/bin/python3
"""Test software TPM cloning and PCR 7-bound LUKS unlock on a Linux test host."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from xml.etree import ElementTree as ET

# This fixture creates VMs and formats a private data disk on the test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt
libvirt.registerErrorHandler(lambda context, error: None, None)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=Path, help='Debian or Ubuntu cloud image with a TPM driver (TIS on ARM64)')
parser.add_argument('--network', required=True, help='Existing active test network')
parser.add_argument('--allow-host-jobs', action='store_true')
args = parser.parse_args()
# Journal cleanup leaves audit history, which the caller must explicitly accept.
if not args.allow_host_jobs:
    parser.error('Use --allow-host-jobs to allow retained job audit history')
module = Path(__file__).resolve().parents[2]
# Use the selected active network without changing its configuration.
connection = libvirt.open('qemu:///system')
network = connection.networkLookupByName(args.network)
assert network.isActive(), 'Selected network must already be active'
# A unique name, pool and directory keep test storage separate from other VMs.
ident = str(uuid.uuid4())
name = 'cloudmin-tpm-test-' + ident[:8]
directory = Path(tempfile.mkdtemp(prefix=name+'-', dir='/var/lib/libvirt/images'))
directory.chmod(0o755)
# Track only resources owned by this run for cleanup after failures.
pool = source = None
clones = []
job_ids = []
key = directory/'identity'
state_root = Path('/var/lib/libvirt/swtpm')


# run(argv, [options...]) runs a fixture command with a 180-second timeout.
# options are subprocess.run keyword arguments; returns stripped stdout.
def run(argv, **kwargs):
    result = subprocess.run(argv, text=True, capture_output=True, timeout=180, **kwargs)
    assert result.returncode == 0, result.stderr or result.stdout
    return result.stdout.strip()


# api(action, fields, [fail]) calls the production API with JSON fields.
# fail defaults to false; when true, require failure and return its stderr.
def api(action, fields, fail=False):
    result = subprocess.run(['perl', str(module/'api.pl'), action],
                            input=json.dumps(fields), text=True, capture_output=True, timeout=60)
    # Negative tests must be refused by the API, not silently accepted.
    if fail:
        assert result.returncode != 0, result.stdout
        return result.stderr
    # Both the process and the API response must report success.
    assert result.returncode == 0, result.stderr
    response = json.loads(result.stdout)
    assert not response.get('error'), response
    return response['result']


# stop(domain) requests clean shutdown, preserving persistent TPM state.
def stop(domain):
    # Cleanup and repeated checks may encounter an already stopped fixture.
    if not domain.isActive():
        return
    domain.shutdown()
    deadline = time.monotonic()+120
    while domain.isActive() and time.monotonic() < deadline:
        time.sleep(1)
    assert not domain.isActive(), 'Fixture shutdown timed out'


# command(domain, shell, [body], [check]) runs a shell command over fixture SSH.
# body supplies stdin, defaulting to none; check defaults to true and requires
# exit status zero. Returns the subprocess result, including stdout and stderr.
def command(domain, shell, body=None, check=True):
    deadline = time.monotonic()+600
    diagnostic = 'No DHCP lease for the test guest'
    while time.monotonic() < deadline:
        interfaces = domain.interfaceAddresses(libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0)
        addresses = [a['addr'] for interface in interfaces.values() for a in interface['addrs']
                     if a['type'] == libvirt.VIR_IP_ADDR_TYPE_IPV4]
        # DHCP can retain an old lease after guest identity changes.
        for address in addresses:
            result = subprocess.run(['ssh', '-F', '/dev/null', '-i', str(key),
                '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                'clonefixture@'+address, 'sudo -n sh -c '+shlex.quote(shell)],
                input=body, text=True, capture_output=True, timeout=600)
            # Retry SSH failures; guest command failures belong to the test.
            if result.returncode != 255:
                # Negative tests inspect the nonzero guest status themselves.
                if check:
                    assert result.returncode == 0, result.stderr + result.stdout
                return result
            diagnostic = result.stderr
        # Give guest boot and DHCP time to progress between attempts.
        time.sleep(2)
    raise AssertionError(diagnostic)


# unlocked(domain) checks guest-agent access and decrypted data after boot.
def unlocked(domain):
    # Wait for first-boot setup before checking the agent and disk contents.
    command(domain, 'cloud-init status --wait >/dev/null')
    domain.agentSetResponseTimeout(3, 0)
    assert domain.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0)
    # The optional data disk can finish unlocking after SSH becomes available.
    result = command(domain, "timeout 120 sh -c 'until test -b /dev/mapper/cloudmin-tpm-test; "
        "do sleep 1; done' || { journalctl -b -u 'systemd-cryptsetup@*' --no-pager -n 40; tpm2_pcrread sha256:7; exit 1; }; "
        'mkdir -p /mnt/tpm-test && mount /dev/mapper/cloudmin-tpm-test /mnt/tpm-test && '
        'cat /mnt/tpm-test/proof && umount /mnt/tpm-test')
    assert result.stdout.strip() == 'TPM clone unlock verified', result.stdout


# clone(mode, shutdown) submits and boots a prepared or unchanged clone.
# shutdown requests a clean source shutdown; returns the tested running clone.
def clone(mode, shutdown):
    choices = api('clone_options', {'id': ident})
    assert choices['tpm'] == 1 and choices['nvram'] == 1, choices
    # Submit current defaults with private fixture access and copied firmware.
    fields = {'id': ident, 'revision': choices['revision'], 'name': name+'-'+mode,
              'hostname': name+'-'+mode+'.example.test', 'attempt': uuid.uuid4().hex,
              'clone_mode': mode, 'shutdown': shutdown, 'nvram_mode': 'copy',
              'username': 'clonefixture', 'auth_type': 'keys',
              'ssh_keys': key.with_suffix('.pub').read_text().strip(),
              'host_ssh_key': 0, 'start': 0, 'autostart': 0,
              'confirm_unchanged': 1, 'confirm_license': 1,
              'pool': pool.UUIDString(), 'network': choices['network']}
    # Reject live TPM copying and fresh firmware before submitting valid work.
    if source.isActive():
        assert 'Shut down' in api('clone', {**fields, 'shutdown': 0}, fail=True)
        assert 'copied UEFI' in api('clone', {**fields, 'nvram_mode': 'fresh'}, fail=True)
    # Keep the job ID for cleanup even when the detached worker fails.
    job = api('clone', fields)
    job_ids.append(job['id'])
    deadline = time.monotonic()+900
    while job['state'] not in ('complete', 'failed', 'cancelled') and time.monotonic() < deadline:
        time.sleep(1)
        job = api('status', {'job': job['id']})
    assert job['state'] == 'complete', job
    domain = connection.lookupByName(fields['name'])
    clones.append(domain)
    # The clone must own separate state files and retain the TPM device version.
    assert not domain.isActive()
    state = state_root/domain.UUIDString()/'tpm2'/'tpm2-00.permall'
    assert state.is_file() and state.stat().st_size > 0
    assert state.stat().st_ino != (state_root/ident/'tpm2'/'tpm2-00.permall').stat().st_ino
    xml = ET.fromstring(domain.XMLDesc(2))
    assert xml.find('./os/nvram').text.strip() != ET.fromstring(source.XMLDesc(2)).find('./os/nvram').text.strip()
    assert xml.find('./devices/tpm/backend').get('version') == '2.0'
    if mode == 'unchanged':
        # Stop the source to avoid duplicate network identities on this LAN.
        assert source.isActive(), 'Shutdown copy must restart its source'
        # Wait for the restarted guest to handle a clean shutdown request.
        unlocked(source)
        stop(source)
    # Both first boot and a later boot must unlock without a recovery key.
    domain.create()
    unlocked(domain)
    stop(domain)
    domain.create()
    unlocked(domain)
    print(mode+': TPM-backed LUKS unlock passed on first boot and reboot', flush=True)
    return domain


try:
    # Create private disks and a fixture-only SSH key; the cached image is read-only.
    pool = connection.storagePoolDefineXML(f'<pool type="dir"><name>{name}</name><target><path>{directory}</path></target></pool>', 0)
    pool.create(0)
    root_disk, data_disk = directory/'root.qcow2', directory/'data.qcow2'
    run(['qemu-img', 'convert', '-O', 'qcow2', str(args.image.resolve(strict=True)), str(root_disk)])
    run(['qemu-img', 'resize', str(root_disk), '8G'])
    run(['qemu-img', 'create', '-q', '-f', 'qcow2', str(data_disk), '128M'])
    run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)])
    # The root stays inspectable; only the separate data disk will be encrypted.
    # Install TPM tools and guest access through this run's private cloud seed.
    config = {'manage_etc_hosts': True, 'package_update': True,
              'packages': ['qemu-guest-agent', 'cryptsetup', 'tpm2-tools'],
              'users': ['default', {'name': 'clonefixture', 'sudo': 'ALL=(ALL) NOPASSWD:ALL',
                                   'ssh_authorized_keys': [key.with_suffix('.pub').read_text().strip()]}],
              # Newer distributions package this systemd helper separately.
              'runcmd': [['sh', '-c', 'test -x /usr/lib/systemd/systemd-cryptsetup || '
                          'DEBIAN_FRONTEND=noninteractive apt-get -y install systemd-cryptsetup'],
                         ['systemctl', 'enable', '--now', 'qemu-guest-agent']]}
    # Give this fixture its own cloud-init identity and read-only seed disk.
    (directory/'user-data').write_text('#cloud-config\n'+json.dumps(config)+'\n')
    (directory/'meta-data').write_text(f'instance-id: {ident}\nlocal-hostname: source.example.test\n')
    seed = directory/f'cloudmin-fixture-seed-{ident.replace("-", "")}.iso'
    run(['xorriso', '-as', 'mkisofs', '-quiet', '-o', str(seed), '-V', 'cidata', '-J', '-r',
         str(directory/'user-data'), str(directory/'meta-data')])
    pool.refresh(0)
    # ARM uses the virt machine's TIS device; x86 uses q35 with CRB.
    arch = connection.getInfo()[0]
    machine, model = ('virt', 'tpm-tis') if arch == 'aarch64' else ('q35', 'tpm-crb')
    net = ET.tostring(ET.Element('source', network=network.name()), encoding='unicode')
    source = connection.defineXML(f'''<domain type="kvm"><name>{name}</name><uuid>{ident}</uuid>
      <metadata><vm xmlns="urn:cloudmin:vm:1"><job>{ident.replace("-", "")}</job></vm></metadata>
      <memory unit="MiB">1536</memory><vcpu>2</vcpu><cpu mode="host-passthrough"/>
      <os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type></os>
      <features><acpi/></features><devices>
      <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{root_disk}"/><target dev="vda" bus="virtio"/></disk>
      <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seed}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
      <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{data_disk}"/><target dev="vdc" bus="virtio"/></disk>
      <interface type="network">{net}<model type="virtio"/></interface>
      <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
      <serial type="pty"><target port="0"/></serial>
      <tpm model="{model}"><backend type="emulator" version="2.0"/></tpm>
      </devices></domain>''')
    # First boot installs guest tools and initializes firmware and TPM state.
    source.create()
    command(source, 'cloud-init status --wait >/dev/null')
    # Reboot after setup before binding the volume to boot measurements.
    stop(source)
    source.create()
    command(source, 'cloud-init status --wait >/dev/null')
    # Refuse images missing the guest TPM driver before formatting the test disk.
    device = command(source, 'test -c /dev/tpmrm0', check=False)
    assert device.returncode == 0, 'The fixture image needs a TPM driver (TIS on ARM64)'
    print('PCR 7 before enrollment: '+command(source, 'tpm2_pcrread sha256:7').stdout.strip(), flush=True)
    # Enroll the data volume against PCR 7 and discard the recovery key.
    command(source, '''set -eu
umask 077
head -c 32 /dev/urandom >/run/tpm-fixture-key
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --batch-mode --key-file /run/tpm-fixture-key /dev/vdc
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 --unlock-key-file=/run/tpm-fixture-key /dev/vdc
cryptsetup open --key-file /run/tpm-fixture-key /dev/vdc cloudmin-tpm-test
rm /run/tpm-fixture-key
mkfs.ext4 -q /dev/mapper/cloudmin-tpm-test
mkdir -p /mnt/tpm-test
mount /dev/mapper/cloudmin-tpm-test /mnt/tpm-test
echo 'TPM clone unlock verified' >/mnt/tpm-test/proof
umount /mnt/tpm-test
# Let the fresh-TPM negative control boot even when its data disk cannot unlock.
printf 'cloudmin-tpm-test UUID=%s none tpm2-device=auto,headless,nofail\n' "$(cryptsetup luksUUID /dev/vdc)" >>/etc/crypttab
# Keep DHCP independent of the old MAC for unchanged copies.
if test -f /etc/netplan/50-cloud-init.yaml; then
    sed -i '/^[[:space:]]*match:/d; /^[[:space:]]*macaddress:/d; /^[[:space:]]*set-name:/d' /etc/netplan/50-cloud-init.yaml
fi
systemctl daemon-reload
''')
    # Prove the source can unlock after reboot before testing any clones.
    stop(source)
    source.create()
    unlocked(source)
    print('Source: PCR 7-bound LUKS unlock passed after reboot', flush=True)
    # Test prepared cloning from a stopped source first.
    stop(source)
    prepared = clone('prepared', 0)
    # Stop the prepared clone to leave memory for the next test.
    stop(prepared)
    # The unchanged copy must shut down and then restart its running source.
    source.create()
    unlocked(source)
    unchanged = clone('unchanged', 1)
    stop(unchanged)
    source.create()
    unlocked(source)
    # Keep one fixture guest active during the negative control.
    stop(source)
    # A fresh TPM must fail the same unlock, proving the copied state was necessary.
    stop(prepared)
    state = state_root/prepared.UUIDString()
    saved = directory/'saved-tpm'
    state.rename(saved)
    try:
        # Let libvirt create empty state and require an actual TPM unlock error.
        prepared.create()
        command(prepared, 'test ! -b /dev/mapper/cloudmin-tpm-test')
        result = command(prepared, 'timeout 30 /usr/lib/systemd/systemd-cryptsetup attach cloudmin-tpm-test /dev/vdc - tpm2-device=auto,headless', check=False)
        assert result.returncode not in (0, 124), 'Fresh TPM did not promptly refuse the copied LUKS volume'
        assert 'TPM' in result.stderr or 'tpm' in result.stderr, result.stderr
    finally:
        # Restore the saved TPM even when the negative control fails.
        stop(prepared)
        shutil.rmtree(state)
        saved.rename(state)
    # Restoring only the TPM state must make the copied volume usable again.
    prepared.create()
    unlocked(prepared)
    print('Fresh TPM refused unlock; restoring the copied TPM restored unlock', flush=True)
    # Deleting a clone must remove its state without touching the source TPM.
    stop(prepared)
    prepared.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    clones.remove(prepared)
    assert not state.exists(), 'Clone deletion left its TPM state behind'
    # The source must still unlock after the clone's state has been deleted.
    stop(source)
    source.create()
    unlocked(source)
    print('Clone deletion removed its TPM; source still boots and unlocks', flush=True)
finally:
    # Remove only UUIDs and storage created by this fixture, even after a failure.
    cleanup_failed = False
    for domain in reversed(clones+([source] if source else [])):
        try:
            # Stop fixture processes before removing firmware and TPM state.
            if domain.isActive():
                domain.destroy()
            domain.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM | libvirt.VIR_DOMAIN_UNDEFINE_TPM)
        except libvirt.libvirtError as error:
            # Report every failed domain cleanup before deciding about storage.
            cleanup_failed = True
            print('Fixture domain cleanup:', error, file=sys.stderr)
    # Preserve disks if a fixture guest could still be using them.
    if cleanup_failed:
        raise RuntimeError('Fixture cleanup needs attention: '+str(directory))
    # Remove this run's pool and volumes without changing the supplied network.
    if pool:
        pool.refresh(0)
        for volume in pool.listAllVolumes():
            volume.delete(0)
        pool.destroy()
        pool.undefine()
    # Remove the private key and finished journals after guest storage is gone.
    shutil.rmtree(directory)
    run(['perl', str(module/'t/live/clone-fixture.pl'), 'cleanup'],
        input=json.dumps({'jobs': job_ids}))
    connection.close()
