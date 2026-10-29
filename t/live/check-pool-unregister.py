"""Test confirmed LVM pool removal using only a private loop-backed fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def run(*args, input=None, expected=0):
    """run(*arguments, [input], [expected]) checks a command and returns stdout.

    input defaults to no supplied stdin; expected defaults to exit status zero.
    """
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=90)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout.strip()


def cli(*args, expected=0):
    """cli(*arguments, [expected]) runs the installed root entry point.

    expected defaults to exit status zero; return the command's stdout.
    """
    return run('perl', str(Path(__file__).resolve().parents[2] / 'cli.pl'), *args, expected=expected)


def main():
    """main() checks host-use refusals and data preservation, then removes fixtures."""
    assert os.uname().sysname == 'Linux' and os.geteuid() == 0
    group = 'cloudmin_pool_stop_' + uuid.uuid4().hex[:12]
    external = group + '-external'
    with tempfile.TemporaryDirectory(prefix='cloudmin-pool-stop-', dir='/var/tmp') as directory:
        # All block-device changes stay inside this newly allocated loop file.
        work = Path(directory)
        image = work / 'pv.raw'
        with image.open('wb') as output:
            output.truncate(512 * 1024**2)
        loop = run('losetup', '--find', '--show', str(image))
        created = mounted = swapping = mapped = False
        try:
            # Initialize only the private loop device and give its VG a unique name.
            run('pvcreate', '--yes', loop)
            run('vgcreate', group, loop)
            created = True
            cli('create-pool', '--name', group, '--group', group, '--no-autostart')
            # Even an empty active group needs explicit permission to stop.
            review = json.loads(cli('unregister-pool', '--pool', group, '--stop', '--review', '--json'))['data']
            assert review['stop_required'] and not review['usage']['reason'], review
            cli('unregister-pool', '--pool', group, '--stop', '--yes')
            run('vgs', group)
            cli('create-pool', '--name', group, '--group', group, '--no-autostart')
            run('lvcreate', '--yes', '--size', '16M', '--name', 'disk', group)
            run('lvcreate', '--yes', '--type', 'thin-pool', '--size', '64M',
                '--poolmetadatasize', '8M', '--name', 'thin', group)
            run('lvcreate', '--yes', '--virtualsize', '16M', '--thinpool', group + '/thin', '--name', 'thin-disk')
            disk = Path('/dev') / group / 'disk'
            thin = Path('/dev') / group / 'thin-disk'

            # blocked() proves both review and submission retain the registration.
            def blocked():
                review = json.loads(cli('unregister-pool', '--pool', group, '--stop', '--review', '--json'))['data']
                assert review['usage']['reason'], review
                cli('unregister-pool', '--pool', group, '--stop', '--yes', expected=1)
                assert group in run('virsh', 'pool-list', '--name').splitlines()
                print('PASS refusal: ' + review['usage']['reason'], flush=True)

            # Open block devices include users that do not appear in libvirt.
            for path in (disk, thin, Path('/dev/mapper') / (group + '-thin_tmeta')):
                with path.open('rb'):
                    blocked()
            # A host mount protects the group even without a guest reference.
            run('mkfs.ext4', '-F', str(disk))
            mount = work / 'mount'
            mount.mkdir()
            run('mount', str(disk), str(mount))
            mounted = True
            blocked()
            run('umount', str(mount))
            mounted = False
            # Swap use also blocks deactivation after the mount is released.
            run('mkswap', str(disk))
            run('swapon', str(disk))
            swapping = True
            blocked()
            run('swapoff', str(disk))
            swapping = False
            # A device outside this VG must not be accepted as an internal holder.
            sectors = run('blockdev', '--getsz', str(disk))
            run('dmsetup', 'create', external, '--table', f'0 {sectors} linear {disk} 0')
            mapped = True
            blocked()
            run('dmsetup', 'remove', external)
            mapped = False
            # Preserve actual thick and thin data across stopping and re-registration.
            for path in (disk, thin):
                with path.open('wb') as output:
                    output.write(b'preserved storage bytes')
            review = json.loads(cli('unregister-pool', '--pool', group, '--stop', '--review', '--json'))['data']
            assert not review['usage']['reason'], review
            # Neither stop permission nor confirmation alone authorizes removal.
            cli('unregister-pool', '--pool', group, '--yes', expected=1)
            cli('unregister-pool', '--pool', group, '--stop', expected=2)
            cli('unregister-pool', '--pool', group, '--stop', '--yes')
            assert group not in run('virsh', 'pool-list', '--all', '--name').splitlines()
            # Re-registration must expose the same thick and thin disk bytes.
            cli('create-pool', '--name', group, '--group', group, '--no-autostart')
            for path in (disk, thin):
                with path.open('rb') as source:
                    assert source.read(23) == b'preserved storage bytes'
            cli('unregister-pool', '--pool', group, '--stop', '--yes')
            print('PASS empty VG, thick/thin data preservation and repeated CLI removal', flush=True)
        finally:
            # Only this fixture's device names and freshly attached loop are changed.
            if mapped:
                # Release the external holder before deactivating its backing LV.
                run('dmsetup', 'remove', external)
            if swapping:
                # Release any swap use left by a failed refusal assertion.
                run('swapoff', str(disk))
            if mounted:
                # Release any mount left by a failed refusal assertion.
                run('umount', str(mount))
            if group in run('virsh', 'pool-list', '--all', '--name').splitlines():
                # Remove only this test's surviving registration.
                if group in run('virsh', 'pool-list', '--name').splitlines():
                    # Libvirt requires the pool to be stopped before undefining it.
                    run('virsh', 'pool-destroy', group)
                run('virsh', 'pool-undefine', group)
            if created:
                # Delete the private VG only after its host users are released.
                run('vgremove', '--yes', group)
            # Detach the private device before its temporary file is removed.
            run('pvremove', '--yes', loop)
            run('losetup', '--detach', loop)


# Importing the helpers does not allocate devices or change storage.
if __name__ == '__main__':
    main()
