"""Check stale LVM registrations without creating or changing any host volumes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def run(*args, input=None, expected=0):
    """run(*arguments, [input], [expected]) checks a command with a 90-second timeout.

    input defaults to no supplied stdin; expected defaults to exit status zero.
    Return stdout on success or stderr for an expected failure.
    """
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=90)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout.strip() if expected == 0 else result.stderr.strip()


def main():
    """main() checks API and CLI removal and references to missing device aliases."""
    assert os.uname().sysname == 'Linux' and os.geteuid() == 0
    module = Path(__file__).resolve().parents[2]
    # Use unique names and confirm the fixture VG does not already exist.
    suffix = uuid.uuid4().hex[:12]
    group, pool, guest = 'cloudmin-missing-' + suffix, 'cloudmin_stale_' + suffix, 'cloudmin_ref_' + suffix
    before = set(run('virsh', 'pool-list', '--all', '--name').splitlines())
    assert group not in run('vgs', '--noheadings', '-o', 'vg_name').split()

    # api(action, fields, [expected]) uses the installed root API and its token.
    def api(action, fields, expected=0):
        result = run('perl', str(module / 'api.pl'), action, input=json.dumps(fields), expected=expected)
        return json.loads(result)['result'] if expected == 0 else result

    with tempfile.TemporaryDirectory(prefix='cloudmin-missing-vg-', dir='/var/tmp') as directory:
        work = Path(directory)
        # Define a registration only; never activate it or create the VG.
        definition = work / 'pool.xml'
        definition.write_text(f"""<pool type='logical'><name>{pool}</name>
            <source><name>{group}</name><format type='lvm2'/></source>
            <target><path>/dev/{group}</path></target></pool>""")
        domain = work / 'domain.xml'
        try:
            # Exercise both stop permissions, as the UI sends stop=1 for review.
            for stop in (0, 1):
                run('virsh', 'pool-define', str(definition))
                pool_id = run('virsh', 'pool-uuid', pool)
                review = api('pool_review', {'id': pool_id, 'stop': stop})
                assert not review['stop_required'] and not review['usage']['reason'], review
                listed = json.loads(run('perl', str(module / 'cli.pl'), 'unregister-pool',
                    '--pool', pool, '--review', '--json'))['data']
                assert listed['id'] == pool_id and not listed['usage']['reason'], listed

                # A stopped guest still owns a disk even after its VG disappears.
                for path in (f'/dev/{group}/disk', '/dev/mapper/' + group.replace('-', '--') + '-disk'):
                    domain.write_text(f"""<domain type='qemu'><name>{guest}</name>
                        <memory unit='MiB'>128</memory><vcpu>1</vcpu><os><type>hvm</type></os>
                        <devices><disk type='block' device='disk'><driver name='qemu' type='raw'/>
                        <source dev='{path}'/><target dev='vda' bus='virtio'/></disk></devices></domain>""")
                    run('virsh', 'define', str(domain))
                    blocked = api('pool_review', {'id': pool_id, 'stop': stop})
                    assert 'still referenced' in blocked['usage']['reason'], blocked
                    error = api('unregister_pool', {'id': pool_id, 'stop': stop,
                        'confirm': 1, 'revision': review['revision']}, expected=1)
                    assert 'still referenced' in error, error
                    run('virsh', 'undefine', guest)

                # Remove only the definition through each supported entry point.
                if stop:
                    # Test the raw API with the UI's stop-enabled review choice.
                    api('unregister_pool', {'id': pool_id, 'stop': 1,
                        'confirm': 1, 'revision': review['revision']})
                else:
                    # The CLI can remove the inactive definition without --stop.
                    run('perl', str(module / 'cli.pl'), 'unregister-pool', '--pool', pool, '--yes')
                assert pool not in run('virsh', 'pool-list', '--all', '--name').splitlines()
                print(f'PASS missing VG: stop={stop}, review, both device aliases and removal', flush=True)
        finally:
            # Definitions are never started, and cleanup touches no block devices.
            if guest in run('virsh', 'list', '--all', '--name').splitlines():
                # A failed reference assertion may leave the fixture guest.
                run('virsh', 'undefine', guest)
            if pool in run('virsh', 'pool-list', '--all', '--name').splitlines():
                # Remove a registration left by a failed removal assertion.
                run('virsh', 'pool-undefine', pool)
    assert set(run('virsh', 'pool-list', '--all', '--name').splitlines()) == before
    print('PASS fixture cleanup; pre-existing pool registrations unchanged', flush=True)


# Importing helpers must not create libvirt definitions.
if __name__ == '__main__':
    main()
