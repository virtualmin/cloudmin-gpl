#!/usr/bin/python3
"""Exercise image form submissions and real libvirt imports on the debug VM."""

import hashlib
import html
import http.cookiejar
import json
import os
import pathlib
import platform
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

# Image and account fixtures belong on the disposable Linux VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
here = pathlib.Path(__file__).resolve().parent
base = 'https://127.0.0.1:10000'
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)
created = []
keep = set()


def request(path, fields=None, body=None, headers=None):
    """
    request(path, [fields], [body], [headers]): use this fixture's session.
    """
    # Encode ordinary form submissions; raw uploads keep their supplied body.
    if fields is not None:
        body = urllib.parse.urlencode(fields).encode()
    hdr = {'Referer': base + '/server-manager/images.cgi'}
    hdr.update(headers or {})
    with opener.open(
        urllib.request.Request(base + path, data=body, headers=hdr), timeout=90
    ) as response:
        return response.read().decode()


def form():
    """form(): return a fresh CSRF token and the live default pool UUID."""
    page = request('/server-manager/image_form.cgi')
    assert 'Add Images' in page and 'Download selected images' in page
    assert 'data-ui-multi="id"' in page and 'setup_image.cgi' in page
    assert 'Cloud image details' not in page
    assert not re.search(r'<input[^>]*value=["\']Continue["\']', page)
    token = re.search(r'name=["\']token["\'][^>]*value=["\']([^"\']+)', page)
    pool = re.search(
        r'<option[^>]*value=["\']([a-f0-9-]{36})["\'][^>]*>default', page
    )
    assert token and pool, 'Form token or default pool missing'
    return {'token': html.unescape(token[1]), 'pool': pool[1], 'ajax': '1'}


def submit(fields):
    """submit(fields): start an import through its actual authenticated CGI."""
    result = json.loads(request('/server-manager/image.cgi', fields))
    assert 'error' not in result, result
    # Track each job once, including idempotent retries.
    if result['id'] not in created:
        created.append(result['id'])
    return result['id']


def wait(job, expected='ready', timeout=900):
    """
    wait(job, [expected], [timeout]): require a terminal state and log phases.
    """
    end = time.monotonic() + timeout
    previous = None
    while time.monotonic() < end:
        status = json.loads(
            request('/server-manager/image-status.cgi?job=' + job)
        )
        # Log phase transitions without repeating every polling response.
        if status.get('state') != previous:
            print('Job phase:', status.get('state'), flush=True)
            previous = status.get('state')
        # A terminal response must match the state expected by this scenario.
        if status.get('terminal'):
            assert status['state'] == expected, status
            return status
        time.sleep(1)
    raise AssertionError('Image job did not complete: ' + job)


def volume(action, job, digest=None):
    """
    volume(action, job, [digest]): verify storage independently through
    Sys::Virt.
    """
    args = ['perl', str(here / 'image-volume.pl'), action, job]
    # Only verification calls that know the source hash compare disk contents.
    if digest:
        args.append(digest)
    result = subprocess.run(args, text=True, capture_output=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def progress(job):
    """
    progress(job): verify read-only GET and POST views of a finished upload.
    """
    # Neither progress method may modify this import or create another job.
    store = pathlib.Path('/var/webmin/modules/server-manager/image-jobs')
    records = set(store.glob('*.json'))
    original = (store / (job + '.json')).read_bytes()
    # urllib sends GET without a body and POST with an explicitly empty body.
    for body in (None, b''):
        page = request(
            '/server-manager/setup_image.cgi?job=' + job + '&navigation=1',
            body=body,
        )
        assert 'This form has expired' not in page, (
            'Progress link was treated as a new import'
        )
        assert re.search(
            r'<span data-second-print>\.\. done</span><br><div data-x-br></div>\s*'
                         r'<span data-first-print>Saving to storage \.\.</span>',
            page,
        ), 'Missing spacing between upload verification and storage progress'
    assert set(store.glob('*.json')) == records, (
        'Progress created another import job'
    )
    assert (store / (job + '.json')).read_bytes() == original, (
        'Progress changed its import job'
    )
    # A job ID cannot bypass token validation when a source is also submitted.
    page = request(
        '/server-manager/setup_image.cgi?job=' + job,
        {'install_type': 'upload', 'token': 'invalid'},
    )
    assert 'This form has expired' in page, (
        'New import accepted an invalid token'
    )


def delete(jobs, expect_blocked=False):
    """
    delete(jobs, [expect_blocked]): exercise confirmation and the bulk action.
    """
    fields = form() | {'job': ','.join(jobs)}
    page = request('/server-manager/delete_images.cgi', fields)
    assert 'Delete the selected images?' in page, (
        'Deletion confirmation missing'
    )
    page = request(
        '/server-manager/delete_images.cgi', fields | {'confirm': '1'}
    )
    starts = re.findall(r'<span data-first-print>(.*?)</span>', page, re.S)
    results = re.findall(r'<span data-second-print>(.*?)</span>', page, re.S)
    assert len(starts) == len(jobs) and len(results) == len(jobs), (
        'Unpaired deletion output'
    )
    assert all(
        start.startswith('Deleting ') and start.endswith(' image ..')
        for start in starts
    )
    assert (
        all(
            '.. failed : ' in result and 'used by virtual machine' in result
            for result in results
        )
        if expect_blocked
        else all(result == '.. done' for result in results)
    )
    if not expect_blocked:
        # A browser Back/resubmit sends the same confirmed POST again.
        replay = request(
            '/server-manager/delete_images.cgi', fields | {'confirm': '1'}
        )
        results = re.findall(
            r'<span data-second-print>(.*?)</span>', replay, re.S
        )
        assert len(results) == len(jobs), 'Replay results missing'
        assert all(
            result == '.. failed : image has already been deleted'
            for result in results
        ), results
        assert '.. done' not in replay, 'Stale deletion reports success'


def batch(fields):
    """batch(fields): return every job started by one multi-selection."""
    result = json.loads(request('/server-manager/image.cgi', fields))
    assert 'error' not in result, result
    for job in result['jobs']:
        # Track every batch member once for cleanup.
        if job not in created:
            created.append(job)
    return result['jobs']


# Fixture credentials stay in memory on the VM and are always removed.
password = secrets.token_urlsafe(36)
subprocess.run(
    ['perl', str(here / 'webmin-user.pl'), 'create'],
    input=password + '\n',
    text=True,
    check=True,
)
try:
    time.sleep(1)
    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {
            'user': 'cloudmin-ui-check',
            'pass': password,
            'page': '/server-manager/images.cgi',
        },
    )
    with tempfile.TemporaryDirectory(prefix='cloudmin-image-fixture-') as tmp:
        source = pathlib.Path(tmp) / 'fixture.qcow2'
        subprocess.run(
            ['qemu-img', 'create', '-q', '-f', 'qcow2', str(source), '32M'],
            check=True,
        )
        # Local imports open the source under an unprivileged UID.
        os.chmod(tmp, 0o755)
        os.chmod(source, 0o644)
        original = source.read_bytes()
        digest = hashlib.sha256(original).hexdigest()

        # Browser uploads use a bounded raw stream, not a multipart memory copy.
        fields = form() | {
            'install_type': 'upload',
            'filename': 'fixture.qcow2',
            'format': 'qcow2',
            'sha256': digest,
        }
        job = submit(fields)
        result = json.loads(
            request(
                '/server-manager/image-upload.cgi?job=' + job,
                body=original,
                headers={
                    'Content-Type': 'application/octet-stream',
                    'X-Cloudmin-Token': fields['token'],
                },
            )
        )
        assert not result.get('error'), result
        wait(job)
        volume('verify', job, digest)
        progress(job)
        print('Browser-upload endpoint and byte integrity: PASS', flush=True)

        # Installer uploads use the same progress handoff without
        # disk inspection.
        iso_root = pathlib.Path(tmp) / 'iso-root'
        iso_root.mkdir()
        (iso_root / 'fixture.txt').write_text(
            'Cloudmin upload progress fixture\n'
        )
        iso = pathlib.Path(tmp) / 'fixture.iso'
        subprocess.run(
            [
                'xorriso',
                '-as',
                'mkisofs',
                '-quiet',
                '-o',
                str(iso),
                str(iso_root),
            ],
            check=True,
            capture_output=True,
        )
        iso_bytes = iso.read_bytes()
        iso_digest = hashlib.sha256(iso_bytes).hexdigest()
        # The upload endpoint must preserve the ISO's bytes and selected format.
        iso_fields = form() | {
            'install_type': 'upload',
            'filename': 'fixture.iso',
            'format': 'iso',
            'sha256': iso_digest,
        }
        iso_job = submit(iso_fields)
        result = json.loads(
            request(
                '/server-manager/image-upload.cgi?job=' + iso_job,
                body=iso_bytes,
                headers={
                    'Content-Type': 'application/octet-stream',
                    'X-Cloudmin-Token': iso_fields['token'],
                },
            )
        )
        assert not result.get('error'), result
        wait(iso_job)
        # Exercise the real progress CGI after the background import completes.
        volume('verify', iso_job, iso_digest)
        progress(iso_job)
        print(
            'ISO upload, GET/POST progress, byte integrity and token checks: PASS',
            flush=True,
        )

        # A confirmed failed upload gets a new attempt token, while an invalid
        # CSRF request never receives one. Lost replies retain idempotency.
        retry_fields = form() | {
            'install_type': 'upload',
            'filename': 'fixture.qcow2',
            'format': 'qcow2',
            'sha256': digest,
        }
        failed = submit(retry_fields)
        upload_headers = {
            'Content-Type': 'application/octet-stream',
            'X-Cloudmin-Token': retry_fields['token'],
        }
        request(
            '/server-manager/image-upload.cgi?job=' + failed,
            body=b'invalid fixture disk',
            headers=upload_headers,
        )
        wait(failed, 'failed')
        rejected = json.loads(
            request(
                '/server-manager/image-upload.cgi?job=' + failed,
                body=original,
                headers=upload_headers | {'X-Cloudmin-Token': 'invalid'},
            )
        )
        assert rejected.get('error') and not rejected.get('retry_token'), (
            rejected
        )
        rejected = json.loads(
            request(
                '/server-manager/image-upload.cgi?job=' + failed,
                body=original,
                headers=upload_headers,
            )
        )
        assert rejected.get('error') and rejected.get('retry_token'), rejected
        rejected = json.loads(
            request('/server-manager/image.cgi', retry_fields)
        )
        assert rejected.get('error') and rejected.get('retry_token'), rejected
        retry_fields['token'] = rejected['retry_token']
        retried = submit(retry_fields)
        assert retried != failed, 'Retry reused a terminal failed job'
        result = json.loads(
            request(
                '/server-manager/image-upload.cgi?job=' + retried,
                body=original,
                headers=upload_headers
                | {'X-Cloudmin-Token': retry_fields['token']},
            )
        )
        assert not result.get('error'), result
        wait(retried)
        volume('verify', retried, digest)
        print(
            'Failed upload retries use a fresh authorized job and preserve disk bytes: PASS',
            flush=True,
        )

        # Limit regression runs to uploads without downloading catalogue images.
        if '--upload-only' in sys.argv:
            delete(created)
            print(
                'Renamed image form, progress and confirmed deletion: PASS',
                flush=True,
            )
            sys.exit(0)

        # Missing CSRF and invalid pool choices must not start a job.
        fields = form() | {
            'install_type': 'local',
            'path': str(source),
            'format': 'qcow2',
        }
        rejected = json.loads(
            request('/server-manager/image.cgi', fields | {'token': ''})
        )
        assert rejected.get('error'), 'Missing CSRF was accepted'
        rejected = json.loads(
            request('/server-manager/image.cgi', fields | {'pool': 'invalid'})
        )
        assert rejected.get('error'), 'Invalid storage was accepted'
        rejected = json.loads(
            request(
                '/server-manager/image.cgi',
                form()
                | {
                    'install_type': 'download',
                    'id': 'debian-13\ninvalid-image',
                },
            )
        )
        assert rejected.get('error'), 'Invalid batch member was accepted'

        # A host-file import must preserve the source and copy its exact bytes.
        job = submit(fields | {'sha256': digest})
        assert submit(fields | {'sha256': digest}) == job, (
            'Double-submit created another job'
        )
        wait(job)
        volume('verify', job, digest)
        assert source.read_bytes() == original, 'Source image was changed'
        print('Host-file import and duplicate submission: PASS', flush=True)

        # A defined VM must prevent deletion even when it is not running.
        volume('protect', job)
        delete([job], expect_blocked=True)
        volume('verify', job, digest)
        volume('unprotect', job)
        delete([job])
        wait(job, 'deleted')
        volume('absent', job)
        print('In-use protection and confirmed deletion: PASS', flush=True)

        # A bad checksum must fail before any usable libvirt volume appears.
        job = submit(
            form()
            | {
                'install_type': 'local',
                'path': str(source),
                'format': 'qcow2',
                'sha256': '0' * 64,
            }
        )
        status = wait(job, 'failed')
        assert 'checksum mismatch' in status['detail'].lower(), status
        volume('absent', job)
        print('Checksum failure and cleanup: PASS', flush=True)

        # One multi-select submission starts two real official OS downloads.
        fields = form() | {
            'install_type': 'download',
            'id': 'debian-13\nubuntu-24.04',
        }
        downloads = batch(fields)
        assert len(downloads) == 2 and len(set(downloads)) == 2
        assert batch(fields) == downloads, (
            'Batch resubmission created duplicate images'
        )
        page = request('/server-manager/images.cgi')
        assert all(job in page for job in downloads), (
            'Active downloads missing from checked table'
        )
        assert 'Delete selected images' in page and 'data-sortable="1"' in page

        # Reposting through the actual form action opens streamed progress.
        body = urllib.parse.urlencode(fields).encode()
        with opener.open(
            urllib.request.Request(
                base + '/server-manager/setup_image.cgi',
                data=body,
                headers={'Referer': base + '/server-manager/images.cgi'},
            ),
            timeout=90,
        ) as response:
            streamed = b''
            while (
                b'Downloading ' not in streamed and b'.. done' not in streamed
            ):
                line = response.readline()
                # The streaming response ends when the CGI closes
                # the connection.
                if not line:
                    break
                streamed += line
            assert (
                b'Adding Images' in streamed
                and b'Perl execution failed' not in streamed
            )
            # Read the remaining phases and check the actual themed output.
            streamed += response.read()
            progress = streamed.decode()
            for downloading in downloads:
                wait(downloading)
            assert 'Return to Return to' not in progress, (
                'Footer repeats Return to'
            )
            assert progress.count('Return to image manager') == 1, (
                'Image Manager return link missing or duplicated'
            )
            assert 'Received 0 bytes' not in progress, (
                'Storage reset the download counter'
            )
            assert 'Downloading image' not in progress, (
                'Internal download state is printed'
            )
            assert not re.search(r'>Ready<br', progress), (
                'Redundant Ready line is printed'
            )
            # Each image owns one parent step, with compact child steps
            # inside it.
            blocks = re.findall(
                r'<span data-first-print>Processing .*? image \.\.</span><br>\s*'
                                r'<ul data-indent-print>(.*?)</ul>\s*'
                                r'<span data-second-print>\.\. done</span>',
                progress,
                re.S,
            )
            assert len(blocks) == 2, (
                'Each image needs a parent step, indented details and final result',
                re.findall(
                    r'<span data-(?:first|second)-print>(.*?)</span>',
                    progress,
                    re.S,
                ),
            )
            assert all(
                block.count('Saving to storage') == 1 for block in blocks
            ), 'Image steps are not grouped together'
            # Check exact spacing and punctuation in the rendered Webmin markup.
            steps = re.findall(
                r'<span data-second-print>\.\. download complete</span><br>\s*'
                               r'<span data-first-print>Verifying vendor SHA-(?:256|512) checksum and checking disk image \.\.</span><br>\s*'
                               r'<span data-second-print>\.\. done</span><br>\s*'
                               r'<span data-first-print>Saving to storage \.\.</span><br>\s*'
                               r'<span data-second-print>\.\. done</span>',
                progress,
            )
            assert len(steps) == 2, (
                'Grouped download, checking and storage have incorrect spacing'
            )
            for section in re.findall(
                r'Saving to storage(.*?)\.\. (?:done|failed)', progress, re.S
            ):
                assert 'Received ' not in section, (
                    'Storage is shown as an HTTP download'
                )
                assert 'download complete' not in section, (
                    'Download completion appears after storage'
                )
        print(
            'Two-image batch and streamed progress after leaving the page: PASS',
            flush=True,
        )
        # Independently verify saved volumes and their visible library metadata.
        for job in downloads:
            wait(job)
            volume('verify', job)
        job = downloads[0]
        result = volume('verify', job)
        assert result['bytes'] > 50 * 1024 * 1024
        page = request('/server-manager/images.cgi?job=' + job)
        assert re.search(
            r'<span\b[^>]*data-image-checksum="'
            + re.escape(job)
            + r'"[^>]*>Passed</span>',
            page,
        )
        assert result['path'] in page
        assert 'data-sortable="1"' in page, 'Image library is not a DataTable'
        print(
            'Official Debian download, SHA-512 verification and library: PASS',
            flush=True,
        )

        # A direct URL must use its own input, not a stale hidden OS choice.
        catalogue = json.loads(
            (here.parent.parent / 'catalog/images.json').read_text()
        )
        debian = next(
            image for image in catalogue['images'] if image['id'] == 'debian-13'
        )
        arch = 'aarch64' if platform.machine() == 'aarch64' else 'x86_64'
        asset = next(
            asset for asset in debian['assets'] if asset['architecture'] == arch
        )
        url_job = submit(
            form()
            | {
                'install_type': 'url',
                'url': asset['url'],
                'id': 'unused-hidden-selection',
                'format': 'qcow2',
                'sha256': result['sha256'],
            }
        )
        wait(url_job)
        volume('verify', url_job, result['sha256'])
        print(
            'Direct HTTPS URL and supplied SHA-256 checksum: PASS', flush=True
        )

        # Cancel two additional downloads together and verify no partial disks.
        cancelling = batch(
            form()
            | {'install_type': 'download', 'id': 'almalinux-10\nrocky-linux-10'}
        )
        delete(cancelling)
        for cancelled in cancelling:
            wait(cancelled, 'deleted')
            volume('absent', cancelled)
        delete([downloads[1], url_job])
        for removed in [downloads[1], url_job]:
            wait(removed, 'deleted')
            volume('absent', removed)
        print(
            'Bulk download cancellation, volume deletion and cleanup: PASS',
            flush=True,
        )
        # Keep a downloaded image only when explicitly requested for
        # later tests.
        if '--keep-download' in sys.argv:
            keep.add(job)
            print('Kept downloaded Debian image:', result['path'], flush=True)

        # Opt in to additional vendor downloads when changing the catalogue.
        if '--extra-catalogue' in sys.argv:
            extra_ids = [
                'alpine-3.24',
                'centos-stream-10',
                'fedora-44',
                'opensuse-leap-16.0',
            ]
            extra = batch(
                form()
                | {'install_type': 'download', 'id': '\n'.join(extra_ids)}
            )
            assert len(extra) == len(extra_ids)
            for image_id, extra_job in zip(extra_ids, extra):
                wait(extra_job)
                volume('verify', extra_job)
                print(
                    'Catalogue download and checksum: PASS ' + image_id,
                    flush=True,
                )
            delete(extra)
            for extra_job in extra:
                wait(extra_job, 'deleted')
                volume('absent', extra_job)
finally:
    cleanup_errors = []
    for job in created:
        # Remove all fixture jobs except downloads explicitly retained.
        if job not in keep:
            try:
                volume('cleanup', job)
            except subprocess.CalledProcessError as error:
                print(
                    'Fixture cleanup needs attention:',
                    job,
                    error.stderr,
                    flush=True,
                )
                cleanup_errors.append(job)
    subprocess.run(['perl', str(here / 'webmin-user.pl'), 'delete'], check=True)
    # Make leftover fixture resources a test failure, even after other
    # checks pass.
    if cleanup_errors:
        raise RuntimeError(
            'Image fixture cleanup failed: ' + ', '.join(cleanup_errors)
        )
