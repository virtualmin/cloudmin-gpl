#!/usr/bin/python3
"""Test service installation, recording and history failure on a test host.

Reinstalls the service. Backs up and restores the recording setting and history
for failure checks. Guest configuration is untouched.
"""
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time

# Require root on Linux before touching host configuration or services.
assert os.uname().sysname == 'Linux' and os.geteuid() == 0
module = Path(__file__).resolve().parents[2]
config = Path('/etc/webmin/server-manager/config')
cache = Path('/run/cloudmin-statistics/statistics-latest.json')
database = Path('/var/webmin/modules/server-manager/metrics.sqlite')
assert database.is_file(), 'Start collection before running this fixture'
original = config.read_text()
setting = re.search(r'^statistics_recording=(.*)$', original, re.M)
original_setting = setting.group(1) if setting else None


def recording(value):
    """
    recording(value) sets recording, or removes it for None, preserving other
    settings.
    """
    body = re.sub(r'^statistics_recording=.*\n?', '', config.read_text(), flags=re.M)
    # None restores a setting that was originally absent.
    if value is not None:
        body = body.rstrip('\n') + '\nstatistics_recording=' + str(value) + '\n'
    # Replace the file atomically while preserving its existing permission bits.
    temporary = config.with_name('config.statistics-fixture')
    assert not temporary.exists()
    temporary.write_text(body)
    temporary.chmod(config.stat().st_mode & 0o777)
    temporary.replace(config)


def service(action):
    """service(action) controls only the statistics collector."""
    subprocess.run(['systemctl', action, 'cloudmin-statistics.service'], check=True, timeout=20)


def install(remove=False):
    """install([remove=False]) updates the service, or removes it when true."""
    subprocess.run(['perl', '-I', str(module.parent), '-e',
                    'require "./server-manager-lib.pl"; '
                    'require "./cloudmin-statistics-lib.pl"; '
                    'install_statistics_service($ARGV[0]);', str(int(remove))],
                   cwd=module, check=True, timeout=60,
                   env={**os.environ, 'WEBMIN_CONFIG': str(config.parent.parent),
                        'WEBMIN_VAR': str(database.parents[2]),
                        'FOREIGN_MODULE_NAME': 'server-manager',
                        'FOREIGN_ROOT_DIRECTORY': str(module.parent)})


def latest(predicate):
    """latest(predicate) waits for fresh cache data, with a bounded deadline."""
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        try:
            value = json.loads(cache.read_text())
            # Only a fresh cache can prove that the collector reached the
            # requested state.
            if time.time() - value['checked_at'] < 3 * value['interval'] and predicate(value):
                return value
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.5)
    raise AssertionError('Collector did not reach the expected state')


def rows():
    """rows() opens a short read-only connection and counts stored intervals."""
    with sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True) as connection:
        return connection.execute('SELECT count(*) FROM samples').fetchone()[0]


def query():
    """query() checks the public command without reading credentials."""
    response = subprocess.run(['perl', str(module / 'cli.pl'), 'get-statistics', '--json'],
                              capture_output=True, text=True, check=True, timeout=30)
    return json.loads(response.stdout)['data']


# Run the destructive database case only when invoked as the fixture program.
if __name__ == '__main__':
    # Keep the backup if recovery itself fails; never discard the only original.
    backup = Path(tempfile.mkdtemp(prefix='cloudmin-statistics-service-', dir='/var/tmp'))
    backup.chmod(0o700)
    shutil.copy2(config, backup / 'config-before')
    saved = False
    try:
        # Upgrade an existing unit without changing host or history identity.
        before = query()
        install()
        latest(lambda value: not value.get('error'))
        upgraded = query()
        assert (upgraded['host_id'], upgraded['generation']) == (before['host_id'], before['generation'])
        unit = Path(subprocess.check_output(['systemctl', 'show', 'cloudmin-statistics.service',
                    '-p', 'FragmentPath', '--value'], text=True).strip())
        assert unit.stat().st_mode & 0o777 == 0o644
        print('PASS service upgrade preserves host and history identity', flush=True)

        # Removal must stop the collector and leave its history intact.
        try:
            install(True)
            assert not unit.exists(), 'Uninstall left the service file behind'
            active = subprocess.run(['systemctl', 'is-active', '--quiet', 'cloudmin-statistics.service'])
            assert active.returncode != 0, 'Uninstalled collector is still running'
            assert database.is_file(), 'Uninstall removed statistics history'
        finally:
            # Reinstall even when a removal assertion fails.
            install()
        latest(lambda value: not value.get('error'))
        restored = query()
        assert (restored['host_id'], restored['generation']) == (before['host_id'], before['generation'])
        print('PASS service removal and reinstall preserve statistics history', flush=True)

        # Observe two live ticks with recording disabled and require no new DB
        # rows.
        recording(0)
        first = latest(lambda value: value.get('recording') == 0)
        count = rows()
        second = latest(lambda value: value.get('recording') == 0 and value['checked_at'] > first['checked_at'])
        assert rows() == count, 'Recording off still writes intervals'
        assert second['vms'] and second['host'], 'Live readings stopped with history'
        assert query()['collector']['available'], 'API lost live readings'
        print('PASS recording off: DB unchanged, live values and API still update', flush=True)
        # Resume writes before checking that a service restart preserves
        # identities.
        recording(1)
        latest(lambda value: value.get('recording') == 1 and value['checked_at'] > second['checked_at'])
        assert rows() > count, 'Recording did not resume'
        host = query()['host_id']
        generation = query()['generation']
        service('restart')
        latest(lambda value: value.get('recording') == 1)
        assert query()['host_id'] == host and query()['generation'] == generation
        print('PASS service restart preserves host and history identity', flush=True)

        # Stop the sole writer before moving its files. The exact original DB and
        # any remaining WAL/SHM files are restored even if an assertion fails.
        service('stop')
        for suffix in ('', '-wal', '-shm'):
            path = Path(str(database) + suffix)
            # WAL and SHM are optional, but any existing companions belong to
            # this backup.
            if path.exists():
                shutil.move(path, backup / path.name)
        saved = True
        # A corrupt history file must not prevent collection or current API
        # readings.
        database.write_bytes(b'Controlled statistics fixture: invalid SQLite header\n')
        database.chmod(0o600)
        service('start')
        failed = latest(lambda value: value.get('error') and 'History recording failed' in value['error'])
        assert failed['vms'] and failed['host'], 'History failure stopped live values'
        result = query()
        assert result['collector']['available'] and result['live'], 'Public read lost live values during DB failure'
        assert not result['history_available'], 'Corrupt database presented as valid history'
        print('PASS corrupt history: collector and live API remain available', flush=True)
    finally:
        service('stop')
        # Restore database files only after the complete original set was moved.
        if saved:
            for suffix in ('', '-wal', '-shm'):
                path = Path(str(database) + suffix)
                path.unlink(missing_ok=True)
                source = backup / path.name
                # Restore only companions that existed when the writer was
                # stopped.
                if source.exists():
                    shutil.move(source, path)
        # Restore the setting and require a healthy collector before deleting
        # backup.
        recording(original_setting)
        service('start')
        final = latest(lambda value: not value.get('error'))
        assert query()['collector']['available']
        shutil.rmtree(backup)
        print('Restored original statistics DB and recording setting; collector is running', flush=True)
