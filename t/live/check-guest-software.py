#!/usr/bin/python3
"""Check Perl guest setup cancellation on a disposable Linux machine."""

import importlib.util
import json
import os
from pathlib import Path
import platform
import secrets
import subprocess
import tempfile
import time
from software_seed import stage_guest_helpers


# main() uses private paths and one transient service, never installed settings.
def main():
    # The test creates a real systemd service on the selected disposable guest.
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Run only as root on a disposable Linux test machine')
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location(
        'fixture', root / 't/software-guest.py'
    )
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    unit = 'cloudmin-software-check-' + secrets.token_hex(4) + '.service'
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-software-check-', dir='/tmp'
    ) as directory:
        # Stage the Pro executor privately, without changing installed files.
        seed = stage_guest_helpers(root, Path(directory) / 'seed', scripts=True)
        fixture.ROOT = seed
        try:
            # Start the production entry point with isolated configuration
            # and state.
            wrapper = Path(directory, 'run.pl')
            wrapper.write_text(
                'use strict; use warnings; no warnings "once";\n'
                               'require ' + json.dumps(str(seed / 'guest-software.pl')) + ';\n'
                               '$Cloudmin::GuestSoftware::DIRECTORY = '
                + json.dumps(directory)
                + ';\n'
                               '$Cloudmin::GuestSoftware::CONFIG = '
                + json.dumps(str(Path(directory, 'config.json')))
                + ';\n'
                               'exit Cloudmin::GuestSoftware::main();\n'
            )
            Path(directory, 'config.json').write_text(
                json.dumps(
                    dict(
                        uuid='fixture',
                        software='none',
                        before_script='sleep 60\necho must-not-run',
                    )
                )
            )
            Path(directory, 'status.json').write_text(
                json.dumps(dict(stage='queued'))
            )
            Path(directory, 'request.json').write_text(
                json.dumps(dict(key='fixture-private-value'))
            )
            subprocess.run(
                [
                    'systemd-run',
                    '--quiet',
                    '--unit=' + unit,
                    '--property=KillMode=control-group',
                    '--property=TimeoutStopSec=3',
                    '--property=RuntimeMaxSec=30',
                    '/usr/bin/perl',
                    str(wrapper),
                    'run',
                ],
                check=True,
                timeout=10,
            )
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if (
                    json.loads(Path(directory, 'status.json').read_text())[
                        'stage'
                    ]
                    == 'before'
                ):
                    # Cancel running work, not a service that has yet to start.
                    break
                time.sleep(0.1)
            else:
                # Failure to reach the script is a fixture failure,
                # not cancellation.
                raise AssertionError(
                    'The Perl service did not start its preparation script'
                )
            # Cancellation must stop the service and its shell children first.
            result = fixture.run_perl(
                r'''
cancel();
install({uuid => 'fixture', before_script => 'exit 77'});
''',
                dict(directory=directory, unit=unit),
                timeout=50,
            )
            assert result.returncode == 0 and not result.stderr, result.stderr
            assert json.loads(result.stdout)['stage'] == 'cancelled'
            assert not Path(directory, 'request.json').exists()
            assert not Path(directory, 'before_script.sh').exists()
            assert (
                'must-not-run' not in Path(directory, 'install.log').read_text()
            )
            assert (
                json.loads(Path(directory, 'status.json').read_text())['stage']
                == 'cancelled'
            )
            state = subprocess.run(
                ['systemctl', 'show', unit, '-p', 'ActiveState', '--value'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=10,
            ).stdout.strip()
            assert state not in ('active', 'activating', 'deactivating'), state
            print(
                'PASS: Perl cancellation stops the real service and removes its request'
            )
            print('PASS: cancelled setup is never replayed')

            # Exercise the exact remote shell wrapper with
            # missing prerequisites.
            result = fixture.run_perl(
                'print Cloudmin::SoftwareWorker::remote_command("root", 0);',
                dict(directory=directory),
            )
            assert result.returncode == 0, result.stderr
            command = result.stdout.replace(
                '/usr/bin/perl', directory + '/missing-perl'
            )
            result = subprocess.run(
                ['/bin/sh', '-c', command],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=10,
            )
            assert json.loads(result.stdout) == {
                'stage': 'failed',
                'reason': 'perl',
            }
            # Hide sudo separately so a privilege failure cannot look like
            # boot delay.
            command = fixture.run_perl(
                'print Cloudmin::SoftwareWorker::remote_command("cloudmin");',
                dict(directory=directory),
            ).stdout
            result = subprocess.run(
                ['/bin/sh', '-c', command],
                env={'PATH': directory},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=10,
            )
            assert json.loads(result.stdout) == {
                'stage': 'failed',
                'reason': 'privilege',
            }
            print(
                'PASS: missing Perl and sudo produce permanent protocol errors'
            )
        finally:
            # Stop only this fixture unit, even after an assertion or timeout.
            subprocess.run(
                ['systemctl', 'stop', unit],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
            subprocess.run(
                ['systemctl', 'reset-failed', unit],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )


# Require an explicit invocation on the selected disposable machine.
if __name__ == '__main__':
    main()
