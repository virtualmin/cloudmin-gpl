#!/usr/bin/env python3
"""
Check the installed license page and HTTP permissions without changing a
license.
"""

import http.cookiejar
import argparse
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

assert os.uname().sysname == 'Linux' and os.geteuid() == 0
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--browser',
    action='store_true',
    help='Also check rendered forms and progress in Chromium',
)
args = parser.parse_args()
helper = Path(__file__).with_name('webmin-user.pl')
base = 'https://127.0.0.1:10000'


class Inputs(HTMLParser):
    """Read form fields independently of theme attribute order."""

    # __init__(self, page) collects fields and link labels from one
    # HTML response.
    def __init__(self, page):
        super().__init__()
        self.values = {}
        self.links = []
        self.link = None
        self.has_error = False
        self.feed(page)

    # handle_starttag(self, tag, attrs) records controls or begins a link label.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Inspect error elements, not translated labels in the theme's scripts.
        if 'data-fatal-error-text' in attrs or (
            tag == 'body' and 'err-body' in attrs.get('class', '').split()
        ):
            self.has_error = True
        if tag == 'input':
            # Attribute order and quote style vary between themes.
            self.values[attrs.get('name')] = attrs.get('value', '')
        elif tag == 'a':
            # Keep the destination while later data callbacks collect its text.
            self.link = [attrs.get('href'), '']

    # handle_data(self, data) appends text only while inside an anchor.
    def handle_data(self, data):
        # Collect text only while an anchor is open.
        if self.link is not None:
            self.link[1] += data

    # handle_endtag(self, tag) completes the current anchor and resets
    # its state.
    def handle_endtag(self, tag):
        # Store a complete link so license errors can be checked by destination.
        if tag == 'a' and self.link is not None:
            self.links.append(self.link)
            self.link = None


# assert_license_link(page) checks the error page's fixed repair destination.
def assert_license_link(page):
    """
    Check the rendered label and destination without depending on the theme.
    """
    assert [
        '/server-manager/pro/license.cgi',
        'System → Settings → License Manager',
    ] in Inputs(page).links


# Use temporary users so each role and theme gets an independent Webmin session.
for theme in ('gray-theme', 'authentic-theme'):
    for mode in ('create', 'create-readonly', 'create-other'):
        user = 'cloudmin-ui-check-' + secrets.token_hex(4)
        password = secrets.token_urlsafe(36)
        created = False
        try:
            subprocess.run(
                ['perl', str(helper), mode, theme, user],
                input=password + '\n',
                text=True,
                check=True,
            )
            created = True
            time.sleep(1)
            # The test VM uses a local certificate; bypass proxies for loopback.
            cookies = http.cookiejar.CookieJar()
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}),
                urllib.request.HTTPCookieProcessor(cookies),
                urllib.request.HTTPSHandler(
                    context=ssl._create_unverified_context()
                ),
            )

            # request(path, [fields]) uses a real Webmin session on this
            # test VM.
            def request(path, fields=None):
                data = (
                    urllib.parse.urlencode(fields).encode()
                    if fields is not None
                    else None
                )
                req = urllib.request.Request(
                    base + path,
                    data=data,
                    headers={
                        'Referer': base + '/server-manager/pro/license.cgi'
                    },
                )
                try:
                    response = opener.open(req, timeout=35)
                except urllib.error.HTTPError as error:
                    # Permission refusals are responses under test, not
                    # transport errors.
                    response = error
                with response:
                    body = response.read().decode()
                assert 'Error - Perl execution failed' not in body, (
                    path + ' crashed'
                )
                return body

            request('/session_login.cgi')
            request(
                '/session_login.cgi',
                {'user': user, 'pass': password, 'page': '/'},
            )
            page = request('/server-manager/pro/license.cgi')
            if mode == 'create-other':
                # Users without module access must see neither controls
                # nor status.
                assert (
                    'name="license_key"' not in page
                    and 'License details' not in page
                )
                print(theme + ': unrelated module user refused')
                continue
            # Both administrator roles share one table without
            # duplicate navigation.
            assert 'License Manager' in page and 'License details' in page, (
                'Missing license page'
            )
            assert page.count('License details') == 1, 'Duplicate license table'
            assert 'Validate and Save License' not in page, (
                'Separate license-entry form remains'
            )
            assert 'Open System' not in page, (
                'Page warning sends users back to itself'
            )
            assert 'legacy license server' not in page, (
                'Obsolete server message is visible'
            )
            assert 'host overview' in page, 'Footer destination is missing'
            status = json.loads(
                request('/server-manager/api.cgi?action=license')
            )['result']
            if (
                mode == 'create'
                and status['edition'] == 'Pro'
                and status['state'] != 'missing'
            ):
                # Review real credentials but never confirm their removal here.
                assert 'Deregister License' in page, (
                    'Deregister button is missing'
                )
                token = Inputs(page).values['token']
                review = request(
                    '/server-manager/pro/update_license.cgi',
                    {'deregister': 'Deregister License', 'token': token},
                )
                review_fields = Inputs(review).values
                assert review_fields.get('confirm') == '1', (
                    'Confirmation is missing'
                )
                assert 'Remove this host' in review, (
                    'Removal warning is missing'
                )
                assert 'license_key' not in review_fields, (
                    'Confirmation copies credentials'
                )
                assert 'data-first-print' not in review, (
                    'Review started removal'
                )
                # Neither review nor an unconfirmed API call may alter
                # the license.
                unchanged = Inputs(
                    request('/server-manager/pro/license.cgi')
                ).values
                assert (
                    unchanged['license_key']
                    == Inputs(page).values['license_key']
                ), 'Review changed the license'
                refused = json.loads(
                    request(
                        '/server-manager/api.cgi',
                        {'action': 'deregister_license', 'token': token},
                    )
                )
                assert 'Confirm license deregistration' in refused['error'], (
                    'API removed a license without confirmation'
                )
                print(
                    theme
                    + ': deregistration confirmation leaves the current license unchanged'
                )
            if status['state'] == 'missing':
                # Missing-license advice depends on whether the user can
                # edit it.
                if mode == 'create-readonly':
                    # Read-only users need an administrator to
                    # supply credentials.
                    assert (
                        'Ask an administrator to add a Cloudmin Pro license'
                        in page
                    )
                else:
                    # Writable users get setup fields without an empty
                    # recheck action.
                    assert (
                        'Add your Cloudmin Pro license using the fields above to make changes.'
                        in page
                    )
                    assert 'Set Up License' in page
                    assert (
                        'name=\"recheck\"' not in page
                        and "name='recheck'" not in page
                    )
            assert 'key' not in status and 'license_key' not in status
            fields = Inputs(page).values
            if mode == 'create' and status['edition'] == 'Pro':
                # Only editable Pro views may reveal the saved license key.
                assert 'license_key' in fields, 'License key field is missing'
                if status['state'] != 'missing':
                    # An installed license should populate the visible
                    # text field.
                    assert fields['license_key'], 'Saved license key is missing'
            else:
                # Neither read-only nor GPL views expose a credential field.
                assert 'license_key' not in fields, (
                    'Unexpected license key field'
                )
            # Both the API and form must reject GET changes before doing
            # any work.
            bad_get = json.loads(
                request('/server-manager/api.cgi?action=check_license')
            )
            assert 'Use POST' in bad_get['error'], (
                'License API accepts GET mutations'
            )
            form_get = request(
                '/server-manager/pro/update_license.cgi?action=check_license'
            )
            assert 'Use POST' in form_get, 'License form accepts GET mutations'
            denied = json.loads(
                request(
                    '/server-manager/api.cgi',
                    {'action': 'check_license', 'token': 'invalid'},
                )
            )
            if mode == 'create-readonly':
                # Read-only enforcement precedes token validation.
                assert 'license_key' not in fields, (
                    'Read-only page offers credential editing'
                )
                assert 'read-only' in denied['error']
            elif status['edition'] == 'Pro':
                # Writable Pro sessions still need valid signed tokens
                # and input.
                assert 'form has expired' in denied['error']
                # Malformed input tests repair permissions without contacting
                # the server.
                assert 'update_license.cgi' in page, (
                    'License form does not use the progress page'
                )
                failed = request(
                    '/server-manager/pro/update_license.cgi',
                    {
                        'update': 'Change License',
                        'serial': 'invalid',
                        'license_key': 'do-not-echo-fixture-key',
                        'token': fields['token'],
                    },
                )
                assert 'Enter a valid license serial number and key' in failed
                assert 'do-not-echo-fixture-key' not in failed
                assert 'data-first-print' not in failed, (
                    'Malformed input started a license check'
                )
                if status['state'] == 'missing':
                    # A missing license can be rechecked without
                    # changing credentials.
                    progress = request(
                        '/server-manager/pro/update_license.cgi',
                        {
                            'recheck': 'Recheck License',
                            'token': fields['token'],
                        },
                    )
                    assert (
                        'data-first-print' in progress
                        and 'Checking the license' in progress
                    )
                    assert (
                        'data-second-print' in progress
                        and '.. failed : license required</span>' in progress
                    )
                    assert not Inputs(progress).has_error, (
                        'License progress opened an error page'
                    )
                    assert any(
                        href and href.endswith('license.cgi')
                        for href, _ in Inputs(progress).links
                    )
                    print(theme + ': license check uses native progress output')
                if not status['allowed']:
                    # Licensing gates mutations without hiding
                    # ordinary controls.
                    blocked = json.loads(
                        request(
                            '/server-manager/api.cgi',
                            {'action': 'create', 'token': fields['token']},
                        )
                    )
                    assert 'License Manager' in blocked['error']
                    assert (
                        'System -> Settings -> License Manager'
                        in blocked['error']
                    )
                    assert '<a' not in blocked['error'], (
                        'API error contains HTML'
                    )
                    assert 'Existing machines' in blocked['error']
                    dashboard = request('/server-manager/index.cgi')
                    assert 'machine_form.cgi' in dashboard, (
                        'Creation control was hidden'
                    )
                    assert (
                        'Changes through Cloudmin are blocked' not in dashboard
                    ), 'License alert on overview'

                    # Preparation must reach the ordinary form POST even without
                    # a license.
                    attempt = json.loads(
                        request(
                            '/server-manager/submission.cgi',
                            {
                                'kind': 'vm',
                                'operation': 'snapshot_create',
                                'token': fields['token'],
                                'proposed': secrets.token_hex(16),
                            },
                        )
                    )
                    assert attempt.get('attempt'), (
                        'License blocked submission preparation'
                    )
                    guests = json.loads(
                        request('/server-manager/api.cgi?action=machines')
                    )['result']
                    if guests:
                        # Open a real guest's form when the test host has one.
                        guest_id = guests[0]['id']
                        snapshot = request(
                            '/server-manager/snapshots.cgi?id='
                            + guest_id
                            + '&view=create'
                        )
                        snapshot_fields = Inputs(snapshot).values
                        assert (
                            snapshot_fields.get('action') == 'snapshot_create'
                        ), 'Snapshot form was hidden'
                        assert (
                            'Changes through Cloudmin are blocked'
                            not in snapshot
                        ), 'License alert on form'
                    else:
                        # The controller checks licensing before looking up
                        # this guest.
                        snapshot_fields = {
                            'id': '00000000-0000-0000-0000-000000000001',
                            'action': 'snapshot_create',
                            'token': fields['token'],
                        }
                    snapshot_fields['attempt'] = attempt['attempt']
                    failed = request(
                        '/server-manager/snapshots.cgi', snapshot_fields
                    )
                    assert (
                        'License Manager' in failed
                        and 'Existing machines' in failed
                    )
                    assert_license_link(failed)
                    assert 'label' not in Inputs(failed).values, (
                        'Snapshot error was rendered inside the form'
                    )

                    # Storage changes use the same standard error page, not an
                    # inline alert.
                    storage = request('/server-manager/storage.cgi?tab=pools')
                    assert 'Changes through Cloudmin are blocked' not in storage
                    assert 'Create Storage Pool' in storage, (
                        'Storage creation control was hidden'
                    )
                    failed = request(
                        '/server-manager/storage.cgi',
                        {
                            'action': 'create',
                            'token': fields['token'],
                            'type': 'dir',
                            'name': 'license-check-must-not-create',
                            'path': '/var/tmp/license-check-must-not-create',
                        },
                    )
                    assert (
                        'License Manager' in failed
                        and 'Existing machines' in failed
                    )
                    assert_license_link(failed)
                    assert 'name' not in Inputs(failed).values, (
                        'Storage error was rendered inside the form'
                    )
                    # Upload preparation forwards denial through the
                    # normal form.
                    upload = json.loads(
                        request(
                            '/server-manager/submission.cgi',
                            {
                                'kind': 'image',
                                'token': fields['token'],
                                'proposed': secrets.token_hex(16),
                            },
                        )
                    )
                    assert upload.get('native_submit') and upload.get(
                        'image_attempts'
                    )
                    failed = request(
                        '/server-manager/setup_image.cgi',
                        {
                            'install_type': 'upload',
                            'token': fields['token'],
                            'image_attempts': upload['image_attempts'],
                        },
                    )
                    assert (
                        'License Manager' in failed
                        and 'Existing machines' in failed
                    )
                    assert_license_link(failed)
                    assert 'install_type' not in Inputs(failed).values, (
                        'Upload error was rendered inside the form'
                    )
                    print(
                        theme
                        + ': controls visible, preparation allowed, saves use error pages'
                    )
            else:
                # GPL retains its edition refusal rather than a Pro token error.
                assert 'Cloudmin Pro' in denied['error']
            if args.browser and mode == 'create' and status['edition'] == 'Pro':
                # Browser checks must leave the host's saved
                # credentials unchanged.
                from license_browser import check_license_browser

                before = Inputs(
                    request('/server-manager/pro/license.cgi')
                ).values
                check_license_browser(cookies, theme)
                after = Inputs(
                    request('/server-manager/pro/license.cgi')
                ).values
                assert all(
                    before.get(k) == after.get(k)
                    for k in ('serial', 'license_key')
                ), 'Browser changed saved credentials'
            print(
                theme
                + ': '
                + mode
                + ' page, API, POST and secret handling passed'
            )
        finally:
            if created:
                # Remove only this fixture user, including after
                # failed assertions.
                subprocess.run(
                    ['perl', str(helper), 'delete', theme, user], check=True
                )
