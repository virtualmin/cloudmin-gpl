"""Exercise thick and thin machine creation using a private loop-backed VG.

Run only on a disposable Linux Cloudmin host with the current source installed.
The existing machine fixture checks boot, SSH, cloud-init and guest removal.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def run(*args, timeout=180):
    """run(arguments..., [timeout]) runs a bounded fixture command."""
    return subprocess.run(
        args, check=True, text=True, stdout=subprocess.PIPE, timeout=timeout
    ).stdout.strip()


def main():
    """
    main() tests both backends while preserving host disks and existing guests.
    """
    if os.geteuid() != 0 or not Path('/proc').is_dir():
        # Fixture storage administration belongs on a Linux test host.
        raise SystemExit('Run on a disposable Linux host as root')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', choices=('logical', 'lvmthin'))
    args = parser.parse_args()
    module = Path(__file__).resolve().parents[2]
    work = Path(
        tempfile.mkdtemp(prefix='cloudmin-lvm-machines-', dir='/var/tmp')
    )
    group = 'cloudmin_lvm_test_' + uuid.uuid4().hex[:12]
    # Back the entire test VG with one new sparse file, never a physical disk.
    image = work / 'pv.raw'
    with image.open('wb') as output:
        output.truncate(64 * 1024**3)
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
            '10G',
            '--poolmetadatasize',
            '32M',
            '--zero',
            'y',
            '--name',
            'thin',
            group,
        )
        definition = work / 'pool.xml'
        definition.write_text(
            f'<pool type="logical"><name>{group}</name>'
                              f'<source><name>{group}</name></source>'
                              f'<target><path>/dev/{group}</path></target></pool>'
        )
        run('virsh', 'pool-define', str(definition))
        run('virsh', 'pool-start', group)
        options = json.loads(run('perl', str(module / 'api.pl'), 'options'))[
            'result'
        ]
        # Prefer a small installed cloud image to keep full-copy
        # staging bounded.
        sources = [
            item
            for item in options['images']
            if item.get('cloud_init')
            and 0 < int(item.get('virtual_size') or 0) <= 12 * 1024**3
        ]
        source = (
            min(sources, key=lambda item: int(item['virtual_size']))
            if sources
            else None
        )
        assert source, (
            'Import a cloud-init image with a disk capacity of at most 12 GiB'
        )
        # Thick disks, their copies and private processing share this host's
        # filesystem through the loop file. Avoid enlarging a small test image.
        size = max(
            int(source['virtual_size']), int(source.get('min_disk_bytes') or 0)
        )
        disk_gib = max(2, (size + 1024**3 - 1) // 1024**3)
        assert shutil.disk_usage(work).free >= (4 * disk_gib + 2) * 1024**3, (
            f'This fixture needs at least {4*disk_gib + 2} GiB free; use a smaller image or a larger test host'
        )
        pools = [
            item
            for item in options['pools']
            if item['name'] in (group, group + '/thin')
        ]
        assert len(pools) == 2, 'Both LVM destinations must be offered'
        for pool in pools:
            if args.backend and pool['type'] != args.backend:
                # A targeted rerun can exercise one backend with the same setup.
                continue
            print('Testing ' + pool['type'], flush=True)
            subprocess.run(
                [
                    'python3',
                    str(module / 't/live/check_machine_create.py'),
                    '--pool-id',
                    pool['id'],
                    '--image-id',
                    source['id'],
                    '--disk-gib',
                    str(disk_gib),
                    '--lvm-operations',
                    '--keep-on-failure',
                ],
                check=True,
                timeout=7200,
                env={**os.environ, 'CLOUDMIN_LVM_FIXTURE_GROUP': group},
            )
    finally:
        # Creation can still own open disks before a domain exists. A timed-out
        # browser must never tear down storage underneath its background job.
        jobs = json.loads(run('perl', str(module / 'api.pl'), 'list'))['result']
        if any(
            job.get('name', '').startswith('cloudmin-create-check-')
            and (
                job['state'] not in ('complete', 'failed', 'cancelled')
                or job.get('cleanup_pending')
            )
            for job in jobs
        ):
            # An unfinished controller may still write disks; preserve its VG.
            raise RuntimeError(
                f'Fixture work still needs recovery; retained {work} and {loop}'
            )
        # Keep the entire fixture if a failed guest cleanup still references it.
        for guest in run('virsh', 'list', '--all', '--name').splitlines():
            xml = run('virsh', 'dumpxml', guest)
            if '/dev/' + group + '/' in xml or group in xml:
                # Failed guest cleanup leaves storage available for recovery.
                raise RuntimeError(
                    f'Fixture is still used by {guest}; retained {work} and {loop}'
                )
        pools = run('virsh', 'pool-list', '--all', '--name').splitlines()
        if group in pools:
            # Remove only the libvirt registration made by this invocation.
            if group in run('virsh', 'pool-list', '--name').splitlines():
                # Inactive registrations need only undefine, not destroy.
                run('virsh', 'pool-destroy', group)
            run('virsh', 'pool-undefine', group)
        if created:
            # VG creation may have failed before the fixture owned any LVs.
            run('vgremove', '--yes', group)
        run('pvremove', '--yes', loop)
        run('losetup', '--detach', loop)
        shutil.rmtree(work)


# Importing helpers must not create storage fixtures.
if __name__ == '__main__':
    main()
