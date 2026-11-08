#!/usr/bin/python3
"""Exercise Perl packages and scripts in a disposable EL8 guest or container."""

import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
from software_seed import stage_guest_helpers


# main() installs one fixture package only on an explicitly selected EL8 target.
def main():
    # This fixture installs packages and must run only on the selected
    # EL8 guest.
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Run only as root on a disposable EL8 test machine')
    release = dict(
        line.split('=', 1)
        for line in Path('/etc/os-release').read_text().splitlines()
        if '=' in line
    )
    # A newer distribution would not exercise EL8's minimal Perl package set.
    if release.get('PLATFORM_ID', '').strip('"') != 'platform:el8':
        raise SystemExit('This check requires EL8')
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location(
        'fixture', root / 't/software-guest.py'
    )
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-el8-check-', dir='/tmp'
    ) as directory:
        # Stage the Pro executor beside the shared helper, as in a guest seed.
        fixture.ROOT = stage_guest_helpers(
            root, Path(directory) / 'seed', scripts=True
        )
        # Exercise real dnf execution between the scripts, without Virtualmin.
        result = fixture.run_perl(
            r'''
save('status.json', {stage => 'queued'});
save('request.json', {});
install({uuid => 'fixture', software => 'none', packages => 'tree',
         before_script => 'printf before > before.txt',
         after_script => "test -f before.txt\nrpm -q tree\nprintf after > after.txt"});
report(status());
''',
            dict(directory=directory),
            timeout=120,
        )
        assert result.returncode == 0 and not result.stderr, result.stderr
        journal = json.loads(Path(directory, 'status.json').read_text())
        assert journal['stage'] == 'complete', Path(
            directory, 'install.log'
        ).read_text()
        assert Path(directory, 'after.txt').read_text() == 'after'
        assert journal['completed'] == ['before', 'packages', 'after']
        # Completed setup must remove private inputs and temporary
        # script copies.
        for name in ('request.json', 'before_script.sh', 'after_script.sh'):
            assert not Path(directory, name).exists(), name
        subprocess.run(['rpm', '-q', 'tree'], check=True, timeout=10)
        print(
            'PASS: EL8 Perl runs preparation, package installation and final setup with cleanup'
        )


# Never perform package installation merely by importing this test.
if __name__ == '__main__':
    main()
