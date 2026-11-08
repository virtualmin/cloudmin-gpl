#!/usr/bin/python3
"""Check prepared live snapshots using a disposable booted cloud-image clone."""

import argparse
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
from xml.etree import ElementTree as ET

# Snapshot and guest mutations belong on the authorized Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt
import libvirt_qemu

libvirt.registerErrorHandler(lambda context, error: None, None)

module = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=Path)
parser.add_argument(
    '--network', required=True, help='Existing network for the disposable guest'
)
parser.add_argument(
    '--allow-host-jobs',
    action='store_true',
    help='Allow integration jobs in the host journal',
)
options = parser.parse_args()
# This uses real controller jobs; their audit history remains after cleanup.
if not options.allow_host_jobs:
    parser.error(
        'This integration test requires --allow-host-jobs; its audit history remains on the host'
    )
image = options.image.resolve(strict=True)
connection = libvirt.open('qemu:///system')
network = connection.networkLookupByName(options.network)
# Do not start or alter the existing network selected for the fixture.
if not network.isActive():
    raise SystemExit('The selected fixture network must already be active')
# Escape the existing network name through XML serialization.
network_source = ET.tostring(
    ET.Element('source', network=network.name()), encoding='unicode'
)
directory = Path(
    tempfile.mkdtemp(
        prefix='cloudmin-snapshot-agent-', dir='/var/lib/libvirt/images'
    )
)
directory.chmod(0o755)
ident = str(uuid.uuid4())
name = 'cloudmin-snapshot-agent-' + ident[:8]
pool = guest = None


# api(action, fields) exercises the production controller and detached worker.
def api(action, fields):
    result = subprocess.run(
        ['perl', str(module / 'api.pl'), action],
        input=json.dumps(fields),
        text=True,
        capture_output=True,
        timeout=45,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)['result']


# wait_job(job) follows the same public progress contract as the browser.
def wait_job(job):
    deadline = time.monotonic() + 180
    while (
        job['state'] not in ('complete', 'failed', 'cancelled')
        and time.monotonic() < deadline
    ):
        time.sleep(.5)
        job = api('status', {'job': job['id']})
    assert job['state'] == 'complete', job.get('error', job['state'])
    return job


# agent_ready() waits for the fixture to boot or return from snapshot restore.
def agent_ready():
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            # A restored guest may need to reconnect its agent channel.
            if guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0):
                return
        except libvirt.libvirtError:
            # Startup and restore can temporarily make the agent unavailable.
            pass
        time.sleep(2)
    raise AssertionError('Fixture QEMU Guest Agent did not respond')


# guest_command(command) checks fixture data with a key created on the
# test host.
def guest_command(command):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        interfaces = guest.interfaceAddresses(
            libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0
        )
        addresses = [
            address['addr']
            for interface in interfaces.values()
            for address in interface['addrs']
            if address['type'] == libvirt.VIR_IP_ADDR_TYPE_IPV4
        ]
        if addresses:
            # Connect only to the fixture address reported by its libvirt lease.
            result = subprocess.run(
                [
                    'ssh',
                    '-F',
                    '/dev/null',
                    '-i',
                    str(key),
                    '-o',
                    'IdentitiesOnly=yes',
                    '-o',
                    'BatchMode=yes',
                    '-o',
                    'ConnectTimeout=5',
                    '-o',
                    'StrictHostKeyChecking=no',
                    '-o',
                    'UserKnownHostsFile=/dev/null',
                    'snapshotfixture@' + addresses[0],
                    'sudo -n sh -c ' + shlex.quote(command),
                ],
                text=True,
                capture_output=True,
                timeout=30,
            )
            # A connection failure can mean SSH is still starting after restore.
            if result.returncode != 255:
                assert result.returncode == 0, result.stderr
                return result.stdout.strip()
        time.sleep(2)
    raise AssertionError('Fixture SSH did not become ready')


# edit_with_snapshot() uses the public job API while saved disk history exists.
def edit_with_snapshot():
    settings = api('settings', {'id': ident})
    # ARM virt on the test host rejects CPU hotplug; memory and networking work.
    cpus = 3 if arch == 'x86_64' else 2
    job = wait_job(
        api(
            'update',
            {
                'id': ident,
                'revision': settings['revision'],
                'cpus': cpus,
                'memory_mib': 896,
                'description': 'Edited with snapshots',
                'changes': [
                    {
                        'action': 'update_interface',
                        'mac': settings['interfaces'][0]['mac'],
                        'inbound_kib': 2048,
                        'outbound_kib': 2048,
                    }
                ],
            },
        )
    )
    assert job['scope'] == 'live'
    # Check saved hardware as well as successful
    # completion of native live calls.
    result = api('settings', {'id': ident})
    assert result['cpus'] == cpus and result['memory_mib'] == 896
    assert result['description'] == 'Edited with snapshots'
    assert result['interfaces'][0]['inbound_kib'] == 2048
    return result


try:
    pool = connection.storagePoolDefineXML(
        f'<pool type="dir"><name>{name}</name><target><path>{directory}</path></target></pool>',
        0,
    )
    pool.create(0)
    disk = directory / 'root.qcow2'
    subprocess.run(
        ['qemu-img', 'convert', '-O', 'qcow2', str(image), str(disk)],
        check=True,
        timeout=120,
    )
    subprocess.run(
        ['qemu-img', 'resize', str(disk), '20G'], check=True, timeout=30
    )
    pool.refresh(0)
    # Fixture SSH avoids requiring guest-exec in the
    # distribution's agent policy.
    key = directory / 'identity'
    subprocess.run(
        ['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)],
        check=True,
    )
    user_data = {
        'packages': ['qemu-guest-agent'],
        'users': [
            'default',
            {
                'name': 'snapshotfixture',
                'sudo': 'ALL=(ALL) NOPASSWD:ALL',
                'ssh_authorized_keys': [
                    key.with_suffix('.pub').read_text().strip()
                ],
            },
        ],
        'runcmd': [
            [
                'sh',
                '-c',
                'if command -v systemctl; then systemctl enable --now qemu-guest-agent; '
                   'else rc-update add qemu-guest-agent default; rc-service qemu-guest-agent start; fi',
            ]
        ],
    }
    (directory / 'user-data').write_text(
        '#cloud-config\n' + json.dumps(user_data) + '\n'
    )
    (directory / 'meta-data').write_text(
        f'instance-id: {ident}\nlocal-hostname: snapshot-fixture\n'
    )
    seed = directory / 'seed.iso'
    subprocess.run(
        [
            'xorriso',
            '-as',
            'mkisofs',
            '-quiet',
            '-o',
            str(seed),
            '-V',
            'cidata',
            '-J',
            '-r',
            str(directory / 'user-data'),
            str(directory / 'meta-data'),
        ],
        check=True,
        timeout=30,
    )
    arch = connection.getInfo()[0]
    machine = 'virt' if arch == 'aarch64' else 'q35'
    guest = connection.defineXML(f'''<domain type="kvm"><name>{name}</name><uuid>{ident}</uuid>
      <memory unit="MiB">1536</memory><currentMemory unit="MiB">1024</currentMemory>
      <vcpu current="2">3</vcpu><cpu mode="host-passthrough">
      <topology sockets="3" dies="1" clusters="1" cores="1" threads="1"/></cpu>
      <os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type></os><features><acpi/></features><devices>
      <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{disk}"/><target dev="vda" bus="virtio"/></disk>
      <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seed}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
      <interface type="network">{network_source}<model type="virtio"/></interface>
      <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
      <serial type="pty"><target port="0"/></serial>
      <memballoon model="virtio"/>
      </devices></domain>''')
    guest.create()
    deadline = time.monotonic() + 150
    responding = False
    guest.agentSetResponseTimeout(2, 0)
    while time.monotonic() < deadline:
        try:
            responding = bool(
                guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0)
            )
            # Continue only after an actual guest-agent response.
            if responding:
                break
        except libvirt.libvirtError:
            pass
        time.sleep(2)
    assert responding, 'Disposable image did not start QEMU Guest Agent'
    before = api('snapshots', {'id': ident})
    assert before['preparation_available'] == 1
    guest_command('echo before > /var/tmp/cloudmin-snapshot-edit-check; sync')
    original = api('settings', {'id': ident})
    assert original['resource_locks'] == {
        'cpus': 0,
        'cpu_limit': 1,
        'memory_mib': 0,
        'memory_limit_mib': 0,
    }
    job = api(
        'snapshot_create',
        {
            'id': ident,
            'revision': before['revision'],
            'label': 'Prepared live point',
        },
    )
    wait_job(job)
    assert guest.isActive(), 'Prepared snapshot stopped the guest'
    status = json.loads(
        libvirt_qemu.qemuAgentCommand(
            guest, '{"execute":"guest-fsfreeze-status"}', 5, 0
        )
    )
    assert status['return'] == 'thawed', status
    history = api('snapshots', {'id': ident})
    point = history['snapshots'][0]
    assert point['mode'] == 'prepared'
    saved_xml = guest.snapshotLookupByName(point['id'], 0).getXMLDesc(0)
    # Editing current hardware must leave the restore point's hardware intact.
    edit_with_snapshot()
    assert (
        ET.fromstring(guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
        .find('cpu/topology')
        .get('sockets')
        == '3'
    )
    assert guest.snapshotLookupByName(point['id'], 0).getXMLDesc(0) == saved_xml
    guest_command('echo after > /var/tmp/cloudmin-snapshot-edit-check; sync')
    # Restore must roll back both later disk writes and current hardware edits.
    history = api('snapshots', {'id': ident})
    wait_job(
        api(
            'snapshot_restore',
            {
                'id': ident,
                'revision': history['revision'],
                'snapshot': point['id'],
                'confirm': 1,
                'shutdown': 1,
                'restart': 1,
            },
        )
    )
    agent_ready()
    restored = api('settings', {'id': ident})
    for field in (
        'cpus',
        'cpu_limit',
        'memory_mib',
        'memory_limit_mib',
        'description',
        'interfaces',
    ):
        assert restored[field] == original[field], (
            field,
            original[field],
            restored[field],
        )
    assert (
        guest_command('cat /var/tmp/cloudmin-snapshot-edit-check') == 'before'
    )
    print(
        'Live edits with a snapshot passed; restore recovered hardware and guest data',
        flush=True,
    )

    # Deleting the same restore point must keep subsequent edits and
    # disk writes.
    edited = edit_with_snapshot()
    guest_command('echo retained > /var/tmp/cloudmin-snapshot-edit-check; sync')
    history = api('snapshots', {'id': ident})
    wait_job(
        api(
            'snapshot_delete',
            {
                'id': ident,
                'revision': history['revision'],
                'snapshot': point['id'],
                'confirm': 1,
            },
        )
    )
    assert guest.isActive(), 'Deleting a prepared snapshot stopped the guest'
    assert not guest.listAllSnapshots(0)
    # Deleting history must retain the new hardware
    # and the guest's latest write.
    retained = api('settings', {'id': ident})
    for field in (
        'cpus',
        'cpu_limit',
        'memory_mib',
        'memory_limit_mib',
        'description',
        'interfaces',
    ):
        assert retained[field] == edited[field], field
    assert (
        guest_command('cat /var/tmp/cloudmin-snapshot-edit-check') == 'retained'
    )
    print(
        'Snapshot deletion preserved live hardware edits and guest data',
        flush=True,
    )
    print(
        'Prepared live creation and deletion passed; guest running, filesystems thawed',
        flush=True,
    )

    # Disconnect only the live fixture channel; its saved definition restores it
    # at boot.
    channel = ET.fromstring(guest.XMLDesc(0)).find(
        "./devices/channel/target[@name='org.qemu.guest_agent.0']/.."
    )
    assert channel is not None
    guest.detachDeviceFlags(
        ET.tostring(channel, encoding='unicode'), libvirt.VIR_DOMAIN_AFFECT_LIVE
    )
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        history = api('snapshots', {'id': ident})
        # Wait until the public API observes the detached agent channel.
        if not history['preparation_available']:
            break
        time.sleep(1)
    assert not history['preparation_available'], 'Fixture agent did not stop'
    job = wait_job(
        api(
            'snapshot_create',
            {
                'id': ident,
                'revision': history['revision'],
                'label': 'Clean shutdown fallback',
                'shutdown': 1,
                'restart': 1,
            },
        )
    )
    assert [event['step'] for event in job['events']] == [
        'snapshot_shutdown',
        'snapshot_create',
        'snapshot_restart',
    ], job
    assert guest.isActive(), 'Fallback did not restart the VM'
    history = api('snapshots', {'id': ident})
    point = history['snapshots'][0]
    assert point['mode'] == 'stopped'
    print(
        'Missing-agent fallback shut down cleanly, saved the snapshot, and restarted',
        flush=True,
    )

    # Wait for a booted guest before exercising the confirmed restore sequence.
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        try:
            # A responding agent confirms that the restarted fixture has booted.
            if guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0):
                break
        except libvirt.libvirtError:
            pass
        time.sleep(2)
    history = api('snapshots', {'id': ident})
    job = wait_job(
        api(
            'snapshot_restore',
            {
                'id': ident,
                'revision': history['revision'],
                'snapshot': point['id'],
                'confirm': 1,
                'shutdown': 1,
                'restart': 1,
            },
        )
    )
    assert [event['step'] for event in job['events']] == [
        'snapshot_shutdown',
        'snapshot_restore',
        'snapshot_restart',
    ], job
    assert guest.isActive(), 'Restore did not honor the requested startup'
    print(
        'Confirmed running restore shut down, restored, and restarted successfully',
        flush=True,
    )
finally:
    # API integration intentionally retains audit history. Cleanup waits for all
    # fixture workers to stop before removing any of their disks.
    from snapshot_fixture import cleanup_fixture

    cleanup_fixture(module, connection, guest, pool, directory)
