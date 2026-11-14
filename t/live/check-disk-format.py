#!/usr/bin/env python3
"""Check that Cloudmin refuses raw disks with QCOW2 headers linking to host files.

Run as root on a disposable Linux Cloudmin host. The test models a guest
writing a QCOW2 header onto its raw disk. Backup, clone, image capture,
growth and attachment must refuse it. Cleanup is attempted after the checks.
"""
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

# This test creates and deletes libvirt storage and root-owned fixtures.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')

POOL = 'default'
NAME = 'cm-diskfmt-%d' % os.getpid()
MARKER = ('CLOUDMIN-DISK-CANARY-%d' % os.getpid()).encode()
REFUSED = 'used as raw, but its contents are detected as qcow2'
failures = []


def run(*args, check=True):
    """run(args..., [check=True]) returns combined command output.
    Nonzero status aborts the test unless check=False is passed for cleanup.
    """
    result = subprocess.run(
        args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    if check and result.returncode:
        # Abort on command failures, except during best-effort cleanup.
        raise SystemExit('%s failed: %s' % (' '.join(args), result.stdout))
    return result.stdout


def cloudmin(*args):
    """cloudmin(args...) returns whether a CLI command worked, and its output."""
    result = subprocess.run(
        ['/usr/sbin/cloudmin', *args, '--json'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=900,
    )
    return result.returncode == 0, result.stdout


def error(output):
    """error(output) extracts the reported error from CLI output."""
    found = re.search(r'"error"\s*:\s*"((?:[^"\\]|\\.)*)"', output)
    return found.group(1) if found else 'no error was reported'


def check(label, passed, detail=''):
    """check(label, passed, [detail]) records and prints one expectation."""
    print(('ok   - ' if passed else 'FAIL - ') + label, flush=True)
    if not passed:
        # Keep checking other paths after recording this failure.
        print('       ' + detail, flush=True)
        failures.append(label)


def canary_lines(root):
    """canary_lines(root) counts marker occurrences in files below root."""
    count = 0
    for path in Path(root).rglob('*'):
        if path.is_file():
            # Skip directories while scanning all backup files.
            with open(path, 'rb') as handle:
                # Overlap reads so a marker split across two chunks counts.
                tail = b''
                while chunk := handle.read(1 << 20):
                    count += (tail + chunk).count(MARKER)
                    count -= tail.count(MARKER)
                    tail = chunk[-len(MARKER):]
    return count


def volumes():
    """volumes() lists the volume names in the test pool."""
    run('virsh', '-q', 'pool-refresh', POOL)
    return run('virsh', '-q', 'vol-list', POOL).split()[0::2]


def craft(path, crafted):
    """craft(path, crafted) writes the crafted header over a raw disk's start,
    as a guest could on its own disk."""
    with open(path, 'r+b') as disk:
        disk.write(crafted)


# Keep fixture names separate from existing domains, volumes and host files.
work = Path(tempfile.mkdtemp(prefix='cm-diskfmt-', dir='/var/tmp'))
canary = Path('/root/%s.txt' % NAME)
resized = Path('/root/%s-data.txt' % NAME)
directory = Path(
    re.search(r'<path>(.*?)</path>', run('virsh', 'pool-dumpxml', POOL)).group(1)
)
try:
    # A root-only host file stands in for any file a guest must never reach.
    canary.write_bytes((MARKER + b'\n') * 4096)
    canary.chmod(0o600)
    # Create a QCOW2 disk backed by the canary. Its 1 GiB capacity meets
    # the minimum size required for cloning.
    run('qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'raw', '-b',
        str(canary), str(work / 'crafted.qcow2'), '1G')
    crafted = (work / 'crafted.qcow2').read_bytes()

    # A stopped machine with one raw file disk, as libvirt tools define them.
    # Cloning needs a disk of at least 1 GiB; it stays sparse.
    for volume, size in (('disk.img', '1G'), ('spare.img', '64M')):
        run('virsh', '-q', 'vol-create-as', POOL, '%s-%s' % (NAME, volume),
            size, '--allocation', '0', '--format', 'raw')
    run('virsh', '-q', 'vol-create-as', POOL, NAME + '-plain.qcow2', '64M',
        '--format', 'qcow2')
    # Use UEFI on the ARM virt machine so cloning can copy its variables.
    arm = platform.machine() == 'aarch64'
    (work / 'domain.xml').write_text(
        "<domain type='kvm'><name>%s</name><memory unit='MiB'>256</memory>"
        "<vcpu>1</vcpu><os%s><type arch='%s' machine='%s'>hvm</type></os>%s"
        "<devices><disk type='file' device='disk'>"
        "<driver name='qemu' type='raw'/><source file='%s/%s-disk.img'/>"
        "<target dev='vda' bus='virtio'/></disk><interface type='network'>"
        "<source network='default'/><model type='virtio'/></interface>"
        "</devices></domain>"
        % (NAME, " firmware='efi'" if arm else '', platform.machine(),
           'virt' if arm else 'q35',
           "<cpu mode='host-passthrough'/>" if arm else '', directory, NAME)
    )
    run('virsh', '-q', 'define', str(work / 'domain.xml'))
    if arm:
        # The first start creates the variables file; the disk is still empty.
        run('virsh', '-q', 'start', NAME)
        run('virsh', '-q', 'destroy', NAME)

    # An ordinary raw disk is still backed up.
    worked, output = cloudmin('backup-systems', '--name', NAME, '--dest-mode',
                              'local', '--dest-path', str(work / 'plain'))
    check('a machine with an ordinary raw disk is backed up', worked,
          error(output))

    # An ordinary raw disk is still grown.
    worked, output = cloudmin('resize-disk', '--name', NAME, '--target', 'vda',
                              '--disk', '2G')
    grown = (directory / (NAME + '-disk.img')).stat().st_size
    check('an ordinary raw disk is grown', worked and grown == 2 * 1024 ** 3,
          'the disk has %d bytes: %s' % (grown, error(output)))

    # Model a guest writing a QCOW2 header that links to the canary.
    craft(directory / (NAME + '-disk.img'), crafted)
    run('virsh', '-q', 'pool-refresh', POOL)
    detected = run('virsh', 'vol-dumpxml', '--pool', POOL, NAME + '-disk.img')
    check('libvirt now detects the raw disk as QCOW2 with a backing file',
          "<format type='qcow2'/>" in detected and '<backingStore>' in detected,
          'libvirt did not detect the QCOW2 backing file; the attack setup failed')

    # A backup must not copy the disk in the detected format.
    worked, output = cloudmin('backup-systems', '--name', NAME, '--dest-mode',
                              'local', '--dest-path', str(work / 'crafted'))
    leaked = canary_lines(work / 'crafted') if (work / 'crafted').exists() else 0
    check('backup refuses the crafted disk',
          not worked and REFUSED in output,
          'backup %s; %d of 4096 lines of a root-only host file are in it; %s'
          % ('completed' if worked else 'failed', leaked, error(output)))

    # A clone must not copy it either.
    worked, output = cloudmin('clone-system', '--name', NAME, '--new-name',
                              NAME + '-clone', '--mode', 'unchanged',
                              '--confirm-unchanged', '--no-start',
                              '--no-autostart')
    check('clone refuses the crafted disk', not worked and REFUSED in output,
          'clone %s: %s' % ('completed' if worked else 'failed', error(output)))

    # Image capture exists only on Pro hosts.
    worked, output = cloudmin('create-image', '--name', NAME, '--image-name',
                              NAME + '-image', '--pool', POOL)
    if 'requires Cloudmin Pro' in output:
        # GPL has no image capture operation to test.
        print('skip - image capture needs Cloudmin Pro', flush=True)
    else:
        # Pro must refuse capture for the same format mismatch.
        check('image capture refuses the crafted disk',
              not worked and REFUSED in output,
              'capture %s: %s'
              % ('completed' if worked else 'failed', error(output)))

    # An unattached disk with the same header must not be attached as QCOW2,
    # where the guest would read the linked file directly.
    craft(directory / (NAME + '-spare.img'), crafted)
    run('virsh', '-q', 'pool-refresh', POOL)
    worked, output = cloudmin('attach-disk', '--name', NAME, '--pool', POOL,
                              '--volume', NAME + '-spare.img')
    attached = re.search(r"<driver[^>]*type='(\w+)'[^>]*/>\s*<source file='[^']*"
                         + NAME + r"-spare\.img'", run('virsh', 'dumpxml', NAME))
    check('attaching the crafted disk is refused',
          not worked and 'links to another file' in output and not attached,
          'attached as %s: %s'
          % (attached.group(1) if attached else 'nothing', error(output)))

    # A QCOW2 disk that links to nothing is still attached.
    worked, output = cloudmin('attach-disk', '--name', NAME, '--pool', POOL,
                              '--volume', NAME + '-plain.qcow2')
    check('an ordinary QCOW2 disk is attached', worked, error(output))

    # Growing a disk in the detected format would resize the file its header
    # names as an external data file. Creating such a header also creates
    # that file, so the root-only host file is written afterwards.
    run('qemu-img', 'create', '-q', '-f', 'qcow2', '-o',
        'data_file=%s' % resized, str(work / 'linked.qcow2'), '1G')
    resized.write_bytes(MARKER + b'\n')
    resized.chmod(0o600)
    craft(directory / (NAME + '-disk.img'),
          (work / 'linked.qcow2').read_bytes())
    run('virsh', '-q', 'pool-refresh', POOL)
    worked, output = cloudmin('resize-disk', '--name', NAME, '--target', 'vda',
                              '--disk', '3G')
    size = resized.stat().st_size
    check('growth refuses the crafted disk',
          not worked and REFUSED in output and size == len(MARKER) + 1,
          'growth %s; a root-only host file of %d bytes now has %d; %s'
          % ('completed' if worked else 'failed', len(MARKER) + 1, size,
             error(output)))
finally:
    # Remove the machine first so its disks are no longer in use.
    run('virsh', '-q', 'destroy', NAME, check=False)
    run('virsh', '-q', 'undefine', NAME, '--nvram', check=False)
    run('virsh', '-q', 'undefine', NAME + '-clone', '--nvram', check=False)
    for volume in volumes():
        if volume.startswith(NAME) or volume.startswith('cloudmin-' + NAME):
            # Leave volumes belonging to other guests and tests alone.
            run('virsh', '-q', 'vol-delete', '--pool', POOL, volume, check=False)
    # Remove the host-file canaries and temporary backup data too.
    canary.unlink(missing_ok=True)
    resized.unlink(missing_ok=True)
    shutil.rmtree(work, ignore_errors=True)

# Any failed expectation makes the test fail after cleanup has run.
if failures:
    raise SystemExit('%d disk format checks failed' % len(failures))
print('Disk format checks passed', flush=True)
