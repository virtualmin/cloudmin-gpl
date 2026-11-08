#!/usr/bin/python3
"""Check that console and SSH browser sessions leave no action-log entries."""

import os
from pathlib import Path
import platform
import re
import subprocess
import argparse

# Browser fixtures create accounts and services on the disposable host only.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--guest-id', required=True, help='UUID of the disposable terminal fixture'
)
options = parser.parse_args()


# opening_count() counts only connection entries for the browser fixture user.
def opening_count():
    path = Path('/var/webmin/webmin.log')
    # A fresh host with no action log has no prior connection entries.
    if not path.exists():
        return 0
    with path.open(errors='replace') as log:
        return sum(
            bool(
                re.search(
                    r'\] cloudmin-ui-check \S+ \S+ server-manager \S+ '
            r'"?(?:console|terminal)"? "?vm"? ',
                    line,
                )
            )
            for line in log
        )


# Reuse browser checks that reach real VNC and SSH backends, with their cleanup.
for script in ('check-console.py', 'check-terminal-browser.py'):
    before = opening_count()
    arguments = (
        ['--guest-id', options.guest_id]
        if script == 'check-terminal-browser.py'
        else []
    )
    subprocess.run(
        ['python3', str(here / script), *arguments], check=True, timeout=480
    )
    assert opening_count() == before, (
        script + ' added connection entries to Webmin Actions Log'
    )
    print(
        'PASS: ' + script + ' did not log routine connection openings',
        flush=True,
    )
