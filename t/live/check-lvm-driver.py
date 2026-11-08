"""
Test the LVM driver using a private loop-backed VG on a disposable Linux VM.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def run(*args):
    """
    run(arguments...) executes a bounded command and retains its diagnostics.
    """
    return subprocess.run(
        args, check=True, text=True, stdout=subprocess.PIPE, timeout=180
    ).stdout.strip()


def main():
    """
    main() creates and removes only the fixture's loop device and volume group.
    """
    if os.geteuid() != 0:
        # Loop devices and fixture VGs require privileges on the test guest.
        raise SystemExit('Run on a disposable Linux host as root')
    source = Path(__file__).resolve().parent
    group = 'cloudmin_lvm_test_' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-lvm-driver-', dir='/var/tmp'
    ) as work:
        # All allocation stays inside a fresh sparse file on the test host.
        image = Path(work) / 'pv.raw'
        with image.open('wb') as output:
            output.truncate(4 * 1024**3)
        loop = run('losetup', '--find', '--show', str(image))
        created = False
        try:
            run('pvcreate', '--yes', loop)
            run('vgcreate', group, loop)
            created = True
            run(
                'lvcreate',
                '--yes',
                '--type',
                'thin-pool',
                '--size',
                '1G',
                '--poolmetadatasize',
                '16M',
                '--zero',
                'y',
                '--name',
                'thin',
                group,
            )
            subprocess.run(
                ['perl', str(source / 'check-lvm-driver.pl'), group, work],
                check=True,
                timeout=300,
            )
        finally:
            # Identity comes from a newly attached loop file, never a host disk.
            pools = run('virsh', 'pool-list', '--all', '--name').splitlines()
            if group in pools:
                # Libvirt registration may survive a failed Perl cleanup.
                if group in run('virsh', 'pool-list', '--name').splitlines():
                    # Stop only the active registration owned by this fixture.
                    run('virsh', 'pool-destroy', group)
                run('virsh', 'pool-undefine', group)
            if created:
                # Do not try removing a VG if its creation never succeeded.
                run('vgremove', '--yes', group)
            run('pvremove', '--yes', loop)
            run('losetup', '--detach', loop)


# Importing helpers must not create storage fixtures.
if __name__ == '__main__':
    main()
