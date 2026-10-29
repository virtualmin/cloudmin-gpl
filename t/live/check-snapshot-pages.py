#!/usr/bin/python3
"""Exercise snapshot pages, confirmations, permissions and theme layout."""
import base64
import argparse
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

# Account and snapshot fixtures belong on the authorized Linux host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt
import websocket

parser = argparse.ArgumentParser()
parser.add_argument('--screenshots-dir', type=Path)
parser.add_argument('--theme', choices=['authentic-theme', 'gray-theme'])
parser.add_argument('--allow-host-jobs', action='store_true', help='Allow integration jobs in the host journal')
options = parser.parse_args()
# Tests use the real controller; its audit history remains after fixture cleanup.
if not options.allow_host_jobs:
    parser.error('This integration test requires --allow-host-jobs; its audit history remains on the host')
# Create an artifact directory only when screenshots were requested.
if options.screenshots_dir:
    options.screenshots_dir.mkdir(parents=True, exist_ok=True)

module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
base = 'https://127.0.0.1:10000'
username = 'cloudmin-ui-check'
connection = libvirt.open('qemu:///system')
directory = Path(tempfile.mkdtemp(prefix='cloudmin-snapshot-ui-', dir='/var/lib/libvirt/images'))
directory.chmod(0o755)
name = 'cloudmin-snapshot-ui-' + uuid.uuid4().hex[:8]
pool = guest = None
created_user = False


class Inputs(HTMLParser):
    """Collect generated fields for an actual confirmation POST."""
    # __init__(self, page) parses the confirmation form controls.
    def __init__(self, page):
        super().__init__()
        self.values = {}
        self.feed(page)

    # handle_starttag(self, tag, attrs) collects successful named inputs.
    def handle_starttag(self, tag, attrs):
        # Ignore page elements that cannot supply an input value.
        if tag == 'input':
            attrs = dict(attrs)
            # Unchecked switches and radio buttons are absent from a browser POST.
            if attrs.get('type') in ('checkbox', 'radio') and 'checked' not in attrs:
                return
            # Unnamed inputs do not contribute submitted fields.
            if attrs.get('name'):
                self.values[attrs['name']] = attrs.get('value', '')


# request(path, [fields], [client]) uses an in-memory Webmin session.
def request(path, fields=None, client=None):
    data = urllib.parse.urlencode(fields).encode() if fields is not None else None
    req = urllib.request.Request(base + path, data=data, headers={'Referer': base + '/server-manager/snapshots.cgi'})
    page = (client or opener).open(req, timeout=90).read().decode()
    assert 'Error - Perl execution failed' not in page, page[:500]
    return page


# check_readonly(theme, path) checks Webmin access to snapshot operations.
def check_readonly(theme, path):
    reader = 'cloudmin-frame-check'
    password = secrets.token_urlsafe(36)
    subprocess.run(['perl', str(helper), 'create-readonly', theme, reader],
                   input=password + '\n', text=True, check=True)
    try:
        time.sleep(1)
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
        request('/session_login.cgi', client=client)
        request('/session_login.cgi', {'user': reader, 'pass': password, 'page': path}, client)
        response = request('/server-manager/api.cgi?action=snapshots&id=' + guest.UUIDString(), client=client)
        assert response.lstrip().startswith('{'), 'Read-only API did not return JSON'
        data = json.loads(response)
        assert 'error' not in data, data.get('error')
        assert len(data['result']['snapshots']) == 2 and 'revision' not in data['result'], data
        for page in (path, '/server-manager/snapshots.cgi'):
            html = request(page, client=client)
            assert 'Before upgrade &lt;test&gt;' in html and 'After upgrade' in html, 'Read-only history is missing'
            assert 'view=restore' not in html and 'view=delete' not in html and 'view=create' not in html
        denied = json.loads(request('/server-manager/api.cgi',
            {'action': 'snapshot_create', 'id': guest.UUIDString(), 'token': 'invalid'}, client))
        assert 'read-only' in denied.get('error', ''), denied
    finally:
        subprocess.run(['perl', str(helper), 'delete', theme, reader], check=True)


# render(cookies, path, screenshot, points) checks browser controls and layout.
# points maps snapshot IDs to their expected default restart choices.
def render(cookies, path, screenshot, points):
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Install Chromium for the browser check'
    with tempfile.TemporaryDirectory(prefix='cloudmin-snapshot-browser-') as profile:
        process = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--no-default-browser-check', '--disable-background-networking', '--disable-sync',
            '--window-size=1440,1000', '--user-data-dir=' + profile, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        socket = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            socket = websocket.create_connection('ws://127.0.0.1:' + port + route, timeout=30, suppress_origin=True)
            serial, session = 0, None

            # call(method, [params]) receives the matching browser response.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                payload = {'id': serial, 'method': method, 'params': params or {}}
                # Use a target session only after the fixture tab is attached.
                if session:
                    payload['sessionId'] = session
                socket.send(json.dumps(payload))
                while True:
                    reply = json.loads(socket.recv())
                    # Ignore unsolicited events until the pending command is answered.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(js) uses the content document, inside a frame or at top level.
            def evaluate(js):
                result = call('Runtime.evaluate', {'expression': '(window.frames.right || window).eval(' + json.dumps(js) + ')', 'returnByValue': True})
                assert 'exceptionDetails' not in result, result
                return result.get('result', {}).get('value')

            target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
            for domain in ('Network', 'Page', 'Runtime'):
                call(domain + '.enable')
            for cookie in cookies:
                call('Network.setCookie', {'name': cookie.name, 'value': cookie.value, 'url': base, 'path': cookie.path, 'secure': True})
            # Enter through the theme shell, as a real navigation click does.
            call('Page.navigate', {'url': base + '/'})
            deadline = time.monotonic() + 30
            while not evaluate('!!(top.document.querySelector("aside") || top.frames.left)') and time.monotonic() < deadline:
                time.sleep(.25)
            # Frame themes need their Cloudmin navigation loaded separately.
            if evaluate('!!top.frames.left'):
                evaluate('top.frames.left.location = "/left.cgi?mode=server-manager"')
            documents = '[top.document, ...Array.from(top.frames, w => w.document)]'
            overview = '(' + documents + ').flatMap(d => Array.from(d.querySelectorAll("a[href]"))).find(a => new URL(a.href).pathname.endsWith("/server-manager/index.cgi"))'
            deadline = time.monotonic() + 30
            while not evaluate('!!(' + overview + ')') and time.monotonic() < deadline:
                time.sleep(.25)
            assert evaluate('!!(' + overview + ')'), 'Cloudmin navigation is missing'
            # Use the shell's module link to exercise its normal page loader.
            # This layout check must not depend on which user VM is selected.
            evaluate('(() => { const a = ' + overview + '; a.href = ' + json.dumps(path) + '; a.click(); })()')
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                # Measure action controls only when the feed contains snapshot actions.
                if evaluate('!!document.querySelector(".cloudmin-snapshot-feed .ui_action")'):
                    break
                time.sleep(.25)
            assert evaluate('!!document.querySelector(".cloudmin-snapshot-feed .ui_action")'), 'Snapshot history did not render: ' + str(evaluate('document.body.innerText.slice(0, 1600)'))
            assert evaluate('document.querySelectorAll(".cloudmin-snapshot-current").length') == 1
            # The shared widget draws its visible button on the inner span.
            buttons = evaluate('Array.from(document.querySelectorAll(".cloudmin-snapshot-history .ui_action_content")).map(b => ({text:b.textContent.trim(),height:b.getBoundingClientRect().height,font:parseFloat(getComputedStyle(b).fontSize),icon:!!b.querySelector("svg")}))')
            assert all(button['height'] >= button['font'] * 1.5 and button['icon'] for button in buttons), buttons
            assert evaluate('(() => { const p = document.querySelector(".cloudmin-snapshot-intro"), c = document.querySelector(".cloudmin-snapshot-history"); return c.getBoundingClientRect().top - p.getBoundingClientRect().bottom >= parseFloat(getComputedStyle(p).marginBottom) - 1 && parseFloat(getComputedStyle(p).marginBottom) > 0; })()'), 'Introduction must have the configured gap before history'
            assert evaluate('!document.body.innerText.includes("<span data-filesize")'), 'Date markup is shown as text'
            assert evaluate('!Array.from(document.querySelectorAll(".cloudmin-snapshots-page a")).some(a => a.textContent.trim() === "All Snapshots")'), 'VM history must not link to the host overview'
            assert evaluate('document.querySelectorAll(".cloudmin-snapshot-history.ui_card").length === 1 && !document.querySelector(".cloudmin-snapshot-entry .ui_card")'), 'History must share a single feed card'
            assert evaluate('document.querySelectorAll(".cloudmin-snapshot-feed .ui_feed_item").length === 3'), 'Saved and working states need separate events'
            assert evaluate('parseFloat(getComputedStyle(document.querySelector(".cloudmin-snapshot-history .ui_card_body")).paddingLeft) >= 12'), 'History is cramped'
            assert evaluate('Array.from(document.querySelectorAll(".cloudmin-snapshot-entry")).every(e => e.querySelector(".cloudmin-snapshot-actions").getBoundingClientRect().left >= e.querySelector(".cloudmin-snapshot-details").getBoundingClientRect().right)'), 'Actions overlap snapshot details'
            assert evaluate('Array.from(document.querySelectorAll(".cloudmin-snapshot-feed .ui_action")).every(e => !getComputedStyle(e).textDecorationLine.includes("underline"))'), 'Action buttons must not be underlined'
            assert evaluate('document.querySelector(".cloudmin-snapshot-working").textContent.includes("After upgrade")'), 'Current state must name its actual parent'
            assert evaluate('document.documentElement.scrollWidth <= innerWidth + 5'), 'History overflows the viewport'
            # Retain the rendered feed only when an artifact path was supplied.
            if screenshot:
                picture = call('Page.captureScreenshot', {'format': 'png'})
                Path(screenshot).write_bytes(base64.b64decode(picture['data']))
            # A narrow panel must put controls below the details without overflow.
            evaluate('document.querySelector(".cloudmin-snapshots-page").style.width = "340px"')
            assert evaluate('Array.from(document.querySelectorAll(".cloudmin-snapshot-entry")).every(e => e.querySelector(".cloudmin-snapshot-actions").getBoundingClientRect().top >= e.querySelector(".cloudmin-snapshot-details").getBoundingClientRect().bottom)'), 'Narrow history actions must wrap below details'
            assert evaluate('(() => { const e = document.querySelector(".cloudmin-snapshot-history"); return e.scrollWidth <= e.clientWidth + 2; })()'), 'Narrow history overflows its card'
            evaluate('document.querySelector(".cloudmin-snapshots-page").style.width = ""')
            # A missing agent defaults to shutdown; the visible warning and
            # submitted mode must follow the actual checkbox in either theme.
            evaluate('document.querySelector(".cloudmin-snapshot-history a[href*=\\"view=create\\"]").click()')
            deadline = time.monotonic() + 30
            while not evaluate('!!document.querySelector("input[name=shutdown]")') and time.monotonic() < deadline:
                time.sleep(.25)
            assert evaluate('document.querySelector("input[name=shutdown]")?.checked'), 'Shutdown must start selected'
            assert evaluate('!!document.querySelector(".alert-warning .fa-exclamation-triangle, .alert-warning .ui_alert_icon svg")'), 'Missing agent needs an orange alert with an icon'
            assert evaluate('document.querySelector("input[name=mode]").value') == 'prepared'
            assert evaluate('document.getElementById("snapshot-unprepared-warning").getClientRects().length') == 0, 'Red warning should start hidden'
            assert evaluate('(() => { const s = document.querySelector(".ui_submit").getBoundingClientRect(), c = document.querySelector(".cloudmin-snapshot-restart").getBoundingClientRect(); return c.left >= s.right && c.top < s.bottom && c.bottom > s.top; })()'), 'Shutdown choice must sit beside Create snapshot'
            for checked in (False, True, False, True):
                evaluate('document.querySelector("input[name=shutdown]").click()')
                assert evaluate('document.querySelector("input[name=shutdown]").checked') is checked
                assert evaluate('document.querySelector("input[name=mode]").value') == ('prepared' if checked else 'unprepared')
                assert evaluate('document.getElementById("snapshot-unprepared-warning").getClientRects().length > 0') is not checked
            assert evaluate('!!document.querySelector("#snapshot-unprepared-warning.alert-danger .fa-bolt, #snapshot-unprepared-warning.alert-danger .ui_alert_icon svg")'), 'Unprepared mode needs a red warning and power-loss icon'
            assert evaluate('document.getElementById("snapshot-unprepared-warning").textContent.includes("power loss")')
            print('PASS: default shutdown choice, inline submit, orange alert and unprepared-mode warning', flush=True)
            # Leave the test form through the theme's normal discard prompt.
            evaluate('Array.from(document.querySelectorAll("a[href]")).find(a => a.textContent.trim().toLowerCase() === "return to snapshots").click()')
            deadline = time.monotonic() + 30
            while not evaluate('!!document.querySelector(".cloudmin-snapshot-feed")') and time.monotonic() < deadline:
                evaluate('document.querySelector(".bootbox-o__f_m-beforeclose-prompt")?.closest(".modal")?.querySelector("[data-bb-handler=danger]")?.click()')
                time.sleep(.25)
            assert evaluate('!!document.querySelector(".cloudmin-snapshot-feed")'), 'Returning to history failed: ' + str(evaluate('document.body.innerText[-1600:]'))
            # Native saved power state must reach the real checkbox in each theme.
            for point, expected in points.items():
                evaluate('Array.from(document.querySelectorAll(".cloudmin-snapshot-feed a[href]"))'
                         '.find(a => new URL(a.href).searchParams.get("view") === "restore" && '
                         'new URL(a.href).searchParams.get("snapshot") === '+json.dumps(point)+').click()')
                deadline = time.monotonic() + 30
                while not evaluate('!!document.querySelector("input[name=restart]")') and time.monotonic() < deadline:
                    time.sleep(.25)
                assert evaluate('document.querySelector("input[name=restart]")?.checked') is expected, 'Restore default differs from snapshot power state'
                assert evaluate('!!document.querySelector(".ui_confirmation .alert-info")'), 'Restore preparation must use an informational alert'
                assert evaluate('(() => { const s = document.querySelector(".ui_confirmation .ui_submit").getBoundingClientRect(), c = document.querySelector(".cloudmin-snapshot-restart").getBoundingClientRect(); return c.left >= s.right && c.top < s.bottom && c.bottom > s.top; })()'), 'Restart choice must be beside the Restore submit'
                # Capture the restore confirmation when screenshots were requested.
                if screenshot:
                    picture = call('Page.captureScreenshot', {'format': 'png'})
                    Path(screenshot).with_name(Path(screenshot).stem + '-restore.png').write_bytes(base64.b64decode(picture['data']))
                evaluate('Array.from(document.querySelectorAll("a[href]"))'
                         '.find(a => a.textContent.trim().toLowerCase() === "return to snapshots").click()')
                deadline = time.monotonic() + 30
                while not evaluate('!!document.querySelector(".cloudmin-snapshot-feed")') and time.monotonic() < deadline:
                    time.sleep(.25)
            # Visit delete through the real action and verify the shared confirmation.
            evaluate('document.querySelector(".cloudmin-snapshot-feed a[href*=\\"view=delete\\"]").click()')
            deadline = time.monotonic() + 30
            while not evaluate('!!document.querySelector(".ui_confirmation")') and time.monotonic() < deadline:
                time.sleep(.25)
            assert evaluate('!!document.querySelector(".ui_confirmation")'), 'Standard delete confirmation is missing'
            assert evaluate('!document.querySelector(".cloudmin-snapshot-history")'), 'Confirmation must have no history toolbar'
            # Capture the delete confirmation for optional visual review.
            if screenshot:
                picture = call('Page.captureScreenshot', {'format': 'png'})
                Path(screenshot).with_name(Path(screenshot).stem + '-delete.png').write_bytes(base64.b64decode(picture['data']))
            # The host overview is reached through the normal Cloudmin navigation.
            host_link = '(' + documents + ').flatMap(d => Array.from(d.querySelectorAll("a[href]"))).find(a => new URL(a.href).pathname.endsWith("/server-manager/snapshots.cgi") && !new URL(a.href).searchParams.has("id"))'
            assert evaluate('!!(' + host_link + ')'), 'Host snapshot navigation is missing'
            evaluate('(' + host_link + ').click()')
            deadline = time.monotonic() + 30
            while not evaluate('!!document.querySelector(".cloudmin-snapshot-summary")') and time.monotonic() < deadline:
                time.sleep(.25)
            cards = evaluate('Array.from(document.querySelectorAll(".cloudmin-snapshot-summary .ui_stat")).map(c => ({border:parseFloat(getComputedStyle(c).borderTopWidth),padding:parseFloat(getComputedStyle(c).paddingLeft),top:c.getBoundingClientRect().top}))')
            assert len(cards) == 3 and all(c['border'] >= 1 and c['padding'] >= 12 for c in cards), cards
            assert max(c['top'] for c in cards) - min(c['top'] for c in cards) < 2, 'Overview cards are not in one row'
            assert evaluate('!document.body.innerText.includes("<span data-filesize") && !document.body.innerText.includes("snapshot_guests") && !document.body.innerText.includes("No snapshots yet")'), 'Overview contains broken or redundant text'
            assert evaluate('document.body.innerText.includes("Total snapshots") && document.body.innerText.includes("Allocated size") && document.body.innerText.includes("Virtual machine name")')
            assert evaluate('!document.querySelector(".cloudmin-snapshot-guests, #hiddendiv_snapshot_guests")'), 'The separate VM section must be absent'
            # Capture the host snapshot overview when screenshots were requested.
            if screenshot:
                picture = call('Page.captureScreenshot', {'format': 'png'})
                Path(screenshot).with_name(Path(screenshot).stem + '-overview.png').write_bytes(base64.b64decode(picture['data']))
            # Host actions open the correct snapshot directly and retain this list
            # as their return destination. Visiting a review must not mutate it.
            for action in ('restore', 'delete'):
                for point in points:
                    evaluate('Array.from(document.querySelectorAll(".cloudmin-snapshot-actions a[href]"))'
                             '.find(a => new URL(a.href).searchParams.get("view") === ' + json.dumps(action) + ' && '
                             'new URL(a.href).searchParams.get("snapshot") === ' + json.dumps(point) + ').click()')
                    deadline = time.monotonic() + 30
                    while not evaluate('!!document.querySelector(".ui_confirmation")') and time.monotonic() < deadline:
                        time.sleep(.25)
                    assert evaluate('document.querySelector("input[name=snapshot]")?.value') == point
                    assert evaluate('document.querySelector("input[name=from]")?.value') == 'all'
                    evaluate('Array.from(document.querySelectorAll("a[href]"))'
                             '.find(a => a.textContent.trim().toLowerCase() === "return to all snapshots").click()')
                    deadline = time.monotonic() + 30
                    while not evaluate('!!document.querySelector(".cloudmin-snapshot-summary")') and time.monotonic() < deadline:
                        time.sleep(.25)
        finally:
            if socket:
                # Let Chromium finish writing its temporary profile before removal.
                try:
                    call('Browser.close')
                except websocket.WebSocketException:
                    pass
                socket.close()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=15)


try:
    pool = connection.storagePoolDefineXML(f'<pool type="dir"><name>{name}</name><target><path>{directory}</path></target></pool>', 0)
    pool.create(0)
    volume = pool.createXML('<volume><name>disk.qcow2</name><capacity unit="MiB">32</capacity><target><format type="qcow2"/></target></volume>', 0)
    arch = connection.getInfo()[0]
    machine = 'virt' if arch == 'aarch64' else 'q35'
    guest = connection.defineXML(f'<domain type="kvm"><name>{name}</name><memory unit="MiB">256</memory><vcpu>1</vcpu><cpu mode="host-passthrough"/><os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type></os><features><acpi/></features><devices><disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{volume.path()}"/><target dev="vda" bus="virtio"/></disk></devices></domain>')
    guest.create(); guest.destroy()
    path = '/server-manager/snapshots.cgi?id=' + guest.UUIDString()
    for theme in [options.theme] if options.theme else ['authentic-theme', 'gray-theme']:
        password = secrets.token_urlsafe(36)
        subprocess.run(['perl', str(helper), 'create', theme, username], input=password + '\n', text=True, check=True)
        created_user = True
        time.sleep(1)
        cookies = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(cookies), urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
        request('/session_login.cgi')
        request('/session_login.cgi', {'user': username, 'pass': password, 'page': path})
        create_page = request(path + '&view=create')
        assert 'Optional notes' in create_page and 'Notes (optional)' not in create_page
        form = Inputs(create_page).values
        assert {'token', 'revision', 'id', 'action', 'label'} <= form.keys()
        form['label'] = 'Before upgrade <test>'
        form['description'] = 'Saved from the snapshot page'
        result = request('/server-manager/snapshots.cgi', form)
        assert 'Creating snapshot' in result
        points = guest.listAllSnapshots(0)
        assert len(points) == 1
        point = points[0].getName()
        history = request(path)
        assert 'Before upgrade &lt;test&gt;' in history and 'You are here' in history
        assert 'Before upgrade &lt;test&gt;' in request('/server-manager/snapshots.cgi')
        # A firmware-only guest has no agent; explicitly exercise the API's live
        # unprepared mode to obtain libvirt's real disk-snapshot state.
        guest.create()
        form = Inputs(request(path + '&view=create')).values
        form['label'] = 'After upgrade'
        form['mode'] = 'unprepared'
        form.pop('shutdown', None)
        assert 'Creating snapshot' in request('/server-manager/snapshots.cgi', form)
        child = next(s.getName() for s in guest.listAllSnapshots(0) if s.getName() != point)
        assert 'view=restore' in request(path), 'Running guest lost its restore action'
        check_readonly(theme, path)
        render(cookies, path, str((options.screenshots_dir or directory) / (theme + '.png')),
               {point: False, child: True})
        # A rejected submission must retain an explicitly unchecked start box.
        retry = Inputs(request(path + '&view=restore&snapshot=' + urllib.parse.quote(child))).values
        assert retry.get('restart') == '1', 'Live snapshot should default to starting'
        retry.pop('restart')
        retry['token'] = 'invalid'
        rejected = Inputs(request('/server-manager/snapshots.cgi', retry)).values
        assert rejected.get('action') == 'snapshot_restore' and 'restart' not in rejected
        # The firmware-only fixture cannot shut down as a real operating system.
        guest.destroy()
        review = request(path + '&view=restore&snapshot=' + urllib.parse.quote(point))
        assert 'Changes made since this snapshot will be discarded' in review
        assert guest.listAllSnapshots(0), 'Opening confirmation changed data'
        assert 'Restoring snapshot' in request('/server-manager/snapshots.cgi', Inputs(review).values)
        deletion = request(path + '&view=delete&snapshot=' + urllib.parse.quote(point))
        assert 'Delete the child snapshots' in deletion, 'Current parent deletion must explain the required order'
        assert 'ui_confirmation' not in deletion, 'Unsupported deletion must not offer submission'
        deletion = request(path + '&view=delete&from=all&snapshot=' + urllib.parse.quote(child))
        assert 'virtual machine keeps its current data' in deletion
        result = request('/server-manager/snapshots.cgi', Inputs(deletion).values)
        # Expose a failed deletion response without assuming the operation ran.
        if 'Deleting snapshot' not in result:
            records = json.loads(request('/server-manager/api.cgi?action=list'))['result']
            errors = [j.get('error') for j in records if j.get('uuid') == guest.UUIDString() and j.get('error')]
            raise AssertionError({'review_form': 'ui_confirmation' in deletion, 'errors': errors})
        assert 'Return to all snapshots' in result, 'Completed host action must return to its list'
        deletion = request(path + '&view=delete&snapshot=' + urllib.parse.quote(point))
        assert 'Deleting snapshot' in request('/server-manager/snapshots.cgi', Inputs(deletion).values)
        assert not guest.listAllSnapshots(0)
        invalid = json.loads(request('/server-manager/api.cgi', {'action': 'snapshot_create', 'id': guest.UUIDString(), 'token': 'invalid'}))
        assert invalid.get('error'), 'Invalid token accepted'
        subprocess.run(['perl', str(helper), 'delete', theme, username], check=True)
        created_user = False
        print(theme + ': create, access controls, activity feed, host action navigation, restore defaults and override, restore, delete and CSRF passed', flush=True)
finally:
    # A failed account cleanup must not skip guest and storage cleanup.
    try:
        # Revoke the fixture account only after successful creation.
        if created_user:
            subprocess.run(['perl', str(helper), 'delete', 'authentic-theme', username], check=True)
    finally:
        from snapshot_fixture import cleanup_fixture
        cleanup_fixture(module, connection, guest, pool, directory)
