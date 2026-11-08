#!/usr/bin/python3
"""Exercise terminal startup and cleanup in a real disposable-VM browser."""

import argparse
import base64
import json
from theme_support import is_spa_theme
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import subprocess
import tempfile
import time

import websocket

# Credentials and the fresh browser profile stay on the disposable VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
helper = Path(__file__).resolve().with_name('webmin-user.pl')
browser = shutil.which('chromium') or shutil.which('chromium-browser')
# Layout, keyboard and navigation checks need a real browser on the VM.
if not browser:
    raise SystemExit('Chromium is required on the disposable VM')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--theme',
    choices=('authentic-theme', 'gray-theme'),
    default='authentic-theme',
)
parser.add_argument(
    '--guest-id',
    required=True,
    help='UUID of a separately provisioned disposable terminal test guest',
)
options = parser.parse_args()
theme = options.theme
import uuid

guest_id = str(uuid.UUID(options.guest_id))
import libvirt

with_connection = libvirt.openReadOnly('qemu:///system')
try:
    test_guest = with_connection.lookupByUUIDString(guest_id)
    # Refuse to type into a guest outside the dedicated terminal fixtures.
    if not test_guest.name().startswith(
        ('cloudmin-terminal-check-', 'cloudmin-create-check-')
    ):
        raise SystemExit(
            'Select a terminal or creation test fixture, never an existing user guest'
        )
finally:
    with_connection.close()
spa = is_spa_theme(theme)
in_frame = False
sent = []
base = 'https://127.0.0.1:10000'
# A dedicated fixture account avoids collisions with other live UI checks.
user = os.environ.get('CLOUDMIN_TEST_USER', 'cloudmin-ui-check')
created = False
chrome = None
cdp = None
errors = []
frames = []
closed_sockets = 0
closed_socket_ids = set()
# Record binary streams by socket ID; the live status channel sends text.
binary_sockets = set()
requests = []
serial = 0
session = None
profile = None


# call(method, [params]) sends a DevTools command and records browser failures.
def call(method, params=None):
    global serial, closed_sockets
    serial += 1
    command = dict(id=serial, method=method, params=params or {})
    # Browser setup runs before a target session has been attached.
    if session:
        command['sessionId'] = session
    cdp.send(json.dumps(command))
    while True:
        message = json.loads(cdp.recv())
        event = message.get('method')
        details = message.get('params', {})
        # Retain page exceptions for the final assertion.
        if event == 'Runtime.exceptionThrown':
            errors.append(
                details['exceptionDetails']
                .get('exception', {})
                .get('description', 'Browser exception')
            )
        # Decode terminal output while excluding the text-only status channel.
        elif event == 'Network.webSocketFrameReceived':
            frame = details['response']
            payload = frame['payloadData']
            # Binary frames identify sockets carrying terminal data.
            if frame['opcode'] == 2:
                binary_sockets.add(details['requestId'])
                frames.append(
                    base64.b64decode(payload).decode(errors='replace')
                )
        # Outbound resize messages prove that xterm measured its viewport.
        elif event == 'Network.webSocketFrameSent':
            sent.append(details['response']['payloadData'])
        # Navigation must close each terminal stream it opened.
        elif event == 'Network.webSocketClosed':
            closed_socket_ids.add(details['requestId'])
            # A status-channel close must not satisfy the terminal assertion.
            if details['requestId'] in binary_sockets:
                closed_sockets += 1
        elif event == 'Network.requestWillBeSent':
            # Keep only filenames; query strings can contain form tokens.
            requests.append(
                details['request']['url'].split('?', 1)[0].rsplit('/', 1)[-1]
            )
        # Wait past events until the numbered command reply arrives.
        if message.get('id') == serial:
            # A failed CDP action cannot count as a completed interaction.
            if 'error' in message:
                raise RuntimeError(message['error']['message'])
            return message.get('result', {})


# evaluate(expression) runs test code without logging expressions or
# form values.
def evaluate(expression):
    # Evaluate in the content frame when the module is loaded there.
    if in_frame:
        expression = 'window.frames.right.eval(' + json.dumps(expression) + ')'
    reply = call(
        'Runtime.evaluate',
        dict(expression=expression, returnByValue=True, awaitPromise=True),
    )
    # Do not print the evaluated expression, which may contain fixture secrets.
    if reply.get('exceptionDetails'):
        raise RuntimeError('Browser evaluation failed')
    return reply.get('result', {}).get('value')


# wait_for(expression, label, [seconds]) waits for a specific visible
# page state.
def wait_for(expression, label, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        # Proceed only once the actual page meets the requested condition.
        if evaluate(expression):
            return
        time.sleep(0.1)
    raise AssertionError(label)


# focus_terminal() waits for the renderer's entrance animation before typing.
def focus_terminal():
    call('Page.bringToFront')
    wait_for(
        '''(() => {
      const input = document.querySelector('#terminal textarea');
      input.focus();
      return document.activeElement === input;
    })()''',
        'Terminal input cannot receive focus',
    )


try:
    password = secrets.token_urlsafe(36)
    subprocess.run(
        ['perl', str(helper), 'create', theme, user],
        input=password + '\n',
        text=True,
        check=True,
    )
    created = True
    time.sleep(1)
    profile = tempfile.TemporaryDirectory(prefix='cloudmin-terminal-browser-')
    directory = profile.name
    # The browser runs only on this VM; it never opens a workstation profile.
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
            '--screen-info={1920x1200}',
            '--window-size=1400,1100',
            '--user-data-dir=' + directory,
            'about:blank',
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    active = Path(directory) / 'DevToolsActivePort'
    deadline = time.monotonic() + 30
    while (
        not active.exists()
        and chrome.poll() is None
        and time.monotonic() < deadline
    ):
        time.sleep(0.1)
    port, route = active.read_text().splitlines()
    cdp = websocket.create_connection(
        'ws://127.0.0.1:' + port + route, timeout=15, suppress_origin=True
    )
    target = call('Target.createTarget', dict(url='about:blank'))['targetId']
    session = call(
        'Target.attachToTarget', dict(targetId=target, flatten=True)
    )['sessionId']
    for domain in ('Page', 'Runtime', 'Network'):
        call(domain + '.enable')
    call('Page.navigate', dict(url=base + '/session_login.cgi'))
    wait_for(
        '!!document.querySelector("input[name=user]")', 'Login form missing'
    )
    evaluate(
        '''(() => {
        document.querySelector('[name=user]').value = %s;
        document.querySelector('[name=pass]').value = %s;
        const form = document.querySelector('[name=user]').form;
        form.submit();
    })()'''
        % (json.dumps(user), json.dumps(password))
    )
    # Load the Cloudmin menu in the left frame before selecting the guest.
    if not spa:
        wait_for(
            '!!window.frames.right && !!window.frames.left',
            'Navigation and content frames missing',
        )
        evaluate(
            "window.frames.left.location = '/left.cgi?mode=server-manager'"
        )
        in_frame = True
    navigation = 'parent.frames.left.document' if in_frame else 'document'
    # Select only the explicitly supplied fixture before using its sidebar.
    overview = (
        navigation + '.querySelector(\'a[href*="/server-manager/index.cgi"]\')'
    )
    wait_for('!!' + overview, 'host overview link missing')
    evaluate(overview + '.click()')
    guest_link = (
        'Array.from(document.querySelectorAll("a[href]")).find(a => '
                  'new URL(a.href).pathname.endsWith("/machine.cgi") && '
                  'new URL(a.href).searchParams.get("id") === '
        + json.dumps(guest_id)
        + ')'
    )
    wait_for('!!(' + guest_link + ')', 'Fixture guest link missing')
    evaluate('(' + guest_link + ').click()')
    terminal_link = (
        'Array.from(' + navigation + '.querySelectorAll("a[href]")).find(a => '
                     'new URL(a.href).pathname.endsWith("/remote_access.cgi") && '
                     'new URL(a.href).searchParams.get("id") === '
        + json.dumps(guest_id)
        + ')'
    )
    wait_for('!!' + terminal_link, 'Terminal sidebar link missing')
    # Click the real sidebar and Connect control through the
    # navigation handlers.
    for attempt in range(2):
        frames.clear()
        # Isolate the SSH sockets opened on this visit from prior console tabs.
        previous_sockets = set(binary_sockets)
        evaluate(terminal_link + '.click()')
        wait_for(
            '!!document.querySelector("input[name=username]")',
            'Connection form missing',
        )
        assert (
            evaluate(
                "[...document.querySelectorAll('.vm-console-tab-label')].map(label => label.textContent.trim()).join(',')"
            )
            == 'SSH terminal,Serial console,Graphical console'
        )
        assert not evaluate(
            '!!document.querySelector("[data-console-status]")'
        ), 'SSH badge visible before Connect'
        assert not evaluate(
            '!!document.querySelector(".page-footer-actions a")'
        ), 'Console still has a return button'
        assert (
            evaluate(
                'new URL(document.querySelector("[name=connect]").form.action).searchParams.get("tab")'
            )
            == 'ssh'
        )
        if spa:
            # The theme strips xnavigation from AJAX requests, but keeps it
            # in history.
            assert (
                evaluate(
                    'new URL(location.href).searchParams.get("xnavigation")'
                )
                == '1'
            )
        # New cloud images can disable passwords; use their provisioned
        # host key.
        key_auth = evaluate(
            '!!document.querySelector("[name=auth] option[value=key]")'
        )
        evaluate(
            'document.querySelector("[name=auth]").value = '
            + json.dumps('key' if key_auth else 'password')
        )
        evaluate('document.querySelector("[name=connect]").click()')
        wait_for(
            '!!document.getElementById("terminal")', 'Terminal viewport missing'
        )
        wait_for(
            '!!document.querySelector("#terminal .xterm-screen")',
            'xterm did not start',
        )
        wait_for(
            'document.querySelector("[data-terminal-status]")?.textContent.trim() === "Connected"',
            'SSH badge did not connect',
        )
        # SSH must inherit the same state palette as the hypervisor badges.
        assert evaluate("""(() => {
          const badge = document.querySelector('[data-terminal-status] .ui_badge');
          const style = getComputedStyle(badge);
          return badge.classList.contains('ui_badge_success') &&
            style.getPropertyValue('--ui-success-soft').trim() &&
            style.backgroundColor !== 'rgba(0, 0, 0, 0)';
        })()"""), 'SSH connected badge has no success palette'
        # The page moves the badge into its header and preserves the tab URL.
        if spa:
            assert evaluate(
                '!!document.querySelector("#headln2c [data-terminal-status]")'
            ), 'SSH badge left the VM subtitle'
            assert (
                evaluate('new URL(location.href).searchParams.get("tab")')
                == 'ssh'
            )
            assert (
                evaluate(
                    'new URL(location.href).searchParams.get("xnavigation")'
                )
                == '1'
            )
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            evaluate('true')
            output = ''.join(frames)
            # A shell or authentication prompt proves SSH reached the guest.
            if (key_auth and re.search(r'[$#] ', output)) or any(
                prompt in output.lower()
                for prompt in ('password:', 'continue connecting')
            ):
                break
            time.sleep(0.1)
        # Exhausting the wait without a prompt is a failed terminal connection.
        else:
            raise AssertionError('Guest SSH prompt missing')
        # Type through xterm, rather than sending directly to the WebSocket.
        if (
            'continue connecting' in ''.join(frames).lower()
            and 'password:' not in ''.join(frames).lower()
        ):
            focus_terminal()
            call('Input.insertText', dict(text='yes'))
            call(
                'Input.dispatchKeyEvent',
                dict(
                    type='keyDown',
                    key='Enter',
                    code='Enter',
                    windowsVirtualKeyCode=13,
                    text='\r',
                ),
            )
            call(
                'Input.dispatchKeyEvent',
                dict(
                    type='keyUp',
                    key='Enter',
                    code='Enter',
                    windowsVirtualKeyCode=13,
                ),
            )
            deadline = time.monotonic() + 20
            while (
                not key_auth
                and 'password:' not in ''.join(frames).lower()
                and time.monotonic() < deadline
            ):
                evaluate('true')
                time.sleep(.1)
            # Password mode must reach its password prompt after
            # host-key consent.
            if not key_auth:
                assert 'password:' in ''.join(frames).lower(), (
                    'Keyboard input did not reach SSH'
                )
        if key_auth:
            # Host-key consent precedes authentication; wait before typing
            # a command.
            deadline = time.monotonic() + 30
            while (
                not re.search(r'[$#] ', ''.join(frames))
                and time.monotonic() < deadline
            ):
                evaluate('true')
                time.sleep(.1)
            assert re.search(r'[$#] ', ''.join(frames)), (
                'Host key login did not reach a shell'
            )
            # A split marker distinguishes shell output from echoed
            # keyboard input.
            focus_terminal()
            call(
                'Input.insertText',
                dict(text="printf '\\n%s%s\\n' cloudmin-terminal- connected"),
            )
            call(
                'Input.dispatchKeyEvent',
                dict(
                    type='keyDown',
                    key='Enter',
                    code='Enter',
                    windowsVirtualKeyCode=13,
                    text='\r',
                ),
            )
            call(
                'Input.dispatchKeyEvent',
                dict(
                    type='keyUp',
                    key='Enter',
                    code='Enter',
                    windowsVirtualKeyCode=13,
                ),
            )
            deadline = time.monotonic() + 30
            while (
                'cloudmin-terminal-connected' not in ''.join(frames)
                and time.monotonic() < deadline
            ):
                evaluate('true')
                time.sleep(.1)
            assert 'cloudmin-terminal-connected' in ''.join(frames), (
                'Host key login or guest keyboard input failed'
            )
        assert any('033[8;(' in data for data in sent), (
            'Terminal did not send its dimensions'
        )
        if spa:
            # Fill the page at desktop and narrow widths below the console tabs.
            window = call('Browser.getWindowForTarget', dict(targetId=target))
            for width, height in (
                (1000, 750),
                (600, 650),
                (1920, 1200),
                (1400, 1100),
            ):
                call(
                    'Browser.setWindowBounds',
                    dict(
                        windowId=window['windowId'],
                        bounds=dict(width=width, height=height),
                    ),
                )
                wait_for(
                    'window.outerWidth === %d && window.outerHeight === %d'
                    % (width, height),
                    'Browser window size did not change',
                )
                wait_for(
                    '''(() => {
                  const content = document.getElementById('content');
                  const bounds = content.getBoundingClientRect();
                  const terminal = document.getElementById('terminal').getBoundingClientRect();
                  const screen = document.querySelector('#terminal .xterm-screen').getBoundingClientRect();
                  return content.scrollHeight <= content.clientHeight + 1 &&
                         !content.querySelector('.page-footer-actions a') &&
                         terminal.bottom <= bounds.bottom && bounds.bottom - terminal.bottom < 50 &&
                         screen.bottom <= terminal.bottom && terminal.bottom - screen.bottom < 35;
                })()''',
                    'SSH terminal does not fill the page below the tabs',
                )
        assert not errors, 'Browser raised JavaScript errors'
        print(
            'PASS: '
            + theme
            + ' sidebar, keyboard input and resize reached the guest SSH prompt, visit',
            attempt + 1,
            flush=True,
        )
        ssh_sockets = binary_sockets - previous_sockets
        assert ssh_sockets, 'SSH stream missing'
        # Switching modes must dispose SSH even though the CGI stays the same.
        if attempt == 0:
            evaluate(
                'document.querySelector(\'a:has(.vm-console-tab-label)[href*="tab=serial"]\').click()'
            )
            wait_for(
                'document.querySelector("#cloudmin-console")?.dataset.consoleMode === "serial"',
                'Serial tab did not replace SSH',
            )
            assert (
                evaluate('new URL(location.href).searchParams.get("tab")')
                == 'serial'
            )
            # In-page navigation must retain the history flag too.
            if spa:
                assert (
                    evaluate(
                        'new URL(location.href).searchParams.get("xnavigation")'
                    )
                    == '1'
                )
        # Leaving must close the SSH sockets, not just the status socket.
        evaluate(
            navigation
            + '.querySelector(\'a[href="/server-manager/index.cgi"]\').click()'
        )
        wait_for(
            '!document.getElementById("terminal")',
            'Navigation did not remove the terminal',
        )
        deadline = time.monotonic() + 10
        while (
            not ssh_sockets.issubset(closed_socket_ids)
            and time.monotonic() < deadline
        ):
            evaluate('true')
            time.sleep(0.1)
        assert ssh_sockets.issubset(closed_socket_ids), (
            'Navigation left the terminal socket open'
        )

    if spa:
        # Image forms use the theme's render hook after each navigation too.
        for attempt in range(2):
            evaluate(
                'document.querySelector(\'a[href="/server-manager/images.cgi"]\').click()'
            )
            wait_for(
                '!!document.getElementById("cloudmin-image-form")',
                'Image form missing',
            )
            evaluate('''(() => {
                const source = document.querySelector('[name=install_type]');
                source.value = 'upload'; jQuery(source).trigger('change');
            })()''')
            wait_for(
                'document.getElementById("cloudmin-image-submit").value === "Import image"',
                'Image form was not initialized by the theme',
            )
            evaluate(
                navigation
                + '.querySelector(\'a[href="/server-manager/index.cgi"]\').click()'
            )
            wait_for(
                '!document.getElementById("cloudmin-image-form")',
                'Image navigation did not finish',
            )
        print(
            'PASS: theme initializes image forms on first and repeat visits',
            flush=True,
        )
    assert not errors, 'Browser raised JavaScript errors'
except Exception:
    # These diagnostics exclude HTML, cookies, submitted passwords and tokens.
    print('Browser errors:', errors)
    print(
        'Requested script files:',
        sorted({name for name in requests if name.endswith('.js')}),
    )
    print(
        'Terminal sockets seen:', len(binary_sockets), 'closed:', closed_sockets
    )
    # Browser diagnostics are available only after DevTools connected.
    if cdp:
        print(
            'xterm globals:',
            evaluate('[typeof Terminal, typeof AttachAddon, typeof FitAddon]'),
        )
        print(
            'Terminal error:',
            evaluate(
                'document.querySelector("[data-fatal-error-text]")?.textContent'
            ),
        )
    raise
finally:
    if cdp:
        # Ask Chrome to finish writing its profile before removing
        # the directory.
        try:
            call('Browser.close')
        except (websocket.WebSocketException, OSError):
            pass
        cdp.close()
    # Finish browser writes before its private profile is removed.
    if chrome:
        try:
            chrome.wait(timeout=10)
        except subprocess.TimeoutExpired:
            chrome.kill()
            chrome.wait()
    # Never remove an account unless this run created it.
    if created:
        subprocess.run(['perl', str(helper), 'delete', '', user], check=True)

    # Early setup failures may precede allocation of the browser profile.
    if profile:
        profile.cleanup()
