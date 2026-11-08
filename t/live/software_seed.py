"""Stage guest setup helpers and the host worker used by their tests."""

from pathlib import Path
import shutil


# stage_guest_helpers(root, directory, [scripts]) stages private guest helpers.
# root is the module Path; directory must be new. scripts defaults to false and
# requires the installed Pro guest executor when true. Returns the bundle Path.
def stage_guest_helpers(root, directory, scripts=False):
    directory = Path(directory)
    directory.mkdir()
    for name in ('guest-software.pl', 'software-worker.pl'):
        shutil.copy2(root / name, directory / name)
    # Put the executor beside the shared helper, as in a real guest seed.
    if scripts:
        pro = root / 'pro/guest-scripts.pl'
        # Refuse script tests when their executor is missing.
        if not pro.is_file():
            raise RuntimeError(
                'This script execution test requires the Cloudmin Pro guest helper'
            )
        shutil.copy2(pro, directory / 'guest-scripts.pl')
    return directory
