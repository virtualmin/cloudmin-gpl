#!/usr/bin/python3
"""Exercise bridge removal through the root CLI on a disposable Cloudmin VM.

Pass the module directory and a standalone Ethernet interface. This temporarily
moves its host addresses to a bridge, checks manual rollback and confirmed
removal and automatic timeout recovery, then restores the original files. Run
through systemd-run so an SSH disconnect cannot kill it. Reboot is not tested.
Do not run against a physical test host's management interface.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


# command(args, [data]) runs with a timeout; data optionally supplies
# text stdin.
def command(args, data=None):
    result = subprocess.run(
        args, input=data, text=True, capture_output=True, timeout=100
    )
    # Report the CLI error before trying to parse its output.
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


# api(action, [fields]) sends a JSON object, empty by default, using CLI tokens.
def api(action, fields=None):
    return json.loads(
        command(['perl', 'api.pl', action], json.dumps(fields or {}))
    )['result']


# wait_state(expected, transaction, [timeout]) waits up to timeout seconds (75).
def wait_state(expected, transaction, timeout=75):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = api('bridge_status', {'id': transaction})
        # Return only once this transaction reaches the requested state.
        if state['state'] == expected:
            return state
        # Other terminal states cannot become the expected result by waiting.
        if state['state'] in ('rollback_failed', 'complete', 'rolled_back'):
            raise RuntimeError(
                'Unexpected recovery state: ' + json.dumps(state)
            )
        time.sleep(1)
    raise RuntimeError('Timed out waiting for ' + expected)


# main(module, interface) tests removal and restores the original files on exit.
def main(module, interface):
    # The fixture changes live networking and must never run on the workstation.
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise RuntimeError('Disposable Linux VM as root required')
    os.chdir(module)
    journal = Path('/var/webmin/modules/server-manager/networking/bridge.json')
    previous = journal.read_bytes() if journal.exists() else None
    # Preserve completed history but never replace an unfinished transaction.
    if previous and json.loads(previous)['state'] not in (
        'complete',
        'rolled_back',
    ):
        raise RuntimeError('Finish the existing bridge transaction first')
    # Reserve a test-only name rather than adopting an existing bridge.
    if any(item['name'] == 'cmtestbr' for item in api('bridges')):
        raise RuntimeError('Fixture bridge already exists')
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-removal-', dir='/var/tmp'
    ) as work:
        original = Path(work) / 'creation.json'
        try:
            # Save the creation backup privately before removal replaces it.
            command(
                [
                    'perl',
                    't/live/network-fixture.pl',
                    'begin',
                    'cmtestbr',
                    interface,
                ]
            )
            created = api('bridge_status')
            original.write_bytes(journal.read_bytes())
            original.chmod(0o600)
            wait_state('confirm', created['id'])
            api('bridge_confirm', {'id': created['id']})
            print('PASS: fixture bridge created and confirmed', flush=True)
            # Exercise manual and timed recovery before keeping the removal.
            for recovery in ('manual', 'timeout', 'confirm'):
                reviewed = api('bridge_remove_review', {'name': 'cmtestbr'})
                assert reviewed['source'] == interface
                assert 'files' not in reviewed and 'saved' not in reviewed
                removed = api(
                    'bridge_remove',
                    {'name': 'cmtestbr', 'revision': reviewed['revision']},
                )
                wait_state('confirm', removed['id'])
                assert not any(
                    item['name'] == 'cmtestbr' for item in api('bridges')
                )
                print(
                    'PASS: CLI removed bridge and retained host addresses',
                    flush=True,
                )
                if recovery != 'confirm':
                    # Timeout recovery must run without a request from
                    # this client.
                    if recovery == 'manual':
                        api('bridge_rollback', {'id': removed['id']})
                        timeout = 75
                    # Allow the recorded recovery deadline to expire without
                    # manual rollback.
                    else:
                        timeout = max(
                            75, removed['deadline'] - time.time() + 75
                        )
                        print(
                            'Waiting for automatic removal recovery', flush=True
                        )
                    wait_state('rolled_back', removed['id'], timeout)
                    # Both recovery paths must restore membership and
                    # exact files.
                    assert any(
                        item['name'] == 'cmtestbr' for item in api('bridges')
                    )
                    command(
                        ['perl', 't/live/network-fixture.pl', 'assert-restored']
                    )
                    print(
                        'PASS: '
                        + recovery
                        + ' recovery restored bridge and exact saved files',
                        flush=True,
                    )
                else:
                    # Confirmation must complete the removal transaction.
                    result = api('bridge_confirm', {'id': removed['id']})
                    assert (
                        result['state'] == 'complete'
                        and result['operation'] == 'remove'
                    )
                    print('PASS: confirmed removal persists', flush=True)
        finally:
            # Restore the initial creation snapshot, even after
            # confirmed removal.
            if original.exists():
                command(
                    [
                        'perl',
                        't/live/network-fixture.pl',
                        'restore-fixture',
                        'cmtestbr',
                        str(original),
                    ]
                )
                command(
                    ['perl', 't/live/network-fixture.pl', 'assert-restored']
                )
                if previous is None:
                    # Leave no transaction history when the fixture created it.
                    journal.unlink()
                else:
                    # Restore the completed journal that preceded this test.
                    journal.write_bytes(previous)
                print(
                    'PASS: original host configuration restored exactly',
                    flush=True,
                )


# Direct execution requires both the installed module and chosen test port.
if __name__ == '__main__':
    # Reject incomplete arguments before any live network operation.
    if len(sys.argv) != 3:
        raise SystemExit(
            'Usage: check-bridge-removal.py MODULE ETHERNET_INTERFACE'
        )
    main(*sys.argv[1:])
