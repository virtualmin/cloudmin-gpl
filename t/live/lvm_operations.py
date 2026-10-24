"""Exercise LVM snapshots and copies using an already booted fixture guest."""
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import tempfile
import time
import libvirt


def reclaim_fixture_space():
    """reclaim_fixture_space() discards unused extents only in this test's loop VG."""
    group = os.environ.get('CLOUDMIN_LVM_FIXTURE_GROUP')
    if not group:
        # Standalone guest checks have no loop-backed VG to reclaim.
        return
    assert re.fullmatch(r'cloudmin_lvm_test_[a-f0-9]{12}', group)

    def run(*args):
        """run(arguments...) bounds fixture-only storage commands."""
        return subprocess.check_output(args, text=True, timeout=120).strip()

    # Prove that this group occupies one private test file, never a host disk.
    report = json.loads(run('pvs', '--reportformat', 'json', '-o', 'pv_name,vg_name'))
    devices = [row['pv_name'].strip() for entry in report['report']
               for row in entry['pv'] if row['vg_name'].strip() == group]
    assert len(devices) == 1 and re.fullmatch(r'/dev/loop\d+', devices[0]), devices
    loop = json.loads(run('losetup', '--json', '--list', '--output', 'NAME,BACK-FILE', devices[0]))
    backing = loop['loopdevices'][0]['back-file']
    assert re.fullmatch(r'/var/tmp/cloudmin-lvm-machines-[a-zA-Z0-9_]+/pv.raw', backing)
    if float(run('vgs', '--noheadings', '--units', 'b', '--nosuffix', '-o', 'vg_free', group)) <= 0:
        # Existing allocations must never be discarded to free fixture space.
        return
    # Deleted LVs can retain blocks in the backing file. Allocate only free
    # extents temporarily, then discard them without touching any existing LV.
    name = 'fixture_reclaim_' + secrets.token_hex(6)
    run('lvcreate', '--yes', '--extents', '100%FREE', '--name', name, group)
    try:
        run('blkdiscard', '/dev/' + group + '/' + name)
    finally:
        run('lvremove', '--yes', group + '/' + name)


def check_operations(uuid, fields, key, skip_snapshots=False, skip_hardware=False, resume_clone=None):
    """check_operations(uuid, fields, key, [skip_snapshots], [skip_hardware],
    [resume_clone]) checks storage using a fixture UUID, creation fields and key.

    Skip flags default false. resume_clone optionally names a retained copy
    from a failed run; otherwise both destination backends get fresh copies.
    """
    module = Path(__file__).resolve().parents[2]
    connection = libvirt.open('qemu:///system')
    guest = connection.lookupByUUIDString(uuid)
    assert guest.name().startswith('cloudmin-create-check-')
    jobs = []
    clones = []
    archives = Path(tempfile.mkdtemp(prefix='cloudmin-lvm-backups-', dir='/var/tmp'))
    # Keep guest access private but recoverable if a long lifecycle test fails.
    recovery = Path(tempfile.mkdtemp(prefix='cloudmin-lvm-recovery-', dir='/var/tmp'))
    shutil.copyfile(key, recovery / 'identity')
    (recovery / 'identity').chmod(0o600)
    shutil.copyfile(str(key) + '.pub', recovery / 'identity.pub')
    saved = {name: fields[name] for name in ('name', 'username', 'network', 'pool')}
    (recovery / 'fixture.json').write_text(json.dumps({'uuid': uuid, 'fields': saved}))
    complete = False

    def api(action, values=None):
        """api(action, [values]) calls the root CLI without Webmin credentials."""
        result = subprocess.run(['perl', str(module / 'api.pl'), action],
                                input=json.dumps(values or {}), text=True,
                                capture_output=True, timeout=120)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)['result']

    def wait(job):
        """wait(job) retains unfinished jobs for diagnosis and recovery."""
        jobs.append(job['id'])
        deadline = time.monotonic() + 1200
        while job['state'] not in ('complete', 'failed', 'cancelled'):
            assert time.monotonic() < deadline, 'LVM operation timed out'
            time.sleep(1)
            job = api('status', {'job': job['id']})
        assert job['state'] == 'complete', job.get('error', job['state'])
        reclaim_fixture_space()
        return job

    def command(domain, text, timeout=60):
        """command(domain, text, [timeout]) connects only to a fixture's libvirt lease."""
        deadline = time.monotonic() + 480
        error = 'No guest lease'
        while time.monotonic() < deadline:
            addresses = domain.interfaceAddresses(libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0)
            for interface in addresses.values():
                for address in interface['addrs']:
                    if address['type'] != libvirt.VIR_IP_ADDR_TYPE_IPV4:
                        # This fixture uses only addresses from its IPv4 lease.
                        continue
                    result = subprocess.run(['ssh', '-F', '/dev/null', '-i', str(key),
                        '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                        fields['username'] + '@' + address['addr'], 'sudo -n sh -c ' + shlex.quote(text)],
                        text=True, capture_output=True, timeout=timeout)
                    if result.returncode == 0:
                        # A lease alone is insufficient; wait for usable guest SSH.
                        return result.stdout.strip()
                    error = result.stderr
            time.sleep(2)
        raise AssertionError(error)

    def snapshot(action, point=None, **extra):
        """snapshot(action, [point], options...) refreshes the submission revision."""
        current = api('snapshots', {'id': uuid})
        return wait(api('snapshot_' + action, {'id': uuid, 'revision': current['revision'],
            'label': 'LVM lifecycle', 'snapshot': point, 'confirm': 1, **extra}))

    def remove(domain):
        """remove(domain) deletes only a named copy owned by this fixture."""
        assert domain in clones and domain.name().startswith(fields['name'] + '-copy-')
        if domain.isActive():
            # Only disposable copies in this function's ownership list are stopped.
            domain.destroy()
        settings = api('settings', {'id': domain.UUIDString()})
        wait(api('delete', {'id': domain.UUIDString(), 'revision': settings['revision'],
            'confirm': 1, 'confirm_name': domain.name(),
            'disks': [disk['target'] for disk in settings['disks'] if disk.get('volume_info')]}))
        clones.remove(domain)

    try:
        if not skip_snapshots:
            # Prepared snapshots need an agent; minimal cloud images may omit it.
            command(guest, 'if ! command -v qemu-ga >/dev/null; then '
                'if command -v dnf >/dev/null; then dnf -y install qemu-guest-agent; '
                'else apt-get update -qq && DEBIAN_FRONTEND=noninteractive '
                'apt-get install -y -qq qemu-guest-agent; fi; fi; '
                'systemctl enable --now qemu-guest-agent', timeout=300)
            command(guest, 'echo before > /root/cloudmin-lvm-marker; sync')
            # Wait for the agent to answer before requesting a prepared snapshot.
            deadline = time.monotonic() + 120
            while True:
                try:
                    guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0)
                    break
                except libvirt.libvirtError:
                    assert time.monotonic() < deadline, 'Guest agent not ready'
                    time.sleep(2)
            snapshot('create', mode='prepared')
            # Changes after capture must disappear when the saved disk is restored.
            points = api('snapshots', {'id': uuid})['snapshots']
            point = next(item['id'] for item in points if item['label'] == 'LVM lifecycle')
            assert guest.isActive() and guest.state()[0] == libvirt.VIR_DOMAIN_RUNNING
            command(guest, 'echo after > /root/cloudmin-lvm-marker; sync')
            snapshot('restore', point, shutdown=1, restart=1)
            assert command(guest, 'cat /root/cloudmin-lvm-marker') == 'before'
            snapshot('delete', point)
            print('Prepared LVM snapshot, shutdown, restore, restart and data check passed', flush=True)

        if not skip_hardware:
            # Exercise durable hardware edits on a small native data volume.
            guest.shutdown()
            deadline = time.monotonic() + 120
            while guest.isActive():
                assert time.monotonic() < deadline, 'Fixture did not shut down'
                time.sleep(1)

            def change(action, values):
                """change(action, values) submits an edit against fresh guest settings."""
                current = api('settings', {'id': uuid})
                return wait(api(action, {'id': uuid, 'revision': current['revision'], **values}))

            before = {item['target'] for item in api('settings', {'id': uuid})['disks']}
            # Keep the added disk small while exercising allocation and growth.
            change('add_disk', {'pool': fields['pool'], 'disk_gib': 0.125})
            added = next(item for item in api('settings', {'id': uuid})['disks'] if item['target'] not in before)
            volume = added['volume_info']
            assert Path(volume['path']).is_block_device()
            change('grow_disk', {'target': added['target'], 'disk_gib': 0.25})
            grown = next(item for item in api('settings', {'id': uuid})['disks'] if item['target'] == added['target'])
            assert grown['volume_info']['capacity'] == 256*1024**2
            change('detach_disk', {'target': added['target']})
            # Detaching preserves the same LV, which can then be reattached.
            assert any(item['key'] == volume['key'] for item in api('settings', {'id': uuid})['attachable_volumes'])
            change('attach_disk', {'pool': fields['pool'], 'volume': volume['name']})
            guest.create()
            command(guest, 'true')
            current = api('settings', {'id': uuid})
            # Live growth must fail without leaving a recovery job or larger LV.
            refused = subprocess.run(['perl', str(module / 'api.pl'), 'grow_disk'],
                input=json.dumps({'id': uuid, 'revision': current['revision'],
                    'target': added['target'], 'disk_gib': 0.5}), text=True, capture_output=True)
            if refused.returncode:
                # Validation can reject growth before submitting a job.
                error = refused.stderr
            else:
                # A queued rejection must finish cleanly and explain the same rule.
                blocked = json.loads(refused.stdout)['result']
                jobs.append(blocked['id'])
                deadline = time.monotonic() + 60
                while blocked['state'] not in ('complete', 'failed', 'cancelled'):
                    assert time.monotonic() < deadline, 'Growth refusal did not finish'
                    time.sleep(1)
                    blocked = api('status', {'job': blocked['id']})
                assert blocked['state'] == 'failed' and not blocked.get('cleanup_pending')
                error = blocked['error']
            assert 'Shut down' in error and 'LVM' in error
            # Delete the extra disk offline, then reboot for live clone checks.
            guest.shutdown()
            deadline = time.monotonic() + 120
            while guest.isActive():
                assert time.monotonic() < deadline, 'Fixture did not shut down'
                time.sleep(1)
            change('delete_disk', {'target': added['target'], 'confirm': 1})
            assert not Path(volume['path']).exists()
            guest.create()
            command(guest, 'true')
            print('LVM data disk add, grow, detach, attach, live-growth refusal and delete passed', flush=True)

        # Cross-backend copies and same-backend copies use the same public API.
        options = api('options')
        file_pool = next(pool for pool in options['pools'] if pool['type'] == 'dir')
        for pool in (file_pool['id'], fields['pool']):
            source_identity = None
            if resume_clone and pool == file_pool['id']:
                # Resume only the caller-named copy of this exact source fixture.
                clone = connection.lookupByName(resume_clone)
                assert clone.name().startswith(fields['name'] + '-copy-') and not guest.isActive()
                clones.append(clone)
                if not clone.isActive():
                    # The retained copy must boot before its data can be checked.
                    clone.create()
            else:
                # Capture the running source into a fresh, independently named copy.
                source_identity = command(guest, 'cat /etc/machine-id')
                choices = api('clone_options', {'id': uuid})
                name = fields['name'] + '-copy-' + secrets.token_hex(3)
                wait(api('clone', {'id': uuid, 'revision': choices['revision'],
                    'name': name, 'hostname': name + '.example.test', 'username': fields['username'],
                    'ssh_keys': Path(str(key) + '.pub').read_text(), 'auth_type': 'keys',
                    'pool': pool, 'network': fields['network'], 'nvram_mode': 'fresh',
                    'start': 0, 'autostart': 0, 'host_ssh_key': 0}))
                clone = connection.lookupByName(name)
                clones.append(clone)
                # Keep live capture coverage without needing RAM for two booted copies.
                guest.shutdown()
                deadline = time.monotonic() + 120
                while guest.isActive():
                    assert time.monotonic() < deadline, 'Source did not shut down'
                    time.sleep(1)
                clone.create()
            assert command(clone, 'cat /root/cloudmin-lvm-marker') == 'before'
            if source_identity:
                # Freshly prepared clones must not reuse the source machine ID.
                assert command(clone, 'cat /etc/machine-id') != source_identity
            print('Live prepared clone to ' + pool + ' boots with independent identity', flush=True)
            # Exercise file-to-LVM restore and native LVM backup using the copy.
            identity = command(clone, 'cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub')
            saved_uuid = clone.UUIDString()
            backup = wait(api('backup', {'id': saved_uuid, 'shutdown': 1,
                'compression': 1, 'target': {'mode': 'local', 'path': str(archives)}}))
            inspected = wait(api('backup_inspect', {'backup': backup['id']}))
            # Remove the copy before restore, which deliberately preserves its UUID.
            remove(clone)
            wait(api('restore', {'inspection': inspected['id'], 'pool': fields['pool'], 'confirm': 1}))
            restored = connection.lookupByUUIDString(saved_uuid)
            clones.append(restored)
            assert not restored.isActive()
            roles = [disk['role'] for disk in api('settings', {'id': saved_uuid})['disks']]
            assert roles.count('system') == 1 and roles.count('seed') == 1, roles
            restored.create()
            # Restore preserves both guest content and SSH/machine identity.
            assert command(restored, 'cat /root/cloudmin-lvm-marker') == 'before'
            assert command(restored, 'cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub') == identity
            print('Backup and restore onto LVM preserve guest identity and data', flush=True)
            remove(restored)
            guest.create()
            command(guest, 'true')

        # Pro capture must accept a logical disk and publish a reusable file.
        if (module / 'pro/VMImages.pm').is_file():
            # GPL skips reusable-image capture; Pro must publish a file from an LV.
            choices = api('image_options', {'id': uuid})
            captured = wait(api('capture_image', {'id': uuid, 'revision': choices['revision'],
                'name': fields['name'] + '-copy-' + secrets.token_hex(3),
                'pool': file_pool['id'], 'clean_credentials': 1}))
            image = next(item for item in api('options')['images'] if item['id'] == captured['id'])
            assert image['prepared_vm'] and image['format'] == 'qcow2'
            assert command(guest, 'cat /root/cloudmin-lvm-marker') == 'before'
            print('Pro capture publishes a prepared image from the live LVM guest', flush=True)
        complete = True
    finally:
        # Never erase evidence while a worker or source recovery owns it.
        safe = all((state := api('status', {'job': job}))['state'] in ('complete', 'failed', 'cancelled')
                   and not state.get('cleanup_pending') for job in jobs)
        if safe and not clones:
            # Journals and archives are disposable only after all copies are gone.
            subprocess.run(['perl', str(module / 't/live/lvm-fixture-cleanup.pl')],
                           input=json.dumps({'jobs': jobs}), text=True, check=True, timeout=30)
            shutil.rmtree(archives)
        else:
            # Retain ownership records when cleanup cannot establish safety.
            print('LVM operation journals retained for recovery', flush=True)
        connection.close()
        if complete:
            # Successful checks no longer need the private guest recovery key.
            shutil.rmtree(recovery)
        else:
            # Preserve access to a failed fixture without printing its credentials.
            print('Private guest access retained in ' + str(recovery), flush=True)
