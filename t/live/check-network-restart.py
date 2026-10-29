#!/usr/bin/python3
"""Check the recovery timeout with a private service that takes 31 seconds to stop.

Run on a disposable Linux host. Existing libvirt services and rules are untouched.
"""
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time

assert os.uname().sysname == 'Linux' and os.geteuid() == 0
module = Path(__file__).resolve().parents[2]
unit = 'cloudmin-restart-check-' + secrets.token_hex(4) + '.service'


def run(*args, **kwargs):
    """run(*args, **kwargs) runs fixture commands with a timeout and no shell."""
    return subprocess.run(args, text=True, capture_output=True, check=True,
                          timeout=75, **kwargs)


with tempfile.TemporaryDirectory(prefix='cloudmin-restart-check-', dir='/var/tmp') as directory:
    marker = Path(directory) / 'slow-once'
    marker.touch()
    stop = Path(directory) / 'stop.sh'
    # Delay the tested restart only; fixture removal should stop immediately.
    stop.write_text(f'if [ -f "{marker}" ]; then\n  rm "{marker}"\n  sleep 31\nfi\n')
    started = False
    try:
        run('systemd-run', '--unit=' + unit, '--collect', '--property=Type=exec',
            '--property=TimeoutStopSec=45', '--property=ExecStop=/bin/sh ' + str(stop),
            '/usr/bin/sleep', 'infinity')
        started = True
        # Require a new active process after a stop exceeding the old deadline.
        before = run('systemctl', 'show', '--property=MainPID', '--value', unit).stdout.strip()
        began = time.monotonic()
        result = run('perl', '-I', str(module.parent), '-I', str(module / 'lib'),
                     '-MCloudmin::NetworkPreflight', '-e', '''
            my $reason;
            my $result = Cloudmin::NetworkPreflight::service_command('restart', $ARGV[0], \\$reason);
            die "$reason\\n" unless defined($result);
            print "Restart completed\\n";
        ''', unit)
        elapsed = time.monotonic() - began
        assert elapsed >= 30, 'The fixture did not exercise the slow shutdown'
        assert run('systemctl', 'is-active', unit).stdout.strip() == 'active'
        after = run('systemctl', 'show', '--property=MainPID', '--value', unit).stdout.strip()
        assert after != before and after != '0', 'The service did not restart'
        print(f'Slow restart completed and verified after {elapsed:.1f} seconds')
    finally:
        # Remove the delay even if startup or the assertion failed.
        marker.unlink(missing_ok=True)
        if started:
            # Stop only this run's transient unit after removing its delay.
            run('systemctl', 'stop', unit)
