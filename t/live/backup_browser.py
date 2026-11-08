"""Check backup forms in a real browser using a fixture's HTTPS session."""

import json
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import websocket


# check_forms(cookies, theme, source, [ssh], [request]) tests forms and SSH
# approval. source is the UUID of the caller's stopped, private guest fixture.
# ssh supplies the private SSH fixture. request is an authenticated HTTP client
# for schedule cleanup; omit both to test only form controls and error pages.
def check_forms(cookies, theme, source, ssh=None, request=None):
    screenshot = None
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for the management browser check'
    # Snap's private /tmp is not the controller's /tmp; use its writable area.
    parent = (
        Path('/root/snap/chromium/common')
        if browser.startswith('/snap/')
        else None
    )
    # Use a profile directory visible inside the Snap browser sandbox.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-manage-browser-', dir=parent
    ) as profile:
        chrome = subprocess.Popen(
            [
                browser,
                '--headless',
                '--no-sandbox',
                '--disable-gpu',
                '--remote-debugging-port=0',
                '--ignore-certificate-errors',
                '--no-first-run',
                '--no-default-browser-check',
                '--disable-background-networking',
                '--disable-sync',
                '--window-size='
                + os.environ.get('CLOUDMIN_BACKUP_VIEWPORT', '1600,1000'),
                '--user-data-dir=' + profile,
                'about:blank',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cdp = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 20
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection(
                'ws://127.0.0.1:' + port + route,
                timeout=30,
                suppress_origin=True,
            )
            serial, session = 0, None
            requests = []

            # call(method, [params]) waits for the matching browser
            # command reply.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = {
                    'id': serial,
                    'method': method,
                    'params': params or {},
                }
                # Tab commands require a session only after attachment.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Record navigation routes without request bodies or tokens.
                    if reply.get('method') == 'Network.requestWillBeSent':
                        request = reply['params']['request']
                        path = urllib.parse.urlsplit(request['url']).path
                        # Ignore static assets and unrelated Webmin requests.
                        if path.startswith(
                            '/server-manager/'
                        ) and path.endswith('.cgi'):
                            requests.append((request['method'], path))
                    # Ignore browser events until the requested command
                    # is answered.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(expression) returns a JSON-compatible value from
            # the page.
            def evaluate(expression):
                # Frame layouts can redirect a direct module URL into
                # their shell.
                expression = (
                    '(window.frames.right || window).eval('
                    + json.dumps(expression)
                    + ')'
                )
                result = call(
                    'Runtime.evaluate',
                    {'expression': expression, 'returnByValue': True},
                )
                # Report JavaScript failures before they cause a later timeout.
                assert 'exceptionDetails' not in result, result.get(
                    'exceptionDetails'
                )
                return result.get('result', {}).get('value')

            # wait(expression, [timeout]) polls through navigation, up to 45s
            # by default.
            def wait(expression, timeout=45):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    # Continue only when the rendered page meets the
                    # requested condition.
                    if evaluate('!!(' + expression + ')'):
                        return
                    time.sleep(.25)
                # Include recent page output and routes to diagnose stuck forms.
                detail = evaluate('document.body?.innerText.slice(-1800)')
                links = evaluate(
                    'Array.from(document.querySelectorAll("a[href]")).filter(a=>/backup|restore/.test(a.textContent)).map(a=>[a.textContent,a.getAttribute("href")])'
                )
                # Capture a failed wait when the caller requested a screenshot.
                if screenshot:
                    picture = call(
                        'Page.captureScreenshot',
                        {'format': 'jpeg', 'quality': 55},
                    )
                    Path(screenshot).write_bytes(
                        base64.b64decode(picture['data'])
                    )
                raise AssertionError(
                    'Browser condition failed: '
                    + expression
                    + '; requests: '
                    + str(requests[-12:])
                    + '; links: '
                    + str(links)
                    + '; page: '
                    + str(detail)
                )

            target = call('Target.createTarget', {'url': 'about:blank'})[
                'targetId'
            ]
            session = call(
                'Target.attachToTarget', {'targetId': target, 'flatten': True}
            )['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain + '.enable')
            call(
                'Emulation.setEmulatedMedia',
                {
                    'features': [
                        {'name': 'prefers-color-scheme', 'value': 'dark'}
                    ]
                },
            )
            for cookie in cookies:
                call(
                    'Network.setCookie',
                    {
                        'name': cookie.name,
                        'value': cookie.value,
                        'url': 'https://127.0.0.1:10000',
                        'path': cookie.path,
                        'secure': True,
                    },
                )
            call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            # Select the module in the navigation frame when present.
            if evaluate('!!top.frames.left'):
                evaluate(
                    'top.frames.left.location="/left.cgi?mode=server-manager"'
                )
            # Sidebar links can appear before their navigation handlers bind.
            # Frame layouts can start with an empty content frame and
            # no referrer.
            if 'authentic' in theme:
                wait('document.body.getAttribute("data-initial-load") === "0"')
            # Open the module directly in the content frame.
            else:
                tree = call('Page.getFrameTree')['frameTree']
                frame = next(
                    f['frame']['id']
                    for f in tree['childFrames']
                    if f['frame'].get('name') == 'right'
                )
                call(
                    'Page.navigate',
                    {
                        'url': 'https://127.0.0.1:10000/server-manager/backups.cgi',
                        'frameId': frame,
                        'referrer': 'https://127.0.0.1:10000/',
                    },
                )
                wait('document.querySelector("#cloudmin-backup-archives")')

            def follow(endpoint):
                """
                follow(endpoint) uses native links and the active theme's
                navigation.
                """
                evaluate(
                    '(() => {const a=document.createElement("a"); a.href='
                    + json.dumps('/server-manager/')
                    + '+'
                    + json.dumps(endpoint)
                    + '; document.body.append(a); a.click(); a.remove();})()'
                )

            for endpoint, selector in [
                ('backup_form.cgi', 'dest0_mode'),
                ('restore_form.cgi', 'src_mode'),
            ]:
                follow('backups.cgi')
                wait(
                    'document.querySelector("#cloudmin-backup-archives .ui_card_body")'
                )
                # Empty cards must not show headings for a nonexistent table.
                assert evaluate(
                    'Array.from(document.querySelectorAll("#cloudmin-backup-archives,#cloudmin-backup-schedules")).every(c=>!c.querySelector(".ui_empty") || !c.querySelector("table"))'
                )
                assert evaluate(
                    'Array.from(document.querySelectorAll("#cloudmin-backup-archives table.ui_columns,#cloudmin-backup-schedules table.ui_columns")).every(t=>t.getBoundingClientRect().width>t.closest(".ui_card_body").getBoundingClientRect().width*.8)'
                )
                # Save evidence only when the caller explicitly requests it.
                if endpoint == 'backup_form.cgi' and os.environ.get(
                    'CLOUDMIN_BACKUP_SCREENSHOTS'
                ):
                    picture = call('Page.captureScreenshot', {'format': 'png'})
                    Path(
                        os.environ['CLOUDMIN_BACKUP_SCREENSHOTS'],
                        theme + '-backups.png',
                    ).write_bytes(base64.b64decode(picture['data']))
                follow(endpoint)
                wait('document.querySelector("select[name=' + selector + ']")')
                if endpoint == 'backup_form.cgi':
                    # The built-in mode switch hides the list without
                    # losing choices.
                    wait(
                        'document.querySelector("#ui_multi_guests select[name=all]")'
                    )
                    assert (
                        evaluate(
                            'document.querySelector("#ui_multi_guests select[name=all]").value'
                        )
                        == '1'
                    )
                    assert not evaluate(
                        'document.querySelector("#ui_multi_guests .ui_multi_list").getClientRects().length'
                    )
                    evaluate(
                        '(() => { const s=document.querySelector("select[name=all]"); s.value="0"; s.dispatchEvent(new Event("change",{bubbles:true})); })()'
                    )
                    wait(
                        'document.querySelector("#ui_multi_guests .ui_multi_list").getClientRects().length'
                    )
                    evaluate(
                        'document.querySelector(\'#ui_multi_guests input[data-ui-multi-item][value="'
                        + source
                        + '"]\').click()'
                    )
                    selected = evaluate(
                        'document.querySelector("input[name=guests]").value'
                    )
                    assert selected, (
                        'Checkbox selection was not added to the submitted field'
                    )
                    for mode in ('1', '0'):
                        evaluate(
                            '(() => { const s=document.querySelector("select[name=all]"); s.value='
                            + json.dumps(mode)
                            + '; s.dispatchEvent(new Event("change",{bubbles:true})); })()'
                        )
                    assert (
                        evaluate(
                            'new FormData(document.querySelector("input[name=guests]").form).get("guests")'
                        )
                        == selected
                    )
                    # Save an optional screenshot without affecting
                    # the assertions.
                    if os.environ.get('CLOUDMIN_BACKUP_SCREENSHOTS'):
                        picture = call(
                            'Page.captureScreenshot', {'format': 'png'}
                        )
                        Path(
                            os.environ['CLOUDMIN_BACKUP_SCREENSHOTS'],
                            theme + '-backup-form.png',
                        ).write_bytes(base64.b64decode(picture['data']))
                # Exercise every installed provider, including Pro's
                # field groups.
                modes = evaluate(
                    'Array.from(document.querySelector("select[name='
                    + selector
                    + ']").options).map(o=>o.value)'
                )
                switch = (
                    'document.querySelector("select[name='
                    + selector
                    + ']").closest(".ui_select_switch")'
                )
                for mode in modes:
                    evaluate(
                        '(() => { const s=document.querySelector("select[name='
                        + selector
                        + ']"); s.value='
                        + json.dumps(mode)
                        + '; s.dispatchEvent(new Event("change",{bubbles:true})); })()'
                    )
                    wait(
                        switch
                        + '.querySelector(":scope > [data-ui-switch-value='
                        + mode
                        + ']")?.getClientRects().length > 0'
                    )
                    visible = evaluate(
                        'Array.from('
                        + switch
                        + '.children).filter(e=>e.matches("[data-ui-switch-value]") && e.getClientRects().length).map(e=>e.dataset.uiSwitchValue)'
                    )
                    assert visible == [mode], visible
                    # SSH has a nested authentication switch within
                    # its provider.
                    if mode == 'ssh':
                        prefix = selector.removesuffix('_mode') + '_ssh_'
                        # The nested selector switches credentials without
                        # hiding the provider.
                        for method, field, hidden in [
                            ('key', 'key_file', 'password'),
                            ('password', 'password', 'key_file'),
                        ]:
                            evaluate(
                                '(() => { const s=document.querySelector("select[name='
                                + prefix
                                + 'authentication]"); s.value='
                                + json.dumps(method)
                                + '; s.dispatchEvent(new Event("change",{bubbles:true})); })()'
                            )
                            wait(
                                'document.querySelector("input[name='
                                + prefix
                                + field
                                + ']").getClientRects().length'
                            )
                            assert not evaluate(
                                'document.querySelector("input[name='
                                + prefix
                                + hidden
                                + ']").getClientRects().length'
                            )
                            assert bool(
                                evaluate(
                                    'document.querySelector("input[name='
                                    + prefix
                                    + 'user]").getClientRects().length'
                                )
                            ) == (method == 'password')
                            assert (
                                evaluate(
                                    'new FormData(document.querySelector("input[name='
                                    + prefix
                                    + 'user]").form).get("'
                                    + prefix
                                    + 'user")'
                                )
                                == ''
                            )
                        for field, hint in [
                            ('user', 'Username'),
                            ('password', 'Password'),
                        ]:
                            assert (
                                evaluate(
                                    'document.querySelector("input[name='
                                    + prefix
                                    + field
                                    + ']").placeholder'
                                )
                                == hint
                            )
                        assert not evaluate(
                            'document.querySelector("input[name='
                            + prefix
                            + 'host_key]")'
                        )
                    if os.environ.get(
                        'CLOUDMIN_BACKUP_SCREENSHOTS'
                    ) and mode in ('local', 'ssh'):
                        # Show the destination fields in both theme layouts.
                        evaluate(
                            'document.querySelector("select[name='
                            + selector
                            + ']").scrollIntoView({block:"start"})'
                        )
                        picture = call(
                            'Page.captureScreenshot',
                            {'format': 'jpeg', 'quality': 70},
                        )
                        Path(
                            os.environ['CLOUDMIN_BACKUP_SCREENSHOTS'],
                            theme + '-' + endpoint + '-' + mode + '.jpg',
                        ).write_bytes(base64.b64decode(picture['data']))
                # Navigation must recognize both execution pages as
                # streaming CGI.
                if 'authentic' in theme:
                    assert evaluate(
                        'unbuffered_header_processor_allow("/server-manager/backup.cgi",true)'
                    )
                    assert evaluate(
                        'unbuffered_header_processor_allow("/server-manager/restore.cgi",true)'
                    )
                # Reject an incomplete SSH destination before any work starts.
                prefix = selector.removesuffix('_mode')
                values = {
                    selector: 'ssh',
                    prefix + '_ssh_host': '',
                    prefix + '_ssh_path': '/var/tmp',
                    prefix + '_ssh_authentication': 'key',
                    prefix + '_ssh_key_file': '/nonexistent-fixture-key',
                }
                if endpoint == 'restore_form.cgi':
                    # Supply an archive name to reach SSH validation.
                    values['filename'] = 'fixture.tar'
                else:
                    # Use only the owned fixture, even while other guests
                    # are busy.
                    values.update(all='0', guests=source)
                evaluate(
                    '(() => {for (const [name,value] of Object.entries('
                    + json.dumps(values)
                    + ')) {const e=document.querySelector("[name="+name+"]"); e.value=value; e.dispatchEvent(new Event("change",{bubbles:true}));}})()'
                )
                button = (
                    'document.querySelector("select[name='
                    + selector
                    + ']").form.querySelector(".ui_form_end_submit, input[type=submit], button[type=submit]")'
                )
                evaluate(button + '.click()')
                wait(
                    'document.querySelector("[data-fatal-error-text]") && !document.querySelector("select[name='
                    + selector
                    + ']")'
                )
                # Back from the error page must restore the chosen destination.
                evaluate('history.back()')
                wait('document.querySelector("select[name=' + selector + ']")')
                assert (
                    evaluate(
                        'document.querySelector("select[name='
                        + selector
                        + ']").value'
                    )
                    == 'ssh'
                ), 'Back lost the destination'
                # Changed input must reach validation with the restored token.
                evaluate(
                    '(() => {const s=document.querySelector("select[name='
                    + selector
                    + ']"); s.value="local"; s.dispatchEvent(new Event("change",{bubbles:true})); document.querySelector("input[name='
                    + prefix
                    + '_local_path]").value="relative-path";})()'
                )
                evaluate(button + '.click()')
                wait(
                    'document.querySelector("[data-fatal-error-text]") && document.body.innerText.includes("Enter an absolute backup directory")'
                )
                print(
                    theme
                    + ': '
                    + endpoint
                    + ' error page and resubmission passed'
                )
            # A scheduled backup shows only the chosen recurrence's
            # time controls.
            follow('backups.cgi')
            wait(
                'document.querySelector("#cloudmin-backup-archives .ui_card_body")'
            )
            evaluate(
                'Array.from(document.querySelectorAll("a[href]")).find(a=>new URL(a.href).pathname.endsWith("/backup_form.cgi") && new URL(a.href).searchParams.get("new")==="1").click()'
            )
            wait('document.querySelector("select[name=frequency]")')
            evaluate(
                'document.querySelector("#hiddenopener_sched, details[data-name=\\"sched\\"] > summary").click()'
            )
            wait(
                'document.querySelector("select[name=frequency]").getClientRects().length'
            )
            for frequency, fields in [
                ('hourly', ['minute']),
                ('daily', ['hour', 'minute']),
                ('weekly', ['weekday', 'hour', 'minute']),
                ('monthly', ['day', 'hour', 'minute']),
                ('yearly', ['month', 'day', 'hour', 'minute']),
            ]:
                evaluate(
                    '(() => {const s=document.querySelector("select[name=frequency]"); s.value='
                    + json.dumps(frequency)
                    + '; s.dispatchEvent(new Event("change",{bubbles:true}));})()'
                )
                prefix = 'schedule_' + frequency + '_'
                wait(
                    'document.querySelector("select[name='
                    + prefix
                    + 'minute]").getClientRects().length'
                )
                visible = evaluate(
                    'Array.from(document.querySelectorAll(".cloudmin-backup-schedule select")).filter(s=>s.name!=="frequency" && s.getClientRects().length).map(s=>s.name)'
                )
                assert visible == [prefix + field for field in fields], visible
                # Daily and calendar schedules keep hour and minute
                # controls level.
                if frequency != 'hourly':
                    positions = evaluate(
                        '["hour","minute"].map(n=>document.querySelector("select[name='
                        + prefix
                        + '"+n+"]").getBoundingClientRect().top)'
                    )
                    assert abs(positions[0] - positions[1]) < 1, (
                        'Hours and minutes must share one row'
                    )
            assert evaluate(
                'Array.from(document.querySelector("select[name=purge]").querySelectorAll("optgroup")).map(g=>g.label)'
            ) == ['Days', 'Weeks', 'Months', 'Years']
            assert (
                evaluate('document.querySelector("select[name=purge]").value')
                == '0'
            )
            assert not evaluate(
                'document.body.innerText.includes("The newest successful backup")'
            )
            assert evaluate(
                'document.querySelector("a[href$=\\"/backup_frequency\\"]") !== null'
            )
            # Capture the schedule controls only when an output directory
            # is supplied.
            if os.environ.get('CLOUDMIN_BACKUP_SCREENSHOTS'):
                evaluate(
                    'document.querySelector("select[name=frequency]").scrollIntoView({block:"center"})'
                )
                picture = call('Page.captureScreenshot', {'format': 'png'})
                Path(
                    os.environ['CLOUDMIN_BACKUP_SCREENSHOTS'],
                    theme + '-backup-schedule.png',
                ).write_bytes(base64.b64decode(picture['data']))
            print(theme + ': schedule controls and grouped retention passed')
            # Run the save test only with an SSH fixture and cleanup client.
            if ssh and request:
                # Leave the host invalid and keep the schedule disabled.
                values = {
                    'dest0_mode': 'ssh',
                    'dest0_ssh_host': '',
                    'dest0_ssh_port': str(ssh.port),
                    'dest0_ssh_authentication': 'key',
                    'dest0_ssh_key_file': str(ssh.work / 'client'),
                    'dest0_ssh_path': str(ssh.work),
                    'description': 'Browser Back fixture',
                }
                evaluate(
                    '(() => { for (const [name,value] of Object.entries('
                    + json.dumps(values)
                    + ')) { const e=document.querySelector("[name="+name+"]"); e.value=value; e.dispatchEvent(new Event("change",{bubbles:true})); } const port=Array.from(document.querySelectorAll("input[name=dest0_ssh_port_def]")).find(e=>e.value==="0"); (port.labels[0] || port).click(); Array.from(document.getElementsByName("enabled")).find(e=>e.value==="0").checked=true; })()'
                )
                evaluate(
                    'document.querySelector("input[name=dest0_ssh_port]").value='
                    + json.dumps(str(ssh.port))
                )
                token = evaluate(
                    'document.querySelector("input[name=token]").value'
                )
                saved = None
                try:
                    # A failed probe must reach error() and allow Back.
                    evaluate('document.querySelector("[name=save]").click()')
                    wait(
                        'document.body.innerText.includes("Enter a valid SSH server, username and port") && !document.querySelector("select[name=dest0_mode]")'
                    )
                    evaluate('history.back()')
                    wait(
                        'document.readyState === "complete" && document.querySelector("select[name=dest0_mode]")'
                    )
                    # Either theme can restore cached markup or reload the form.
                    # The corrected save below verifies its returned
                    # token works.
                    token = evaluate(
                        'document.querySelector("input[name=token]").value'
                    )
                    assert (
                        evaluate(
                            'document.querySelector("select[name=dest0_mode]").value'
                        )
                        == 'ssh'
                    ), 'Back lost the destination'
                    assert (
                        evaluate(
                            'document.querySelector("input[name=description]").value'
                        )
                        == values['description']
                    ), 'Back lost the entered description'
                    # Wait for optional controls to restore their values.
                    wait(
                        '!document.querySelector("input[name=dest0_ssh_port]").disabled'
                    )
                    restored = evaluate(
                        '(() => {const f=new FormData(document.querySelector("select[name=dest0_mode]").form); return Object.fromEntries(["dest0_mode","dest0_ssh_port_def","dest0_ssh_port","dest0_ssh_authentication","dest0_ssh_key_file","enabled"].map(n=>[n,f.get(n)]));})()'
                    )
                    assert restored == {
                        'dest0_mode': 'ssh',
                        'dest0_ssh_port_def': '0',
                        'dest0_ssh_port': str(ssh.port),
                        'dest0_ssh_authentication': 'key',
                        'dest0_ssh_key_file': str(ssh.work / 'client'),
                        'enabled': '0',
                    }, restored
                    # Fix only the host, approve its key and save the form.
                    evaluate(
                        'document.querySelector("input[name=dest0_ssh_host]").value="127.0.0.1"; document.querySelector("[name=save]").click()'
                    )
                    wait('document.querySelector("[data-backup-host-trust]")')
                    evaluate(
                        'document.querySelector("[data-backup-host-trust]").click()'
                    )
                    wait('document.querySelector("#cloudmin-backup-schedules")')
                    saved = evaluate(
                        'Array.from(document.querySelectorAll("a[href] ")).find(a=>a.textContent==="Browser Back fixture")?.getAttribute("href")'
                    )
                    assert saved, 'Corrected schedule was not saved'
                    saved = saved.split('sched=', 1)[1].split('&', 1)[0]
                finally:
                    # Remove the test schedule if it was saved.
                    if saved:
                        request(
                            '/server-manager/backup_sched.cgi',
                            {'token': token, 'sched': saved, 'delete': 1},
                        )
                    ssh.reset()
                print(
                    theme
                    + ': error page, browser Back and corrected schedule save passed'
                )
            if ssh:
                # Intercept only the final operation; probes and approvals use
                # real HTTP.
                follow('backups.cgi')
                wait(
                    'document.querySelector("#cloudmin-backup-archives .ui_card_body")'
                )
                follow('restore_form.cgi')
                wait('document.querySelector("select[name=src_mode]")')
                values = {
                    'src_mode': 'ssh',
                    'src_ssh_host': '127.0.0.1',
                    'src_ssh_port': str(ssh.port),
                    'src_ssh_authentication': 'key',
                    'src_ssh_key_file': str(ssh.work / 'client'),
                    'src_ssh_path': str(ssh.work),
                    'filename': 'fixture.tar',
                }
                evaluate(
                    '(() => { for (const [name,value] of Object.entries('
                    + json.dumps(values)
                    + ')) { const e=document.querySelector("[name="+name+"]"); e.value=value; e.dispatchEvent(new Event("change",{bubbles:true})); } const port=Array.from(document.querySelectorAll("input[name=src_ssh_port_def]")).find(e=>e.value==="0"); (port.labels[0] || port).click(); })()'
                )
                evaluate(
                    'document.querySelector("input[name=src_ssh_port]").value='
                    + json.dumps(str(ssh.port))
                )
                port_fields = evaluate(
                    '(() => { const f=new FormData(document.querySelector("select[name=src_mode]").form); return [f.get("src_ssh_port_def"),f.get("src_ssh_port")]; })()'
                )
                assert port_fields == ['0', str(ssh.port)], (
                    port_fields,
                    evaluate(
                        'Array.from(document.querySelectorAll("input[name=src_ssh_port_def]")).map(e=>e.parentElement.outerHTML)'
                    ),
                )
                evaluate(
                    '(() => { const form=document.querySelector("select[name=src_mode]").form; window.hostTrustForwarded=false; form.addEventListener("submit",e=>{e.preventDefault(); e.stopImmediatePropagation(); window.hostTrustForwarded=true;},true); })()'
                )
                # Capture approval status and errors without keys or tokens.
                evaluate(
                    '(() => {const original=window.fetch; window.hostTrustReplies=[]; window.fetch=async (...args)=>{const response=await original(...args); if(String(args[0]).includes("backup-host-key.cgi")) {const result=await response.clone().json(); window.hostTrustReplies.push({status:result.status,error:result.error});} return response;};})()'
                )
                for changed in (False, True):
                    # Reinstall simulation must show both old and
                    # new fingerprints.
                    if changed:
                        ssh.rotate()
                        evaluate('window.hostTrustForwarded=false')
                    evaluate(
                        'document.querySelector("select[name=src_mode]").form.requestSubmit()'
                    )
                    wait('document.querySelector("[data-backup-host-trust]")')
                    text = evaluate(
                        'document.querySelector("[data-backup-host-confirm]").textContent'
                    )
                    assert (
                        'SSH server key has changed'
                        if changed
                        else 'Unknown SSH server'
                    ) in text
                    assert (
                        'Previously trusted fingerprints' in text
                    ) == changed
                    assert 'SHA256:' in text
                    assert '[127.0.0.1]:' + str(ssh.port) in text, (
                        'Confirmation targeted another SSH service'
                    )
                    assert not evaluate('window.hostTrustForwarded')
                    if not changed:
                        # Cancellation must not silently trust the
                        # probed server.
                        evaluate(
                            'document.querySelector("[data-backup-host-cancel]").click()'
                        )
                        assert not ssh.trust.exists()
                        evaluate(
                            'document.querySelector("select[name=src_mode]").form.requestSubmit()'
                        )
                        wait(
                            'document.querySelector("[data-backup-host-trust]")'
                        )
                    evaluate(
                        'document.querySelector("[data-backup-host-trust]").click()'
                    )
                    wait('window.hostTrustForwarded')
                    assert ssh.trust.exists(), evaluate(
                        'window.hostTrustReplies'
                    )
                # Already trusted servers submit without asking again.
                evaluate(
                    'window.hostTrustForwarded=false; document.querySelector("select[name=src_mode]").form.requestSubmit()'
                )
                wait('window.hostTrustForwarded')
                assert not evaluate(
                    'document.querySelector("[data-backup-host-trust]")'
                )
                print(
                    theme
                    + ': SSH approval, cancellation and explicit replacement passed'
                )
            print(
                theme
                + ': browser destination switching and progress routing passed'
            )
        finally:
            # An attached browser can exit cleanly through DevTools.
            if cdp:
                # Let Chromium stop its profile writers before removing
                # the directory.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, OSError):
                    pass
                cdp.close()
            # Stop the owned browser directly if DevTools setup failed.
            else:
                chrome.terminate()
            try:
                chrome.wait(timeout=10)
            # Bound shutdown if the owned browser cannot exit normally.
            except subprocess.TimeoutExpired:
                chrome.kill()
                chrome.wait()
