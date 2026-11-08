#!/usr/bin/python3
"""
Exercise catalogue downloads and cache reuse through real virtual machine
creation.
"""

import http.cookiejar
import argparse
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import platform
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request

# Keep fixture accounts and guest changes on an authorized Linux test host.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on an authorized Linux test host as root')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--uncached',
    action='store_true',
    help='Download a separate fixture copy of Rocky 10',
)
args = parser.parse_args()
here = Path(__file__).resolve().parent
base = 'https://127.0.0.1:10000'
cookies = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(cookies),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
)
helper = here / 'webmin-user.pl'
user = 'cloudmin-ui-check'
password = secrets.token_urlsafe(36)
created = False
job_id = None
originals = {}
fixture_slug = None


class Form(HTMLParser):
    """Read control values from one Webmin form."""

    # __init__(self, page, action) limits extraction to the intended form.
    def __init__(self, page, action):
        super().__init__()
        self.action, self.active, self.select, self.textarea = (
            action,
            False,
            None,
            None,
        )
        self.fields = {}
        self.feed(page)

    # handle_starttag(self, tag, attrs) follows input, select and
    # textarea defaults.
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        # Ignore controls outside the requested form.
        if tag == 'form':
            self.active = a.get('action') == self.action
        # Other forms may reuse the same control names.
        if not self.active:
            return
        name = a.get('name')
        # Submit enabled named inputs and only checked selection controls.
        if tag == 'input' and name and 'disabled' not in a:
            # Unchecked checkboxes and radio buttons do not submit a value.
            if (
                a.get('type') not in ('submit', 'button', 'checkbox', 'radio')
                or 'checked' in a
            ):
                self.fields[name] = a.get('value', '')
        elif tag == 'select':
            # Remember which field owns the following options.
            self.select = name
        elif tag == 'option' and self.select:
            # An explicit selection overrides the browser's
            # first-option default.
            if self.select not in self.fields or 'selected' in a:
                self.fields[self.select] = a.get('value', '')
        elif tag == 'textarea':
            # Accumulate text nodes until this multiline control ends.
            self.textarea = name
            self.fields[name] = ''

    # handle_data(self, data) retains multiline control values as plain text.
    def handle_data(self, data):
        # Labels and unrelated text must not become submitted field values.
        if self.active and self.textarea:
            self.fields[self.textarea] += data

    # handle_endtag(self, tag) prevents controls from leaking across
    # form boundaries.
    def handle_endtag(self, tag):
        # Stop collecting controls at the form boundary.
        if tag == 'form':
            self.active = False
        elif tag == 'select':
            # Later options cannot overwrite the completed selection.
            self.select = None
        elif tag == 'textarea':
            # Later text belongs to the page, not the completed control.
            self.textarea = None


# request(path, [fields], [as_json]) submits only the generated fixture session.
def request(path, fields=None, as_json=False):
    data = None
    headers = {'Referer': base + '/server-manager/machine_form.cgi'}
    # GET requests have no body; mutations use the controller's expected format.
    if fields is not None:
        data = (
            json.dumps(fields)
            if as_json
            else urllib.parse.urlencode(fields, doseq=True)
        ).encode()
        headers['Content-Type'] = (
            'application/json'
            if as_json
            else 'application/x-www-form-urlencoded'
        )
    with opener.open(
        urllib.request.Request(base + path, data=data, headers=headers),
        timeout=90,
    ) as response:
        page = response.read().decode()
    assert 'Error - Perl execution failed' not in page, path + ' crashed'
    return page


# api(action, [fields]) uses the public controller, including its token checks.
def api(action, fields=None):
    result = json.loads(
        request(
            '/server-manager/api.cgi'
            + ('?action=' + action if fields is None else ''),
            None if fields is None else {'action': action, **fields},
            fields is not None,
        )
    )
    assert 'result' in result, result.get('error', 'Missing API result')
    return result['result']


# wait_job(ident) bounds asynchronous image and guest creation checks.
def wait_job(ident):
    deadline = time.monotonic() + 1800
    last = None
    while time.monotonic() < deadline:
        job = api('status', {'job': ident})
        progress = job.get('image_progress', {})
        state = (job['state'], job.get('phase'), progress.get('state'))
        if state != last:
            # Report phase changes without flooding output on every poll.
            print('Progress:', state, flush=True)
            last = state
        if job['state'] in ('complete', 'failed', 'cancelled'):
            # Surface the worker's terminal failure instead of polling forever.
            assert job['state'] == 'complete', job.get('error', job['state'])
            return job
        time.sleep(2)
    raise AssertionError('Creation did not finish within 30 minutes')


try:
    # Create a temporary administrator session without using host credentials.
    subprocess.run(
        ['perl', str(helper), 'create', 'authentic-theme', user],
        input=password + '\n',
        text=True,
        check=True,
    )
    created = True
    # Test clean-install defaults and restore any customized presets afterward.
    for kind in ('template', 'plan'):
        path = Path('/etc/webmin/server-manager') / (kind + 's.json')
        originals[path] = path.read_bytes() if path.exists() else None
        path.unlink(missing_ok=True)
    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {'user': user, 'pass': password, 'page': '/server-manager/index.cgi'},
    )
    # Opening the default form must select native Rocky without downloading it.
    options = api('options')
    image = next(
        i
        for i in options['catalogue_images']
        if i['id'] == 'catalogue:rocky-linux-10'
    )
    assert image['architecture'] == options['capabilities']['architecture']
    initial_imports = {i['id'] for i in options['images']}
    default = next(
        t
        for t in options['presets']['template']['entries']
        if t['id'] == '0' * 31 + '1'
    )
    assert default['settings']['image'] == image['id']
    form = Form(
        request('/server-manager/machine_form.cgi'), 'setup_machine.cgi'
    ).fields
    assert form['image'] == image['id'], form.get('image')
    assert form['install_source'] == 'cloud' and form['auth_type'] == 'password'
    assert initial_imports == {i['id'] for i in api('options')['images']}, (
        'Opening a form started a download'
    )
    if args.uncached:
        # A unique catalogue entry exercises downloading without hiding or
        # deleting the administrator's cached image.
        path = Path('/etc/webmin/server-manager/image-catalogue.json')
        originals[path] = path.read_bytes() if path.exists() else None
        fixture_slug = 'custom-creation-check-' + secrets.token_hex(4)
        entry = dict(
            image,
            id=fixture_slug,
            new='1',
            token=options['token'],
            name='Creation download fixture',
            min_disk_gib=math.ceil(
                int(image.get('min_disk_bytes') or 0) / 1024**3
            ),
        )
        request('/server-manager/save_catalog_image.cgi', entry)
        image = next(
            i
            for i in api('options')['catalogue_images']
            if i['id'] == 'catalogue:' + fixture_slug
        )
        assert not image['downloaded'], (
            'Fixture unexpectedly reused an existing import'
        )
    size = max(
        1,
        math.ceil(
            max(
                int(image.get('virtual_size') or 0),
                int(image.get('min_disk_bytes') or 0),
            )
            / 1024**3
        ),
    )
    pool = next(
        p
        for p in options['pools']
        if int(p['available']) > (size + 2) * 1024**3
    )
    fields = dict(
        template=default['id'],
        plan='0' * 31 + '1',
        image=image['id'],
        pool=pool['id'],
        network=options['networks'][0]['key'],
        install_source='cloud',
        cpus=1,
        memory_mib=512,
        disk_gib=size,
        username='cloudmin',
        auth_type='password',
        start=0,
        autostart=0,
    )
    # Create two stopped guests to compare the source volume across requests.
    source_id = None
    for iteration in range(2):
        submitted = dict(
            fields,
            token=api('options')['token'],
            name='cloudmin-create-check-catalogue-' + secrets.token_hex(3),
            password=secrets.token_urlsafe(32),
        )
        job = api('create', submitted)
        job_id = job['id']
        assert api('create', submitted)['id'] == job_id, (
            'Same request was not idempotent'
        )
        job = wait_job(job_id)
        inspect = json.loads(
            subprocess.check_output(
                ['perl', str(here / 'machine_fixture.pl'), 'inspect', job_id],
                text=True,
            )
        )
        assert not inspect['vm']['active'], 'Fixture unexpectedly booted'
        cache = [
            i
            for i in api('options')['images']
            if i.get('slug') == image['catalogue_id']
            and i.get('architecture') == image['architecture']
            and i.get('url') == image['url']
        ]
        assert cache, 'Completed creation did not retain its source image'
        matching = next(
            i for i in cache if i['volume_path'] == inspect['source']
        )
        assert job['image_progress']['state'] == 'ready'
        assert any(
            e['step'] == 'image' and e['state'] == 'done' for e in job['events']
        )
        if iteration:
            # The second request must reuse the first request's verified cache.
            assert matching['id'] == source_id, (
                'Second creation downloaded another copy'
            )
            assert {i['id'] for i in cache} == cached_ids, (
                'Cache reuse allocated another source'
            )
            print(
                'PASS: second creation reused the same verified source volume',
                flush=True,
            )
        else:
            # Record the first source whether it was already cached
            # or downloaded.
            source_id = matching['id']
            cached_ids = {i['id'] for i in cache}
            if not image.get('downloaded'):
                # An uncached catalogue entry must produce a new source record.
                assert source_id not in initial_imports
                print(
                    'PASS: uncached Rocky 10 downloaded, verified and used to create a stopped guest',
                    flush=True,
                )
            else:
                # An existing cache is also a valid starting point for
                # this test.
                print(
                    'PASS: existing Rocky 10 cache used to create a stopped guest',
                    flush=True,
                )
        subprocess.run(
            ['perl', str(here / 'machine_fixture.pl'), 'cleanup', job_id],
            check=True,
        )
        job_id = None
    print(
        'PASS: default template, native architecture, password mode and idempotent creation',
        flush=True,
    )
finally:
    try:
        if job_id:
            # Cancel unfinished creation before removing this
            # fixture's resources.
            current = api('status', {'job': job_id})
            if current['state'] not in ('complete', 'failed', 'cancelled'):
                # Wait for allocation to stop before tearing down its resources.
                api('cancel', {'job': job_id, 'token': api('options')['token']})
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    if api('status', {'job': job_id})['state'] in (
                        'complete',
                        'failed',
                        'cancelled',
                    ):
                        # The worker has acknowledged cancellation or finished.
                        break
                    time.sleep(1)
            subprocess.run(
                ['perl', str(here / 'machine_fixture.pl'), 'cleanup', job_id],
                check=True,
            )
    finally:
        try:
            if fixture_slug:
                # Remove only this run's import after its fixture guests
                # are gone.
                for path in Path(
                    '/var/webmin/modules/server-manager/image-jobs'
                ).glob('*.json'):
                    record = json.loads(path.read_text())
                    if record.get('slug') == fixture_slug:
                        # Match our slug, not other imports of the same URL.
                        subprocess.run(
                            [
                                'perl',
                                str(here / 'image-volume.pl'),
                                'cleanup',
                                record['id'],
                            ],
                            check=True,
                        )
        finally:
            # Configuration and account cleanup must survive import failures.
            for path, content in originals.items():
                if content is None:
                    # Remove configuration created only for this test.
                    path.unlink(missing_ok=True)
                else:
                    # Restore the administrator's exact pre-test settings.
                    path.write_bytes(content)
            if created:
                # Remove account data only after fixture account creation.
                subprocess.run(
                    [
                        'perl',
                        str(here / 'machine_fixture.pl'),
                        'forget-passwords',
                    ],
                    check=True,
                )
                subprocess.run(
                    ['perl', str(helper), 'delete', 'authentic-theme', user],
                    check=True,
                )
