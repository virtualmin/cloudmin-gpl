#!/usr/bin/python3
"""Exercise clone flattening on private ext4 and loopback NFS pools."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from xml.etree import ElementTree as ET

# Loop devices, mounts and exports are confined to a disposable Linux test VM.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on a disposable Linux test VM as root')
import libvirt


# run(arguments...) runs fixture tools with a 120-second timeout and no shell.
def run(*arguments):
    return subprocess.check_output(
        arguments, text=True, stderr=subprocess.STDOUT, timeout=120
    ).strip()


directory = Path(
    tempfile.mkdtemp(prefix='cloudmin-clone-pools-', dir='/var/tmp')
)
directory.chmod(0o755)
connection = libvirt.open('qemu:///system')
loop = None
pools = []
exported = False
try:
    # Format only a loop device backed by this newly allocated fixture file.
    image = directory / 'filesystem.img'
    with image.open('wb') as stream:
        stream.truncate(512 * 1024**2)
    loop = run('losetup', '--find', '--show', str(image))
    run('mkfs.ext4', '-q', loop)
    target = directory / 'filesystem'
    target.mkdir()
    xml = ET.Element('pool', type='fs')
    # Let libvirt mount the private ext4 filesystem as a supported storage pool.
    ET.SubElement(xml, 'name').text = directory.name + '-fs'
    source = ET.SubElement(xml, 'source')
    ET.SubElement(source, 'device', path=loop)
    ET.SubElement(source, 'format', type='ext4')
    ET.SubElement(ET.SubElement(xml, 'target'), 'path').text = str(target)
    pool = connection.storagePoolDefineXML(
        ET.tostring(xml, encoding='unicode'), 0
    )
    pools.append(pool)
    pool.create(0)
    helper = Path(__file__).with_name('check-clone-storage.pl')
    print(run('perl', str(helper), pool.name()), flush=True)
    # Export only this fixture to the loopback client; no LAN export is added.
    exported_path = target / 'export'
    exported_path.mkdir(mode=0o755)
    run('systemctl', 'start', 'nfs-server')
    run(
        'exportfs',
        '-i',
        '-o',
        'rw,sync,no_subtree_check,no_root_squash',
        '127.0.0.1:' + str(exported_path),
    )
    exported = True
    mount = directory / 'nfs'
    mount.mkdir()
    xml = ET.Element('pool', type='netfs')
    # Use a loopback NFS pool to exercise the same volume-copy API over NFS.
    ET.SubElement(xml, 'name').text = directory.name + '-nfs'
    source = ET.SubElement(xml, 'source')
    ET.SubElement(source, 'host', name='127.0.0.1')
    ET.SubElement(source, 'dir', path=str(exported_path))
    ET.SubElement(source, 'format', type='nfs')
    ET.SubElement(ET.SubElement(xml, 'target'), 'path').text = str(mount)
    pool = connection.storagePoolDefineXML(
        ET.tostring(xml, encoding='unicode'), 0
    )
    pools.append(pool)
    pool.create(0)
    print(run('perl', str(helper), pool.name()), flush=True)
    print('PASS: ext4 filesystem and NFS clone pools', flush=True)
finally:
    # Unmount before detaching the loop device and removing its backing file.
    for pool in reversed(pools):
        if pool.name().endswith('-fs') and exported:
            # Remove the export before unmounting the filesystem that
            # contains it.
            run('exportfs', '-u', '127.0.0.1:' + str(exported_path))
            exported = False
        if pool.isActive():
            # Stop only pools created above, never the host's existing storage.
            pool.destroy()
        pool.undefine()
    if exported:
        # Partial setup may leave an export even without a defined NFS pool.
        run('exportfs', '-u', '127.0.0.1:' + str(exported_path))
    if loop:
        # Release the allocated loop device before deleting its private
        # backing file.
        run('losetup', '-d', loop)
    shutil.rmtree(directory)
    connection.close()
