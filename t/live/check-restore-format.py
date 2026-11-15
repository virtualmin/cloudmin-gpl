#!/usr/bin/python3
"""Check restored disk formats and raw reads on a disposable Cloudmin host."""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from xml.etree import ElementTree as ET

# This test creates a guest, storage and a root-only host file.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
import libvirt

module = Path(__file__).resolve().parents[2]
# Separate names and paths keep cleanup confined to this run.
ident = str(uuid.uuid4())
name = 'cloudmin-backup-test-format-' + ident[:8]
work = Path(tempfile.mkdtemp(prefix=name + '-', dir='/var/tmp'))
storage = Path(tempfile.mkdtemp(prefix=name + '-', dir='/var/lib/libvirt/images'))
canary = Path('/root/' + name)
conn = libvirt.open('qemu:///system')
pool = guest = token = None
jobs = []


def api(action, fields=None):
    """api(action, [fields]) returns Cloudmin's result.
    fields is an optional dictionary of request values.
    """
    fields = dict(fields or {})
    if token:
        # Mutations use the host's normal form validation.
        fields['token'] = token
    result = subprocess.run(
        ['perl', str(module / 'api.pl'), action],
        input=json.dumps(fields), text=True, capture_output=True, timeout=60,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)['result']


def wait(job):
    """wait(job) returns a completed job, tracking its ID for cleanup."""
    jobs.append(job['id'])
    # Fail the test if the job does not finish within five minutes.
    deadline = time.monotonic() + 300
    while job['state'] not in ('complete', 'failed', 'cancelled'):
        assert time.monotonic() < deadline, 'Fixture job timed out'
        time.sleep(1)
        job = api('status', {'job': job['id']})
    assert job['state'] == 'complete', job.get('error', job['state'])
    return job


try:
    # Use a private pool so cleanup cannot remove existing guest disks.
    token = api('options')['token']
    storage.chmod(0o755)
    pool = conn.storagePoolDefineXML(
        f'<pool type="dir"><name>{name}</name>'
        f'<target><path>{storage}</path></target></pool>', 0,
    )
    pool.create(0)
    # Raw guest sectors may contain a QCOW2 header pointing to a host file.
    marker = b'HOST-ONLY-RESTORE-CANARY\n' * 128
    canary.write_bytes(marker)
    canary.chmod(0o600)
    subprocess.run(['qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'raw',
                    '-b', str(canary), str(work / 'disk0'), '8M'], check=True)
    # Pad the crafted file to the raw capacity declared in the archive.
    with (work / 'disk0').open('r+b') as disk:
        disk.truncate(8 * 1024**2)
    raw_start = (work / 'disk0').read_bytes()[:4096]
    # Keep an ordinary QCOW2 disk beside the crafted raw disk.
    subprocess.run(['qemu-img', 'create', '-q', '-f', 'qcow2',
                    str(work / 'disk1'), '8M'], check=True)
    # Model the ISO signature that libvirt detects in cloud-init seed media.
    with (work / 'disk2').open('wb') as disk:
        disk.seek(32768)
        disk.write(b'\x01CD001\x01')
        disk.truncate(1024**2)
    # Describe all three disk formats and keep the ISO media read-only.
    arch = platform.machine()
    machine = 'virt' if arch == 'aarch64' else 'q35'
    devices = ''.join(
        f'<disk type="file" device="disk"><driver name="qemu" type="{fmt}"/>'
        f'<source file="/old/disk{i}"/><target dev="vd{chr(97+i)}" bus="virtio"/>'
        + ('<readonly/>' if i == 2 else '') + '</disk>'
        for i, fmt in enumerate(('raw', 'qcow2', 'raw'))
    )
    # A minimal guest is enough to open disks without booting an OS.
    (work / 'domain.xml').write_text(
        f'<domain type="kvm"><name>{name}</name><uuid>{ident}</uuid>'
        '<memory unit="MiB">256</memory><vcpu>1</vcpu>'
        f'<os><type arch="{arch}" machine="{machine}">hvm</type></os>'
        f'<cpu mode="host-passthrough"/><devices>{devices}</devices></domain>'
    )
    # Declare each disk's original format and checksum in the archive.
    members = ('domain.xml', 'disk0', 'disk1', 'disk2')
    manifest = {
        'format': 'cloudmin-full-1', 'name': name, 'uuid': ident,
        'files': {member: {'size': (work / member).stat().st_size,
                           'sha256': hashlib.sha256((work / member).read_bytes()).hexdigest()}
                  for member in members},
        'disks': [{'file': f'disk{i}', 'target': f'vd{chr(97+i)}',
                   'format': fmt, 'capacity': (1 if i == 2 else 8) * 1024**2}
                  for i, fmt in enumerate(('raw', 'qcow2', 'raw'))],
    }
    # Write the manifest first, as required by the archive reader.
    with tarfile.open(work / 'fixture.tar', 'w') as archive:
        data = json.dumps(manifest).encode()
        info = tarfile.TarInfo('manifest.json')
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
        for member in members:
            archive.add(work / member, arcname=member)
    # Exercise inspection and restore through the normal controller.
    inspection = wait(api('backup_inspect', {
        'target': {'mode': 'local', 'path': str(work)}, 'filename': 'fixture.tar',
    }))
    wait(api('restore', {'inspection': inspection['id'],
                         'pool': pool.UUIDString(), 'confirm': 1}))
    # Libvirt detects the headers, but VM drivers must keep the saved formats.
    guest = conn.lookupByUUIDString(ident)
    assert not guest.isActive() and not guest.autostart(), 'Restored guest is running or has autostart enabled'
    disks = ET.fromstring(guest.XMLDesc(0)).findall('./devices/disk')
    pool.refresh(0)
    detected = [ET.fromstring(conn.storageVolLookupByPath(
        disk.find('source').get('file')).XMLDesc(0)).find('./target/format').get('type')
        for disk in disks]
    assert detected == ['qcow2', 'qcow2', 'iso'], detected
    assert [disk.find('driver').get('type') for disk in disks] == ['raw', 'qcow2', 'raw']
    print('PASS: restore keeps archive formats despite QCOW2 and ISO detection', flush=True)
    # Starting QEMU paused opens every disk without executing the crafted bytes.
    guest.createWithFlags(libvirt.VIR_DOMAIN_START_PAUSED)
    assert guest.blockPeek('vda', 0, 4096, 0) == raw_start, 'Raw disk read returned different bytes'
    assert guest.blockPeek('vdc', 32768, 7, 0) == b'\x01CD001\x01', 'Seed bytes changed'
    assert canary.read_bytes() == marker, 'Host test file changed'
    print('PASS: QEMU reads raw guest sectors, not the linked host file', flush=True)
finally:
    # Keep test files while jobs are unfinished or need recovery.
    states = [api('status', {'job': jid}) for jid in jobs]
    safe = all(job['state'] in ('complete', 'failed', 'cancelled') and
               not job.get('cleanup_pending') for job in states)
    if safe:
        # Finished jobs allow cleanup. Find the guest even if setup failed
        # before assigning it to the local variable.
        guest = next((domain for domain in conn.listAllDomains(0)
                      if domain.UUIDString() == ident), None)
        if guest:
            # Confirm this run owns the guest before removing its definition.
            assert guest.name() == name
            if guest.isActive():
                # Stop QEMU before removing its disks.
                guest.destroy()
            guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
        if pool:
            # Setup may fail before registering a pool.
            if pool.isActive():
                # Deactivate the pool before unregistering it.
                pool.destroy()
            pool.undefine()
        # Remove this guest's backup cache and files; keep finished job history.
        subprocess.run(['perl', str(module / 't/live/backup-fixture-cleanup.pl'), ident],
                       check=True)
        shutil.rmtree(storage)
        shutil.rmtree(work)
        canary.unlink(missing_ok=True)
    else:
        # Report the archive directory so unfinished work can be inspected.
        print('Kept test files for recovery: ' + str(work), file=sys.stderr)
    conn.close()
