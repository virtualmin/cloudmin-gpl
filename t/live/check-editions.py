#!/usr/bin/python3
"""Exercise Pro removal and GPL previews on a disposable Cloudmin Pro host."""
import http.cookiejar
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import websocket

# This test moves installed Pro files and edits the test host's module settings.
if os.geteuid() != 0 or os.uname().sysname != 'Linux':
    raise SystemExit('Run as root on an authorized disposable Linux test host')
MODULE = Path(__file__).resolve().parents[2]
BASE = 'https://127.0.0.1:10000'
HELPER = MODULE / 't/live/webmin-user.pl'
CONFIG = Path('/etc/webmin/server-manager/config')
TEMPLATES = CONFIG.with_name('templates.json')


class Form(HTMLParser):
    """Collect form defaults, checking controls' own disabled attributes."""

    # __init__(self, page) collects default fields from one HTML response.
    def __init__(self, page):
        super().__init__()
        self.fields, self.select, self.textarea = {}, None, None
        self.feed(page)

    # handle_starttag(self, tag, attrs) collects successful named form controls.
    # Fieldset inheritance is checked separately in the real browser below.
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        name = a.get('name')
        # Omit disabled inputs and unchecked choices from the submission.
        if tag == 'input' and name and 'disabled' not in a:
            # Buttons have no default submission value unless explicitly chosen.
            if a.get('type') not in ('submit', 'button', 'checkbox', 'radio') or 'checked' in a:
                self.fields[name] = a.get('value', '')
        # Options belong only to the current enabled select.
        elif tag == 'select':
            self.select = name if 'disabled' not in a else None
        # Disabled provider options must never become a submitted default.
        elif tag == 'option' and self.select and 'disabled' not in a:
            # An explicit selection replaces the first eligible option.
            if self.select not in self.fields or 'selected' in a:
                self.fields[self.select] = a.get('value', '')
        # Textareas collect their content through the following data callbacks.
        elif tag == 'textarea' and name and 'disabled' not in a:
            self.textarea = name
            self.fields[name] = ''

    # handle_data(self, data) preserves textarea text across parser callbacks.
    def handle_data(self, data):
        # Ignore labels and other page text outside an enabled textarea.
        if self.textarea:
            self.fields[self.textarea] += data

    # handle_endtag(self, tag) ends collection when a control closes.
    def handle_endtag(self, tag):
        # Later options must not inherit a preceding select's name.
        if tag == 'select':
            self.select = None
        # Later text must not become part of the saved script.
        elif tag == 'textarea':
            self.textarea = None


# browser_check(jar, path, pro, [hidden]) checks native disabled semantics after JS.
# jar supplies cookies; pro selects the expected edition. hidden defaults to
# false and, when true, expects all script previews to be absent.
def browser_check(jar, path, pro, hidden=False):
    # Use a private profile and guest-local debugger, with no saved user data.
    with tempfile.TemporaryDirectory(prefix='cloudmin-edition-browser-') as profile:
        chrome = subprocess.Popen([shutil.which('chromium') or shutil.which('chromium-browser'), '--headless', '--no-sandbox',
            '--disable-gpu', '--remote-debugging-port=0', '--ignore-certificate-errors',
            '--no-first-run', '--disable-background-networking', '--disable-sync',
            '--user-data-dir='+profile, 'about:blank'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cdp = None
        try:
            # Chromium chooses its debugger port; wait for its startup file.
            active = Path(profile)/'DevToolsActivePort'
            deadline = time.monotonic()+30
            while not active.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            port, route = active.read_text().splitlines()
            cdp = websocket.create_connection('ws://127.0.0.1:'+port+route, timeout=30, suppress_origin=True)
            serial, session = 0, None

            # call(method, [params]) ignores events while waiting for its own reply.
            def call(method, params=None):
                nonlocal serial
                serial += 1
                payload = dict(id=serial, method=method, params=params or {})
                # Tab commands use a session; initial target creation does not.
                if session:
                    payload['sessionId'] = session
                cdp.send(json.dumps(payload))
                while True:
                    reply = json.loads(cdp.recv())
                    # Ignore notifications and replies belonging to other calls.
                    if reply.get('id') == serial:
                        assert 'error' not in reply, reply
                        return reply.get('result', {})

            # evaluate(expression) supports both SPA and legacy frame themes.
            def evaluate(expression):
                result = call('Runtime.evaluate', {'expression': '(window.frames.right || window).eval('+json.dumps(expression)+')', 'returnByValue': True})
                assert 'exceptionDetails' not in result, result.get('exceptionDetails')
                return result.get('result', {}).get('value')

            # Enable navigation and form commands for a new tab.
            target = call('Target.createTarget', {'url': 'about:blank'})['targetId']
            session = call('Target.attachToTarget', {'targetId':target,'flatten':True})['sessionId']
            call('Network.enable')
            call('Runtime.enable')
            call('Page.enable')
            # Open the requested form using only this fixture user's session.
            for cookie in jar:
                call('Network.setCookie', dict(name=cookie.name,value=cookie.value,url=BASE,path=cookie.path,secure=True))
            call('Page.navigate', {'url': BASE+path, 'referrer': BASE+'/'})
            deadline = time.monotonic()+40
            while time.monotonic()<deadline:
                # Wait for the actual initializer, not just HTML arrival.
                if evaluate('!!document.querySelector("select[name=software]")?.form?.dataset.softwareReady'):
                    break
                time.sleep(.2)
            else:
                # Report form state without exposing cookies or password fields.
                raise AssertionError('Software form did not initialize: '+str(evaluate('JSON.stringify({path:location.pathname, forms:[...document.forms].map(f=>new URL(f.action).pathname), hasSoftware:!!document.querySelector("select[name=software]"), initializer:typeof window.cloudminSoftwareInit, error:document.forms.length ? null : document.body?.innerText.slice(0,700), scripts:[...document.scripts].map(s=>s.src).filter(Boolean)})')))
            # Changing software must keep GPL scripts disabled and unsubmitted.
            state = evaluate('''(() => {
                const f = document.querySelector('select[name=software]').form;
                f.elements.software.value = 'virtualmin-pro';
                f.dispatchEvent(new Event('change', {bubbles:true}));
                const fields = [...f.querySelectorAll('[data-vm-script] input')];
                return {count:fields.length, blocked:fields.every(e=>e.matches(':disabled')),
                    packageEnabled:!f.elements.packages_mode[0].matches(':disabled'),
                    virtualminEnabled:!f.elements.software.matches(':disabled'),
                    submitted:[...new FormData(f).keys()].filter(k=>/^(before|after)_script/.test(k)),
                    styled:!!f.querySelector('[data-pro-disabled="setup-scripts-elem"]')};
            })()''')
            assert state['packageEnabled'] and state['virtualminEnabled'], state
            # Hiding advertisements removes empty preview fields entirely.
            if hidden:
                assert state['count'] == 0, state
            # Installed Pro exposes working, submitted script controls.
            elif pro:
                assert state['count'] and not state['blocked'] and state['submitted'], state
            # GPL retains styled previews that native FormData cannot submit.
            else:
                assert state['count'] and state['blocked'] and not state['submitted'] and state['styled'], state
        finally:
            # Release the debugger and browser before removing their profile.
            if cdp:
                # Let Chromium finish profile writes before deleting its files.
                try:
                    call('Browser.close')
                except (websocket.WebSocketException, OSError):
                    pass
                cdp.close()
            else:
                # Startup may fail before a debugging connection is available.
                chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Do not leave a hung fixture browser behind.
                chrome.kill()
                chrome.wait()


# main() tests both themes before and after temporarily removing Pro helpers.
# Configuration, templates, helpers and fixture users are restored on exit.
def main():
    # Save exact file contents and generate credentials only on the test guest.
    originals = {p: p.read_bytes() if p.exists() else None for p in (CONFIG, TEMPLATES)}
    user = 'cloudmin-ui-check-'+secrets.token_hex(4)
    password = secrets.token_urlsafe(36)
    created = False
    with tempfile.TemporaryDirectory(prefix='cloudmin-edition-package-') as work:
        disabled = []
        try:
            for theme in ('authentic-theme', 'gray-theme'):
                # This fixture user's login is restricted to loopback addresses.
                subprocess.run(['perl',str(HELPER),'create',theme,user],input=password+'\n',text=True,check=True,capture_output=True)
                created = True
                jar = http.cookiejar.CookieJar()
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                    urllib.request.HTTPCookieProcessor(jar), urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))

                # request(path, [fields], [json_body]) never prints session credentials.
                def request(path, fields=None, json_body=False):
                    data = None if fields is None else (json.dumps(fields) if json_body else urllib.parse.urlencode(fields)).encode()
                    headers = {'Referer':BASE+'/server-manager/machine_form.cgi'}
                    # Form posts and JSON API calls use different content types.
                    if json_body:
                        headers['Content-Type']='application/json'
                    with opener.open(urllib.request.Request(BASE+path,data=data,headers=headers),timeout=60) as response:
                        page=response.read().decode()
                    assert 'Error - Perl execution failed' not in page, 'CGI execution failed'
                    return page

                # Log in and obtain valid source, pool and network choices.
                request('/session_login.cgi')
                request('/session_login.cgi',dict(user=user,**{'pass':password},page='/server-manager/index.cgi'))
                path='/server-manager/edit_tmpl.cgi?id='+('0'*31+'2')+'&editmode=software'
                options=json.loads(request('/server-manager/api.cgi?action=options'))['result']
                image=next(i for i in options['images']+options.get('catalogue_images',[]) if i.get('format')!='iso')
                size=max(20,math.ceil(int(image.get('virtual_size') or image.get('min_disk_bytes') or 0)/1024**3))
                # Review a script request without allocating a virtual machine.
                fields=dict(token=options['token'],name='cloudmin-edition-check',image=image['id'],
                    pool=options['pools'][0]['id'],network=options['networks'][0]['key'],cpus=1,memory_mib=1024,
                    disk_gib=size,username='cloudmin',auth_type='password',password=secrets.token_urlsafe(32),
                    hostname='edition.example.test',start=1,software='none',before_script='true')
                result=json.loads(request('/server-manager/api.cgi',dict(fields,action='review'),True))
                assert result.get('result',{}).get('before_script')=='true', result.get('error')
                browser_check(jar,path,True)
                # Save a real Pro template, then remove only its implementation files.
                form=Form(request(path)).fields
                form.update(before_script_mode='inline',before_script='echo preserved',after_script_mode='inline',after_script='true')
                request('/server-manager/save_tmpl.cgi',form)
                for name in ('SetupScripts.pm','guest-scripts.pl','VMImages.pm','BackupCloud.pm'):
                    source=MODULE/'pro'/name
                    destination=Path(work)/name
                    # /tmp may use a different filesystem from the module.
                    shutil.move(source, destination)
                    disabled.append((source,destination))
                # The saved script stays visible, but direct GPL requests fail.
                page=request(path)
                assert 'echo preserved' in page and 'clear_setup_scripts' in page
                browser_check(jar,path,False)
                for action in ('review','create'):
                    result=json.loads(request('/server-manager/api.cgi',dict(fields,action=action),True))
                    assert 'require Cloudmin Pro' in result.get('error',''), result.get('error')
                # Inheriting a script cannot bypass the API or CLI edition gate.
                inherited=dict(fields,template='0'*31+'2')
                inherited.pop('before_script')
                result=json.loads(request('/server-manager/api.cgi',dict(inherited,action='review'),True))
                assert 'require Cloudmin Pro' in result.get('error',''), result.get('error')
                cli_fields={k:v for k,v in fields.items() if k!='token'}
                cli=subprocess.run(['perl',str(MODULE/'api.pl'),'review'],input=json.dumps(cli_fields),text=True,capture_output=True)
                assert cli.returncode and 'require Cloudmin Pro' in cli.stderr, cli.stderr
                # Unrelated form saves preserve omitted disabled script values.
                form=Form(page).fields
                form.update(packages_mode='list',packages='jq')
                request('/server-manager/save_tmpl.cgi',form)
                assert 'echo preserved' in request(path)
                # GPL can explicitly discard scripts instead of executing them.
                form=Form(request(path)).fields
                form['clear_setup_scripts']='1'
                request('/server-manager/save_tmpl.cgi',form)
                assert 'echo preserved' not in request(path)
                # GPL still accepts packages and both Virtualmin template editions.
                for software in ('none','virtualmin-gpl','virtualmin-pro'):
                    ordinary=dict(inherited,software=software,packages='jq',virtualmin_type='mini',webmin_register='0')
                    result=json.loads(request('/server-manager/api.cgi',dict(ordinary,action='review'),True))
                    assert 'result' in result, result.get('error')
                # The preference hides empty previews in either theme.
                CONFIG.write_text(re.sub(r'^hide_pro_tips=.*\n?', '', CONFIG.read_text(),flags=re.M)+'\nhide_pro_tips=1\n')
                assert 'data-pro-disabled="setup-scripts' not in request(path)
                browser_check(jar,path,False,True)
                # Restore this theme's state before testing the next theme.
                CONFIG.write_bytes(originals[CONFIG])
                for source,destination in reversed(disabled):
                    shutil.move(destination, source)
                disabled.clear()
                subprocess.run(['perl',str(HELPER),'delete',theme,user],check=True,capture_output=True)
                created=False
                print('PASS:',theme,'Pro/GPL forms, scripts, inherited settings, API/CLI gates and advertising toggle',flush=True)
        finally:
            # Restore moved helpers even if a request or assertion failed.
            for source,destination in reversed(disabled):
                shutil.move(destination, source)
            # Restore both pre-existing files and their original absence.
            for path,content in originals.items():
                # Remove only a file created by this fixture.
                if content is None:
                    path.unlink(missing_ok=True)
                # Preserve the exact original configuration and template bytes.
                else:
                    path.write_bytes(content)
            # A failed theme pass may still have its temporary Webmin user.
            if created:
                subprocess.run(['perl',str(HELPER),'delete','authentic-theme',user],check=True,capture_output=True)


# Importing the helpers must not run the system-changing fixture.
if __name__=='__main__':
    main()
