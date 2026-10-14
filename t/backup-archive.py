#!/usr/bin/python3
"""Exercise archive integrity and extraction without touching host services."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'backup-archive.py'


class ArchiveTests(unittest.TestCase):
    """ArchiveTests validates fixed members, checksums, and bounded extraction."""

    def setUp(self):
        """setUp(self) creates an isolated fixture directory."""
        self.temp = tempfile.TemporaryDirectory(prefix='cloudmin-archive-')
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def run_request(self, **request):
        """run_request(self, **request) passes keyword fields to the real archive helper."""
        (self.root / 'request.json').write_text(json.dumps({'limit': 32*1024**2, **request}))
        return subprocess.run(['python3', str(SCRIPT)], cwd=self.root, capture_output=True, text=True)

    def make_archive(self, extra=None, corrupt=False):
        """make_archive(self, [extra], [corrupt]) builds controlled hostile fixtures."""
        members = {'domain.xml': b'<domain/>', 'disk0': b'disk bytes'}
        manifest = {'format': 'cloudmin-full-1', 'files': {
            name: {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            for name, data in members.items()}}
        # Change bytes after computing metadata so the checksum must fail.
        if corrupt:
            members['disk0'] = b'bad! bytes'
        with tarfile.open(self.root / 'archive', 'w') as archive:
            for name, data in {'manifest.json': json.dumps(manifest).encode(), **members}.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            # Append a hostile member after otherwise valid manifest content.
            if extra:
                archive.addfile(extra)

    def test_round_trip(self):
        """test_round_trip(self) preserves exact bytes with and without compression."""
        # Verify both formats using the actual helper and fresh extracted files.
        for compressed in (False, True):
            for name, data in {'disk0': b'\0'*4096+b'guest', 'domain.xml': b'<domain/>'}.items():
                (self.root / name).write_bytes(data)
            result = self.run_request(mode='pack', manifest={'format': 'cloudmin-full-1'},
                                      members=['domain.xml','disk0'], compression=compressed)
            self.assertEqual(result.returncode, 0, result.stderr)
            (self.root / 'output').rename(self.root / 'archive')
            # Remove input files so extraction cannot accidentally reuse them.
            for name in ('disk0', 'domain.xml', 'manifest.json'):
                (self.root / name).unlink()
            result = self.run_request(extract=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.root/'disk0').read_bytes(), b'\0'*4096+b'guest')

    def test_reject_bad_checksum(self):
        """test_reject_bad_checksum(self) rejects altered disk contents."""
        self.make_archive(corrupt=True)
        self.assertNotEqual(self.run_request(extract=True).returncode, 0)

    def test_reject_paths_links_and_duplicates(self):
        """test_reject_paths_links_and_duplicates(self) never extracts archive paths."""
        for name, kind in [('../escape',tarfile.REGTYPE), ('/tmp/escape',tarfile.REGTYPE),
                           ('disk0',tarfile.SYMTYPE), ('disk0',tarfile.LNKTYPE), ('disk0',tarfile.REGTYPE)]:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.linkname = '/etc/passwd' if kind != tarfile.REGTYPE else ''
            self.make_archive(info)
            self.assertNotEqual(self.run_request().returncode, 0)

    def test_reject_size_budget(self):
        """test_reject_size_budget(self) bounds expanded size before extraction."""
        self.make_archive()
        self.assertNotEqual(self.run_request(limit=1).returncode, 0)

    @unittest.skipUnless(os.environ.get('CLOUDMIN_LARGE_ARCHIVE_TEST'), 'Large disk check runs on a test host')
    def test_large_disk(self):
        """test_large_disk(self) packs and verifies a disk beyond the USTAR limit."""
        size = 9*1024**3
        with (self.root/'disk0').open('wb') as disk:
            disk.truncate(size)
        (self.root/'domain.xml').write_bytes(b'<domain/>')
        result = self.run_request(mode='pack', manifest={'format':'cloudmin-full-1'},
                                  members=['domain.xml','disk0'], compression=True, limit=size+1024**2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['manifest']['files']['disk0']['size'], size)
        (self.root/'output').rename(self.root/'archive')
        result = self.run_request(limit=size+1024**2)
        self.assertEqual(result.returncode, 0, result.stderr)


# Run these archive cases when invoked directly.
if __name__ == '__main__':
    unittest.main()
