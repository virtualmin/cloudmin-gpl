#!/usr/bin/python3
"""Test configuration categories, display defaults and saved inventory tabs."""

from html.parser import HTMLParser
import http.cookiejar
import json
import os
from pathlib import Path
import platform
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

from theme_support import is_spa_theme

# Run account and configuration changes only on an authorized Linux test host.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')


class Form(HTMLParser):
    """
    Read submitted form values, selector choices, table settings and tab IDs.
    """

    # __init__(self, page, action) limits submitted values to one form.
    def __init__(self, page, action):
        super().__init__()
        self.action, self.active, self.select = action, False, None
        self.fields, self.inputs, self.status = {}, {}, None
        self.options, self.tabs, self.selected_tabs = {}, None, {}
        self.feed(page)

    # handle_starttag(self, tag, attrs) follows browser form submission rules.
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        # Capture live table metadata even when it is outside the saved form.
        if attrs.get('id') == 'cloudmin-vm-status':
            self.status = json.loads(attrs.get('data-config', '{}'))
        # Native tab metadata sits outside mutation forms.
        if 'data-inventory-tabs' in attrs:
            self.tabs = json.loads(attrs['data-inventory-tabs'])
        # The widget's hidden input records the server-selected initial tab.
        if tag == 'input' and attrs.get('name') in (
            'mode',
            'cloudmin_network_tabs',
            'cloudmin_storage_tabs',
        ):
            self.selected_tabs[attrs['name']] = attrs.get('value')
        # Only the named form contributes submitted controls.
        if tag == 'form':
            self.active = attrs.get('action') == self.action
        # Ignore navigation and controls from unrelated forms.
        if not self.active:
            return
        name = attrs.get('name')
        # Retain all input attributes so tests can check disabled
        # identity fields.
        if tag == 'input' and name:
            self.inputs[name] = attrs
            # Disabled inputs and buttons are not ordinary submitted values.
            if 'disabled' not in attrs and attrs.get('type') not in (
                'submit',
                'button',
            ):
                # Unchecked radio buttons and checkboxes are omitted
                # by browsers.
                if (
                    attrs.get('type') not in ('checkbox', 'radio')
                    or 'checked' in attrs
                ):
                    self.fields[name] = attrs.get('value', '')
        # Remember which setting owns the following options.
        elif tag == 'select':
            self.select = name
            self.options[name] = []
        # Collect options only while a named selector is open.
        elif tag == 'option' and self.select:
            # Retain available pool IDs as well as the selected value for tests.
            self.options[self.select].append(attrs.get('value', ''))
            # The first option is the fallback; an explicit selection
            # replaces it.
            if self.select not in self.fields or 'selected' in attrs:
                self.fields[self.select] = attrs.get('value', '')

    # handle_endtag(self, tag) keeps later controls out of the previous group.
    def handle_endtag(self, tag):
        # Stop including controls once the target form closes.
        if tag == 'form':
            self.active = False
        # Later options must not overwrite the preceding selector's value.
        elif tag == 'select':
            self.select = None


# Keep original settings and generate fixture credentials only on the test host.
helper = Path(__file__).with_name('webmin-user.pl')
config = Path('/etc/webmin/server-manager/config')
original = config.read_bytes()
theme = sys.argv[1] if len(sys.argv) > 1 else 'authentic-theme'
password = secrets.token_urlsafe(36)
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
other_user = 'cloudmin-ui-check-' + secrets.token_hex(4)
other_created = False
preferences = Path('/var/webmin/modules/server-manager')
# Keep the unit and its running and boot states for cleanup.
service_name = 'cloudmin-statistics.service'
was_active = (
    subprocess.run(
        ['systemctl', 'is-active', '--quiet', service_name]
    ).returncode
    == 0
)
was_enabled = (
    subprocess.run(
        ['systemctl', 'is-enabled', service_name],
        capture_output=True,
        text=True,
    ).stdout.strip()
    == 'enabled'
)
unit = Path('/etc/systemd/system') / service_name
assert unit.is_file() and not unit.is_symlink(), (
    'Start with an installed, unmasked collector'
)
original_unit = unit.read_bytes()
# Use a temporary account to test the real configuration editor.
subprocess.run(
    ['perl', str(helper), 'create', theme, user],
    input=password + '\n',
    text=True,
    check=True,
)
# Keep a private recovery copy if the test process is interrupted
# before cleanup.
with tempfile.NamedTemporaryFile(
    prefix='cloudmin-config-backup-', dir='/var/tmp', delete=False
) as backup:
    backup.write(original)
backup_path = Path(backup.name)
print('Configuration recovery copy: ' + str(backup_path), flush=True)
try:
    # Grant host access for configuration checks, then test revocation below.
    subprocess.run(
        ['perl', str(helper), 'acl', theme, user],
        input=json.dumps({'admin': 1}) + '\n',
        text=True,
        check=True,
    )
    time.sleep(1)
    # Use a private cookie jar for direct requests to the test host's Webmin.
    base = 'https://127.0.0.1:10000'
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )

    # request(path, [fields]) uses only this host-generated fixture session.
    # Omit fields for GET; supplying a field dictionary sends a form POST.
    def request(path, fields=None):
        body = (
            None if fields is None else urllib.parse.urlencode(fields).encode()
        )
        req = urllib.request.Request(
            base + path,
            data=body,
            headers={'Referer': base + '/config.cgi?module=server-manager'},
        )
        with opener.open(req, timeout=60) as response:
            page = response.read().decode('utf-8', errors='replace')
        assert 'Error - Perl execution failed' not in page, (
            'CGI execution failed'
        )
        return page

    # editor(section) reads exactly the section Webmin will save.
    def editor(section):
        return Form(
            request('/config.cgi?module=server-manager&section=' + section),
            'config_save.cgi',
        )

    # saved() verifies persisted values independently of the rendered widgets.
    def saved():
        return dict(
            line.split('=', 1)
            for line in config.read_text().splitlines()
            if '=' in line
        )

    # Log in through Webmin and inspect the real configuration form.
    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {'user': user, 'pass': password, 'page': '/server-manager/index.cgi'},
    )
    # Each category edits its own settings without clearing the others.
    categories = {
        'line0': ('libvirt_uri', 'host_details'),
        'line1': ('machine_columns', 'machine_detail_sections'),
        'line2': (
            'machine_show_description',
            'machine_show_template_description',
            'machine_generate_password',
            'machine_host_ssh_key',
            'machine_create_sections',
        ),
        'line3': (
            'remote_access_remember',
            'terminal_auth',
            'terminal_auto',
            'webmin_confirm',
        ),
        'line4': (
            'backup_columns',
            'backup_schedule_columns',
            'backup_sections',
        ),
        'line5': ('snapshot_columns', 'snapshot_notes'),
        'line6': (
            'images_remember',
            'image_pool',
            'catalogue_host_arch',
            'image_max_size',
            'image_advanced',
            'image_columns',
            'catalogue_columns',
        ),
        'line7': (
            'networks_remember',
            'bridge_confirm_timeout',
            'network_columns',
        ),
        'line8': (
            'storage_remember',
            'storage_pool_columns',
            'storage_volume_columns',
        ),
        'line9': (
            'statistics_enabled',
            'statistics_recording',
            'statistics_interval',
            'statistics_guest_interval',
            'statistics_raw_hours',
            'statistics_minute_days',
            'statistics_five_days',
            'statistics_hour_days',
            'statistics_budget',
            'statistics_uplinks',
        ),
    }
    changes = {
        'line0': {'host_details': 'problems'},
        'line1': {
            'machine_columns': 'name,state,autostart,controls',
            'machine_detail_sections': 'disks',
        },
        'line2': {'machine_create_sections': 'network'},
        'line3': {
            'remote_access_remember': '0',
            'terminal_auth': 'password',
            'terminal_auto': '0',
            'webmin_confirm': '1',
        },
        'line4': {
            'backup_columns': 'name,size',
            'backup_schedule_columns': 'name,state',
            'backup_sections': 'opts,sched',
        },
        'line5': {
            'snapshot_columns': 'name,guest,size,position',
            'snapshot_notes': '0',
        },
        'line6': {
            'images_remember': '0',
            'image_pool': '',
            'catalogue_host_arch': '1',
            'image_columns': 'name,state,pool',
            'catalogue_columns': 'name,architecture,size',
            'image_advanced': '1',
        },
        'line7': {
            'networks_remember': '0',
            'network_columns': 'name,guests',
            'bridge_confirm_timeout': '420',
        },
        'line8': {
            'storage_remember': '0',
            'storage_pool_columns': 'name,space',
            'storage_volume_columns': 'name,used_by',
        },
        'line9': {'statistics_enabled': '0'},
    }
    all_keys = {key for keys in categories.values() for key in keys}
    for section, keys in categories.items():
        ui = editor(section)
        # Custom column editors submit checkbox names rather than the
        # setting key.
        for key in keys:
            prefix = (
                'cataloguecol_' if key == 'catalogue_columns' else key + '_'
            )
            assert key in ui.fields or any(
                name.startswith(prefix) for name in ui.inputs
            ), key + ' is missing'
        if is_spa_theme(theme):
            # Category navigation must not mix unrelated settings into the page.
            for key in all_keys - set(keys):
                prefix = (
                    'cataloguecol_' if key == 'catalogue_columns' else key + '_'
                )
                assert key not in ui.fields and not any(
                    name.startswith(prefix) for name in ui.inputs
                ), key + ' is in the wrong category'
        fields = dict(ui.fields, save='Save')
        for key, value in changes[section].items():
            if key.endswith(('_columns', '_sections')):
                # Replace the selected set while retaining disabled
                # required columns.
                prefix = (
                    'cataloguecol_' if key == 'catalogue_columns' else key + '_'
                )
                fields = {
                    k: v for k, v in fields.items() if not k.startswith(prefix)
                }
                fields.update(
                    {prefix + column: '1' for column in value.split(',')}
                )
            else:
                # Radio groups, selectors and numeric inputs submit one value.
                fields[key] = value
        # Saving one category must preserve every setting outside that category.
        before = saved()
        page = request('/config_save.cgi', fields)
        # The redirected overview must carry the theme's navigation refresh.
        if section == 'line9':
            marker = (
                'theme_post_save=-1'
                if is_spa_theme(theme)
                else 'top.left.location = top.left.location'
            )
            assert marker in page, 'Disabling did not refresh navigation'
        after = saved()
        for key, value in changes[section].items():
            assert after.get(key) == value, key + ' was not saved correctly'
        assert {k: v for k, v in before.items() if k not in keys} == {
            k: v for k, v in after.items() if k not in keys
        }, section + ' changed another category'
        # Check persisted choices through the widgets, not just the saved file.
        reopened = editor(section)
        for key, value in changes[section].items():
            if key.endswith(('_columns', '_sections')):
                # Checkbox groups must reopen with exactly the selected set.
                prefix = (
                    'cataloguecol_' if key == 'catalogue_columns' else key + '_'
                )
                selected = {
                    name[len(prefix) :]
                    for name, attrs in reopened.inputs.items()
                    if name.startswith(prefix) and 'checked' in attrs
                }
                assert selected == set(value.split(',')), (
                    key + ' did not reopen correctly'
                )
            else:
                # Single-value controls must retain the submitted value.
                assert reopened.fields[key] == value, (
                    key + ' did not reopen correctly'
                )
    print(
        'PASS: all configuration categories save and reopen without changing other categories ('
        + theme
        + ')',
        flush=True,
    )

    # Saving the collection switch stops the process and disables boot startup.
    assert (
        subprocess.run(
            ['systemctl', 'is-active', '--quiet', service_name]
        ).returncode
        != 0
    )
    assert (
        subprocess.run(
            ['systemctl', 'is-enabled', '--quiet', service_name]
        ).returncode
        != 0
    )
    # Disabling collection must keep history and hide old live readings.
    result = json.loads(request('/server-manager/api.cgi?action=statistics'))[
        'result'
    ]
    assert (
        not result['collector']['enabled']
        and not result['collector']['available']
    )
    assert result['history_available'] and not result.get('live'), (
        'Disabling lost history or kept live readings'
    )
    # Disabled collection must remove statistics from navigation.
    menu_path = (
        '/xhr.cgi?type=nav&action=get&subtype=cloudmin'
        if is_spa_theme(theme)
        else '/left.cgi?mode=server-manager'
    )
    menu = request(menu_path)
    assert 'statistics.cgi' not in menu, (
        'Disabled statistics links are still in the menu'
    )
    # Updating the installed unit must not turn collection back on.
    module = Path(__file__).resolve().parents[2]
    subprocess.run(
        [
            'perl',
            '-I',
            str(module.parent),
            '-e',
            'require "./server-manager-lib.pl"; require "./cloudmin-statistics-lib.pl"; '
                    'install_statistics_service();',
        ],
        cwd=module,
        check=True,
        timeout=60,
        env={
            **os.environ,
            'WEBMIN_CONFIG': '/etc/webmin',
            'WEBMIN_VAR': '/var/webmin',
            'FOREIGN_MODULE_NAME': 'server-manager',
            'FOREIGN_ROOT_DIRECTORY': str(module.parent),
        },
    )
    assert (
        subprocess.run(
            ['systemctl', 'is-active', '--quiet', service_name]
        ).returncode
        != 0
    )
    assert (
        subprocess.run(
            ['systemctl', 'is-enabled', '--quiet', service_name]
        ).returncode
        != 0
    )
    # Re-enabling must repair a deleted unit through the real
    # configuration form.
    unit.unlink()
    subprocess.run(['systemctl', 'daemon-reload'], check=True, timeout=20)
    stats = editor('line9')
    page = request(
        '/config_save.cgi',
        dict(stats.fields, statistics_enabled='1', save='Save'),
    )
    assert unit.is_file() and unit.stat().st_mode & 0o777 == 0o644, (
        'Missing unit was not restored'
    )
    assert marker in page, 'Enabling did not refresh navigation'
    assert (
        subprocess.run(
            ['systemctl', 'is-active', '--quiet', service_name]
        ).returncode
        == 0
    )
    assert (
        subprocess.run(
            ['systemctl', 'is-enabled', '--quiet', service_name]
        ).returncode
        == 0
    )
    # Re-enabling must restore both guest and host navigation links.
    menu = request(menu_path)
    assert 'statistics.cgi?id=' in menu and 'Host Statistics' in menu, (
        'Statistics menu links did not return'
    )
    # The process can start before its first sample is available.
    deadline = time.monotonic() + 40
    while True:
        result = json.loads(
            request('/server-manager/api.cgi?action=statistics')
        )['result']
        # A fresh sample confirms that collection resumed.
        if result['collector']['available']:
            break
        assert time.monotonic() < deadline, 'Collection did not resume'
        time.sleep(1)
    print(
        'PASS: collection switch, retained history, upgrade and statistics menus ('
        + theme
        + ')',
        flush=True,
    )

    # Required columns stay fixed, including when other columns are hidden.
    ui = editor('line1')
    assert 'disabled' in ui.inputs['machine_columns_name'], (
        'Virtual machine identity is optional'
    )
    assert 'disabled' in ui.inputs['machine_columns_state'], (
        'Virtual machine state is optional'
    )
    overview = Form(request('/server-manager/index.cgi'), 'unused')
    assert overview.status['columns'] == [
        'name',
        'state',
        'autostart',
        'controls',
    ]
    assert all(len(row) == 4 for row in overview.status['rows'].values())
    # Consumers of settings from the other categories must still render.
    for page in (
        'images.cgi',
        'networks.cgi',
        'storage.cgi',
        'machine_form.cgi',
        'backups.cgi',
        'backup_form.cgi?new=1',
        'snapshots.cgi',
    ):
        html = request('/server-manager/' + page)
        assert (
            'Undefined subroutine' not in html and 'Cannot use' not in html
        ), page + ' failed'
    print('PASS: required columns and reduced live table templates', flush=True)

    # Two-choice settings use radios, and import defaults reach the real form.
    for section, key in (
        ('line5', 'snapshot_notes'),
        ('line6', 'images_remember'),
        ('line6', 'catalogue_host_arch'),
        ('line7', 'networks_remember'),
        ('line8', 'storage_remember'),
    ):
        assert editor(section).inputs[key]['type'] == 'radio', (
            key + ' is not a radio'
        )
    imports = Form(request('/server-manager/image_form.cgi'), 'setup_image.cgi')
    assert imports.options.get('pool'), (
        'No active import pool available for the live test'
    )
    pool = imports.options['pool'][-1]
    image_settings = editor('line6')
    request(
        '/config_save.cgi',
        dict(image_settings.fields, image_pool=pool, save='Save'),
    )
    assert saved()['image_pool'] == pool
    imports = Form(request('/server-manager/image_form.cgi'), imports.action)
    assert imports.fields['pool'] == pool, (
        'Import form did not select the preferred pool'
    )
    print('PASS: radio controls and preferred import pool', flush=True)

    # Remember native tab clicks through the same signed POST used by
    # the client.
    pages = (
        (
            'images',
            'line6',
            'images.cgi',
            'mode',
            'catalogue',
            'images',
            'mode=add',
            'add',
        ),
        (
            'networks',
            'line7',
            'networks.cgi',
            'cloudmin_network_tabs',
            'net_bridges',
            'net_overview',
            'tab=interfaces',
            'net_interfaces',
        ),
        (
            'storage',
            'line8',
            'storage.cgi',
            'cloudmin_storage_tabs',
            'storage_volumes',
            'storage_overview',
            'tab=pools',
            'storage_pools',
        ),
    )
    for (
        scope,
        section,
        page,
        field,
        chosen,
        default,
        explicit,
        expected,
    ) in pages:
        # Enable memory and obtain the real page's token before its first save.
        settings = editor(section)
        request(
            '/config_save.cgi',
            dict(settings.fields, **{scope + '_remember': '1'}, save='Save'),
        )
        ui = Form(request('/server-manager/' + page), 'unused')
        assert ui.selected_tabs[field] == default and ui.tabs, (
            scope + ' has no initial memory widget'
        )
        # Save through the endpoint; a fresh page must restore the tab.
        fields = {'page': scope, 'tab': chosen, 'token': ui.tabs['token']}
        reply = json.loads(
            request('/server-manager/save_inventory_tab.cgi', fields)
        )
        assert reply['saved'] == 1, scope + ' did not save'
        reopened = Form(request('/server-manager/' + page), 'unused')
        assert reopened.selected_tabs[field] == chosen, (
            scope + ' did not reopen the saved tab'
        )
        # Explicit links override memory; unsigned requests cannot update it.
        linked = Form(
            request('/server-manager/' + page + '?' + explicit), 'unused'
        )
        assert linked.selected_tabs[field] == expected, (
            scope + ' ignored an explicit link'
        )
        rejected = json.loads(
            request(
                '/server-manager/save_inventory_tab.cgi',
                dict(fields, token='invalid'),
            )
        )
        assert rejected['saved'] == 0, 'Unsigned tab preference was accepted'
        # Disabled memory uses the default and omits the browser save handler.
        settings = editor(section)
        request(
            '/config_save.cgi',
            dict(settings.fields, **{scope + '_remember': '0'}, save='Save'),
        )
        disabled = Form(request('/server-manager/' + page), 'unused')
        assert (
            disabled.selected_tabs[field] == default and disabled.tabs is None
        )
        # Re-enable memory so the read-only and other-user checks use
        # saved state.
        settings = editor(section)
        request(
            '/config_save.cgi',
            dict(settings.fields, **{scope + '_remember': '1'}, save='Save'),
        )
    # Webmin's urlize escapes hyphens in these generated usernames too.
    pref = preferences / ('inventory-tabs-' + user.replace('-', '%2D'))
    assert pref.stat().st_mode & 0o777 == 0o600
    print(
        'PASS: all three saved tabs, explicit links, signed requests and disabled memory',
        flush=True,
    )

    # Separate Webmin logins must not inherit each other's saved navigation.
    subprocess.run(
        ['perl', str(helper), 'create', theme, other_user],
        input=password + '\n',
        text=True,
        check=True,
    )
    other_created = True
    subprocess.run(
        ['perl', str(helper), 'acl', theme, other_user],
        input=json.dumps({'admin': 1}) + '\n',
        text=True,
        check=True,
    )
    # Give the second login its own cookies so requests cannot reuse the first.
    original_opener = opener
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )
    request('/session_login.cgi')
    request(
        '/session_login.cgi',
        {
            'user': other_user,
            'pass': password,
            'page': '/server-manager/index.cgi',
        },
    )
    # Another account sees each page's default, despite the first user's saves.
    for (
        scope,
        section,
        page,
        field,
        chosen,
        default,
        explicit,
        expected,
    ) in pages:
        ui = Form(request('/server-manager/' + page), 'unused')
        assert ui.selected_tabs[field] == default, (
            scope + ' leaked another user choice'
        )
    # Restore the first session and revoke writes without clearing its choices.
    opener = original_opener
    subprocess.run(
        ['perl', str(helper), 'readonly', theme, user],
        input='1\n',
        text=True,
        check=True,
    )
    before = pref.read_bytes()
    for (
        scope,
        section,
        page,
        field,
        chosen,
        default,
        explicit,
        expected,
    ) in pages:
        ui = Form(request('/server-manager/' + page), 'unused')
        assert ui.selected_tabs[field] == chosen and ui.tabs is None, (
            'Read-only preference handling failed'
        )
    request('/server-manager/save_inventory_tab.cgi', fields)
    assert pref.read_bytes() == before, 'Read-only request changed saved tabs'
    # Later configuration tests need the first account's normal write access.
    subprocess.run(
        ['perl', str(helper), 'readonly', theme, user],
        input='0\n',
        text=True,
        check=True,
    )
    print('PASS: per-user memory and read-only restrictions', flush=True)

    # Rejected network settings must leave the entire file unchanged.
    network = editor('line7')
    assert network.inputs['bridge_confirm_timeout']['type'] == 'number'
    before = config.read_bytes()
    invalid = dict(network.fields, bridge_confirm_timeout='0', save='Save')
    error = request('/config_save.cgi', invalid)
    assert 'whole number from 120 to 900' in error, (
        'Timeout validation was not displayed'
    )
    assert config.read_bytes() == before, (
        'Rejected timeout changed configuration'
    )
    print(
        'PASS: timeout validation without changing host networking', flush=True
    )

    # Presets own resource and login defaults; creation preferences stay here.
    creation_settings = editor('line2')
    assert not (
        {
            'vm_default_cpus',
            'vm_default_memory',
            'vm_default_disk',
            'vm_default_start',
            'vm_default_autostart',
            'vm_username',
            'vm_auth_type',
        }
        & creation_settings.fields.keys()
    )
    creation = Form(
        request('/server-manager/machine_form.cgi'), 'setup_machine.cgi'
    )
    assert creation.fields.get('template') and creation.fields.get('plan')
    print('PASS: named template and plan retain creation defaults', flush=True)

    # Configured controls cannot override the user's grants.
    subprocess.run(
        ['perl', str(helper), 'acl', theme, user],
        input=json.dumps({'admin': 0, 'vms': '', 'power': 0}) + '\n',
        text=True,
        check=True,
    )
    restricted = Form(request('/server-manager/index.cgi'), 'unused')
    assert 'controls' not in restricted.status['columns'], (
        'Configuration bypassed ACL'
    )
    print('PASS: display configuration cannot grant VM controls', flush=True)
finally:
    # Restore exact settings and remove accounts even after a failed assertion.
    config.write_bytes(original)
    assert config.read_bytes() == original, 'Configuration restoration failed'
    # Restore the unit even when the missing-file recovery check failed.
    unit.write_bytes(original_unit)
    unit.chmod(0o644)
    subprocess.run(['systemctl', 'daemon-reload'], check=True, timeout=20)
    # Restore both boot and running state, including after a failed switch test.
    subprocess.run(
        ['systemctl', 'enable' if was_enabled else 'disable', service_name],
        check=True,
    )
    subprocess.run(
        ['systemctl', 'start' if was_active else 'stop', service_name],
        check=True,
    )
    backup_path.unlink()
    subprocess.run(['perl', str(helper), 'delete', theme, user], check=True)
    # Earlier assertions may have failed before creating the second account.
    if other_created:
        subprocess.run(
            ['perl', str(helper), 'delete', theme, other_user], check=True
        )
    # Remove navigation files separately; account deletion does not own them.
    for name in (user, other_user):
        (preferences / ('inventory-tabs-' + name.replace('-', '%2D'))).unlink(
            missing_ok=True
        )
