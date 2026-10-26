#!/usr/bin/python3
"""Run backup and recovery checks against a temporary loopback NFS export."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

# Runtime exports and mounts belong only on an authorized Linux test host.
if sys.platform != 'linux' or os.geteuid():
    raise SystemExit('Run as root on an authorized Linux test host')
module = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    """run(*args, **kwargs) bounds each fixture command and raises on failure."""
    return subprocess.run(args, check=True, timeout=kwargs.pop('timeout', 60), **kwargs)


# Preserve the server state and use only this run's private export and mount.
active = subprocess.run(['systemctl', 'is-active', '--quiet', 'nfs-server']).returncode == 0
root = Path(tempfile.mkdtemp(prefix='cloudmin-backup-nfs-', dir='/var/tmp'))
export = root/'export'
mount = root/'mount'
export.mkdir(mode=0o700)
mount.mkdir(mode=0o700)
started = exported = mounted = False
try:
    # Reuse an existing server; start it temporarily only when necessary.
    if not active:
        run('systemctl', 'start', 'nfs-server')
        started = True
    run('exportfs', '-i', '-o', 'rw,sync,no_subtree_check,no_root_squash', '127.0.0.1:'+str(export))
    exported = True
    run('mount', '-t', 'nfs', '-o', 'vers=4.2,proto=tcp', '127.0.0.1:'+str(export), str(mount))
    mounted = True
    filesystem = run('stat', '-f', '-c', '%T', str(mount), capture_output=True, text=True).stdout.strip()
    assert filesystem == 'nfs', 'Fixture is not using an NFS mount'
    # Exercise real archive writes, inspection, retention and rollback on NFS.
    run('perl', str(module/'t/live/check-backup-jobs.pl'), timeout=900,
        env={**os.environ, 'CLOUDMIN_BACKUP_DESTINATION_ROOT':str(mount)})
    assert not list(export.iterdir()), 'NFS fixture left backup archives behind'
    print('PASS: NFS backup, inspection, retention, recovery and cleanup')
finally:
    # Attempt every cleanup step; never delete a directory still mounted.
    errors = []
    for needed, command in (
        (mounted, ['umount', str(mount)]),
        (exported, ['exportfs', '-u', '127.0.0.1:'+str(export)]),
        (started, ['systemctl', 'stop', 'nfs-server']),
    ):
        # Undo only fixture resources that setup reached.
        if needed:
            try:
                run(*command)
            except (subprocess.SubprocessError, OSError) as error:
                errors.append(str(error))
    # Failed jobs may retain archives for recovery; keep those files available.
    if not errors and not list(export.iterdir()):
        shutil.rmtree(root)
    # Retain the directory when a mount or export still needs cleanup.
    else:
        raise RuntimeError('NFS fixture needs cleanup at '+str(root)+': '+'; '.join(errors))
