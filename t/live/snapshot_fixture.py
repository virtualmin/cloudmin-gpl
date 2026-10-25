"""Cleanup shared by the snapshot API and browser integration fixtures."""
import shutil
import subprocess
import time


# cleanup_fixture(module, connection, guest, pool, directory) removes only this
# test's unique resources. An uncertain worker or libvirt failure retains disks
# for inspection, rather than unlinking files that QEMU may still be using.
def cleanup_fixture(module, connection, guest, pool, directory):
    identity = name = None
    try:
        # Wait for the fixture guest workers before removing any disk files.
        if guest:
            # A mismatched name must retain the guest and storage for inspection.
            if not guest.name().startswith(('cloudmin-snapshot-agent-', 'cloudmin-snapshot-ui-')):
                raise RuntimeError('Refusing to clean up a non-fixture virtual machine')
            identity, name = guest.UUIDString(), guest.name()
            deadline = time.monotonic() + 60
            while True:
                result = subprocess.run(['perl', str(module / 't/live/snapshot-jobs.pl'), guest.UUIDString()],
                                        text=True, capture_output=True, timeout=15, check=True)
                # No active worker means it is safe to continue fixture cleanup.
                if int(result.stdout) == 0:
                    break
                # Keep disks if a worker fails to release them within the deadline.
                if time.monotonic() >= deadline:
                    raise RuntimeError(f'Fixture worker remains active; retained {directory}')
                time.sleep(1)
            # Stop the owned guest before removing snapshots and disk files.
            if guest.isActive():
                guest.destroy()
            import libvirt
            for point in guest.listAllSnapshots(0):
                point.delete(libvirt.VIR_DOMAIN_SNAPSHOT_DELETE_METADATA_ONLY)
            guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
        # An early setup failure may leave no fixture storage pool.
        if pool:
            # Deactivate only the pool allocated by this test.
            if pool.isActive():
                pool.destroy()
            pool.undefine()
        shutil.rmtree(directory)
        # Retire this fixture's jobs only after its guest and disks are removed.
        if identity:
            subprocess.run(['perl', str(module / 't/live/snapshot-jobs.pl'), identity,
                            'cleanup', name, str(directory)],
                           text=True, capture_output=True, timeout=30, check=True)
    finally:
        connection.close()
