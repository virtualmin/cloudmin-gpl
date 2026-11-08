#!/usr/bin/python3
"""Test templates and plans through Webmin, Chromium and guest creation."""

import base64
import http.cookiejar
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import platform
import secrets
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import websocket

# Keep fixture accounts, browser profiles and guest changes on a Linux
# test host.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on an authorized Linux test host as root')
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


# editor(kind, [ident], [section]) reads values from the requested editor form.
def editor(kind, ident=None, section=None):
    stem = 'tmpl' if kind == 'template' else 'plan'
    return Form(
        request(
            '/server-manager/edit_'
            + stem
            + '.cgi?'
            + ('id=' + ident if ident else 'new=1')
            + ('&editmode=' + section if section else '')
        ),
        'save_' + stem + '.cgi',
    ).fields


# save(kind, fields) requires a successful redirect to the list page.
def save(kind, fields):
    stem = 'tmpl' if kind == 'template' else 'plan'
    page = request('/server-manager/save_' + stem + '.cgi', fields)
    # The list's signed action form confirms the save returned to its list page.
    assert Form(page, 'delete_' + stem + 's.cgi').fields.get('token'), (
        'Preset save failed: ' + FormText(page)
    )


# FormText(page) extracts recent page text for preset failure diagnostics.
def FormText(page):
    import re

    page = re.sub(r'<(script|style)\b[^>]*>.*?</\1>', '', page, flags=re.S)
    return re.sub('<[^>]*>', ' ', page)[-2000:]


# browser_check(template, plan) tests selectors and navigation in a browser.
def browser_check(template, plan):
    binary = shutil.which('chromium') or shutil.which('chromium-browser')
    assert binary, 'Chromium is required'
    parent = (
        Path('/root/snap/chromium/common')
        if binary.startswith('/snap/')
        else None
    )
    # Snap Chromium can only use profiles within its allowed data directory.
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix='cloudmin-presets-browser-', dir=parent
    ) as profile:
        chrome = subprocess.Popen(
            [
                binary,
                '--headless',
                '--no-sandbox',
                '--disable-gpu',
                '--remote-debugging-port=0',
                '--ignore-certificate-errors',
                '--no-first-run',
                '--disable-background-networking',
                '--disable-sync',
                '--window-size=1600,1100',
                '--user-data-dir=' + profile,
                'about:blank',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cdp = None
        try:
            active = Path(profile) / 'DevToolsActivePort'
            deadline = time.monotonic() + 30
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection(
                'ws://127.0.0.1:' + port + route,
                timeout=30,
                suppress_origin=True,
            )
            serial, session = 0, None

            # call(method, [params]) routes commands to the fixture's
            # browser tab.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                command = {
                    'id': serial,
                    'method': method,
                    'params': params or {},
                }
                # Browser commands precede attachment; later calls target
                # the tab.
                if session:
                    command['sessionId'] = session
                cdp.send(json.dumps(command))
                while True:
                    reply = json.loads(cdp.recv())
                    # Ignore asynchronous events while waiting for this reply.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(expression) surfaces exceptions in either supported
            # theme layout.
            def evaluate(expression):
                result = call(
                    'Runtime.evaluate',
                    {
                        'expression': '(window.frames.right || window).eval('
                        + json.dumps(expression)
                        + ')',
                        'returnByValue': True,
                    },
                )
                assert 'exceptionDetails' not in result, result.get(
                    'exceptionDetails'
                )
                return result.get('result', {}).get('value')

            # wait(expression) bounds navigation waits without busy polling.
            def wait(expression):
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    # Continue only after the page exposes the expected state.
                    if evaluate('!!(' + expression + ')'):
                        return
                    time.sleep(.25)
                raise AssertionError(
                    'Browser wait failed: '
                    + expression
                    + '; page: '
                    + str(evaluate('document.body?.innerText.slice(-1800)'))
                )

            # Reuse only the fixture session in a fresh isolated browser tab.
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
                        'url': base,
                        'path': cookie.path,
                        'secure': True,
                    },
                )
            call('Page.navigate', {'url': base + '/'})
            wait('top.document.querySelector("aside") || top.frames.left')
            if evaluate('!!top.frames.left'):
                # Select the module through the navigation frame when present.
                evaluate(
                    'top.frames.left.location = "/left.cgi?mode=server-manager"'
                )
            documents = '[document, top.document, top.frames.left?.document, top.frames.right?.document].filter(Boolean)'
            overview_link = (
                '('
                + documents
                + ').flatMap(d=>Array.from(d.querySelectorAll("a[href]"))).find(a=>new URL(a.href).pathname.endsWith("/server-manager/index.cgi"))'
            )
            wait(overview_link)
            evaluate('(' + overview_link + ').click()')
            create_link = (
                '('
                + documents
                + ').flatMap(d=>Array.from(d.querySelectorAll("a[href]"))).find(a=>new URL(a.href).pathname.endsWith("/machine_form.cgi"))'
            )
            wait(create_link)
            evaluate('(' + create_link + ').click()')
            # Initialization keeps the source inventory in the current form.
            wait(
                'document.querySelector("#vm-create-form template[data-vm-images]")'
            )
            # Each selector must work after initial load and with
            # enhanced-select events.
            evaluate(
                'window.presetForm = document.querySelector("#vm-create-form"); window.f = presetForm.elements'
            )
            assert evaluate('f.plan.value') == plan
            assert evaluate(
                '[...f.template.options, ...f.plan.options].every(o => o.value && o.text !== "Custom")'
            )
            # Test untouched, server-selected units before applying a plan or
            # editing resources, which would hide the selected-attribute reset.
            allocation = '[f.cpus.value, f.memory_mib.value, f.memory_mib_units.value, f.disk_gib.value, f.disk_gib_units.value]'
            original_allocation = evaluate(allocation)
            for selected in [
                '0' * 31 + '2',
                '0' * 31 + '3',
                '0' * 31 + '1',
                template,
            ]:
                evaluate(
                    'f.template.value='
                    + json.dumps(selected)
                    + '; jQuery(f.template).trigger("change")'
                )
                assert evaluate(allocation) == original_allocation, (
                    'Template changed resource values or units'
                )
                assert evaluate('f.plan.value') == plan, (
                    'Template changed the selected plan'
                )
            evaluate(
                'f.memory_mib.value="9"; f.memory_mib.dispatchEvent(new Event("change", {bubbles:true}))'
            )
            assert evaluate('f.plan.value') == plan
            evaluate(
                'f.plan.value='
                + json.dumps(plan)
                + '; jQuery(f.plan).trigger("change")'
            )
            assert (
                evaluate(
                    'Number(f.memory_mib.value)*Number(f.memory_mib_units.value)'
                )
                == 512 * 1024**2
            )
            evaluate(
                'f.username.value="manual"; f.username.dispatchEvent(new Event("change", {bubbles:true}))'
            )
            assert evaluate('f.template.value') == template
            evaluate(
                'f.template.value='
                + json.dumps(template)
                + '; f.template.dispatchEvent(new Event("change", {bubbles:true}))'
            )
            assert evaluate('f.username.value') == 'cloudmin'
            assert evaluate('f.start.value') == '0'
            assert evaluate('f.plan.value') == plan, (
                'Template selection changed the resource plan'
            )
            evaluate('window.cloudminVmCreateInit()')
            assert evaluate('f.plan.value') == plan, (
                'Repeated initializer changed selections'
            )
            # Default Template must select cloud media even when the newest
            # import is an ISO.
            evaluate(
                'f.template.value="'
                + '0' * 31
                + '1"; jQuery(f.template).trigger("change")'
            )
            assert evaluate('f.image.value') == 'catalogue:rocky-linux-10'
            assert evaluate('f.install_source.value') == 'cloud'
            assert evaluate(
                '!f.password.disabled && f.password.getClientRects().length > 0'
            )
            assert evaluate(
                'f.ssh_keys.disabled && f.ssh_keys.getClientRects().length === 0'
            )
            # Chips must follow actual controls, including edits inside
            # closed sections.
            evaluate(
                'window.chipText = name => presetForm.querySelector(`[data-vm-chip="${name}"]`).textContent.trim()'
            )
            assert evaluate('chipText("image")') == 'Rocky Linux 10'
            evaluate(
                'f.plan.value="'
                + '0' * 31
                + '1"; jQuery(f.plan).trigger("change")'
            )
            assert (
                evaluate('chipText("resources")')
                == '2 CPU, 2 GiB memory, 20 GiB disk'
            )
            evaluate(
                'f.memory_mib.value="1.5"; f.memory_mib.dispatchEvent(new Event("input", {bubbles:true}))'
            )
            assert evaluate('chipText("resources").includes("1.5 GiB memory")')
            evaluate(
                'f.plan.value='
                + json.dumps(plan)
                + '; jQuery(f.plan).trigger("change")'
            )
            # A hidden hostname is omitted, while a separate one is submitted.
            evaluate(
                'f.hostname_set.checked=false; f.hostname_set.dispatchEvent(new Event("change", {bubbles:true}))'
            )
            assert evaluate(
                '!new FormData(presetForm).has("hostname") && !f.hostname.required'
            )
            assert evaluate(
                '[...presetForm.querySelectorAll("[data-vm-installer], [data-vm-source-empty]")].every(n => n.getClientRects().length === 0)'
            )
            # Built-in templates fill setup options without opening the section
            # or supplying license credentials.
            evaluate(
                'f.template.value="'
                + '0' * 31
                + '3"; jQuery(f.template).trigger("change")'
            )
            assert evaluate('f.software.value') == 'virtualmin-pro'
            assert (
                evaluate('chipText("software")') == 'Virtualmin Pro with Apache'
            )
            assert evaluate(
                '!f.hostname_set.checked && !f.hostname.required && f.hostname.getClientRects().length === 0'
            )
            assert evaluate('!new FormData(presetForm).has("hostname")')
            # Only the user opens the separate hostname field.
            evaluate(
                'f.hostname_set.checked=true; f.hostname_set.dispatchEvent(new Event("change", {bubbles:true}))'
            )
            assert evaluate(
                '!f.hostname.required && f.hostname.getClientRects().length > 0'
            )
            assert evaluate('new FormData(presetForm).has("hostname")')
            assert evaluate(
                'document.querySelector("#hiddendiv_vm_software").classList.contains("opener_hidden")'
            ), 'Template selection opened the Software section'
            # Open Software for the control checks below; Pro credentials are
            # shown separately in the details section.
            evaluate(
                'window.hidden_opener("hiddendiv_vm_software", "hiddenopener_vm_software")'
            )
            assert evaluate(
                '!f.virtualmin_key.disabled && f.virtualmin_key.getClientRects().length > 0'
            )
            evaluate(
                'f.virtualmin_key.value="fixture-only"; f.template.value="'
                + '0' * 31
                + '2"; jQuery(f.template).trigger("change")'
            )
            assert evaluate('f.software.value') == 'virtualmin-gpl'
            assert evaluate(
                'f.virtualmin_key.disabled && f.virtualmin_key.value === ""'
            )
            evaluate(
                'f.software.value="none"; jQuery(f.software).trigger("change")'
            )
            assert evaluate(
                'f.virtualmin_bundle.disabled && f.virtualmin_bundle.getClientRects().length === 0'
            )
            assert evaluate('!f.packages.disabled')

            # script_choices(form) checks source panels and submitted controls.
            # form is a JavaScript expression selecting the fixture form.
            def script_choices(form):
                evaluate(
                    'window.scriptForm = '
                    + form
                    + '; window.scriptFields = scriptForm.elements'
                )
                # GPL previews must stay disabled and absent from FormData.
                if not (here.parents[1] / 'pro/SetupScripts.pm').is_file():
                    assert evaluate(
                        '[...scriptForm.querySelectorAll("[data-vm-script] input")].every(e=>e.matches(":disabled"))'
                    )
                    assert not evaluate(
                        '[...new FormData(scriptForm).keys()].some(k=>/^(before|after)_script/.test(k))'
                    )
                    return
                # Pro source changes expose and submit only the selected input.
                for field in ('before_script', 'after_script'):
                    for mode in ('none', 'file', 'inline', 'none'):
                        evaluate(
                            'scriptForm.querySelector('
                            + json.dumps(
                                'input[name='
                                + field
                                + '_mode][value='
                                + mode
                                + ']'
                            )
                            + ').click()'
                        )
                        state = evaluate(
                            '(() => { const body = scriptFields['
                            + json.dumps(field)
                            + ']; '
                            'const path = scriptFields['
                            + json.dumps(field + '_path')
                            + ']; '
                            'return {body:!body.disabled, path:!path.disabled, '
                            'bodyVisible:body.getClientRects().length > 0, '
                            'pathVisible:path.getClientRects().length > 0, '
                            'chooserVisible:path.closest("[data-vm-script-source]").querySelector("button,input[type=button]").getClientRects().length > 0, '
                            'submitted:Array.from(new FormData(scriptForm).keys())}; })()'
                        )
                        assert (
                            state['body']
                            == state['bodyVisible']
                            == (mode == 'inline')
                        ), state
                        assert (
                            state['path']
                            == state['pathVisible']
                            == (mode == 'file')
                        ), state
                        assert state['chooserVisible'] == (mode == 'file'), (
                            state
                        )
                        assert (field in state['submitted']) == (
                            mode == 'inline'
                        ), state
                        assert (field + '_path' in state['submitted']) == (
                            mode == 'file'
                        ), state
                # Each option opens help with its own matching title.
                for field in ('before_script', 'after_script'):
                    assert evaluate(
                        '!!scriptForm.querySelector('
                        + json.dumps('a[href*="machine_' + field + '"]')
                        + ')'
                    )
                assert evaluate(
                    '!!scriptForm.querySelector("a[href*=machine_packages]")'
                )
                assert not evaluate(
                    'scriptForm.innerText.includes("POSIX shell scripts run once")'
                )

            script_choices('presetForm')
            print(
                'PASS: built-in template selection, collapsed sections and per-creation license fields',
                flush=True,
            )
            # If navigation prompts, discard only this fixture's edits.
            prompt = 'document.querySelector(".bootbox-o__f_m-beforeclose-prompt")?.closest(".modal")?.querySelector("[data-bb-handler=danger]")'
            # Actual navigation links must load both management and
            # creation pages.
            for path, condition in [
                (
                    'edit_newtmpl.cgi',
                    'document.querySelector("a[href*=edit_tmpl]")',
                ),
                (
                    'machine_form.cgi',
                    'document.querySelector("#vm-create-form template[data-vm-images]")',
                ),
            ]:
                link = (
                    '('
                    + documents
                    + ').flatMap(d=>Array.from(d.querySelectorAll("a[href]"))).find(a=>new URL(a.href).pathname.endsWith("/'
                    + path
                    + '"))'
                )
                wait(link)
                evaluate('(' + link + ').click()')
                wait(condition + ' || ' + prompt)
                if evaluate('!!(' + prompt + ')'):
                    # Continue after the hostname and software control checks.
                    evaluate(prompt + '.click()')
                wait(condition)

            # q(selector) quotes native CSS selectors for the fixture's
            # page queries.
            def q(selector):
                return 'document.querySelector(' + json.dumps(selector) + ')'

            # The native settings category must contain both links, not
            # stand-alone items.
            wait(
                '('
                + documents
                + ').some(d=>d.querySelector("#global_setting a[href*=edit_newtmpl]"))'
            )
            for kind, ident, stem in [
                ('template', template, 'tmpl'),
                ('plan', plan, 'plan'),
            ]:
                path = 'edit_new' + stem + '.cgi'
                link = (
                    '('
                    + documents
                    + ').flatMap(d=>Array.from(d.querySelectorAll("a[href]"))).find(a=>new URL(a.href).pathname.endsWith("/'
                    + path
                    + '"))'
                )
                evaluate('(' + link + ').click()')
                entry = q('a[href="edit_' + stem + '.cgi?id=' + ident + '"]')
                # If navigation prompts, discard only this fixture's edits.
                wait(entry + ' || ' + prompt)
                if evaluate('!!(' + prompt + ')'):
                    # Continue past the theme's unsaved-fixture warning.
                    evaluate(prompt + '.click()')
                wait(entry)
                evaluate(entry + '.click()')
                form = 'form[action="save_' + stem + '.cgi"]'
                wait(
                    q(form + ' input[name=id]')
                    + '?.value === '
                    + json.dumps(ident)
                )
                assert not evaluate(
                    'document.body.innerText.includes("Return to Return to")'
                )
                assert not evaluate('!!' + q(form + ' fieldset'))
                if kind == 'template':
                    # Template sections preserve native navigation and buttons.
                    nav = q('form[action="edit_tmpl.cgi"]')
                    evaluate(
                        nav
                        + '.elements.editmode.value="access"; '
                        + nav
                        + '.elements.editmode.dispatchEvent(new Event("change", {bubbles:true}))'
                    )
                    wait(
                        q(form + ' input[name=editmode]')
                        + '?.value === "access"'
                    )
                    assert evaluate(
                        '!!document.querySelector("input[name=username]")'
                    )
                    # Password-only access hides keys; inheritance follows
                    # Default Template.
                    wait(q(form) + '?.dataset.accessReady === "1"')
                    evaluate(
                        'window.accessForm = '
                        + q(form)
                        + '; window.accessFields = accessForm.elements'
                    )
                    original_auth = evaluate('accessFields.auth_type.value')
                    for auth in ('password', 'keys', 'both', ''):
                        evaluate(
                            'accessFields.auth_type.value='
                            + json.dumps(auth)
                            + '; jQuery(accessFields.auth_type).trigger("change")'
                        )
                        shown = (
                            auth != 'password'
                            if auth
                            else evaluate(
                                'accessForm.dataset.defaultAuth !== "password"'
                            )
                        )
                        assert (
                            evaluate('!accessFields.ssh_keys.disabled') == shown
                        )
                        assert (
                            evaluate(
                                'accessFields.ssh_keys.getClientRects().length > 0'
                            )
                            == shown
                        )
                    evaluate(
                        'accessFields.auth_type.value='
                        + json.dumps(original_auth)
                        + '; jQuery(accessFields.auth_type).trigger("change")'
                    )
                    wait(
                        'document.body.hasAttribute("layout-column") && '
                        + q(form + ' button[name=save] i')
                    )
                    assert evaluate(
                        '!!' + q('button[name=nprev] .fa-arrow-circle-o-left')
                    )
                    assert evaluate(
                        '!!'
                        + q(
                            form + ' button[name=next] .fa-arrow-circle-o-right'
                        )
                    )
                    assert evaluate(
                        '!!' + q(form + ' button[name=clone] .fa-clone')
                    )
                    picture = call(
                        'Page.captureScreenshot',
                        {'format': 'jpeg', 'quality': 70},
                    )
                    Path('/var/tmp/cloudmin-presets-template.jpg').write_bytes(
                        base64.b64decode(picture['data'])
                    )
                    evaluate(q(form + ' [name=next]') + '.click()')
                    wait(
                        q(form + ' input[name=editmode]')
                        + '?.value === "network"'
                    )
                    assert evaluate(
                        '!!document.querySelector("input[name=gateway4]")'
                    )
                    evaluate(nav + '.querySelector("[name=nprev]").click()')
                    wait(
                        q(form + ' input[name=editmode]')
                        + '?.value === "access"'
                    )
                    # Software is independent of Virtualmin in the template
                    # editor too.
                    evaluate(
                        nav
                        + '.elements.editmode.value="software"; '
                        + nav
                        + '.elements.editmode.dispatchEvent(new Event("change", {bubbles:true}))'
                    )
                    wait(
                        q(form + ' input[name=editmode]')
                        + '?.value === "software"'
                    )
                    wait(q(form) + '?.dataset.softwareReady === "1"')
                    evaluate(
                        'window.s = '
                        + q(form)
                        + '.elements; s.software.value="none"; jQuery(s.software).trigger("change")'
                    )
                    assert evaluate(
                        's.virtualmin_bundle.disabled && s.virtualmin_bundle.getClientRects().length === 0'
                    ), evaluate(
                        '({value:s.software.value, disabled:s.virtualmin_bundle.disabled, '
                        'rows:document.querySelectorAll("[data-vm-virtualmin]").length, '
                        'html:s.virtualmin_bundle.closest("tr, .ui_table_row")?.outerHTML.slice(0,2500)})'
                    )
                    # Inherited packages stay hidden until an explicit list
                    # is selected.
                    package_mode = evaluate('s.packages_mode.value')
                    for mode in ('inherit', 'none', 'list'):
                        evaluate(
                            's.packages_mode.value='
                            + json.dumps(mode)
                            + '; jQuery(s.packages_mode[0]).trigger("change")'
                        )
                        assert evaluate(
                            '!s.packages.disabled && s.packages.getClientRects().length > 0'
                        ) == (mode == 'list')
                    evaluate(
                        's.packages_mode.value='
                        + json.dumps(package_mode)
                        + '; jQuery(s.packages_mode[0]).trigger("change")'
                    )
                    script_choices(q(form))
                    evaluate(
                        's.software.value="virtualmin-gpl"; jQuery(s.software).trigger("change")'
                    )
                    assert evaluate(
                        '!s.virtualmin_bundle.disabled && s.virtualmin_bundle.getClientRects().length > 0'
                    )
                else:
                    # Plans use the native collapsible form rather
                    # than sections.
                    assert evaluate(
                        '!!document.querySelector("#hiddendiv_main")'
                    )
                    wait(
                        'document.body.hasAttribute("layout-column") && '
                        + q(form + ' button[name=save] i')
                    )
                    picture = call(
                        'Page.captureScreenshot',
                        {'format': 'jpeg', 'quality': 70},
                    )
                    Path('/var/tmp/cloudmin-presets-plan.jpg').write_bytes(
                        base64.b64decode(picture['data'])
                    )
            print(
                'PASS: System Settings, native editors, section navigation and Save and Next',
                flush=True,
            )
            print(
                'PASS: Chromium preset switching, unit conversion and theme navigation',
                flush=True,
            )
            # Load every distribution logo through the real module asset route.
            call(
                'Page.navigate',
                {
                    'url': base + '/server-manager/image_form.cgi',
                    'referrer': base + '/',
                },
            )
            wait('document.querySelector("[data-ui-multi-heading] img")')
            wait(
                '[...document.querySelectorAll("[data-ui-multi-heading] img")].every(i=>i.complete && i.naturalWidth > 0)'
            )
            icons = evaluate(
                '[...document.querySelectorAll("[data-ui-multi-heading] img")].map(i=>({src:i.getAttribute("src"),width:i.width,height:i.height,alt:i.alt}))'
            )
            assert len(icons) >= 8, icons
            assert all(
                i['src'].startswith('images/os/')
                and i['width'] == i['height'] == 16
                and i['alt'] == ''
                for i in icons
            ), icons
            print(
                'PASS: local SVG distribution logos load at 16 x 16 pixels',
                flush=True,
            )
        finally:
            # Close only the browser connection created by this fixture.
            if cdp:
                try:
                    call('Browser.close')
                except Exception:
                    # The process wait below handles a lost connection.
                    pass
                cdp.close()
            else:
                # Startup may fail before a debugging connection is available.
                chrome.terminate()
            try:
                chrome.wait(timeout=15)
            except subprocess.TimeoutExpired:
                # Bound teardown if this fixture browser stops responding.
                chrome.kill()
                chrome.wait()


try:
    # Create a fixture session without using administrator credentials.
    subprocess.run(
        ['perl', str(helper), 'create', 'authentic-theme', user],
        input=password + '\n',
        text=True,
        check=True,
    )
    created = True
    # Back up only the two files this fixture changes; always restore
    # user settings.
    for kind in ('template', 'plan'):
        path = Path('/etc/webmin/server-manager') / (kind + 's.json')
        originals[path] = path.read_bytes() if path.exists() else None
        # Exercise shipped defaults without inheriting host customizations.
        path.unlink(missing_ok=True)
    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {'user': user, 'pass': password, 'page': '/server-manager/index.cgi'},
    )
    options = api('options')
    # Fresh hosts can exercise the same path by downloading a catalogue image.
    image = next(
        (i for i in options['images'] if i.get('format') != 'iso'), None
    )
    # Use a catalogue image when the host has no imported cloud image.
    if image is None:
        image = next(
            i
            for i in options['catalogue_images']
            if i['id'] == 'catalogue:rocky-linux-10'
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
        if int(p['available']) > size * 1024**3 + 256 * 1024**2
    )
    network = options['networks'][0]
    # Built-in defaults are visible records, with no separate
    # module-default mode.
    builtin = {e['id']: e for e in options['presets']['template']['entries']}
    assert set(builtin) == {'0' * 31 + str(i) for i in range(1, 6)}
    assert all(
        e['settings']['virtualmin_type'] == 'full'
        for e in builtin.values()
        if e['id'] != '0' * 31 + '1'
    )
    base_id = '0' * 31 + '1'
    base_plan = next(
        e for e in options['presets']['plan']['entries'] if e['id'] == base_id
    )
    assert base_plan['name'] == 'Default Plan'
    for stem in ('tmpl', 'plan'):
        page = request('/server-manager/edit_new' + stem + '.cgi')
        assert (
            'Use module defaults' not in page
            and 'name="clear_default"' not in page
        )
    for field in ('template', 'plan'):
        assert options['presets'][field]['default'], (
            'Every list needs a default'
        )

    # Missing Pro credentials must fail before submitting or allocating a VM.
    before_jobs = api('list')
    invalid = dict(
        action='create',
        token=options['token'],
        template='0' * 31 + '3',
        name='cloudmin-create-check-pro-denied',
        image=image['id'],
        pool=pool['id'],
        network=network['key'],
        cpus=1,
        memory_mib=1024,
        disk_gib=max(20, size),
        virtualmin_type='mini',
        username='cloudmin',
        auth_type='password',
        password=secrets.token_urlsafe(32),
        hostname='pro-denied.example.test',
        start=1,
        virtualmin_serial='123456',
    )
    refused = json.loads(request('/server-manager/api.cgi', invalid, True))
    if 'Not enough free host memory' in refused.get('error', ''):
        # Memory preflight can prevent this request reaching license validation.
        print(
            'SKIP: Pro credential check blocked by host memory preflight',
            flush=True,
        )
    else:
        # With sufficient memory, the missing license must be the
        # refusal reason.
        assert 'license serial and key' in refused.get('error', ''), (
            refused.get('error', 'Unexpected success')
        )
        print('PASS: Pro credential validation before allocation', flush=True)
    assert before_jobs == api('list'), 'Missing license submitted a job'
    print(
        'PASS: bundled templates; rejected request allocated no VM', flush=True
    )
    # Create editable records through the same forms administrators use.
    label = 'Preset fixture ' + secrets.token_hex(4)
    values = editor('plan')
    values.update(
        name=label,
        description='Fixture',
        cpus=1,
        memory_mib=512,
        memory_mib_units=1024**2,
        disk_gib=size,
        disk_gib_units=1024**3,
    )
    save('plan', values)
    plan = next(
        p
        for p in api('options')['presets']['plan']['entries']
        if p['name'] == label
    )
    values = editor('template')
    values.update(name=label, next='1')
    following = Form(
        request('/server-manager/save_tmpl.cgi', values), 'save_tmpl.cgi'
    ).fields
    assert following['editmode'] == 'image', (
        'Create and Next did not open image settings'
    )
    template = next(
        t
        for t in api('options')['presets']['template']['entries']
        if t['name'] == label
    )
    # Save a catalogue choice before returning to this fixture's
    # imported source.
    catalogue = next(
        i
        for i in options['catalogue_images']
        if i['id'] == 'catalogue:rocky-linux-10'
    )
    values = editor('template', template['id'], 'image')
    values.update(image=catalogue['id'], pool=pool['id'])
    save('template', values)
    assert (
        editor('template', template['id'], 'image')['image'] == catalogue['id']
    )
    print(
        'PASS: template editor saves and restores a catalogue selection',
        flush=True,
    )
    # Independent section saves must preserve previously selected settings.
    for section, settings in [
        ('image', dict(image=image['id'], pool=pool['id'])),
        ('access', dict(username='cloudmin', auth_type='password')),
        ('network', dict(network=network['key'], address_mode='dhcp')),
        ('boot', dict(start='0', autostart='0')),
    ]:
        values = editor('template', template['id'], section)
        values.update(settings)
        save('template', values)
    # Clearing packages must override Default Template, including API creation
    # that supplies only the template ID and leaves software fields omitted.
    values = editor('template', base_id, 'software')
    values['packages_mode'] = 'list'
    values['packages'] = 'jq'
    save('template', values)
    values = editor('template', template['id'], 'software')
    values['packages_mode'] = 'none'
    values['packages'] = ''
    save('template', values)
    template = next(
        t
        for t in api('options')['presets']['template']['entries']
        if t['id'] == template['id']
    )
    assert template['settings']['packages'] == '', (
        'Cleared packages were not saved'
    )
    # List actions select defaults and copy full records by ID.
    for kind, entry, stem in [
        ('template', template, 'tmpl'),
        ('plan', plan, 'plan'),
    ]:
        page = request('/server-manager/edit_new' + stem + '.cgi')
        fields = Form(page, 'delete_' + stem + 's.cgi').fields
        latest = next(
            e
            for e in api('options')['presets'][kind]['entries']
            if e['id'] == entry['id']
        )
        assert 'revision' not in latest and not any(
            k.startswith('revision_') for k in fields
        )
        fields.update(d=entry['id'], default='1')
        response = request('/server-manager/delete_' + stem + 's.cgi', fields)
        assert api('options')['presets'][kind]['default'] == entry['id'], (
            FormText(response)
        )
        # Copy opens a new editor and retains every section when it is saved.
        clone = Form(
            request(
                '/server-manager/save_' + stem + '.cgi',
                dict(editor(kind, entry['id']), clone='1'),
            ),
            'save_' + stem + '.cgi',
        ).fields
        assert not clone['id'] and clone['name'].startswith('Copy of ')
        save(kind, clone)
        copied = next(
            e
            for e in api('options')['presets'][kind]['entries']
            if e['name'] == clone['name']
        )
        assert (
            copied['id'] != entry['id']
            and copied['settings'] == latest['settings']
        )
        # Browser Back can reuse an earlier editor or copy form after a save.
        earlier = editor(kind, entry['id'])
        changed = dict(earlier, description='Updated fixture')
        save(kind, changed)
        save(
            kind,
            dict(
                earlier,
                description='Resaved fixture',
                revision='previous-revision',
            ),
        )
        latest = next(
            e
            for e in api('options')['presets'][kind]['entries']
            if e['id'] == entry['id']
        )
        assert latest['description'] == 'Resaved fixture'
        save(
            kind,
            dict(
                clone,
                name=clone['name'] + ' again',
                clone_revision='previous-revision',
            ),
        )
        response = request('/server-manager/delete_' + stem + 's.cgi', fields)
        assert api('options')['presets'][kind]['default'] == entry['id'], (
            FormText(response)
        )
    # Creation from defaults copies the selected template's complete settings.
    defaults = Form(
        request('/server-manager/edit_tmpl.cgi?new=1&cp=1'), 'save_tmpl.cgi'
    ).fields
    defaults['name'] = label + ' from defaults'
    save('template', defaults)
    copied = next(
        e
        for e in api('options')['presets']['template']['entries']
        if e['name'] == defaults['name']
    )
    assert copied['settings'] == template['settings']
    print(
        'PASS: Create and Next, copy, creation from defaults and repeated form saves',
        flush=True,
    )
    browser_check(template['id'], plan['id'])
    # A real stopped VM proves UI and API defaults reach the existing worker.
    token = api('options')['token']
    fields = dict(
        token=token,
        template=template['id'],
        plan=plan['id'],
        name='cloudmin-create-check-presets-' + secrets.token_hex(4),
        password=secrets.token_urlsafe(32),
    )
    job = api('create', fields)
    job_id = job['id']
    deadline = time.monotonic() + 600
    while (
        job['state'] not in ('complete', 'failed', 'cancelled')
        and time.monotonic() < deadline
    ):
        time.sleep(1)
        job = api('status', {'job': job_id})
    assert job['state'] == 'complete', job.get('error', job['state'])
    inspected = json.loads(
        subprocess.check_output(
            ['perl', str(here / 'machine_fixture.pl'), 'inspect', job_id],
            text=True,
        )
    )
    assert (
        inspected['vm']['vcpus'] == 1
        and inspected['vm']['memory_kib'] == 512 * 1024
    )
    assert not inspected['vm']['active']
    # A later preset edit cannot rewrite a submitted VM or break
    # retry attachment.
    changed = editor('plan', plan['id'])
    changed['cpus'] = 2
    save('plan', changed)
    assert api('create', fields)['id'] == job_id
    assert api('settings', {'id': job['uuid']})['cpus'] == 1
    print(
        'PASS: create from template and plan, stopped guest allocations, immutable job and retry',
        flush=True,
    )
    # A used template cannot be deleted until its virtual machine is removed.
    for kind, entry, stem in [
        ('template', template, 'tmpl'),
        ('plan', plan, 'plan'),
    ]:
        page = request('/server-manager/edit_new' + stem + '.cgi')
        selected = Form(page, 'delete_' + stem + 's.cgi').fields
        selected.update(d=entry['id'], delete='1')
        confirmation = request(
            '/server-manager/delete_' + stem + 's.cgi', selected
        )
        assert any(
            e['id'] == entry['id']
            for e in api('options')['presets'][kind]['entries']
        )
        confirmed = Form(confirmation, 'delete_' + stem + 's.cgi').fields
        confirmed['confirm'] = '1'
        response = request(
            '/server-manager/delete_' + stem + 's.cgi', confirmed
        )
        if kind == 'template':
            # Used templates cannot be deleted; plans supply initial sizes only.
            assert 'used by virtual machines' in FormText(response), FormText(
                response
            )
            assert any(
                e['id'] == entry['id']
                for e in api('options')['presets'][kind]['entries']
            )
            assert api('settings', {'id': job['uuid']})['cpus'] == 1
            subprocess.run(
                ['perl', str(here / 'machine_fixture.pl'), 'cleanup', job_id],
                check=True,
            )
            request('/server-manager/delete_' + stem + 's.cgi', confirmed)
        remaining = api('options')['presets'][kind]
        assert not any(e['id'] == entry['id'] for e in remaining['entries'])
        assert remaining['default'] == base_id, (
            'Deleting a custom default must select the built-in preset'
        )
    assert api('create', fields)['id'] == job_id
    print(
        'PASS: used template deletion refused; deletion after guest removal restores the default',
        flush=True,
    )
    # Exercise both read-only and delegated denials using the same valid
    # admin token.
    for readonly in (True, False):
        if readonly:
            # Read-only mode must deny writes even to an administrator.
            subprocess.run(
                ['perl', str(helper), 'readonly', 'authentic-theme', user],
                input='1\n',
                text=True,
                check=True,
            )
        else:
            # Normal mode must still deny delegated users without admin access.
            subprocess.run(
                ['perl', str(helper), 'readonly', 'authentic-theme', user],
                input='0\n',
                text=True,
                check=True,
            )
            subprocess.run(
                ['perl', str(helper), 'acl', 'authentic-theme', user],
                input='{"admin":0}\n',
                text=True,
                check=True,
            )
        before = {p: p.read_bytes() for p in originals}
        for path in (
            'save_plan.cgi',
            'save_tmpl.cgi',
            'delete_plans.cgi',
            'delete_tmpls.cgi',
        ):
            for supplied in ('', token):
                refused = request(
                    '/server-manager/' + path,
                    {'token': supplied, 'name': 'denied', 'default': 1},
                )
                assert (
                    'read-only' if readonly else 'Access denied'
                ) in refused, path + ' was not refused'
        assert before == {p: p.read_bytes() for p in originals}, (
            'Refused mutation changed configuration'
        )
    print(
        'PASS: all preset mutations denied without and with an admin token',
        flush=True,
    )
finally:
    # Teardown addresses only this fixture's job, saved configuration
    # and account.
    try:
        if job_id:
            # Remove only the guest whose job was captured by this fixture.
            subprocess.run(
                ['perl', str(here / 'machine_fixture.pl'), 'cleanup', job_id],
                check=True,
            )
    finally:
        for path, content in originals.items():
            if content is None:
                # Remove a settings file only when the fixture created it.
                path.unlink(missing_ok=True)
            else:
                # Restore the exact contents that preceded the test.
                path.write_bytes(content)
        if created:
            # Remove the temporary account and its fixture password records.
            subprocess.run(
                ['perl', str(here / 'machine_fixture.pl'), 'forget-passwords'],
                check=True,
            )
            subprocess.run(
                ['perl', str(helper), 'delete', 'authentic-theme', user],
                check=True,
            )
