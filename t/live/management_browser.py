"""Submit the VM editor in a real browser using a fixture's HTTPS session."""
import json
import base64
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import websocket


# check_memory_inputs(evaluate) checks native browser validity without saving.
# evaluate runs JavaScript in the editor's document, including framed themes.
def check_memory_inputs(evaluate):
    result = evaluate(r"""(() => {
        const form = document.getElementById('vm-edit-form');
        const memory = form.elements.memory_mib, maximum = form.elements.memory_limit_mib;
        // Fixed guest layouts do not offer editable memory controls.
        if (memory.disabled || maximum.disabled) return {locked: true};
        const units = form.elements.memory_mib_units, maxUnits = form.elements.memory_limit_mib_units;
        const fields = [memory, maximum, units, maxUnits];
        const saved = fields.map(input => input.value);
        // check(ok, message) throws a diagnostic for the Python caller.
        const check = (ok, message) => { if (!ok) throw new Error(message); };
        // event(input, name, [synthetic]) sends a native event by default.
        const event = (input, name, synthetic = false) => {
            // Exercise theme notifications when jQuery is present.
            if (synthetic && window.jQuery) jQuery(input).trigger(name);
            // Framed pages and ordinary controls use native bubbling events.
            else input.dispatchEvent(new Event(name, {bubbles: true}));
        };
        try {
            // Arbitrary whole MiB must work, not only multiples of 128.
            units.value = maxUnits.value = '1048576';
            event(units, 'change'); event(maxUnits, 'change', true);
            maximum.value = '2000'; event(maximum, 'input');
            memory.value = '1000'; event(memory, 'input');
            check(memory.checkValidity() && maximum.checkValidity(), '1000/2000 MiB rejected');
            // Fractions are invalid while typing and become whole MiB on commit.
            memory.value = '1152.6'; event(memory, 'input');
            check(memory.validity.stepMismatch, 'Fractional MiB was accepted');
            event(memory, 'change', true);
            check(memory.value === '1153' && memory.checkValidity(), 'MiB commit did not round');
            // Spinners must keep whole MiB when increasing or decreasing.
            memory.stepUp(); event(memory, 'input');
            check(memory.value === '1281' && memory.checkValidity(), 'MiB spinner kept a fraction');
            memory.stepDown(); event(memory, 'input');
            check(memory.value === '1153', 'MiB spinner did not decrease by 128');
            // Theme-only input events must refresh both the grid and allocation cap.
            memory.value = '1000'; event(memory, 'input', true);
            maximum.value = '2000'; event(maximum, 'input', true);
            check(memory.checkValidity() && maximum.checkValidity(), 'Theme integer input rejected');
            maximum.value = '1500'; event(maximum, 'input', true);
            check(Number(memory.max) === 1500, 'Theme maximum did not update allocation bounds');
            // GiB retains tenths and exact quarter-GiB entries.
            units.value = '1073741824'; event(units, 'change', true);
            memory.value = '1.1'; event(memory, 'input');
            memory.stepUp(); event(memory, 'input');
            check(memory.value === '1.2' && memory.checkValidity(), 'GiB increment is incorrect');
            memory.stepDown(); event(memory, 'input');
            check(memory.value === '1.1', 'GiB decrement is incorrect');
            memory.value = '1.25'; event(memory, 'input', true);
            check(memory.checkValidity(), 'Quarter GiB rejected');
            // Unit changes and KiB spinners must still represent whole MiB.
            memory.value = '1152.6'; event(memory, 'input');
            units.value = '1048576'; event(units, 'change', true);
            check(memory.value === '1153' && memory.checkValidity(), 'Unit change kept fractional MiB');
            units.value = '1024'; event(units, 'change');
            memory.value = '1048576'; event(memory, 'input');
            memory.stepUp(); event(memory, 'input');
            check(memory.value === '1179648' && memory.checkValidity(), 'KiB increment is incorrect');
            // Host, minimum and selected-maximum checks must remain active.
            units.value = '1048576'; event(units, 'change');
            memory.value = '255'; event(memory, 'input');
            check(memory.validity.rangeUnderflow, 'Minimum memory was bypassed');
            memory.value = '1501'; event(memory, 'input');
            check(memory.validity.rangeOverflow, 'Maximum memory was bypassed');
            check(form.elements.cpus.step === '1', 'CPU step changed');
            return {passed: true};
        } catch (error) {
            // Return assertion details across the browser debugging connection.
            return {error: error.message};
        } finally {
            // Leave the caller's form exactly as it was; never submit these values.
            fields.forEach((input, index) => { input.value = saved[index]; });
            event(units, 'change'); event(maxUnits, 'change');
        }
    })()""")
    assert result and (result.get('passed') or result.get('locked')), result


# edit_guest(cookies, uuid, [action], [screenshot], [on_shutdown],
# [disk_choice],
#            [disk], [on_confirmation]) exercises the installed management UI.
# action defaults to update; other optional inputs default to no extra action.
# on_shutdown completes a controlled fixture's stop after the pending view loads.
# disk supplies one disk's target/name, or targets for whole-VM deletion.
# on_confirmation checks that opening deletion or power-off confirmation is harmless.
def edit_guest(cookies, uuid, action='update', screenshot=None, on_shutdown=None, disk_choice=None, disk=None, on_confirmation=None):
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for the management browser check'
    # Snap's private /tmp is not the controller's /tmp; use its writable area.
    parent = Path('/root/snap/chromium/common') if browser.startswith('/snap/') else None
    # Use a profile directory visible inside the Snap browser sandbox.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cloudmin-manage-browser-', dir=parent) as profile:
        chrome = subprocess.Popen([browser, '--headless', '--no-sandbox', '--disable-gpu',
            '--remote-debugging-port=0', '--ignore-certificate-errors', '--no-first-run',
            '--no-default-browser-check', '--disable-background-networking', '--disable-sync',
            '--window-size=1600,1000', '--user-data-dir='+profile, 'about:blank'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        try:
            active = Path(profile)/'DevToolsActivePort'
            deadline = time.monotonic()+20
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:'+port+route,
                                              timeout=30, suppress_origin=True)
            serial, session = 0, None

            # call(method, [params]) waits for the matching browser command reply.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = {'id': serial, 'method': method, 'params': params or {}}
                # Tab commands require a session only after attachment.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Ignore browser events until the requested command is answered.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(expression) returns a JSON-compatible value from the page.
            def evaluate(expression):
                # Frame layouts can redirect a direct module URL into their shell.
                expression = ('(window.frames.right || window).eval('+json.dumps(expression)+')')
                result = call('Runtime.evaluate', {'expression': expression, 'returnByValue': True})
                return result.get('result', {}).get('value')

            # wait(expression, [timeout]) polls through navigation, up to 45s by
            # default.
            def wait(expression, timeout=45):
                deadline = time.monotonic()+timeout
                while time.monotonic() < deadline:
                    # Continue only when the rendered page meets the requested condition.
                    if evaluate('!!('+expression+')'):
                        return
                    time.sleep(.25)
                detail = evaluate('document.body?.innerText.slice(0, 1500)')
                # Capture a failed wait when the caller requested a screenshot.
                if screenshot:
                    picture = call('Page.captureScreenshot', {'format': 'jpeg', 'quality': 55})
                    Path(screenshot).write_bytes(base64.b64decode(picture['data']))
                raise AssertionError('Browser condition failed: '+expression+'; page: '+str(detail))

            target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
            for domain in ('Page', 'Runtime', 'Network'):
                call(domain+'.enable')
            for cookie in cookies:
                call('Network.setCookie', {'name': cookie.name, 'value': cookie.value,
                     'url': 'https://127.0.0.1:10000', 'path': cookie.path, 'secure': True})
            # Open the theme shell, then use its actual navigation links.
            call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            # Load Cloudmin navigation in the separate frame-based sidebar.
            if evaluate('!!top.frames.left'):
                evaluate('top.frames.left.location = "/left.cgi?mode=server-manager"')
            navigation = '[top.document, ...Array.from(top.frames, w => w.document)]'
            overview = ('('+navigation+').flatMap(d => Array.from(d.querySelectorAll("a[href]")))'
                        '.find(a => new URL(a.href).pathname.endsWith("/server-manager/index.cgi"))')
            wait(overview)
            evaluate('('+overview+').click()')
            details_action = action.removeprefix('details_') if action.startswith('details_') else None
            pages = ('machine.cgi',) if details_action else ('machine.cgi', 'edit_machine.cgi')
            for page in pages:
                # URLs may encode UUID hyphens or include theme parameters.
                documents = ('[document]' if page == 'machine.cgi' else
                             navigation)
                link = ('('+documents+').flatMap(d => Array.from(d.querySelectorAll("a[href]"))).find(a => '
                        'new URL(a.href).pathname.endsWith('+json.dumps('/'+page)+') && '
                        'new URL(a.href).searchParams.get("id") === '+json.dumps(uuid)+')')
                wait(link)
                evaluate('('+link+').click()')
                if action == 'power_cycle':
                    # Wait for each navigation before clicking its next link.
                    wait('document.querySelector("[data-vm-details]")' if page == 'machine.cgi' else
                         'document.querySelector("#vm-edit-form")')
            if action == 'power_cycle':
                # Exercise the themed saved-change banner and its independent POST.
                wait('document.querySelector("#vm-power-cycle-form button")?.getClientRects().length > 0')
                assert evaluate('document.querySelector("[data-pending-title]").textContent.includes("Saved.")')
                assert evaluate('document.querySelector("#vm-power-cycle-form").closest("#vm-edit-form") === null')
                assert evaluate('document.querySelector("#vm-power-cycle-form").closest(".ui_form_grouped_buttons") === document.querySelector("#vm-shutdown-form").closest(".ui_form_grouped_buttons")')
                assert evaluate('!document.querySelector("#vm-next-start-notice")')
                assert evaluate('document.querySelector(".vm-header-status").closest("#headln2c") !== null')
                assert evaluate('!document.querySelector("[data-vm-pending-banner] .vm-header-status")')
                assert evaluate('document.querySelector("#vm-power-cycle-form").target !== "_blank"')
                # Badges share a center and height; footer buttons share their row.
                positions = evaluate('''(() => {
                    const rect = selector => {
                        const r = document.querySelector(selector).getBoundingClientRect();
                        return {top:r.top, height:r.height, left:r.left, right:r.right};
                    };
                    return {running:rect('.vm-pending-state'), pending:rect('[data-vm-header-pending] .ui_badge'),
                        shutdown:rect('#vm-shutdown-form button'), cycle:rect('#vm-power-cycle-form button')};
                })()''')
                assert abs(positions['running']['height']-positions['pending']['height']) < 1, positions
                assert abs(positions['running']['top']-positions['pending']['top']) < 1, positions
                assert abs(positions['shutdown']['height']-positions['cycle']['height']) < 1, positions
                assert abs(positions['shutdown']['top']-positions['cycle']['top']) < 1, positions
                assert positions['cycle']['left'] > positions['shutdown']['right'], positions
                # Save optional visual evidence after checking the button
                # geometry.
                if screenshot:
                    picture = call('Page.captureScreenshot', {'format': 'jpeg', 'quality': 75})
                    Path(screenshot).write_bytes(base64.b64decode(picture['data']))
                evaluate('document.querySelector("#vm-power-cycle-form button").click()')
                wait('!document.querySelector("[data-vm-pending-banner]")?.getClientRects().length')
                # The banner also clears during shutdown; wait for the new boot.
                wait('document.querySelector("#vm-edit-form") && document.querySelector("#vm-shutdown-form") && !document.querySelector("[data-vm-pending-banner]")?.getClientRects().length', timeout=180)
                assert evaluate('document.querySelector("#vm-power-cycle-form").hidden')
                return
            if action in ('force_off', 'details_force_off'):
                # Exercise the escape from pending shutdown, and allow paused guests.
                wait('document.querySelector("[data-vm-active] .ui_action")?.getClientRects().length > 0'
                     if details_action else 'document.querySelector("#vm-shutdown-form .ui_submit")?.getClientRects().length > 0')
                wait('document.querySelector("#cloudmin-vm-status")?.dataset.statusConnected === "1"')
                # Details expose force-off beside the live power controls.
                if details_action:
                    # Exercise pending shutdown only for a running guest, not a paused one.
                    if evaluate('document.querySelector("#cloudmin-vm-status").dataset.power === "running"'):
                        evaluate('document.querySelector("[data-vm-running] input[value=shutdown]").form.querySelector(".ui_action").click()')
                        wait('document.querySelector("#cloudmin-vm-status")?.dataset.vmShutdownRequested === "1"')
                    force = 'document.querySelector("[data-vm-active] .ui_action")'
                # The editor has its own shutdown form and emergency-stop control.
                else:
                    evaluate('document.querySelector("#vm-shutdown-form .ui_submit").click()')
                    wait('document.querySelector("#vm-shutdown-form .ui_submit")?.disabled')
                    force = 'document.querySelector("#vm-force-off-review-form .ui_submit")'
                confirm = 'document.querySelector("#vm-force-off-form")'
                # Return without submitting, then reopen and confirm.
                for cancel in (True, False):
                    wait('('+force+')?.getClientRects().length > 0')
                    evaluate('('+force+').click()')
                    wait(confirm)
                    assert evaluate(confirm+'.method') == 'post'
                    assert evaluate(confirm+'.elements.id.value') == uuid
                    assert evaluate(confirm+'.elements.confirm.value') == '1'
                    assert evaluate('document.body.innerText.includes("Unsaved data will be lost and filesystems may be damaged")')
                    assert on_confirmation, 'An independent guest-state check is required'
                    on_confirmation()
                    # Cancelling must return to the originating page without stopping the guest.
                    if cancel:
                        destination = '/machine.cgi' if details_action else '/edit_machine.cgi'
                        evaluate('Array.from(document.querySelectorAll("a[href]")).find(a => '
                                 'a.textContent.trim().startsWith("Return to ") && '
                                 'new URL(a.href).pathname.endsWith('+json.dumps(destination)+') && '
                                 'new URL(a.href).searchParams.get("id") === '+json.dumps(uuid)+').click()')
                        wait('!('+confirm+') && ('+force+')?.getClientRects().length > 0')
                        on_confirmation()
                    else:
                        # Capture the confirmation before its destructive submission.
                        if screenshot:
                            picture = call('Page.captureScreenshot', {'format': 'png'})
                            Path(screenshot).write_bytes(base64.b64decode(picture['data']))
                        evaluate(confirm+'.querySelector(".ui_submit").click()')
                # Details update live; an editor request returns to saved settings.
                wait('!('+confirm+')')
                # Details must replace active controls with Start after force-off.
                if details_action:
                    wait('document.querySelector("[data-vm-start] .ui_action")?.getClientRects().length > 0')
                    assert evaluate('document.querySelector("[data-vm-active]").hidden')
                # The editor returns to editable settings after force-off completes.
                else:
                    wait('document.querySelector("#vm-edit-form")')
                return
            if details_action:
                # Power buttons keep the details page and menu for all three actions.
                group = '[data-vm-start]' if details_action == 'start' else '[data-vm-running]'
                link = ('document.querySelector('+json.dumps(group+' input[name=action][value='+details_action+']')+
                        ')?.form.querySelector(".ui_action")')
                wait('('+link+')?.getClientRects().length > 0')
                wait('document.querySelector("#cloudmin-vm-status")?.dataset.statusConnected === "1"')
                # Opening details selects its guest asynchronously in the sidebar.
                menu = '(top.document.querySelector("aside") || top.frames.left.document.body)'
                menu_link = ('Array.from('+menu+'.querySelectorAll("a[href]")).find(a => '
                             'new URL(a.href).pathname.endsWith("/machine.cgi") && '
                             'new URL(a.href).searchParams.get("id") === '+json.dumps(uuid)+')')
                wait(menu_link)
                positions = evaluate('''(group => {
                    const state = document.querySelector('[data-vm-field="power"]').getBoundingClientRect();
                    const first = document.querySelector(group+' .ui_action').getBoundingClientRect();
                    const buttons = Array.from(document.querySelectorAll('[data-vm-running] .ui_action, [data-vm-active] .ui_action'))
                        .filter(button => button.getClientRects().length).map(button => {
                            const rect = button.getBoundingClientRect();
                            return { tag: button.tagName, left: rect.left, right: rect.right, top: rect.top,
                                decoration: getComputedStyle(button.querySelector('.ui_action_content > span')).textDecorationLine };
                        });
                    return { gap: first.left-state.right, row: Math.abs(first.top-state.top), buttons };
                })('''+json.dumps(group)+')')
                assert 0 < positions['gap'] < 40 and positions['row'] < 10, positions
                for button in positions['buttons']:
                    assert button['tag'] == 'BUTTON' and button['decoration'] == 'none', positions
                # Compare all gaps when reboot, shutdown and force-off are visible.
                if len(positions['buttons']) == 3:
                    reboot, shutdown, force_off = positions['buttons']
                    assert abs(reboot['top']-force_off['top']) < 1, positions
                    assert abs((shutdown['left']-reboot['right'])-(force_off['left']-shutdown['right'])) < 1, positions
                # Save the power-control layout when requested.
                if screenshot:
                    picture = call('Page.captureScreenshot', {'format': 'jpeg', 'quality': 75})
                    Path(screenshot).write_bytes(base64.b64decode(picture['data']))
                evaluate('''(() => {
                    top.cloudminDetailsBeforeAction = document.querySelector('#cloudmin-vm-status');
                })()''')
                evaluate('top.cloudminNavigationCheck = '+menu_link)
                evaluate('('+link+').click()')
                wait('document.querySelector("#cloudmin-vm-status") && '
                     'document.querySelector("#cloudmin-vm-status") !== top.cloudminDetailsBeforeAction')
                assert evaluate('new URL(location.href).pathname.endsWith("/machine.cgi")'), 'power action left details'
                feedback = {'start': 'Start requested', 'reboot': 'Reboot requested', 'shutdown': 'Shutdown requested'}
                wait('document.body.textContent.includes('+json.dumps(feedback[details_action])+')')
                wait('document.querySelector("#cloudmin-vm-status")?.dataset.statusConnected === "1"')
                if details_action == 'shutdown':
                    # A diskless guest stays active until the test completes its stop.
                    assert evaluate('document.querySelector("[data-vm-running]").hidden'), 'pending shutdown offers repeat actions'
                    assert evaluate('document.querySelector("[data-vm-start]").hidden'), 'pending shutdown offers Start'
                    evaluate('top.cloudminDetailsPendingShutdown = document.querySelector("#cloudmin-vm-status")')
                    assert on_shutdown, 'A controlled stop callback is required'
                    on_shutdown()
                    wait('document.querySelector("[data-vm-start] .ui_action")?.getClientRects().length > 0')
                    assert evaluate('document.querySelector("#cloudmin-vm-status") === top.cloudminDetailsPendingShutdown'), 'shutdown reloaded details'
                    assert evaluate('document.querySelector("[data-vm-running]").hidden'), 'stopped guest offers running actions'
                # Start and reboot must leave running controls visible.
                else:
                    wait('document.querySelector("#cloudmin-vm-status")?.dataset.power === "running"')
                    assert evaluate('document.querySelector("[data-vm-start]").hidden'), 'running guest still offers Start'
                    assert not evaluate('document.querySelector("[data-vm-running]").hidden'), 'running guest has no power actions'
                assert evaluate('!!top.cloudminNavigationCheck?.isConnected'), 'power action rebuilt the theme menu'
                return
            if action == 'delete_running':
                # Confirmation is available while running and is read-only on GET.
                wait('document.querySelector("#vm-delete-form .ui_submit")')
                assert not evaluate('document.querySelector("#vm-delete-form .ui_submit").disabled')
                evaluate('document.querySelector("#vm-delete-form .ui_submit").click()')
                wait('document.querySelector("#vm-delete-confirm-form")')
                assert not evaluate('document.querySelector("input[name=confirm_name]:not([type=hidden])")')
                assert not evaluate('document.body.textContent.includes("Type the virtual machine name")')
                assert evaluate('document.querySelector("input[name=shutdown]").value') == '1'
                assert not evaluate('Array.from(document.querySelectorAll("input[name=disks]")).some(i => i.checked)')
                assert on_confirmation(), 'opening confirmation stopped the VM'
                # The initial unchecked selection must preview a clean shutdown.
                assert evaluate('document.querySelector("[data-delete-stop-text]").textContent.includes("shut down cleanly")')
                assert evaluate('document.body.textContent.includes("Read-only setup media")')
                for target in disk['targets']:
                    # Select exactly the disks requested
                    # by this fixture scenario.
                    evaluate('document.querySelector('+json.dumps('input[name=disks][value="'+target+'"]')+').click()')
                expected = 'powered off immediately' if disk['targets'] == ['vda'] else 'shut down cleanly'
                wait('document.querySelector("[data-delete-stop-text]").textContent.includes('+json.dumps(expected)+')')
                # Save optional visual evidence before submitting deletion.
                if screenshot:
                    picture = call('Page.captureScreenshot', {'format': 'png'})
                    Path(screenshot).write_bytes(base64.b64decode(picture['data']))
                evaluate('document.querySelector("input[name=confirm_name]").form.querySelector(".ui_submit").click()')
                # Deletion may wait for a clean stop
                # before returning to inventory.
                wait('document.querySelector("#cloudmin-overview")', timeout=150)
                return
            wait('document.querySelector("[name=memory_mib][data-vm-limits-ready]")')
            check_memory_inputs(evaluate)
            running = action == 'shutdown'
            if running:
                # Live fields stay editable; shutdown is a separate submission.
                wait('document.querySelector("#vm-shutdown-form .ui_submit")')
                assert evaluate('document.querySelector("#vm-edit-form") !== null')
                assert not evaluate('document.querySelector("input[name=cpus]").disabled')
                assert not evaluate('document.querySelector("input[name=cpu_limit]").disabled')
                assert evaluate('document.querySelector("input[name=cpus]").type') == 'number'
                assert int(evaluate('document.querySelector("input[name=cpus]").max')) > 0
                # Deferred changes are explained by the banner after saving.
                assert evaluate('!document.querySelector("#vm-next-start-notice")')
                # Unit changes from theme widgets must update native range validation.
                limits = evaluate('''(() => {
                    const form = document.querySelector('#vm-edit-form');
                    const input = form.elements.memory_mib;
                    const units = form.elements.memory_mib_units;
                    units.value = '1048576';
                    if (window.jQuery) jQuery(units).trigger('change');
                    else units.dispatchEvent(new Event('change', {bubbles: true}));
                    input.value = Number(input.max) + 1;
                    return {min: Number(input.min), max: Number(input.max),
                        expected: Number(form.elements.memory_limit_mib.value) * Number(form.elements.memory_limit_mib_units.value) / 1048576,
                        valid: input.checkValidity()};
                })()''')
                assert limits['min'] == 256 and limits['max'] == limits['expected'] and not limits['valid'], limits
                assert not evaluate('document.querySelector("#vm-shutdown-form .ui_submit").disabled')
            # A stopped guest must expose independent Save, Start and Delete forms.
            else:
                wait('document.querySelector("input[name=cpus]")')
                wait('document.querySelector("#vm-delete-form .ui_submit")'
                     '.getBoundingClientRect().width > 0')
                controls = evaluate('''(() => {
                    const save = document.querySelector('[form="vm-edit-form"]');
                    const start = document.querySelector('#vm-start-form .ui_submit');
                    const remove = document.querySelector('#vm-delete-form .ui_submit');
                    return { save: save.disabled, start: start.disabled, remove: remove.disabled,
                        saveForm: save.form.getAttribute('id'),
                        startForm: start.form.getAttribute('id'),
                        deleteForm: remove.form.getAttribute('id'),
                        saveX: save.getBoundingClientRect().right,
                        startX: start.getBoundingClientRect().left,
                        startEnd: start.getBoundingClientRect().right,
                        deleteX: remove.getBoundingClientRect().left };
                })()''')
                assert controls['saveForm'] == 'vm-edit-form', controls
                assert controls['startForm'] == 'vm-start-form', controls
                assert controls['deleteForm'] == 'vm-delete-form', controls
                assert 0 <= controls['startX']-controls['saveX'] < 40, controls
                assert controls['startEnd']+100 < controls['deleteX'], controls
                assert controls['save'] == controls['remove'] == running, controls
                assert controls['start'] == running, controls
                assert not evaluate('document.querySelector("#vm-shutdown-form") !== null')
                assert evaluate('document.querySelector("input[name=memory_mib]").disabled') == running
            # save_editor(tab) waits for the redirected form without a Back click.
            def save_editor(tab):
                evaluate('''(() => {
                    top.cloudminEditorBeforeSave = document.querySelector('#vm-edit-form');
                    const navigation = top.document.querySelector('aside') || top.frames.left.document.body;
                    top.cloudminNavigationCheck = navigation.querySelector('a[href*="edit_machine.cgi"]');
                    document.querySelector('[form="vm-edit-form"]').click();
                    return true;
                })()''')
                wait('document.querySelector("#vm-edit-form") && '
                     'document.querySelector("#vm-edit-form") !== top.cloudminEditorBeforeSave')
                assert evaluate('document.querySelector("input[name=vm_edit_tabs]").value') == tab
                assert not evaluate('document.querySelector("[data-second-print]") !== null')
                assert evaluate('!!top.cloudminNavigationCheck?.isConnected'), 'save rebuilt the theme menu'

            # disk_panel(name, [header]) supports both Webmin accordion renderings.
            def disk_panel(name, header=False):
                selector = ('#hiddenopener_'+name+', details[data-name="'+name+'"] > summary'
                            if header else '#hiddendiv_'+name+', details[data-name="'+name+'"] > table')
                return 'document.querySelector('+json.dumps(selector)+')'

            # disk_panel_open(name) reads native disclosure state when available.
            def disk_panel_open(name):
                return ('(panel => panel.closest("details[data-name]")?.open ?? '
                        '(panel.getBoundingClientRect().height > 0))('+disk_panel(name)+')')

            # open_disk_panel(name, [opened]) clicks the theme's own panel control.
            def open_disk_panel(name, opened=True):
                panel = disk_panel(name)
                wait(panel)
                # Avoid toggling a panel that already has the requested state.
                if bool(evaluate(disk_panel_open(name))) != opened:
                    evaluate(disk_panel(name, True)+'.click()')
                wait(disk_panel_open(name)+' === '+json.dumps(opened))

            if action in ('delete_disk', 'detach_disk'):
                # Expanding storage details must not vertically recenter the label.
                evaluate('Array.from(document.querySelectorAll(".nav-tabs a, .ui_tabs a")).find(a => a.textContent.trim() === "Disks").click()')
                link = ('Array.from(document.querySelectorAll("a[href*=delete_disk]"))'
                        '.find(a => new URL(a.href).searchParams.get("delete_disk") === '+json.dumps(disk['target'])+')')
                wait(disk_panel('vm_add_disk', True)+'?.getBoundingClientRect().height > 0')
                for panel in ('vm_add_disk', 'vm_remove_disk'):
                    assert not evaluate(disk_panel_open(panel)), 'disk panel should start closed'
                    open_disk_panel(panel)
                assert evaluate('document.querySelector("input[name=add_disk_size]").form.getAttribute("id")') == 'vm-edit-form'
                if action == 'detach_disk':
                    # Closing the panel must keep its pending detach in Save.
                    evaluate('''(target => {
                        const form = document.querySelector('#vm-edit-form');
                        const field = Array.from(form.elements).find(i => i.name.endsWith('_target') && i.value === target);
                        form.elements[field.name.replace('_target', '_detach')].closest('.ui_toggle').click();
                    })('''+json.dumps(disk['target'])+')')
                    open_disk_panel('vm_remove_disk', False)
                    save_editor('disks')
                    assert not evaluate('!!('+link+')'), 'detached disk is still listed'
                    return
                wait('('+link+')?.getClientRects().length > 0')
                evaluate('window.diskCheckRow = document.querySelector('+json.dumps('input[name$="_target"][value="'+disk['target']+'"]')+').closest(".ui_list_item")')
                before = evaluate('diskCheckRow.querySelector(".ui_list_desc > span").getBoundingClientRect().top')
                evaluate('diskCheckRow.querySelector("summary").click()')
                wait('diskCheckRow.querySelector("details").open')
                alignment = evaluate('''(() => {
                    const label = diskCheckRow.querySelector('.ui_list_desc > span').getBoundingClientRect();
                    const summary = diskCheckRow.querySelector('summary').getBoundingClientRect();
                    return { label: label.top, summary: summary.top };
                })()''')
                assert abs(before-alignment['label']) < 1, alignment
                assert abs(alignment['label']-alignment['summary']) < 8, alignment
                # Capture the expanded disk facts for optional alignment review.
                if screenshot:
                    picture = call('Page.captureScreenshot', {'format': 'jpeg', 'quality': 75})
                    Path(screenshot).write_bytes(base64.b64decode(picture['data']))
                evaluate('top.cloudminNavigationCheck = (top.document.querySelector("aside") || top.frames.left.document.body).querySelector("a[href*=edit_machine]")')
                evaluate('('+link+').click()')
                confirm = 'document.querySelector("input[name=action][value=delete_disk]")?.form'
                wait(confirm)
                assert evaluate('new URL(location.href).pathname.endsWith("/edit_machine.cgi")'), 'confirmation left the editor CGI'
                assert evaluate(confirm+'.getAttribute("action")') == 'edit_machine.cgi'
                assert not evaluate('document.querySelector("input[name=confirm_name]") !== null'), 'disk deletion still requires typing'
                assert evaluate('document.querySelector(".alert-danger")?.textContent.includes("permanently deletes")'), 'disk deletion warning is not red'
                assert evaluate('document.body.textContent.includes('+json.dumps(disk['name'])+')')
                evaluate(confirm+'.querySelector(".ui_submit").click()')
                wait('document.querySelector("#vm-edit-form")')
                assert evaluate('document.querySelector("input[name=vm_edit_tabs]").value') == 'disks'
                assert not evaluate('!!('+link+')'), 'deleted disk is still listed'
                assert evaluate('!!top.cloudminNavigationCheck?.isConnected'), 'disk deletion rebuilt the VM menu'
                return
            if action == 'save':
                # Save must still submit the editor from outside its form.
                evaluate('document.querySelector("textarea[name=description]").value = "Saved browser settings"')
                save_editor('resources')
                wait('document.querySelector("textarea[name=description]")?.value === "Saved browser settings"')
                return
            if action == 'start':
                # Invalid unsaved fields must neither block Start nor become saved settings.
                evaluate('document.querySelector("textarea[name=description]").value = "Unsaved start check"')
                evaluate('document.querySelector("input[name=cpus]").value = "invalid"')
                evaluate('top.cloudminNavigationCheck = top.document.querySelector("aside") || top.frames.left.document.body; true')
                evaluate('document.querySelector("#vm-start-form .ui_submit").click()')
                wait('document.querySelector("#cloudmin-vm-status") && !document.querySelector("#vm-start-form, #vm-shutdown-form")')
                assert evaluate('!!top.cloudminNavigationCheck?.isConnected'), 'start discarded the theme navigation'
                return
            if not running:
                # Switch real tabs and keep typed resource values across them.
                evaluate('document.querySelector("textarea[name=description]").value = "Unsaved tab check"')
                for label, selector in [('Disks', 'input[name=add_disk_size]'),
                                        ('Network interfaces', 'select[name=add_interface_network]'),
                                        ('Resources', 'input[name=cpus]')]:
                    link = ('Array.from(document.querySelectorAll(".nav-tabs a, .ui_tabs a"))'
                            '.find(a => a.textContent.trim() === '+json.dumps(label)+')')
                    wait(link)
                    evaluate('('+link+').click()')
                    # Open both storage sections before checking their fields.
                    if label == 'Disks':
                        open_disk_panel('vm_add_disk')
                        open_disk_panel('vm_remove_disk')
                    wait('document.querySelector('+json.dumps(selector)+').getBoundingClientRect().height > 0')
                    assert evaluate('document.querySelector('+json.dumps(selector)+').form.getAttribute("id")') == 'vm-edit-form'
                    assert evaluate('document.querySelectorAll(".tab-pane .ui_submit, .ui_tabs_start .ui_submit").length') == 0
                    assert evaluate('document.querySelector("[form=vm-edit-form]").getBoundingClientRect().width') > 0
                    # Other hardware tabs must hide resource inputs without losing values.
                    if label != 'Resources':
                        assert evaluate('document.querySelector("input[name=cpus]").getBoundingClientRect().width') == 0
                    # Check storage details, read-only media and detach behavior together.
                    if label == 'Disks':
                        assert evaluate('Array.from(document.querySelectorAll(".ui_badge")).some(b => b.innerText === "Read-only")')
                        assert evaluate('document.querySelector("details summary").textContent') == 'Storage location'
                        # The styled switch stays off until explicitly selected.
                        assert evaluate('document.querySelector("input[name=disk_0_detach]").closest(".ui_toggle_danger") !== null')
                        assert evaluate('document.querySelector("input[name=disk_0_detach]").closest(".ui_toggle").querySelector(".ui_toggle_track").getBoundingClientRect().width') > 20
                        # Detach disables both growth fields and restores their values when undone.
                        for detached in (True, False):
                            state = evaluate('''(() => {
                                const form = document.querySelector('#vm-edit-form');
                                const size = form.elements.disk_0_size;
                                const units = form.elements.disk_0_size_units;
                                if (!form.elements.disk_0_detach.checked) size.value = '14';
                                form.elements.disk_0_detach.closest('.ui_toggle').click();
                                return {checked: form.elements.disk_0_detach.checked,
                                    sizeDisabled: size.disabled, unitsDisabled: units.disabled,
                                    size: size.value, units: units.value,
                                    submitted: new FormData(form).has('disk_0_size')};
                            })()''')
                            assert state == dict(checked=detached, sizeDisabled=detached,
                                                 unitsDisabled=detached, size='14',
                                                 units='1073741824', submitted=not detached), state
                        evaluate('document.querySelector("input[name=disk_0_size]").value = ""')
                        # Select only the extra fixture disk for the removal scenario.
                        if action == 'remove_devices':
                            evaluate('''(() => {
                                const target = Array.from(document.querySelectorAll('input[name$="_target"]')).find(i => i.value === 'vdc');
                                target.form.elements[target.name.replace('_target', '_detach')].closest('.ui_toggle').click();
                            })()''')
                assert evaluate('document.querySelector("textarea[name=description]").value') == 'Unsaved tab check'
            # Submit the separate shutdown form and wait for the editor to reopen.
            if action == 'shutdown':
                # Keep the actual navigation node to detect a full-page escape.
                evaluate('top.cloudminNavigationCheck = top.document.querySelector("aside") || top.frames.left.document.body; true')
                evaluate('document.querySelector("#vm-shutdown-form .ui_submit").click()')
                if on_shutdown:
                    # A controlled guest stays active long enough to check feedback.
                    wait('document.body.innerText.includes("Shutdown requested.")')
                    assert evaluate('document.querySelector("#vm-shutdown-form .ui_submit").disabled')
                    on_shutdown()
                # The socket must reopen the editor without a manual page load.
                wait('document.querySelector("#vm-start-form") && '
                     '!document.querySelector("#vm-shutdown-form")')
                wait('document.querySelector(".nav-tabs, .ui_tabs")')
                assert not evaluate('document.querySelector("#vm-delete-form .ui_submit").disabled')
                assert not evaluate('document.querySelector("#cloudmin-vm-status")')
                assert evaluate('!!top.cloudminNavigationCheck?.isConnected'), 'shutdown discarded the theme navigation'
                return
            # Opening deletion must show confirmation with disks unselected.
            if action == 'delete':
                evaluate('document.querySelector("#vm-delete-form .ui_submit").click()')
                wait('document.querySelector("#vm-delete-confirm-form")')
                assert not evaluate('Array.from(document.querySelectorAll("input[name=disks]")).some(i => i.checked)')
                return
            if action in ('clone_disk', 'attach_disk'):
                # Submit each disk choice through the real radio table and shared Save.
                evaluate('(Array.from(document.querySelectorAll(".nav-tabs a, .ui_tabs a"))'
                         '.find(a => a.textContent.trim() === "Disks")).click()')
                wait('document.querySelector("input[name=add_disk_size]").getBoundingClientRect().height > 0')
                mode = 'clone' if action == 'clone_disk' else 'attach'
                field = 'clone_image' if action == 'clone_disk' else 'attach_volume'
                evaluate('document.querySelector("input[name=add_disk_action][value='+mode+']").click()')
                evaluate('document.querySelector("[name='+field+']").value = '+json.dumps(disk_choice))
                save_editor('disks')
                return
            if action == 'update':
                # These edits remain pending until the same Save as the resources.
                evaluate('''(() => {
                    const form = document.querySelector('#vm-edit-form');
                    form.elements.disk_0_size.value = '13';
                    form.elements.disk_0_size_units.value = '1073741824';
                    form.elements.add_disk_action.value = 'create';
                    form.elements.add_disk_size.value = '1';
                    form.elements.add_disk_size_units.value = '1073741824';
                    form.elements.add_interface_network.value = form.elements.nic_0_network.value;
                })()''')
            elif action == 'remove_devices':
                # The selected disk toggle and NIC checkbox are saved together.
                evaluate('''(() => {
                    const form = document.querySelector('#vm-edit-form');
                    form.elements.nic_1_remove.checked = true;
                })()''')
            # Save from a hardware tab and return to the same section afterward.
            tab, label, selector = ('disks', 'Disks', 'input[name=add_disk_size]') if action == 'update' else (
                'interfaces', 'Network interfaces', 'select[name=add_interface_network]')
            evaluate('(Array.from(document.querySelectorAll(".nav-tabs a, .ui_tabs a"))'
                     '.find(a => a.textContent.trim() === '+json.dumps(label)+')).click()')
            wait('document.querySelector('+json.dumps(selector)+').getBoundingClientRect().height > 0')
            assert evaluate('document.querySelector("input[name=vm_edit_tabs]").value') == tab, evaluate(
                'Array.from(document.forms).map(f => ({id: f.getAttribute("id"), '
                'tab: f.elements.vm_edit_tabs?.value}))')
            # Capture the selected hardware tab before saving.
            if screenshot:
                picture = call('Page.captureScreenshot', {'format': 'jpeg', 'quality': 55})
                Path(screenshot).write_bytes(base64.b64decode(picture['data']))
            # Dispatch through the browser so the theme's submit handler also runs.
            evaluate('''(() => {
                const form = document.querySelector('input[name=action][value=update]').form;
                form.elements.cpus.value = '2';
                form.elements.memory_mib_units.value = '1048576';
                form.elements.memory_mib_units.dispatchEvent(new Event('change', {bubbles: true}));
                form.elements.memory_mib.value = '1024';
                // Match typing so the memory step grid follows the new value.
                form.elements.memory_mib.dispatchEvent(new Event('input', {bubbles: true}));
                form.elements.description.value = 'Browser edit: <guest & café>';
                form.elements.boot.value = 'disk:vda';
                form.elements.bootmenu.checked = true;
                return true;
            })()''')
            save_editor(tab)
            assert not evaluate('document.body.textContent.includes("Perl execution failed")')
            # Successful saves reopen fresh settings on the selected hardware tab.
            wait('document.querySelector("input[name=cpus]")?.value === "2"')
            assert evaluate('document.querySelector("input[name=vm_edit_tabs]").value') == tab, evaluate(
                '({url: location.href, tab: document.querySelector("input[name=vm_edit_tabs]").value})')
            if tab == 'disks':
                # Saving replaces the tab contents,
                # including its collapsed panel.
                open_disk_panel('vm_add_disk')
            wait('document.querySelector('+json.dumps(selector)+').getBoundingClientRect().height > 0')
            assert not evaluate('document.querySelector("input[name=disk_0_detach]").checked')
            if action == 'update':
                # Returning and saving again must not repeat disk or NIC additions.
                inventory = '''(() => ({
                    disks: document.querySelectorAll('input[name$="_target"]').length,
                    interfaces: document.querySelectorAll('input[name$="_mac"]').length,
                    volumes: document.querySelector('select[name=attach_volume]').options.length
                }))()'''
                before = evaluate(inventory)
                for _ in range(2):
                    assert evaluate('''(() => {
                        const form = document.querySelector('#vm-edit-form');
                        return form.elements.add_disk_size.value === '' &&
                            form.elements.attach_volume.value === '' &&
                            form.elements.add_interface_network.value === '';
                    })()''')
                    save_editor(tab)
                    wait('document.querySelector("input[name=cpus]")?.value === "2"')
                    assert evaluate(inventory) == before, evaluate(inventory)
        finally:
            if cdp:
                # Let Chromium stop its profile writers before removing the directory.
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
            except subprocess.TimeoutExpired:
                chrome.kill()
                chrome.wait()
