"""Exercise directory-pool creation and lifecycle in both Webmin themes.

Run on an authorized Linux test host with Chromium and python3-websocket.
Temporary accounts and pools are removed even when an assertion fails.
"""

import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import websocket


def check_storage(cookies, theme, name, path):
    """
    check_storage(cookies, theme, name, path): exercise real browser forms.
    """
    browser = shutil.which('chromium') or shutil.which('chromium-browser')
    assert browser, 'Chromium is required for the storage browser check'
    # Snap's private /tmp is not the controller's /tmp; use its writable area.
    parent = (
        Path('/root/snap/chromium/common')
        if browser.startswith('/snap/')
        else None
    )
    # Create the profile in the area visible to Snap Chromium.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-jobs-browser-', dir=parent
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
                '--window-size=1600,1000',
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
                # Use a session only for commands sent after tab attachment.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Wait past browser events for the requested command result.
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
                # Report JavaScript failures rather than treating them as
                # absent controls.
                if result.get('exceptionDetails'):
                    raise AssertionError(result['exceptionDetails'])
                return result.get('result', {}).get('value')

            # wait(expression) polls the current page for up to 45 seconds.
            def wait(expression):
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    # Proceed only after the document and requested control
                    # are ready.
                    if evaluate(
                        '!!(document.body && document.readyState === "complete" && ('
                        + expression
                        + '))'
                    ):
                        return
                    time.sleep(.25)
                detail = evaluate('document.body?.innerText.slice(0, 1500)')
                raise AssertionError(
                    'Browser condition failed: '
                    + expression
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
            # Enter through an ordinary link so the theme owns its navigation.
            call('Page.navigate', {'url': 'https://127.0.0.1:10000/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            # A frame shell can exist before its right-hand page has a referrer.
            wait(
                'document.location.href.startsWith("https://127.0.0.1:10000/") && document.readyState === "complete"'
            )
            evaluate(
                "(() => { const a = document.createElement('a'); a.href = '/server-manager/storage.cgi'; document.body.append(a); a.click(); a.remove(); })()"
            )
            wait('document.querySelector(".cloudmin-storage-page")')

            # tab(name) uses the same native controls as the VM editor.
            def tab(name):
                evaluate(
                    "(() => { const a = document.querySelector('a[href=\"#att_storage_"
                    + name
                    + "\"], a#tab_storage_"
                    + name
                    + ", #tab_storage_"
                    + name
                    + " a'); if (a) a.click(); })()"
                )
                wait(
                    "document.querySelector('[data-storage-tab="
                    + name
                    + "]')?.getClientRects().length > 0"
                )
                assert evaluate(
                    "Array.from(document.querySelectorAll('[data-storage-tab]')).filter(t => t.getClientRects().length).length === 1"
                )

            # pool_tab(name) switches between existing pools and creation.
            def pool_tab(name):
                evaluate(
                    "(() => { const a = document.querySelector('a[href=\"#att_storage_pool_"
                    + name
                    + "\"], a#tab_storage_pool_"
                    + name
                    + ", #tab_storage_pool_"
                    + name
                    + " a'); if (a) a.click(); })()"
                )
                wait(
                    "document.querySelector('[data-storage-pool-tab="
                    + name
                    + "]')?.getClientRects().length > 0"
                )
                assert evaluate(
                    "Array.from(document.querySelectorAll('[data-storage-pool-tab]')).filter(t => t.getClientRects().length).length === 1"
                )
                assert evaluate(
                    "document.querySelector('[data-storage-tab=pools]').getClientRects().length > 0"
                ), 'Inner tabs keep pool management visible'

            # An inventory of protected volumes still shows disabled controls.
            tab('volumes')
            controls = evaluate("""(() => {
                const table = document.querySelector('#cloudmin-storage-volumes');
                const inventory = table?.querySelector('table[data-sortable]');
                if (!inventory) return null;
                // Configured column visibility must not change the row count.
                const rows = Array.from(inventory.rows).slice(1);
                const boxes = Array.from(table.querySelectorAll('input[type=checkbox][name=volume]'));
                const button = table.querySelector('button[name=delete],input[type=submit][name=delete]');
                return {rows: rows.length, boxes: boxes.length,
                    selectable: boxes.filter(c => !c.disabled).length,
                    visible: !!button?.getClientRects().length, disabled: button?.disabled};
            })()""")
            # Check selection behavior only when the inventory contains a table.
            if controls:
                assert evaluate(
                    "!!document.querySelector('#cloudmin-storage-volumes[data-storage-tab=volumes] > form.ui_form')"
                ), 'Volume form must be directly inside the existing tab'
                assert controls['rows'] == controls['boxes'], controls
                assert controls['visible'], 'Delete button must remain visible'
                assert controls['disabled'] == (controls['selectable'] == 0), (
                    controls
                )
                for link in ('select_all', 'select_invert'):
                    assert evaluate(
                        "!!document.querySelector('#cloudmin-storage-volumes a."
                        + link
                        + "')?.getClientRects().length"
                    ), link + ' must remain visible'
                    evaluate(
                        "document.querySelector('#cloudmin-storage-volumes a."
                        + link
                        + "').click()"
                    )
                    assert evaluate(
                        "!document.querySelector('#cloudmin-storage-volumes input[type=checkbox][name=volume]:disabled:checked')"
                    ), 'Selection controls must skip protected volumes'
                assert evaluate(
                    "!document.querySelector('#cloudmin-storage-volumes input[type=checkbox][name=volume]:checked')"
                )
                print('Existing inventory controls:', controls, flush=True)

            tab('pools')
            assert evaluate(
                "document.querySelector('[data-storage-pool-tab=list]').getClientRects().length > 0"
            ), 'Existing pools open first'
            assert evaluate(
                "!document.querySelector('[data-storage-pool-tab=create]').getClientRects().length"
            ), 'Creation starts hidden'
            pool_tab('create')
            pool_tab('list')
            pool_tab('create')
            # The LVM selector and management link share a line, and the boot
            # setting uses the native toggle without changing submission values.
            assert evaluate("!!document.querySelector('select[name=group]')"), (
                'LVM groups need a dropdown'
            )
            assert evaluate(
                "!document.body.innerText.includes('Cannot list LVM volume groups:')"
            ), 'Live group discovery must succeed'
            assert evaluate(
                "!!document.querySelector('input[name=autostart]')?.closest('.ui_toggle')"
            ), 'Start at boot needs a toggle'
            # Check full-width row metadata in the theme that consumes it.
            if theme == 'authentic-theme':
                assert evaluate(
                    "!!document.querySelector('select[name=group]')?.closest('[data-column-span=all]')"
                ), 'Storage backend needs a full-width row'
            management = evaluate("""(() => {
                const select = document.querySelector('select[name=group]');
                const link = select.closest('td').querySelector('a[href*=\"/lvm/\"]');
                if (!link) return {missing: true, markup: select.closest('td').innerHTML};
                const field = (select.closest('.bootstrap-select') || select).getBoundingClientRect();
                const manage = link.getBoundingClientRect();
                return {label: link.textContent.trim(), field: field.toJSON(), link: manage.toJSON(),
                    button: link.classList.contains('ui_action') && !!link.querySelector('svg'),
                    markup: select.closest('td').innerHTML,
                    cell: select.closest('td').getBoundingClientRect().toJSON(),
                    beside: manage.left >= field.right && manage.top < field.bottom && manage.bottom > field.top};
            })()""")
            assert (
                management.get('label') == 'Manage'
                and management.get('button')
                and management.get('beside')
            ), management
            # Empty fields are neutral; a real POST is validated by the server.
            assert evaluate(
                "!document.querySelector('input[name=name]').required && !document.querySelector('input[name=path]').required"
            )
            assert evaluate(
                "!document.querySelector('input[name=name]').matches(':invalid') && !document.querySelector('input[name=path]').matches(':invalid')"
            )
            evaluate(
                "document.querySelector('input[value=create][name=action]').form.querySelector('button[type=submit]').click()"
            )
            wait("document.body.innerText.includes('Use a pool name')")
            assert evaluate(
                "document.querySelector('[data-storage-pool-tab=create]').getClientRects().length > 0"
            ), 'Server validation returns to creation'
            assert evaluate(
                "!document.querySelector('[data-storage-pool-tab=list]').getClientRects().length"
            ), 'Validation keeps the list hidden'
            evaluate(
                "document.querySelector('input[name=name]').value = "
                + json.dumps(name)
            )
            # A forged option must still be validated server-side. A removed
            # group returns to the prompt without selecting a different group.
            evaluate(
                "document.querySelector('input[name=type][value=logical]').click()"
            )
            evaluate(
                "document.querySelector('select[name=group]').add(new Option("
                + json.dumps(name + '-missing')
                + ", "
                + json.dumps(name + '-missing')
                + ", true, true))"
            )
            evaluate(
                "document.querySelector('input[value=create][name=action]').form.querySelector('button[type=submit]').click()"
            )
            wait(
                "document.body.innerText.includes('LVM volume group is missing')"
            )
            assert evaluate(
                "document.querySelector('[data-storage-pool-tab=create]').getClientRects().length > 0"
            ), 'Group validation keeps creation visible'
            assert evaluate(
                "document.querySelector('input[name=type][value=logical]').checked"
            )
            assert evaluate(
                "document.querySelector('select[name=group]').value === ''"
            )
            evaluate(
                "document.querySelector('input[name=type][value=dir]').click()"
            )
            evaluate(
                "document.querySelector('input[name=path]').value = "
                + json.dumps(path)
            )
            evaluate(
                "document.querySelector('input[value=create][name=action]').form.querySelector('button[type=submit]').click()"
            )
            wait(
                "Array.from(document.querySelectorAll('.cloudmin-storage-card')).some(card => card.querySelector('.ui_card_title')?.textContent.trim() === "
                + json.dumps(name)
                + ")"
            )
            assert evaluate(
                "document.querySelector('[data-storage-pool-tab=list]').getClientRects().length > 0"
            ), 'Successful creation returns to the list'
            assert evaluate(
                "!document.querySelector('[data-storage-pool-tab=create]').getClientRects().length"
            ), 'Successful creation hides the form'
            card_id = evaluate(
                "Array.from(document.querySelectorAll('.cloudmin-storage-card')).find(card => card.querySelector('.ui_card_title')?.textContent.trim() === "
                + json.dumps(name)
                + ").id"
            )
            selector = '#' + card_id

            # The overview is a compact, responsive index into the
            # management cards.
            tab('overview')
            assert evaluate(
                "document.querySelectorAll('.cloudmin-storage-summary .ui_stat').length === 4"
            )
            assert evaluate(
                "document.querySelector('.cloudmin-storage-overview-table').textContent.includes("
                + json.dumps(name)
                + ")"
            )
            for width in (1600, 1280, 1000, 760, 480):
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': width,
                        'height': 1000,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                time.sleep(.3)
                assert evaluate(
                    "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
                ), 'Overview overflows page at ' + str(width)
                assert evaluate(
                    "Array.from(document.querySelectorAll('.cloudmin-storage-summary .ui_stat')).every(tile => tile.scrollWidth <= tile.clientWidth + 2)"
                ), 'Summary text overflows tile'
            call('Emulation.clearDeviceMetricsOverride')
            picture = call('Page.captureScreenshot', {'format': 'png'})
            Path(
                '/var/tmp/cloudmin-storage-' + theme + '-overview.png'
            ).write_bytes(base64.b64decode(picture['data']))
            padding = evaluate(
                "(() => { const rows=document.querySelectorAll('.cloudmin-storage-overview-table tr'); const td=getComputedStyle(rows[1].querySelector('td')); const th=getComputedStyle(rows[0].querySelector('th, td')); return {row:td.padding, head:th.padding, aligned:parseFloat(td.paddingTop) >= 8 && td.paddingLeft === th.paddingLeft}; })()"
            )
            assert padding['aligned'], (
                'Overview row padding and headings align: ' + str(padding)
            )
            evaluate(
                "Array.from(document.querySelectorAll('.cloudmin-storage-pool-link')).find(a => a.textContent.trim() === "
                + json.dumps(name)
                + ").click()"
            )
            wait(
                "document.querySelector('[data-storage-tab=pools]')?.getClientRects().length > 0"
            )
            wait(
                "document.querySelector('.cloudmin-storage-card.cloudmin-storage-selected')?.id === "
                + json.dumps(card_id)
            )
            assert evaluate(
                "document.querySelector('.cloudmin-storage-card').id === "
                + json.dumps(card_id)
            ), 'Selected pool appears first'

            def boot_button():
                """
                boot_button(): measure the rendered boot action relative to its
                fact.
                """
                return evaluate(
                    """(() => {
                    const form = document.querySelector('"""
                    + selector
                    + """ input[value=autostart]').form;
                    const button = form.querySelector('button');
                    const box = button.getBoundingClientRect();
                    return {top: box.top - form.closest('.ui_dl_row').getBoundingClientRect().top,
                        height: box.height, checked: !!button.querySelector('.ui_svg_icon_check')};
                })()"""
                )

            initial = boot_button()
            assert initial['checked']
            for expected, checked in (('1', False), ('0', True)):
                evaluate(
                    "document.querySelector('"
                    + selector
                    + " input[value=autostart]').form.querySelector('button').click()"
                )
                wait(
                    "document.querySelector('"
                    + selector
                    + " input[value=autostart]')?.form.elements.enabled.value === '"
                    + expected
                    + "'"
                )
                current = boot_button()
                assert current['checked'] == checked
                assert (
                    abs(initial['top'] - current['top']) < .1
                    and abs(initial['height'] - current['height']) < .1
                ), 'Boot toggle shifts vertically'

            # Wrapped paths stay within their fact columns at every
            # tested width.
            for width in (1600, 1280, 1000, 760, 480):
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': width,
                        'height': 1000,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                time.sleep(.4)
                # Capture the overflowing layout and offending elements
                # before failing.
                if not evaluate(
                    "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
                ):
                    picture = call('Page.captureScreenshot', {'format': 'png'})
                    Path(
                        '/var/tmp/cloudmin-storage-' + theme + '-overflow.png'
                    ).write_bytes(base64.b64decode(picture['data']))
                    detail = evaluate(
                        "Array.from(document.querySelectorAll('.cloudmin-storage-page *')).filter(e => e.getClientRects().length && e.getBoundingClientRect().right > document.documentElement.clientWidth+2).slice(0,12).map(e => ({tag:e.tagName, cls:e.className, width:e.getBoundingClientRect().width, text:e.textContent.slice(0,80)}))"
                    )
                    raise AssertionError(
                        'Pool cards overflow at '
                        + str(width)
                        + ': '
                        + str(detail)
                    )
                assert evaluate(
                    "Array.from(document.querySelectorAll('.cloudmin-storage-card')).every(card => Array.from(card.querySelectorAll('.ui_dl_row')).every(row => row.getBoundingClientRect().right <= card.getBoundingClientRect().right+1))"
                ), 'Facts escape card'
            call('Emulation.clearDeviceMetricsOverride')
            picture = call('Page.captureScreenshot', {'format': 'png'})
            Path(
                '/var/tmp/cloudmin-storage-' + theme + '-pools.png'
            ).write_bytes(base64.b64decode(picture['data']))

            # A native volume appears in its own sortable inventory tab.
            subprocess.run(
                [
                    'virsh',
                    '-c',
                    'qemu:///system',
                    'vol-create-as',
                    name,
                    'fixture.raw',
                    '1M',
                    '--allocation',
                    '4K',
                    '--format',
                    'raw',
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(
                [
                    'virsh',
                    '-c',
                    'qemu:///system',
                    'vol-create-as',
                    name,
                    'second.raw',
                    '1M',
                    '--allocation',
                    '4K',
                    '--format',
                    'raw',
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            evaluate(
                "document.querySelector('"
                + selector
                + " input[value=stop]').form.querySelector('button').click()"
            )
            wait(
                "document.querySelector('" + selector + " input[value=start]')"
            )
            assert evaluate(
                "document.querySelector('"
                + selector
                + "').textContent.includes('Start this pool to view')"
            )
            assert Path(path, 'fixture.raw').exists(), 'Stop removed disk'
            evaluate(
                "document.querySelector('"
                + selector
                + " input[value=start]').form.querySelector('button').click()"
            )
            wait("document.querySelector('" + selector + " input[value=stop]')")
            tab('volumes')
            assert evaluate(
                "document.querySelector('[data-storage-tab=volumes]').textContent.includes('fixture.raw')"
            )
            wait(
                "Array.from(document.querySelectorAll('#cloudmin-storage-volumes table[data-sortable] td')).every(td => td.scrollWidth <= td.clientWidth + 1)"
            )
            for width in (1280, 760, 480):
                call(
                    'Emulation.setDeviceMetricsOverride',
                    {
                        'width': width,
                        'height': 1000,
                        'deviceScaleFactor': 1,
                        'mobile': False,
                    },
                )
                time.sleep(.3)
                assert evaluate(
                    "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
                ), 'Volume table overflows page at ' + str(width)
                overflow = evaluate(
                    "Array.from(document.querySelectorAll('#cloudmin-storage-volumes table[data-sortable] td')).filter(td => td.scrollWidth > td.clientWidth + 1).map(td => ({column:td.cellIndex, text:td.textContent.trim().slice(0,100), width:td.clientWidth, content:td.scrollWidth}))"
                )
                assert not overflow, (
                    'Volume text overlaps another column at '
                    + str(width)
                    + ': '
                    + str(overflow)
                )
            call('Emulation.clearDeviceMetricsOverride')
            picture = call('Page.captureScreenshot', {'format': 'png'})
            Path(
                '/var/tmp/cloudmin-storage-' + theme + '-volumes.png'
            ).write_bytes(base64.b64decode(picture['data']))

            # Standard select-all stays in this form and excludes owned disks.
            evaluate(
                "document.querySelector('#cloudmin-storage-volumes a.select_all').click()"
            )
            assert evaluate(
                "Array.from(document.querySelectorAll('#cloudmin-storage-volumes input[type=checkbox][name=volume]')).every(c => c.disabled ? !c.checked : c.checked)"
            )
            assert evaluate(
                "Array.from(document.querySelector('#cloudmin-storage-volumes table[data-sortable]').rows).slice(1).filter(r => r.querySelector('a[href*=\"machine.cgi\"]') || r.textContent.includes('Imported image')).every(r => r.querySelector('input[type=checkbox][name=volume]')?.disabled)"
            ), 'Owned volumes keep disabled checkboxes'
            evaluate(
                "document.querySelector('#cloudmin-storage-volumes a.select_invert').click()"
            )
            assert evaluate(
                "!document.querySelector('#cloudmin-storage-volumes input[type=checkbox][name=volume]:checked')"
            )

            # review_volumes() selects both fixture files and verifies their
            # review. Opening the review must leave both files intact.
            def review_volumes():
                evaluate(
                    "Array.from(document.querySelectorAll('#cloudmin-storage-volumes input[type=checkbox][name=volume]')).forEach(c => { if (c.value.startsWith("
                    + json.dumps(card_id.removeprefix('cloudmin-pool-') + '/')
                    + ") && /\\/(fixture|second)\\.raw$/.test(c.value)) c.click(); })"
                )
                evaluate(
                    "document.querySelector('#cloudmin-storage-volumes form').querySelector('input[type=submit],button[type=submit]').click()"
                )
                wait(
                    "document.querySelector('.cloudmin-storage-delete input[name=confirm]')"
                )
                for filename in ('fixture.raw', 'second.raw'):
                    assert Path(path, filename).exists(), (
                        'Review deleted a volume'
                    )
                    assert evaluate(
                        "document.querySelector('.cloudmin-storage-delete').textContent.includes("
                        + json.dumps(path + '/' + filename)
                        + ")"
                    ), 'Review shows each exact path'

            review_volumes()
            evaluate(
                "document.querySelector('.cloudmin-storage-delete a[href=\"storage.cgi?tab=volumes\"]').click()"
            )
            wait(
                "document.querySelector('#cloudmin-storage-volumes > form input[value=review_volumes]') && !document.querySelector('.cloudmin-storage-delete')"
            )
            assert (
                Path(path, 'fixture.raw').exists()
                and Path(path, 'second.raw').exists()
            ), 'Cancel deleted a volume'
            review_volumes()
            evaluate(
                "document.querySelector('.cloudmin-storage-delete button[type=submit]').click()"
            )
            wait(
                "document.body.innerText.includes('Confirm permanent volume deletion')"
            )
            assert (
                Path(path, 'fixture.raw').exists()
                and Path(path, 'second.raw').exists()
            ), 'Unchecked confirmation deleted a volume'
            review_volumes()
            evaluate(
                "document.querySelector('.cloudmin-storage-delete input[name=confirm]').click()"
            )
            picture = call('Page.captureScreenshot', {'format': 'png'})
            Path(
                '/var/tmp/cloudmin-storage-' + theme + '-delete.png'
            ).write_bytes(base64.b64decode(picture['data']))
            evaluate(
                "document.querySelector('.cloudmin-storage-delete button[type=submit]').click()"
            )
            wait(
                "document.querySelector('[data-storage-tab=volumes]')?.getClientRects().length > 0 && !document.querySelector('.cloudmin-storage-delete') && !Array.from(document.querySelectorAll('.cloudmin-storage-volume-name')).some(e => e.textContent === 'fixture.raw' || e.textContent === 'second.raw')"
            )
            assert (
                not Path(path, 'fixture.raw').exists()
                and not Path(path, 'second.raw').exists()
            ), 'Confirmed volumes remain on disk'
            print(
                'Bulk selection, review, cancel, confirmation and two-volume deletion: PASS',
                flush=True,
            )

            # Invalid creation preserves entered values and leaves no
            # extra pool.
            tab('pools')
            pool_tab('create')
            evaluate(
                "document.querySelector('input[name=name]').value = "
                + json.dumps(name)
            )
            evaluate(
                "document.querySelector('input[name=path]').value = "
                + json.dumps(path)
            )
            evaluate(
                "document.querySelector('input[value=create][name=action]').form.querySelector('button[type=submit]').click()"
            )
            wait("document.body.innerText.includes('already exists')")
            assert evaluate(
                "document.querySelector('input[name=name]').value === "
                + json.dumps(name)
            )
            assert evaluate(
                "document.querySelector('input[name=path]').value === "
                + json.dumps(path)
            )
            # Active unregistration reviews and confirms both
            # operations together.
            tab('pools')
            pool_tab('list')
            evaluate(
                "document.querySelector('"
                + selector
                + " input[value=review_pool]').form.querySelector('button').click()"
            )
            wait("document.body.innerText.includes('Stop and Unregister')")
            assert evaluate(
                "document.querySelector('input[name=stop]').value === '1'"
            )
            kept = Path(path, 'kept.raw')
            kept.write_bytes(b'preserve this data')
            # The submit button confirms removal; there is no second toggle.
            wait("document.querySelector('input[value=unregister]')")
            assert evaluate(
                "document.querySelector('input[name=confirm]').type === 'hidden' && document.querySelector('input[name=confirm]').value === '1'"
            )
            evaluate(
                "document.querySelector('input[value=unregister]').form.querySelector('button[type=submit]').click()"
            )
            wait(
                "document.querySelector('[data-storage-pool-tab=list]')?.getClientRects().length > 0 && !document.querySelector('"
                + selector
                + "')"
            )
            # Removing the registration must leave the fixture file intact.
            assert kept.read_bytes() == b'preserve this data'
            print(
                'Pool review, confirmed stop and data-preserving unregistration: PASS',
                flush=True,
            )
            print(
                'Overview, card navigation, pool lifecycle, server validation and responsive layout: PASS',
                flush=True,
            )
        finally:
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
            except subprocess.TimeoutExpired:
                chrome.kill()
                chrome.wait()


# Each theme gets an isolated local account and a uniquely named directory pool.
if __name__ == '__main__':
    import argparse
    import http.cookiejar
    import os
    import secrets
    import ssl
    import urllib.parse
    import urllib.request

    parser = argparse.ArgumentParser()
    parser.add_argument('--theme', choices=('authentic-theme', 'gray-theme'))
    args = parser.parse_args()
    assert os.uname().sysname == 'Linux' and os.geteuid() == 0
    helper = str(Path(__file__).with_name('webmin-user.pl'))
    for theme in (
        (args.theme,) if args.theme else ('authentic-theme', 'gray-theme')
    ):
        password = secrets.token_urlsafe(36)
        name = 'cm-storage-web-' + secrets.token_hex(4)
        user = 'cloudmin-ui-check-' + secrets.token_hex(4)
        created = False
        with tempfile.TemporaryDirectory(
            prefix='cloudmin-storage-web-', dir='/var/lib/libvirt'
        ) as directory:
            os.chmod(directory, 0o755)
            path = directory + '/extra storage'
            try:
                subprocess.run(
                    ['perl', helper, 'create', theme, user],
                    input=password + '\n',
                    text=True,
                    check=True,
                )
                created = True
                time.sleep(1)
                cookies = http.cookiejar.CookieJar()
                opener = urllib.request.build_opener(
                    urllib.request.ProxyHandler({}),
                    urllib.request.HTTPCookieProcessor(cookies),
                    urllib.request.HTTPSHandler(
                        context=ssl._create_unverified_context()
                    ),
                )
                base = 'https://127.0.0.1:10000'
                opener.open(base + '/session_login.cgi', timeout=30).read()
                data = urllib.parse.urlencode(
                    {'user': user, 'pass': password, 'page': '/'}
                ).encode()
                opener.open(
                    base + '/session_login.cgi', data, timeout=30
                ).read()
                print(theme, flush=True)
                check_storage(cookies, theme, name, path)
            finally:
                pools = subprocess.check_output(
                    [
                        'virsh',
                        '-c',
                        'qemu:///system',
                        'pool-list',
                        '--all',
                        '--name',
                    ],
                    text=True,
                ).splitlines()
                # An early setup failure may leave no fixture pool.
                if name in pools:
                    active = subprocess.check_output(
                        [
                            'virsh',
                            '-c',
                            'qemu:///system',
                            'pool-list',
                            '--name',
                        ],
                        text=True,
                    ).splitlines()
                    # Stop only the test pool if it is still active.
                    if name in active:
                        subprocess.run(
                            [
                                'virsh',
                                '-c',
                                'qemu:///system',
                                'pool-destroy',
                                name,
                            ],
                            check=True,
                            stdout=subprocess.DEVNULL,
                        )
                    subprocess.run(
                        [
                            'virsh',
                            '-c',
                            'qemu:///system',
                            'pool-undefine',
                            name,
                        ],
                        check=True,
                        stdout=subprocess.DEVNULL,
                    )
                # Remove the account only after successful fixture setup.
                if created:
                    subprocess.run(
                        ['perl', helper, 'delete', theme, user], check=True
                    )
