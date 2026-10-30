#!/usr/bin/python3
"""Check named creation defaults and password handling on a Cloudmin test host."""

from html.parser import HTMLParser
import http.cookiejar
import json
import os
from pathlib import Path
import platform
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

# Webmin account and configuration changes belong on the disposable VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')


class Form(HTMLParser):
    """Read successful form controls without including unchecked radio buttons."""

    # __init__(self, page, action)
    def __init__(self, page, action):
        """Parse the form with the given action, including select and textarea values."""
        super().__init__()
        self.action = action
        self.active = False
        self.select = None
        self.textarea = None
        self.fields = {}
        self.feed(page)

    # handle_starttag(self, tag, attrs)
    def handle_starttag(self, tag, attrs):
        """Collect submitted values while preserving the selected option."""
        attrs = dict(attrs)
        # Select the intended form by its submission endpoint.
        if tag == 'form':
            self.active = attrs.get('action') == self.action
        # Ignore navigation and other unrelated forms.
        if not self.active:
            return
        name = attrs.get('name')
        # Collect enabled input fields with names.
        if tag == 'input' and name and 'disabled' not in attrs:
            kind = attrs.get('type')
            # Match browser submission rules for buttons and checkable controls.
            if kind not in ('submit', 'button') and (
                    kind not in ('checkbox', 'radio') or 'checked' in attrs):
                self.fields[name] = attrs.get('value', '')
        # Remember which select owns subsequent options.
        elif tag == 'select':
            self.select = name
        # Use an option only while inside a named select.
        elif tag == 'option' and self.select:
            # An explicit selection overrides the browser default first option.
            if self.select not in self.fields or 'selected' in attrs:
                self.fields[self.select] = attrs.get('value', '')
        # Start collecting editable multiline values.
        elif tag == 'textarea' and name:
            self.textarea = name
            self.fields[name] = ''

    # handle_data(self, data)
    def handle_data(self, data):
        """Keep editable textareas, including descriptions and public keys."""
        # Append text only within a textarea in the selected form.
        if self.active and self.textarea:
            self.fields[self.textarea] += data

    # handle_endtag(self, tag)
    def handle_endtag(self, tag):
        """End each control and form at its closing tag."""
        # Stop collecting values after the selected form closes.
        if tag == 'form':
            self.active = False
        # Do not attach later options to the preceding select.
        elif tag == 'select':
            self.select = None
        # Do not append surrounding page text to a textarea.
        elif tag == 'textarea':
            self.textarea = None


helper = Path(__file__).with_name('webmin-user.pl')
config = Path('/etc/webmin/server-manager/config')
original = config.read_bytes()
# Template edits need their own backup now that login defaults live there.
presets = Path('/etc/webmin/server-manager/templates.json')
original_presets = presets.read_bytes() if presets.exists() else None
login_password = secrets.token_urlsafe(36)
subprocess.run(['perl', str(helper), 'create'], input=login_password + '\n',
               text=True, check=True)
try:
    time.sleep(1)
    base = 'https://127.0.0.1:10000'
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))

    # request(path, [fields])
    def request(path, fields=None):
        """Use normal login cookies and the same-origin referer for form requests."""
        payload = urllib.parse.urlencode(fields).encode() if fields is not None else None
        req = urllib.request.Request(base + path, data=payload,
                                     headers={'Referer': base + '/config.cgi?module=server-manager'})
        try:
            response = opener.open(req, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            page = response.read().decode('utf-8')
        assert 'Error - Perl execution failed' not in page, 'CGI execution failed'
        return page

    # settings(**values)
    def settings(**values):
        """Save this configuration category through Webmin's actual parser."""
        fields = Form(request('/config.cgi?module=server-manager&section=line2'),
                      'config_save.cgi').fields
        assert 'machine_generate_password' in fields and 'vm_username' not in fields, 'Creation preferences are missing or duplicated'
        fields.update(values, save='Save')
        return request('/config_save.cgi', fields)

    # template_settings([**values]) saves access fields through the real form.
    def template_settings(**values):
        fields = Form(request('/server-manager/edit_tmpl.cgi?id=' + '0'*31 + '1&editmode=access'), 'save_tmpl.cgi').fields
        fields.update(values)
        return request('/server-manager/save_tmpl.cgi', fields)

    # vm_form([fields])
    def vm_form(fields=None):
        """Open a fresh VM form through GET or theme navigation POST."""
        # Credential checks require cloud-init, regardless of image list order.
        values = dict(fields or {}, image=cloud_image['id'], install_source='cloud',
                      template='0'*31+'1', plan='0'*31+'1')
        if fields is None:
            # Keep GET coverage while selecting a compatible cloud image.
            page = request('/server-manager/machine_form.cgi?' + urllib.parse.urlencode(values))
        else:
            # Theme navigation submits the same selection through POST.
            page = request('/server-manager/machine_form.cgi', values)
        return Form(page, 'setup_machine.cgi').fields

    # vm_error(page, message)
    def vm_error(page, message):
        """Require Webmin's error page and return link, without the creation form."""
        assert 'Cannot create virtual machine' in page and message in page, 'Validation error is missing'
        assert 'Return to previous page' in page, 'Standard error return link is missing'
        assert not Form(page, 'setup_machine.cgi').fields, 'Validation redisplayed the creation form'

    # validate(fields)
    def validate(fields):
        """Use optional API validation to test defaults without creating a guest."""
        # Keep host capacity checks from masking the credential validation.
        page = request('/server-manager/api.cgi', dict(fields, action='review', cpus='1',
                       memory_mib='512', memory_mib_units=str(1024**2)))
        result = json.loads(page)
        assert 'result' in result, result.get('error', 'API validation failed')
        assert 'password_hash' not in result['result'], 'API exposed a password hash'
        return result['result']

    request('/session_login.cgi')
    request('/session_login.cgi', {'user': 'cloudmin-ui-check', 'pass': login_password,
                                  'page': '/server-manager/index.cgi'})
    jobs_before = json.loads(request('/server-manager/api.cgi?action=list'))['result']
    # Installer ISOs bypass cloud-init and cannot exercise login defaults.
    images = json.loads(request('/server-manager/api.cgi?action=options'))['result']['images']
    cloud_image = next((image for image in images if image.get('format') != 'iso'), None)
    # Require an imported cloud image before testing saved creation defaults.
    if cloud_image is None:
        raise SystemExit('Import a cloud image before running this check')

    # Creation defaults must survive saving and reloading the native editor.
    settings(machine_show_description='1', machine_generate_password='1', machine_host_ssh_key='0')
    template_settings(username='root', auth_type='both')
    saved = Form(request('/config.cgi?module=server-manager&section=line2'), 'config_save.cgi').fields
    assert all(saved.get(key) == value for key, value in {
        'machine_show_description': '1', 'machine_generate_password': '1', 'machine_host_ssh_key': '0'}.items()), 'Preferences did not persist'
    first = vm_form()
    assert first['vm_operation'] == 'create', 'Form still requires a review step'
    generated = first['password']
    assert len(generated) == 24 and 'password_again' not in first, 'Expected one generated password field'
    assert first['username'] == 'root' and first['auth_type'] == 'both', 'Configured access defaults are missing'
    assert 'description' in first, 'Description was not enabled'
    assert 'machine_host_ssh_key' not in first and 'host_ssh_key' not in first, 'Host-key policy leaked into VM form'
    settings(machine_host_ssh_key='1')
    saved = Form(request('/config.cgi?module=server-manager&section=line2'), 'config_save.cgi').fields
    assert saved['machine_host_ssh_key'] == '1'
    # Terminal preferences are in Remote connections; preserve the other values.
    for method in ('password', 'key'):
        terminal_settings = Form(request('/config.cgi?module=server-manager&section=line3'), 'config_save.cgi').fields
        assert 'terminal_auth' in terminal_settings
        request('/config_save.cgi', dict(terminal_settings, terminal_auth=method, save='Save'))
        saved_terminal = Form(request('/config.cgi?module=server-manager&section=line3'), 'config_save.cgi').fields
        assert saved_terminal['terminal_auth'] == method, 'Terminal default did not persist'
    print('PASS: host-key and terminal defaults save through Module Configuration without VM form controls')
    second = vm_form({'navigation': '1'})
    assert len(second['password']) == 24 and second['password'] != generated, 'New forms reused a password'
    print('PASS: native configuration saves all defaults; GET and theme POST receive fresh passwords')

    # An invalid default must not replace usable configuration.
    before_invalid = presets.read_bytes()
    invalid = template_settings(username='nobody')
    assert 'Choose a guest login account' in invalid, 'Reserved account was accepted'
    assert presets.read_bytes() == before_invalid, 'Invalid username changed template'

    # Optional API validation accepts the configured values without a UI review step.
    first.update(name='defaults-check-' + secrets.token_hex(4), auth_type='password',
                 username='fixtureuser', description='Keep this description')
    validated = validate(first)
    assert validated['password_set'] and validated['username'] == 'fixtureuser', 'Configured values did not validate'
    assert generated not in json.dumps(validated), 'API exposed a generated password'
    settings(machine_show_description='0')
    template_settings(auth_type='keys', username='cloudmin')
    changed = vm_form()
    assert 'description' not in changed and changed['auth_type'] == 'keys', 'Changed defaults were not applied'
    assert changed['username'] == 'cloudmin', 'Changed username was not applied'

    # Validation uses the standard error page and keeps generated secrets private.
    second.update(name='invalid/name', auth_type='password', cpus='1', memory_mib='512', memory_mib_units=str(1024**2))
    invalid_page = request('/server-manager/setup_machine.cgi', second)
    vm_error(invalid_page, 'Enter a virtual machine name')
    assert second['password'] not in invalid_page, 'Validation echoed a generated password'
    corrected = dict(second, name='corrected-' + secrets.token_hex(4), password='')
    assert validate(corrected)['password_set'], 'Validation lost the retained password'

    # Disabling generation leaves the password field empty for manual entry.
    settings(machine_generate_password='0')
    template_settings(auth_type='password')
    manual = vm_form()
    assert 'description' not in manual and manual['auth_type'] == 'password', 'Hidden description or authentication default is wrong'
    assert manual['password'] == '' and 'password_again' not in manual, 'Expected one empty password field'
    # Direct creation rejects missing credentials before starting work.
    manual.update(name='manual-check-' + secrets.token_hex(4), cpus='1', memory_mib='512', memory_mib_units=str(1024**2))
    vm_error(request('/server-manager/setup_machine.cgi', manual), 'Enter an initial password')
    vm_error(request('/server-manager/setup_machine.cgi', dict(manual, token='invalid')),
             'This form has expired')
    manual_password = secrets.token_urlsafe(24)
    manual.update(password=manual_password)
    manual_result = validate(manual)
    assert manual_result['password_set'] and manual_password not in json.dumps(manual_result), 'Manual password validation failed'
    assert json.loads(request('/server-manager/api.cgi?action=list'))['result'] == jobs_before, 'Validation created a VM job'
    print('PASS: validation preserves credentials; disabled generation allows manual entry; no VM jobs created')
finally:
    # Restore configuration and remove fixture credentials even after a failed check.
    config.write_bytes(original)
    if original_presets is None:
        # Remove a template store only when this test created it.
        presets.unlink(missing_ok=True)
    else:
        # Restore existing template settings byte for byte.
        presets.write_bytes(original_presets)
    try:
        subprocess.run(['perl', str(helper.with_name('machine_fixture.pl')), 'forget-passwords'], check=True)
    finally:
        subprocess.run(['perl', str(helper), 'delete'], check=True)
