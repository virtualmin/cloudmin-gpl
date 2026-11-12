#!/usr/bin/python3
"""Check signed forms, API permissions and scheduled delivery on a test host.

Run as root on Linux. Cleanup removes this run's accounts and notification
records. Test messages go only to loopback receivers. Existing guests and
notification rules are left alone. Requires Chromium, python3-websocket and two
guests. Pass an existing screenshot directory to save review images. Add
--setup-only to run only the form and row-action checks, or --forms-only
to check only the editors. Full runs expect the notification interval to
remain at its default of 60 seconds for the scheduled-delivery deadline.
"""
import base64
import http.cookiejar
import http.server
import json
import os
from pathlib import Path
import secrets
import signal
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import websocket

# Run only as root on Linux.
assert sys.platform.startswith('linux') and os.geteuid() == 0
# The module root, the account helper, the local Webmin address and
# the events the sink received.
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
base = 'https://127.0.0.1:10000'
received = []


class Sink(http.server.BaseHTTPRequestHandler):
    """Accept fixture notifications on loopback without forwarding them."""

    def do_POST(self):
        """do_POST(self) records an event and sends its fixture response."""
        received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        if self.path == '/slow':
            # Delay acceptance so the page must show progress before completion.
            time.sleep(3)
        self.send_response(503 if self.path == '/fail' else 204)
        self.end_headers()

    def log_message(self, *_args):
        """log_message(self, [args...]) keeps request data out of logs."""


def account(action, theme, user, data=None):
    """account(action, theme, user, [data]) runs the fixture account helper.

    Optional data supplies password or ACL input on stdin, never in argv.
    """
    subprocess.run(['perl', str(helper), action, theme, user], input=data,
                   text=True, check=True, stdout=subprocess.DEVNULL)


def login(user, password):
    """login(user, password) returns an opener and cookie jar for the test user.

    Requests use loopback and accept the debug host's self-signed certificate.
    """
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    opener.open(base + '/session_login.cgi', timeout=30).read()
    opener.open(urllib.request.Request(base + '/session_login.cgi', data=
        urllib.parse.urlencode({'user': user, 'pass': password, 'page': '/'}).encode(),
        headers={'Referer': base + '/'}), timeout=30).read()
    return opener, jar


def api(opener, values, write=False):
    """api(opener, values, [write]) calls the installed API with real ACL checks.

    write defaults to false for GET; true sends a JSON POST.
    """
    url = base + '/server-manager/api.cgi'
    headers = {'Referer': base + '/server-manager/', 'Accept': 'application/json'}
    if write:
        # Mutations exercise the real signed POST path.
        headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(url, json.dumps(values).encode(), headers)
    else:
        # Reads keep parameters in the URL, as public API clients do.
        request = urllib.request.Request(url + '?' + urllib.parse.urlencode(values),
                                         headers=headers)
    return json.loads(opener.open(request, timeout=30).read())


def browser(jar, target, guest, theme, rule_name):
    """browser(jar, target, guest, theme, rule_name) runs real UI mutations.

    jar supplies the fixture session. A null target runs setup and row checks;
    otherwise target and guest identify the edit and scoped-history fixtures.
    theme selects navigation and rule_name isolates this run's saved records.
    """
    binary = shutil.which('chromium') or shutil.which('chromium-browser')
    assert binary, 'Chromium is required'
    parent = Path('/root/snap/chromium/common') if binary.startswith('/snap/') else None
    if parent:
        # Snap Chromium needs its temporary profile inside the permitted tree.
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-notifications-', dir=parent) as profile:
        process = subprocess.Popen([binary, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--disable-background-networking', '--disable-sync', '--window-size=1400,1000',
            '--user-data-dir=' + profile, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        channel = None
        try:
            # Connect only to the debug port created by this browser process.
            portfile = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not portfile.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = portfile.read_text().splitlines()
            channel = websocket.create_connection('ws://127.0.0.1:' + port + route,
                                                   timeout=30, suppress_origin=True)
            serial, session = 0, None

            def call(method, params=None):
                """call(method, [params]) waits for one browser command response.

                params defaults to an empty object. Ignore unsolicited events.
                """
                nonlocal serial
                serial += 1
                request = {'id': serial, 'method': method, 'params': params or {}}
                if session:
                    # Route page commands to the tab after it has been attached.
                    request['sessionId'] = session
                channel.send(json.dumps(request))
                while True:
                    response = json.loads(channel.recv())
                    if response.get('id') == serial:
                        # Only the matching response completes this call.
                        # Browser events and other responses are skipped.
                        assert 'error' not in response, response.get('error')
                        return response.get('result', {})

            def evaluate(script):
                """evaluate(script) runs JavaScript in the content document.

                Framed themes use the right frame; other themes use the window.
                The script may inspect or change controls and returns by value.
                """
                response = call('Runtime.evaluate', {'expression': '(window.frames.right || window).eval(' + json.dumps(script) + ')',
                    'returnByValue': True})
                assert 'exceptionDetails' not in response, 'Page evaluation failed'
                return response['result'].get('value')

            # Use a private tab and import only this
            # temporary account's cookies.
            page = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId': page, 'flatten': True})['sessionId']
            call('Page.enable')
            call('Page.bringToFront')
            call('Emulation.setDeviceMetricsOverride', {
                'width': 1400, 'height': 1000, 'deviceScaleFactor': 1, 'mobile': False})
            call('Network.enable')
            for cookie in jar:
                call('Network.setCookie', {'name': cookie.name, 'value': cookie.value,
                    'domain': cookie.domain, 'path': cookie.path, 'secure': cookie.secure})
            def wait(script, label):
                """wait(script, label) polls JavaScript for up to 30 seconds.

                label describes timeout failure without including form data.
                """
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    try:
                        if evaluate(script):
                            # Stop as soon as the expected
                            # page or widget is ready.
                            return
                    except AssertionError:
                        # Navigation can temporarily
                        # remove the content document.
                        pass
                    time.sleep(.2)
                raise AssertionError(label)

            def navigate(path):
                """navigate(path) opens a module page with its referrer."""
                call('Page.navigate', {'referrer': base + '/',
                    'url': base + '/server-manager/' + path})
                wait('''(() => {
                    const expected = new URL(''' + json.dumps(
                        base + '/server-manager/' + path) + ''');
                    const current = new URL(location.href);
                    return document.readyState === 'complete' &&
                        current.pathname === expected.pathname &&
                        [...expected.searchParams].every(([k, v]) =>
                            current.searchParams.get(k) === v);
                })()''', 'Navigation did not finish: ' + path)

            def click(selector):
                """click(selector) activates a required content element."""
                assert evaluate('''(() => {
                    const node = document.querySelector(''' + json.dumps(selector) + ''');
                    // A missing control must fail the Python assertion.
                    if (!node) return false;
                    node.click();
                    return true;
                })()'''), 'Missing control: ' + selector

            def set_enabled(value):
                """set_enabled(value) checks radio state and submission."""
                expected = '1' if value else '0'
                result = evaluate("""(() => {
                    const field = document.querySelector('input[name=enabled][value="' +
                        """ + json.dumps(expected) + """ + '"]');
                    // Reject other control types before checking submission.
                    if (field.type !== 'radio') throw new Error('Enabled is not a radio');
                    field.click();
                    return [field.checked, new FormData(field.form).get('enabled')];
                })()""")
                assert result == [True, expected], ('Enabled submission', result)

            def select_values(name, values):
                """select_values(name, values) checks multiselect submission."""
                result = evaluate("""(() => {
                    const field = document.querySelector('select[name="' +
                        """ + json.dumps(name) + """ + '"]');
                    const values = """ + json.dumps(values) + """;
                    // Both selectors must use the native multiple-value control.
                    if (!field.multiple) throw new Error('Expected a multiselect');
                    for (const option of field.options)
                        option.selected = values.includes(option.value);
                    field.dispatchEvent(new Event('change', {bubbles: true}));
                    const height = field.getBoundingClientRect().height;
                    // Keep the list height within its limits.
                    if (height < 50 || height > 220)
                        throw new Error('Multiselect height out of range: ' + height);
                    return new FormData(field.form).getAll(field.name);
                })()""")
                assert sorted(result) == sorted(values), ('Multiselect submission', name, result)

            def screenshot(name):
                """screenshot(name) saves a PNG in the optional argv directory.

                Prefix the image name with the current theme.
                """
                if len(sys.argv) < 2 or sys.argv[1].startswith('--'):
                    # Screenshot capture is optional, including setup-only runs.
                    return
                call('Page.bringToFront')
                time.sleep(1)
                data = call('Page.captureScreenshot', {'format': 'png'})['data']
                (Path(sys.argv[1]) / (theme + '-' + name + '.png')).write_bytes(
                    base64.b64decode(data))

            # Authentic's sidebar loads content through its
            # normal SPA navigation.
            if theme == 'authentic-theme':
                call('Page.navigate', {'url': base + '/', 'referrer': base + '/'})
                wait("""!!document.querySelector('a[href="/server-manager/notifications.cgi"]')""",
                     'Notification sidebar link did not load')
                click('a[href="/server-manager/notifications.cgi"]')
            else:
                # Framed themes can open the content page directly.
                navigate('notifications.cgi')
            wait('!!document.querySelector("#notification-history")',
                 'History did not load')

            if target is None:
                # Exercise setup, editing and row actions using
                # records named for this run.
                def tab(label, section):
                    """tab(label, section) opens a tab and waits for content."""
                    assert evaluate("""(() => {
                        const tab = [...document.querySelectorAll('a')].find(a =>
                            a.textContent.trim() === """ + json.dumps(label) + """ &&
                            (a.hasAttribute('data-toggle') || a.hasAttribute('onclick')));
                        // A missing tab must fail this click check.
                        if (!tab) return false;
                        tab.click();
                        return true;
                    })()""")
                    wait('document.querySelector("div[id$=_notifications_' + section + ']").offsetHeight > 0',
                         'Tab did not open: ' + label)

                def fill(name, value):
                    """fill(name, value) sets a field and triggers change."""
                    evaluate("""(() => {
                        const field = document.querySelector('[name=""" + name + """ ]');
                        field.value = """ + json.dumps(value) + """;
                        field.dispatchEvent(new Event('change', {bubbles: true}));
                    })()""")

                def state(mode):
                    """state(mode) checks visible and submitted fields.

                    mode names the delivery choice, such as saved or email.
                    """
                    result = evaluate("""(() => {
                        const form = document.querySelector('[name=secret]').form;
                        const data = new FormData(form);
                        return ['target_name', 'email_address', 'webhook_url', 'secret',
                            'telegram_chat', 'telegram_token', 'pushover_user', 'pushover_token',
                            'gotify_url', 'gotify_token'].map(name => {
                            const field = form.elements[name];
                            return [field.getBoundingClientRect().height > 0,
                                !field.disabled, data.has(name)];
                        });
                    })()""")
                    # Each field must be shown, enabled and submitted together,
                    # or hidden, disabled and left out.
                    expected = [mode != 'saved', mode == 'email',
                                mode in ('webhook', 'slack', 'discord', 'teams', 'ntfy'),
                                mode in ('webhook', 'ntfy'),
                                mode == 'telegram', mode == 'telegram',
                                mode == 'pushover', mode == 'pushover',
                                mode == 'gotify', mode == 'gotify']
                    assert result == [[value]*3 for value in expected], ('Delivery fields', result)

                def submit(section, name):
                    """submit(section, name) saves and waits for its row."""
                    evaluate("""(() => {
                        const form = document.querySelector('[name=secret]').form;
                        (form.querySelector('button.ui_form_end_submit') ||
                            form.querySelector('[type=submit]')).click();
                    })()""")
                    wait('!!document.querySelector("div[id$=_notifications_' + section + ']") && '
                         'document.body.innerText.includes(' + json.dumps(name) + ')',
                         'Save did not return to the correct inventory')
                    assert evaluate('document.querySelector("div[id$=_notifications_' + section + ']").offsetHeight') > 0

                def open_rule():
                    """open_rule() checks that Create Rule opens the editor."""
                    tab('Rules', 'rules')
                    click('a[href="notification_form.cgi?kind=rule"]')
                    wait('!!document.querySelector("input[value=save_notification_rule]")',
                         'Create Rule did not open the rule form directly')
                    assert evaluate('!!document.querySelector("select[name=metric]")')
                    assert not evaluate('document.body.innerText.includes("Set Up Targets")')

                # New forms must work with either an empty
                # or populated inventory.
                existing = api(opener, {'action': 'notification_config'})['result']
                open_rule()
                assert evaluate('document.querySelector("input[name=enabled]").checked')
                set_enabled(True)
                state('saved' if existing['targets'] else 'email')
                # A selected set must survive mode
                # changes, saving and reopening.
                machines = api(opener, {'action': 'machines'})['result']
                guest_ids = [m['id'] for m in machines[:2]]
                assert len(guest_ids) == 2, 'Two guests are needed for monitor selection checks'
                fill('scope_mode', 'selected')
                select_values('scope', guest_ids)
                fill('scope_mode', 'host')
                assert not evaluate('document.querySelector("#notification-selected-guests").offsetHeight')
                assert not evaluate('new FormData(document.querySelector("[name=scope_mode]").form).has("scope")')
                fill('scope_mode', 'selected')
                assert evaluate('document.querySelector("#notification-selected-guests").offsetHeight')
                assert sorted(evaluate('[...document.querySelector("select[name=scope]").selectedOptions].map(i => i.value)')) == sorted(guest_ids)
                # Conditions hide only irrelevant fields and
                # exclude them from POST.
                def condition_state(metric, names):
                    """condition_state(metric, names) checks submitted fields."""
                    fill('metric', metric)
                    actual = evaluate("""(() => {
                        const form = document.querySelector('[name=metric]').form;
                        const data = new FormData(form);
                        return ['device', 'threshold', 'duration', 'cooldown', 'reminder'].filter(name => {
                            const field = form.elements[name];
                            const visible = field.getBoundingClientRect().height > 0;
                            // Exclude hidden controls from POST.
                            if (visible !== data.has(name) || visible === field.disabled)
                                throw new Error('Field visibility and submission disagree');
                            return visible;
                        });
                    })()""")
                    assert actual == names, ('Condition fields', metric, actual)

                condition_state('cpu', ['threshold', 'duration', 'cooldown', 'reminder'])
                condition_state('filesystem', ['device', 'threshold', 'duration', 'cooldown', 'reminder'])
                condition_state('guest_down', ['duration', 'cooldown', 'reminder'])
                condition_state('job_failed', [])
                condition_state('cpu', ['threshold', 'duration', 'cooldown', 'reminder'])

                # Changing measurement units must reset
                # the limit and comparison.
                condition_state('filesystem_free', ['device', 'threshold', 'duration', 'cooldown', 'reminder'])
                assert evaluate('document.querySelector("[name=threshold]").value') == '1'
                assert evaluate('document.querySelector("[name=comparison]").value') == 'le'
                assert evaluate('document.querySelector("#notification-unit-gib").offsetHeight') > 0
                condition_state('disk_read', ['threshold', 'duration', 'cooldown', 'reminder'])
                assert evaluate('document.querySelector("[name=threshold]").value') == '100'
                assert evaluate('document.querySelector("#notification-unit-rate").offsetHeight') > 0
                condition_state('load_5', ['threshold', 'duration', 'cooldown', 'reminder'])
                condition_state('pool_inactive', ['device', 'duration', 'cooldown', 'reminder'])
                condition_state('collector_stale', ['duration', 'cooldown', 'reminder'])
                assert not evaluate('new FormData(document.querySelector("[name=metric]").form).has("comparison")')
                condition_state('cpu', ['threshold', 'duration', 'cooldown', 'reminder'])
                # Each provider enables only its own address and token inputs.
                for delivery in ('slack', 'discord', 'teams', 'ntfy', 'telegram',
                                 'pushover', 'gotify'):
                    fill('delivery', delivery)
                    state(delivery)
                fill('delivery', 'saved' if existing['targets'] else 'email')
                # Native table rows must fit a narrow viewport without overflow.
                call('Emulation.setDeviceMetricsOverride', {
                    'width': 620, 'height': 1000, 'deviceScaleFactor': 1, 'mobile': False})
                time.sleep(.5)
                assert evaluate("""(() => {
                    const editor = document.querySelector('#notification-editor');
                    return editor.querySelector('table') &&
                        !editor.querySelector('.ui_card, .ui_grid, .ui_field');
                })()"""), 'Notification forms must use native table rows'
                assert evaluate("""(() => {
                    const editor = document.querySelector('#notification-editor');
                    return editor.scrollWidth <= editor.clientWidth + 2;
                })()"""), 'Notification form overflows the narrow viewport'
                screenshot('rule-narrow')
                call('Emulation.setDeviceMetricsOverride', {
                    'width': 1400, 'height': 1000, 'deviceScaleFactor': 1, 'mobile': False})
                time.sleep(.5)
                # Switching delivery preserves the draft
                # address for each method.
                fill('delivery', 'email')
                fill('email_address', 'setup@example.invalid')
                fill('delivery', 'webhook')
                state('webhook')
                fill('webhook_url', 'https://example.invalid/setup')
                fill('delivery', 'email')
                state('email')
                assert evaluate('document.querySelector("[name=email_address]").value') == 'setup@example.invalid'
                assert not evaluate('!!document.querySelector("[name=clear_secret]")')
                # Save a disabled rule so the fixture cannot send real alerts.
                fill('name', rule_name + '-email')
                fill('target_name', rule_name + '-email-destination')
                set_enabled(False)
                click('input[name=recovery][value="0"]')
                screenshot('rule-with-new-email')
                submit('rules', rule_name + '-email')
                # Verify the paired save and guest
                # selection through the real API.
                cfg = api(opener, {'action': 'notification_config'})['result']
                email = next(t for t in cfg['targets'] if t['name'] == rule_name + '-email-destination')
                rule = next(r for r in cfg['rules'] if r['name'] == rule_name + '-email')
                assert not rule['enabled'] and rule['targets'] == [email['id']]
                assert email['address'] == 'setup@example.invalid'
                assert not rule['recovery']
                assert sorted(rule['scope']) == sorted(guest_ids)

                # Reopening the saved rule selects its
                # destination without new fields.
                click('a[href="notification_form.cgi?kind=rule&object=' + rule['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_rule]")', 'Rule edit failed')
                state('saved')
                assert evaluate('document.querySelector("select[name=scope_mode]").value') == 'selected'
                assert sorted(evaluate('[...document.querySelector("select[name=scope]").selectedOptions].map(i => i.value)')) == sorted(guest_ids)
                assert not evaluate('document.querySelector("input[name=enabled]").checked')
                assert evaluate('document.querySelector("[name=recovery]").form.elements.recovery.value') == '0'
                # Editing recovery must reuse the
                # destination, not create another.
                click('input[name=recovery][value="1"]')
                assert evaluate('[...document.querySelector("select[name=targets]").selectedOptions].map(i => i.value)') == [email['id']]
                select_values('targets', [email['id']])
                fill('delivery', 'email')
                assert not evaluate('new FormData(document.querySelector("[name=delivery]").form).has("targets")')
                fill('delivery', 'saved')
                assert evaluate('[...document.querySelector("select[name=targets]").selectedOptions].map(i => i.value)') == [email['id']]
                screenshot('rule-with-saved-destination')
                submit('rules', rule_name + '-email')
                cfg = api(opener, {'action': 'notification_config'})['result']
                assert len([r for r in cfg['targets'] if r['name'].startswith(rule_name + '-')]) == 1
                assert next(r for r in cfg['rules'] if r['id'] == rule['id'])['recovery']

                # A new webhook is also saved with its rule,
                # including a private token.
                open_rule()
                # Pick a guest, then switch to all guests. The hidden selection
                # must not be saved.
                fill('scope_mode', 'selected')
                select_values('scope', [guest_ids[0]])
                fill('scope_mode', 'guests')
                fill('delivery', 'webhook')
                state('webhook')
                fill('name', rule_name + '-webhook')
                fill('target_name', rule_name + '-webhook-destination')
                fill('webhook_url', 'https://example.invalid/setup')
                saved_token = secrets.token_urlsafe(24)
                fill('secret', saved_token)
                set_enabled(False)
                submit('rules', rule_name + '-webhook')
                # Only credential presence, never its value,
                # may return from the API.
                cfg = api(opener, {'action': 'notification_config'})['result']
                hook = next(t for t in cfg['targets'] if t['name'] == rule_name + '-webhook-destination')
                rule = next(r for r in cfg['rules'] if r['name'] == rule_name + '-webhook')
                assert not rule['enabled'] and rule['targets'] == [hook['id']]
                assert rule['scope'] == 'guests', 'Hidden selections overrode all guests'
                assert hook['has_secret'] and 'secret' not in hook
                tab('Destinations', 'targets')
                screenshot('destinations')
                # Editors show the saved token while the API stays redacted.
                click('a[href="notification_form.cgi?kind=target&object=' + hook['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination edit failed')
                assert evaluate('document.querySelector("[name=secret]").value') == saved_token, 'Saved token was not populated'
                assert evaluate('document.querySelector("[name=secret]").type') == 'text'
                assert not evaluate('!!document.querySelector("[name=clear_secret]")')
                assert not evaluate('!!document.querySelector("[name=metric]")')
                submit('targets', hook['name'])
                click('a[href="notification_form.cgi?kind=target&object=' + hook['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination edit failed')
                assert evaluate('document.querySelector("[name=secret]").value') == saved_token, 'Unchanged save lost the token'
                # Replacing a saved token must survive another editor load.
                saved_token = secrets.token_urlsafe(24)
                fill('secret', saved_token)
                submit('targets', hook['name'])
                click('a[href="notification_form.cgi?kind=target&object=' + hook['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination edit failed')
                assert evaluate('document.querySelector("[name=secret]").value') == saved_token, 'Replacement token was not saved'
                # Clearing the visible field removes the token after saving.
                fill('secret', '')
                submit('targets', hook['name'])
                cfg = api(opener, {'action': 'notification_config'})['result']
                assert not next(t for t in cfg['targets'] if t['id'] == hook['id'])['has_secret'], 'Cleared token was retained'
                click('a[href="notification_form.cgi?kind=target&object=' + hook['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination edit failed')
                assert evaluate('document.querySelector("[name=secret]").value') == '', 'Cleared token reappeared'
                screenshot('destination-without-token')
                # Later row-action checks require this fixture to have a token.
                fill('secret', saved_token)
                submit('targets', hook['name'])
                # Standalone creation has no rule condition or token-removal
                # checkbox; tokens are edited through the visible field.
                click('a[href="notification_form.cgi?kind=target"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination create failed')
                assert not evaluate('!!document.querySelector("[name=metric]")')
                assert not evaluate('!!document.querySelector("[name=clear_secret]")')
                fill('name', rule_name + '-standalone')
                fill('email_address', 'standalone@example.invalid')
                set_enabled(False)
                screenshot('new-destination')
                submit('targets', rule_name + '-standalone')
                cfg = api(opener, {'action': 'notification_config'})['result']
                assert len([r for r in cfg['rules'] if r['name'].startswith(rule_name + '-')]) == 2
                assert len([r for r in cfg['targets'] if r['name'].startswith(rule_name + '-')]) == 3
                # A standalone destination can be enabled
                # without sending alerts.
                standalone = next(t for t in cfg['targets'] if t['name'] == rule_name + '-standalone')
                assert not standalone['enabled']
                click('a[href="notification_form.cgi?kind=target&object=' + standalone['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination edit failed')
                assert not evaluate('document.querySelector("input[name=enabled]").checked')
                set_enabled(True)
                submit('targets', standalone['name'])
                cfg = api(opener, {'action': 'notification_config'})['result']
                assert next(t for t in cfg['targets'] if t['id'] == standalone['id'])['enabled']
                # Help links must resolve to the visible field titles.
                for suffix, title in [('send_to', 'Send to'), ('destination_name', 'Destination name'),
                                      ('targets', 'Destinations'), ('email_address', 'Email address'),
                                      ('webhook_url', 'Webhook URL'), ('telegram_chat', 'Chat ID'),
                                      ('telegram_token', 'Bot token'),
                                      ('pushover_user', 'User or group key'),
                                      ('pushover_token', 'Pushover application token'),
                                      ('gotify_url', 'Gotify server URL'),
                                      ('gotify_token', 'Gotify application token')]:
                    request = urllib.request.Request(base + '/help.cgi/server-manager/notifications_' + suffix,
                        headers={'Referer': base + '/server-manager/'})
                    assert title in opener.open(request, timeout=30).read().decode()

                # Save the new units and comparison through the real rule form.
                tab('Rules', 'rules')
                click('a[href="notification_form.cgi?kind=rule&object=' + rule['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_rule]")', 'Rule edit failed')
                fill('metric', 'filesystem_free')
                fill('scope_mode', 'host')
                fill('device', '/')
                fill('threshold', '10')
                fill('comparison', 'le')
                submit('rules', rule['name'])
                # The API must return the new condition, still disabled.
                cfg = api(opener, {'action': 'notification_config'})['result']
                updated = next(r for r in cfg['rules'] if r['id'] == rule['id'])
                assert updated['metric'] == 'filesystem_free' and updated['comparison'] == 'le'
                assert updated['threshold'] == 10 and not updated['enabled']
                # Private chat URLs survive form saves but stay out of listings.
                tab('Destinations', 'targets')
                click('a[href="notification_form.cgi?kind=target&object=' + standalone['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination edit failed')
                fill('type', 'teams')
                fill('webhook_url', 'https://workflow.example.invalid/hooks/fixture?sig=fixture-private')
                set_enabled(False)
                submit('targets', standalone['name'])
                # The API and the list hide the URL. The editor still shows it.
                cfg = api(opener, {'action': 'notification_config'})['result']
                private = next(t for t in cfg['targets'] if t['id'] == standalone['id'])
                assert private['type'] == 'teams' and 'address' not in private
                assert 'fixture-private' not in evaluate('document.body.innerText')
                click('a[href="notification_form.cgi?kind=target&object=' + standalone['id'] + '"]')
                wait('!!document.querySelector("input[value=save_notification_target]")', 'Destination edit failed')
                assert evaluate('document.querySelector("[name=webhook_url]").value').endswith('sig=fixture-private')
                submit('targets', standalone['name'])
                if '--forms-only' in sys.argv:
                    # Fake Telegram credentials are saved only for disabled
                    # rules and destinations, and never used
                    # by subsequent send tests.
                    click('a[href="notification_form.cgi?kind=target&object=' + standalone['id'] + '"]')
                    wait('!!document.querySelector("input[value=save_notification_target]")', 'Telegram edit failed')
                    fill('type', 'telegram')
                    fill('telegram_chat', '-1001234567890')
                    fill('telegram_token', '123456:fixture_Browser-token')
                    # Telegram must submit only its chat ID and bot token.
                    assert evaluate("""(() => {
                        const form = document.querySelector('[name=telegram_chat]').form;
                        const data = new FormData(form);
                        return data.get('type') === 'telegram' &&
                            data.get('telegram_chat') === '-1001234567890' &&
                            data.has('telegram_token') &&
                            !data.has('secret') && !data.has('webhook_url') && !data.has('email_address');
                    })()"""), 'Telegram submits only its own address fields'
                    set_enabled(False)
                    submit('targets', standalone['name'])
                    # The API returns the chat ID, but only says that a token
                    # is saved. The list does not show the token either.
                    cfg = api(opener, {'action': 'notification_config'})['result']
                    telegram = next(t for t in cfg['targets'] if t['id'] == standalone['id'])
                    assert (telegram['type'], telegram.get('address')) == ('telegram', '-1001234567890'), ('Saved Telegram destination', telegram['type'], telegram.get('address'))
                    assert telegram['has_secret'] and 'secret' not in telegram and not telegram['enabled']
                    assert 'fixture_Browser-token' not in evaluate('document.body.innerText')
                    # The editor shows the token in its own field, not in the
                    # generic token field.
                    click('a[href="notification_form.cgi?kind=target&object=' + standalone['id'] + '"]')
                    wait('!!document.querySelector("input[value=save_notification_target]")', 'Telegram reopen failed')
                    assert evaluate('document.querySelector("[name=telegram_token]").value') == '123456:fixture_Browser-token'
                    assert evaluate('document.querySelector("[name=secret]").value') == ''
                    submit('targets', standalone['name'])
                    # Inline Telegram creation must attach the new destination
                    # to the disabled rule without exposing its token.
                    tab('Rules', 'rules')
                    click('a[href="notification_form.cgi?kind=rule&object=' + rule['id'] + '"]')
                    wait('!!document.querySelector("input[value=save_notification_rule]")', 'Inline Telegram edit failed')
                    fill('delivery', 'telegram')
                    state('telegram')
                    fill('target_name', rule_name + '-telegram-inline')
                    fill('telegram_chat', '@fixture_channel')
                    fill('telegram_token', '123456:fixture_Inline-token')
                    set_enabled(False)
                    submit('rules', rule['name'])
                    # The rule must now use only the new Telegram destination.
                    cfg = api(opener, {'action': 'notification_config'})['result']
                    inline = next(t for t in cfg['targets'] if t['name'] == rule_name + '-telegram-inline')
                    assert inline['type'] == 'telegram' and inline['address'] == '@fixture_channel'
                    assert inline['has_secret'] and 'secret' not in inline
                    updated = next(r for r in cfg['rules'] if r['id'] == rule['id'])
                    assert updated['targets'] == [inline['id']] and not updated['enabled']
                    # Save and reopen push destinations, then attach inline
                    # destinations to a disabled rule. Never send fake tokens.
                    for method in ('pushover', 'gotify'):
                        address_field = 'pushover_user' if method == 'pushover' else 'gotify_url'
                        address = 'u' * 30 if method == 'pushover' else 'https://push.example.invalid/gotify'
                        navigate('notification_form.cgi?kind=target&object=' + standalone['id'])
                        wait('!!document.querySelector("input[value=save_notification_target]")', 'Push editor missing')
                        fill('type', method)
                        fill(address_field, address)
                        fill(method + '_token', 'a' * 30)
                        set_enabled(False)
                        submit('targets', standalone['name'])
                        cfg = api(opener, {'action': 'notification_config'})['result']
                        saved = next(t for t in cfg['targets'] if t['id'] == standalone['id'])
                        assert saved['type'] == method and saved['has_secret'] and not saved['enabled']
                        assert 'secret' not in saved and 'a' * 30 not in evaluate('document.body.innerText')
                        if method == 'pushover':
                            # User keys are private in both the API and list.
                            assert 'address' not in saved and saved['has_private_address']
                            assert 'u' * 30 not in evaluate('document.body.innerText')
                        else:
                            # Server URLs remain public without their token.
                            assert saved['address'] == address
                        navigate('notification_form.cgi?kind=target&object=' + standalone['id'])
                        wait('!!document.querySelector("input[value=save_notification_target]")', 'Push reopen failed')
                        assert evaluate('document.querySelector("[name=' + method + '_token]").value') == 'a' * 30
                        assert evaluate('document.querySelector("[name=' + address_field + ']").value') == address
                        submit('targets', standalone['name'])
                        navigate('notification_form.cgi?kind=rule&object=' + rule['id'])
                        wait('!!document.querySelector("input[value=save_notification_rule]")', 'Inline push editor missing')
                        fill('delivery', method)
                        state(method)
                        inline_name = rule_name + '-' + method + '-inline'
                        fill('target_name', inline_name)
                        fill(address_field, address)
                        fill(method + '_token', 'a' * 30)
                        set_enabled(False)
                        submit('rules', rule['name'])
                        cfg = api(opener, {'action': 'notification_config'})['result']
                        inline = next(t for t in cfg['targets'] if t['name'] == inline_name)
                        updated = next(r for r in cfg['rules'] if r['id'] == rule['id'])
                        assert inline['type'] == method and inline['has_secret']
                        assert updated['targets'] == [inline['id']] and not updated['enabled']
                    # API-created names must survive display
                    # and an unchanged form save.
                    api_name = rule_name + '-API'
                    api_target = api(opener, {'action': 'save_notification_target',
                        'target': {'name': api_name, 'type': 'email', 'enabled': 0,
                                   'address': 'sink@example.invalid'}, 'token': token}, True)['result']['id']
                    navigate('notification_form.cgi?kind=target&object=' + api_target)
                    wait('!!document.querySelector("input[value=save_notification_target]")', 'API destination edit failed')
                    assert evaluate('document.querySelector("[name=name]").value') == api_name
                    submit('targets', api_name)
                    cfg = api(opener, {'action': 'notification_config'})['result']
                    assert next(t for t in cfg['targets'] if t['id'] == api_target)['name'] == api_name
                    # Progress and confirmation pages must preserve Unicode too.
                    click('#notification-target-' + api_target + ' [name=delete]')
                    wait('!!document.querySelector("[name=confirm]")', 'Unicode confirmation missing')
                    assert evaluate('document.body.innerText.includes(' + json.dumps(api_name) + ')')
                    click('[name=confirm]')
                    wait('document.querySelectorAll("[data-second-print]").length === 1', 'Unicode deletion failed')
                    assert evaluate('document.body.innerText.includes(' + json.dumps(api_name) + ')')
                    # Layout changes need only the editor and submission checks.
                    print('PASS notification forms, conditional rows and submissions:', theme, flush=True)
                    return
                # Slow success and explicit failure use only our loopback sink.
                test_targets = []
                for suffix, path in [('success', '/slow'), ('failure', '/fail')]:
                    data = {'name': rule_name + '-test-' + suffix, 'type': 'webhook',
                            'address': f'http://127.0.0.1:{sink.server_port}' + path}
                    test_targets.append(api(opener, {'action': 'save_notification_target',
                        'target': data, 'token': token}, True)['result']['id'])
                # Rows wrap long values and keep actions
                # scoped to one destination.
                long_target = api(opener, {'action': 'save_notification_target',
                    'target': {'name': rule_name + '-long-' + 'x'*40, 'type': 'webhook',
                        'address': f'http://127.0.0.1:{sink.server_port}/' + 'x'*200,
                        'enabled': 0}, 'token': token}, True)['result']['id']
                navigate('notifications.cgi?tab=targets&xnavigation=1' if theme == 'authentic-theme'
                         else 'notifications.cgi?tab=targets')
                wait('!!document.querySelector("#notification-target-' + hook['id'] + '")',
                     'Destination rows missing')
                assert not evaluate('!!document.querySelector("div[id$=_notifications_targets] input[name=object][type=checkbox]")')
                assert evaluate('document.querySelector("#notification-target-' + long_target + ' [name=send]").disabled')
                if theme == 'authentic-theme':
                    # The theme must recognize this CGI as a
                    # streaming progress page.
                    assert evaluate("unbuffered_header_processor_allow(document.querySelector('#notification-target-" + hook['id'] + " .notification-actions form').action, 1)"), 'Row actions must stream through the theme'
                assert evaluate("""(() => {
                    const row = document.querySelector('#notification-target-""" + hook['id'] + """');
                    return row.querySelector('.notification-used_by').innerText === '1 rule' &&
                        row.querySelector('.notification-last_delivery').innerText === 'No recent deliveries' &&
                        !row.querySelector('details') &&
                        ['send', 'delete'].every(name => {
                            const button = row.querySelector('[name=' + name + ']');
                            return button.offsetWidth > 0 && button.querySelector('svg');
                        });
                })()"""), 'Row usage, delivery or direct actions incorrect'
                screenshot('destination-rows')
                # Inline switches save state without losing the
                # token or other fields.
                for enabled in (False, True):
                    click('#notification-enabled-' + hook['id'])
                    wait('!!document.querySelector("#notification-enabled-' + hook['id'] + '") && '
                         'document.querySelector("#notification-enabled-' + hook['id'] + '").checked === '
                         + json.dumps(enabled) + ' && document.querySelector("#notification-target-'
                         + hook['id'] + ' [name=send]").disabled === ' + json.dumps(not enabled),
                         'Inline toggle did not finish saving')
                    current = api(opener, {'action': 'notification_config'})['result']
                    saved = next(t for t in current['targets'] if t['id'] == hook['id'])
                    assert bool(saved['enabled']) == enabled and saved['has_secret']
                    assert saved['address'] == hook['address'] and saved['name'] == hook['name']
                # Usage links narrow Rules and provide a way
                # back to the full list.
                click('#notification-target-' + hook['id'] + ' .notification-used_by a')
                wait('document.body.innerText.includes("Rules using ' + hook['name'] + '")',
                     'Usage link did not filter rules')
                assert evaluate('document.querySelectorAll(".notification-rules [role=rowgroup] > .notification-row").length') == 1
                click('a[href="notifications.cgi?tab=rules"]')
                wait('document.querySelectorAll(".notification-rules [role=rowgroup] > .notification-row").length >= 2',
                     'Show all rules did not remove filter')
                navigate('notifications.cgi?tab=targets')
                # At phone width rows reflow inside the content area.
                call('Emulation.setDeviceMetricsOverride', {
                    'width': 420, 'height': 1000, 'deviceScaleFactor': 1, 'mobile': False})
                wait("getComputedStyle(document.querySelector('.notification-destinations .notification-head')).display === 'none'",
                     'Destination rows did not reflow on mobile')
                screenshot('destination-rows-mobile')
                assert evaluate("""[...document.querySelectorAll('.notification-destinations .notification-row')].every(row =>
                    row.scrollWidth <= row.clientWidth + 1 &&
                    row.getBoundingClientRect().right <= document.documentElement.clientWidth + 1)"""), 'Destination row overflow at phone width'
                call('Emulation.setDeviceMetricsOverride', {
                    'width': 1400, 'height': 1000, 'deviceScaleFactor': 1, 'mobile': False})

                # Each row sends only its own test and
                # reports its actual result.
                for index, target_id in enumerate(test_targets):
                    click('#notification-target-' + target_id + ' [name=send]')
                    if index == 0:
                        # The slow endpoint shows whether progress is streamed
                        # or held back until the send finishes.
                        wait('document.querySelectorAll("[data-first-print]").length > '
                             'document.querySelectorAll("[data-second-print]").length',
                             'Send progress was buffered until completion')
                    wait('document.querySelectorAll("[data-second-print]").length === 1',
                         'Test send did not show its result')
                    expected = '.. done' if index == 0 else '.. failed : delivery failed'
                    assert evaluate('document.body.innerText.includes(' + json.dumps(expected) + ')')
                    assert evaluate('document.querySelectorAll("[data-first-print]").length') == 1
                    screenshot('send-progress-' + str(index))
                    # Returning to the list must show the attempt just made.
                    click('a[href="notifications.cgi?tab=targets"]')
                    wait('!!document.querySelector("#notification-target-' + hook['id'] + '")',
                         'Progress return failed')
                    expected_status = 'Accepted by destination' if index == 0 else 'Failed, retry pending'
                    status_text = evaluate('document.querySelector("#notification-target-' + target_id +
                                           ' .notification-last_delivery .ui_chip_text").innerText')
                    assert expected_status + ' · ' in status_text, 'Delivery timestamp is missing'
                    assert '<' not in status_text and '>' not in status_text, 'Date markup is visible as text'
                    screenshot('destination-delivery-' + str(index))

                # Cancellation preserves the row; deletion reports
                # per-destination errors.
                click('#notification-target-' + standalone['id'] + ' [name=delete]')
                wait('!!document.querySelector("[name=confirm]")', 'Delete confirmation missing')
                assert evaluate('document.body.innerText.includes("Delete this notification destination?")')
                assert not evaluate('!!document.querySelector("[data-first-print]")')
                screenshot('delete-confirmation')
                click('a[href="notifications.cgi?tab=targets"]')
                wait('!!document.querySelector("#notification-target-' + standalone['id'] + '")',
                     'Cancel did not preserve the destination')
                # Referenced destinations fail deletion;
                # unused ones can be removed.
                for record, expected in [(hook, '.. failed : remove this destination from its rules first'),
                                         (standalone, '.. done')]:
                    click('#notification-target-' + record['id'] + ' [name=delete]')
                    wait('!!document.querySelector("[name=confirm]")', 'Delete confirmation missing')
                    click('[name=confirm]')
                    wait('document.querySelectorAll("[data-second-print]").length === 1',
                         'Delete did not show its result')
                    assert evaluate('document.body.innerText.includes(' + json.dumps(expected) + ')')
                    click('a[href="notifications.cgi?tab=targets"]')
                    wait('!!document.querySelector("#notification-target-' + hook['id'] + '")',
                         'Delete return failed')
                cfg = api(opener, {'action': 'notification_config'})['result']
                assert not any(t['id'] == standalone['id'] for t in cfg['targets'])
                assert any(t['id'] == hook['id'] for t in cfg['targets'])

                # Rule rows work like destination rows and change only their
                # own record.
                navigate('notifications.cgi?tab=rules')
                wait('!!document.querySelector(".notification-rules")', 'Rule rows missing')
                assert not evaluate('!!document.querySelector(".notification-rules input[type=checkbox][name=object]")')
                rule_ids = [r['id'] for r in cfg['rules'] if r['name'].startswith(rule_name + '-')]
                assert len(rule_ids) == 2
                # Rule IDs are random and one fixture is now a free-space rule,
                # so choose the remaining CPU rule by its condition. It requires
                # five minutes, so this short check cannot alert.
                before = next(r for r in cfg['rules']
                              if r['id'] in rule_ids and r['metric'] == 'cpu')
                assert before['duration'] >= 5
                for enabled in (True, False):
                    selector = '#notification-rule-enabled-' + before['id']
                    # Wait for the saved page, not the old
                    # checkbox's immediate change.
                    evaluate('window.notificationTestSwitch = document.querySelector(' +
                             json.dumps(selector) + '); true')
                    click(selector)
                    wait('''(() => {
                        const node = document.querySelector(''' + json.dumps(selector) + ''');
                        return node && node !== window.notificationTestSwitch &&
                            node.checked === ''' + json.dumps(enabled) + ''';
                    })()''', 'Rule switch did not finish saving')
                    # The switch restarts the rule's checks, so its start time
                    # may change. No other setting may.
                    current = api(opener, {'action': 'notification_config'})['result']
                    saved = next(r for r in current['rules'] if r['id'] == before['id'])
                    assert bool(saved['enabled']) == enabled
                    assert {k:v for k,v in saved.items() if k not in ('enabled', 'created')} == {
                        k:v for k,v in before.items() if k not in ('enabled', 'created')}
                # Rule rows must also fit a narrow content
                # area without overflow.
                screenshot('rule-rows')
                call('Emulation.setDeviceMetricsOverride', {
                    'width':420, 'height':1000, 'deviceScaleFactor':1, 'mobile':False})
                wait("getComputedStyle(document.querySelector('.notification-rules .notification-head')).display === 'none'",
                     'Rules did not reflow on mobile')
                assert evaluate("[...document.querySelectorAll('.notification-rules .notification-row')].every(r => r.scrollWidth <= r.clientWidth + 1)"), 'Rule row overflow'
                screenshot('rule-rows-mobile')
                call('Emulation.setDeviceMetricsOverride', {
                    'width':1400, 'height':1000, 'deviceScaleFactor':1, 'mobile':False})
                # Confirming deletes one rule; cancelling preserves its row.
                for rule_id in rule_ids:
                    click('#notification-rule-' + rule_id + ' [name=delete]')
                    wait('!!document.querySelector("[name=confirm]")', 'Rule confirmation missing')
                    assert evaluate('document.body.innerText.includes("Delete this notification rule?")')
                    # Cancelling returns to the same row without deleting it.
                    click('a[href="notifications.cgi?tab=rules"]')
                    wait('!!document.querySelector("#notification-rule-' + rule_id + '")', 'Cancel removed a rule')
                    # Confirming deletes the rule and reports the result.
                    click('#notification-rule-' + rule_id + ' [name=delete]')
                    wait('!!document.querySelector("[name=confirm]")', 'Rule confirmation missing')
                    click('[name=confirm]')
                    wait('document.querySelectorAll("[data-second-print]").length === 1',
                         'Rule delete did not show its result')
                    assert evaluate('document.body.innerText.includes(".. done")')
                    click('a[href="notifications.cgi?tab=rules"]')
                    wait('!!document.querySelector("div[id$=_notifications_rules]")', 'Rule return failed')
                    current = api(opener, {'action': 'notification_config'})['result']
                    assert not any(r['id'] == rule_id for r in current['rules'])
                print('PASS setup, responsive rule and destination rows, inline switches, usage links and progress actions:', theme, flush=True)
                return

            # Existing-record tests must start in inventory,
            # not an embedded editor.
            wait('!!document.querySelector("#notification-history")',
                 'History did not load')
            assert not evaluate('!!document.querySelector("input[value=save_notification_target]")')
            assert not evaluate('!!document.querySelector("input[value=save_notification_rule]")')
            screenshot('history')
            # Both native tab implementations must switch
            # without loading a form.
            assert evaluate('''(() => {
                const tab = Array.from(document.querySelectorAll('a')).find(a =>
                    a.textContent.trim() === 'Destinations' &&
                    (a.hasAttribute('data-toggle') || a.hasAttribute('onclick')));
                // Missing native tabs must not pass as successful clicks.
                if (!tab) return false;
                tab.click();
                return true;
            })()''')
            # The destination list replaces history, and stored markup
            # stays inert.
            wait('document.querySelector("div[id$=_notifications_targets]").offsetHeight > 0',
                 'Native target tab did not switch')
            assert evaluate('document.querySelector("#notification-history").offsetHeight') == 0
            assert not evaluate('!!window.notificationInjected'), 'Stored markup executed'
            screenshot('targets')
            # Cancelling deletion must leave the destination in the list.
            click('#notification-target-' + target + ' [name=delete]')
            wait('!!document.querySelector("[name=confirm]")',
                 'Delete confirmation did not open')
            click('a[href="notifications.cgi?tab=targets"]')
            wait('!!document.querySelector("div[id$=_notifications_targets]")',
                 'Delete confirmation did not return')
            # Creation must open an empty editor with a working return link.
            click('div[id$=_notifications_targets] a[href="notification_form.cgi?kind=target"]')
            wait('!!document.querySelector("input[value=save_notification_target]")',
                 'Create target button did not open an editor')
            assert evaluate('location.pathname.endsWith("/notification_form.cgi")')
            assert evaluate('document.querySelector("input[name=object]").value') == ''
            assert not evaluate('!!document.querySelector("div[id$=_notifications_targets]")')
            assert not evaluate('document.body.innerText.includes("Return to Return to")')
            screenshot('create-target')
            click('a[href="notifications.cgi?tab=targets"]')
            wait('!!document.querySelector("div[id$=_notifications_targets]")', 'Target return failed')
            # Saved hostile markup must remain escaped in both list and editor.
            click('a[href="notification_form.cgi?kind=target&object=' + target + '"]')
            wait('!!document.querySelector("input[value=save_notification_target]")',
                 'Target editor did not load')
            assert not evaluate('!!window.notificationInjected'), 'Editor executed stored markup'
            assert evaluate('document.querySelector("input[name=secret]").value') == ''
            # Save through the signed form and wait for the updated inventory.
            evaluate('''(() => {
                const form = document.querySelector('input[value=save_notification_target]').form;
                form.elements.name.value = 'Notification fixture edited';
                (form.querySelector('button.ui_form_end_submit') ||
                    form.querySelector('[type=submit]')).click();
                return true;
            })()''')
            wait('!!document.querySelector("div[id$=_notifications_targets]") && document.body.innerText.includes("Notification fixture edited")',
                 'Signed target form did not save')
            assert evaluate('document.querySelector("div[id$=_notifications_targets]").offsetHeight') > 0
            # Use the create button and the native target
            # selector to save a rule.
            navigate('notifications.cgi?tab=rules')
            wait('!!document.querySelector("div[id$=_notifications_rules]")', 'Rules did not load')
            click('div[id$=_notifications_rules] a[href="notification_form.cgi?kind=rule"]')
            wait('!!document.querySelector("input[value=save_notification_rule]")',
                 'Create rule button did not open an editor')
            assert evaluate('location.pathname.endsWith("/notification_form.cgi")')
            select_values('targets', [target])
            set_enabled(False)
            screenshot('create-rule')
            # Name the rule and submit the signed form.
            evaluate('''(() => {
                const form = document.querySelector('input[value=save_notification_rule]').form;
                form.elements.name.value = ''' + json.dumps(rule_name) + ''';
                (form.querySelector('button.ui_form_end_submit') ||
                    form.querySelector('[type=submit]')).click();
                return true;
            })()''')
            wait('!!document.querySelector("div[id$=_notifications_rules]") && document.body.innerText.includes(' + json.dumps(rule_name) + ')',
                 'Signed rule form did not save')
            assert evaluate('document.querySelector("div[id$=_notifications_rules]").offsetHeight') > 0
            screenshot('rules')
            # Guest history retains the selected VM and has no host controls.
            navigate('notifications.cgi?id=' + guest)
            wait('!!document.querySelector("#notification-history")', 'Guest history did not load')
            assert evaluate('document.body.innerText.includes("Guest Notifications")')
            assert evaluate('''[...document.querySelectorAll('a[href]')].some(a => {
                const url = new URL(a.href);
                return url.pathname.endsWith('/machine.cgi') &&
                    url.searchParams.get('id') === ''' + json.dumps(guest) + ''';
            })'''), 'Guest return link lost its VM'

            # The guest view has no tabs and no signed token.
            assert not evaluate('!!document.querySelector("input[name=notification_tabs]")')
            assert not evaluate('!!document.querySelector("input[name=token]")')
            screenshot('guest')

        finally:
            if channel:
                # Close only the browser connection opened by this fixture.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, AssertionError):
                    # Browser shutdown may close the
                    # socket before acknowledging.
                    pass
                channel.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # A stuck fixture browser must not outlive its private profile.
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


# Each installed theme gets its own account, browser profile and saved records.
with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Sink) as sink:
    threading.Thread(target=sink.serve_forever, daemon=True).start()
    try:
        for theme in ('authentic-theme', 'gray-theme'):
            if not (module.parent / theme).is_dir():
                # Skip themes absent from this debug installation.
                continue
            user = 'cloudmin-ui-check-' + secrets.token_hex(4)
            password = secrets.token_urlsafe(32)
            created, target, rule, opener, token, test = False, None, None, None, None, None
            try:
                # Create an administrator account for this theme and sign in.
                account('create', theme, user, password + '\n')
                created = True
                account('acl', theme, user, json.dumps({'admin': 1}))
                time.sleep(1)
                opener, jar = login(user, password)
                token = api(opener, {'action': 'options'})['result']['token']
                # Run the setup, form and row checks with Unicode record names.
                browser(jar, None, None, theme, user + '-setup-Größe-М-Ã©-😀')
                if '--setup-only' in sys.argv or '--forms-only' in sys.argv:
                    # The selected subset has finished its browser checks.
                    continue
                # Reads cannot mutate state, and POST still
                # requires a valid token.
                assert 'error' in api(opener, {'action': 'save_notification_target',
                    'token': token}), 'Writes must reject GET'
                data = {'name': '<img src=x onerror=window.notificationInjected=1>',
                    'type': 'webhook', 'address': f'http://127.0.0.1:{sink.server_port}/events'}
                assert 'error' in api(opener, {'action': 'save_notification_target',
                    'target': data}, True), 'Writes must require a signed token'
                # Stored markup tests escaping without sending
                # to an external address.
                target = api(opener, {'action': 'save_notification_target',
                    'target': data, 'token': token}, True)['result']['id']
                # Check existing records with this destination and one guest.
                guests = api(opener, {'action': 'machines'})['result']
                assert guests, 'At least one guest is needed for page and ACL checks'
                guest = guests[0]['id']
                rule_name = user + '-rule'
                browser(jar, target, guest, theme, rule_name)
                # The browser renamed the destination and saved a rule that is
                # still disabled.
                cfg = api(opener, {'action': 'notification_config'})['result']
                assert next(t for t in cfg['targets'] if t['id'] == target)['name'] == 'Notification fixture edited'
                rule = next(r for r in cfg['rules'] if r['name'] == rule_name)['id']
                assert not next(r for r in cfg['rules'] if r['id'] == rule)['enabled']
                # The 100-second deadline allows a default 60-second check
                # interval plus scheduler and delivery time.
                test = api(opener, {'action': 'test_notification_target',
                    'object': target, 'token': token}, True)['result']['id']
                deadline = time.monotonic() + 100
                while time.monotonic() < deadline:
                    if any(event['id'] == test for event in received):
                        # This test's event arrived. Other fixture
                        # deliveries do not count.
                        break
                    time.sleep(1)
                else:
                    # A deadline expiry is a worker failure,
                    # not a transport success.
                    raise AssertionError('Scheduled worker did not deliver within 100 seconds')
                # History must record the delivery as sent.
                history = api(opener, {'action': 'notifications', 'cursor': test - 1})['result']
                assert history['events'][0]['deliveries'][0]['state'] == 'sent'
                guests = api(opener, {'action': 'machines'})['result']
                assert guests, 'At least one existing guest is needed for ACL testing'
                guest = guests[0]['id']
                # Delegated access permits only the assigned guest's history.
                account('acl', theme, user, json.dumps({'admin': 0, 'vms': guest}))
                assert 'error' in api(opener, {'action': 'notification_config'})
                assert 'error' in api(opener, {'action': 'notifications'})
                assert 'result' in api(opener, {'action': 'notifications', 'id': guest})
                assert 'error' in api(opener, {'action': 'test_notification_target',
                    'object': target, 'token': token}, True)
                print('PASS tabs, create/edit pages, guest history, escaping, signed API, cron and ACL:', theme, flush=True)
            finally:
                if created:
                    # Restore this fixture account's rights
                    # before removing its records.
                    account('acl', theme, user, json.dumps({'admin': 1}))
                    if opener and token:
                        # API cleanup needs the authenticated
                        # session and signed token.
                        cfg = api(opener, {'action': 'notification_config'})['result']
                        # Clean up test events even when a browser
                        # assertion interrupted progress.
                        fixture_ids = {r['id'] for r in cfg['targets']
                                       if r['name'].startswith(user + '-setup-')}
                        history = api(opener, {'action': 'notifications', 'limit': 500})['result']
                        for event in history['events']:
                            matches = [d['target'] for d in event.get('deliveries', [])
                                       if d['target'] in fixture_ids]
                            if event['metric'] == 'test' and matches:
                                # Remove only events addressed
                                # to this run's targets.
                                subprocess.run(['perl', str(module / 't/live/clean-notifications.pl'), str(module)],
                                    input=json.dumps({'event': event['id'], 'target': matches[0]}),
                                    text=True, check=True)
                        # Remove only this run's setup records,
                        # including partial failures.
                        for record in cfg['rules']:
                            if record['name'].startswith(user + '-setup-'):
                                # The unique run prefix
                                # excludes pre-existing records.
                                assert 'result' in api(opener, {'action': 'delete_notification_rule',
                                    'object': record['id'], 'token': token}, True)
                        for record in cfg['targets']:
                            if record['name'].startswith(user + '-setup-'):
                                # The unique run prefix
                                # excludes pre-existing records.
                                assert 'result' in api(opener, {'action': 'delete_notification_target',
                                    'object': record['id'], 'token': token}, True)
                        # Find the edit rule by name if the run failed before
                        # recording its ID.
                        rule = next((r['id'] for r in cfg['rules']
                                     if r['name'] == user + '-rule'), rule)
                        if rule:
                            # Remove the edit fixture rule
                            # before its destination.
                            assert 'result' in api(opener, {'action': 'delete_notification_rule',
                                'object': rule, 'token': token}, True)
                        if target:
                            # Rules are gone, so their fixture
                            # destination is removable.
                            assert 'result' in api(opener, {'action': 'delete_notification_target',
                                'object': target, 'token': token}, True)
                    if test:
                        # The scheduled-delivery test has
                        # its own retained event.
                        subprocess.run(['perl', str(module / 't/live/clean-notifications.pl'), str(module)],
                            input=json.dumps({'event': test, 'target': target}), text=True, check=True)
                    account('delete', theme, user)
    finally:
        sink.shutdown()
print('Fixture accounts, targets, rules and browser profiles removed', flush=True)
