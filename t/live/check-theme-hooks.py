#!/usr/bin/python3
"""Check theme hooks and LVM integration on a disposable Cloudmin VM."""
import http.cookiejar
import json
from theme_support import is_spa_theme
import os
from pathlib import Path
import platform
import re
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid as uuidlib
import libvirt

# Account and theme changes belong on the disposable Linux VM.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')
here = Path(__file__).resolve().parent
webmin = here.parent.parent.parent
helper = here / 'webmin-user.pl'
base = 'https://127.0.0.1:10000'
user = None
created = False
fixture = conn = None
# This fixture needs an installed frame-based theme.
if not (webmin / 'gray-theme' / 'left.cgi').is_file():
    raise SystemExit('Frame-based theme is not installed under ' + str(webmin))

# Webmin's LVM module resolves guest hosts through Cloudmin 9 functions; a
# device no guest uses walks every guest record without matching one.
LVM_CHECK = r'''
BEGIN {
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	chdir($ARGV[0]) or die "Cannot enter the LVM module: $!";
	unshift(@INC, "$ARGV[0]/..");
	$0 = "$ARGV[0]/cloudmin-lvm-check.pl";
}
use WebminCore;
init_config();
foreign_require('lvm', 'lvm-lib.pl');
foreign_require('server-manager');
my @guests = server_manager::list_managed_servers();
my @status = lvm::device_status('/dev/cloudmin-check-none');
die "device_status matched a device no guest uses\n" if (@status);
print scalar(@guests), "\n";
'''


# Exercise the actual installed hooks with both ID formats. No VM is changed.
HOOK_CHECK = r'''
BEGIN {
	$ENV{'WEBMIN_CONFIG'} = '/etc/webmin';
	$ENV{'WEBMIN_VAR'} = '/var/webmin';
	$ENV{'REMOTE_USER'} = 'root';
	$ENV{'THEME_DIRS'} = $ARGV[1];
	$ENV{'THEME_ROOT'} = "$ARGV[0]/$ARGV[1]";
	chdir("$ARGV[0]/server-manager") or die $!;
	unshift(@INC, $ARGV[0]);
	$0 = "$ARGV[0]/server-manager/theme-hook-check.pl";
}
use WebminCore;
init_config();
load_theme_library();
foreign_require('server-manager');
my @results;
for my $id ('12345', '0f9c2b7e-3a1d-4c5e-9b8a-7d6e5f4c3b2a') {
	for my $action ('select', 'create', 'delete') {
		my $out = '';
		{
		local *STDOUT;
		open(STDOUT, '>', \$out) or die $!;
		my $vm = { uuid => $id, name => 'fixture' };
		# Selection changes the active guest without changing inventory.
		if ($action eq 'select') {
			server_manager::select_theme_server($vm);
			}
		else {
			# Inventory changes require a navigation reload.
			server_manager::notify_theme_save($vm, $action);
			}
		}
		push(@results, { id => $id, action => $action, output => $out });
		}
	}
print convert_to_json(\@results);
'''


# check_hooks(theme) validates real selection and change output for each layout.
def check_hooks(theme):
    result = subprocess.run(['perl', '-e', HOOK_CHECK, str(webmin), theme],
                            capture_output=True, text=True, check=True)
    records = json.loads(result.stdout)
    assert len(records) == 6, 'Missing hook output'
    for record in records:
        output = record['output']
        # SPA navigation consumes the marker directly from the response text.
        if is_spa_theme(theme):
            key = 'theme_select_server' if record['action'] == 'select' else 'theme_post_save'
            assert output == '<!--\n%s=%s\n-->\n' % (key, record['id']), 'Wrong SPA hook marker'
        else:
            # Frame themes reload their navigation through a script block.
            assert '<script>' in output and '.location' in output, 'Frame hook did not refresh navigation'
            # Selection must retain either a numeric ID or a UUID in the URL.
            if record['action'] == 'select':
                assert 'sid=' + record['id'] in output, 'Frame hook lost the guest ID'
    print('PASS: ' + theme + ' selection/create/delete hooks with numeric IDs and UUIDs')


# session()
def session():
    """Create a browser session whose cookies stay in this VM process."""
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))


# request(path, [fields])
def request(path, fields=None):
    """Send a real request and return the HTTP status with the page text."""
    body = urllib.parse.urlencode(fields).encode() if fields is not None else None
    req = urllib.request.Request(base + path, data=body, headers={'Referer': base + '/'})
    try:
        response = opener.open(req, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.read().decode(errors='replace')


# page(path)
def page(path):
    """Fetch a page that must render without calling a missing Cloudmin function."""
    status, text = request(path)
    assert 'Undefined subroutine' not in text, path + ' calls a missing Cloudmin function'
    assert status == 200 and 'Perl execution failed' not in text, '%s failed with HTTP %s' % (path, status)
    return text


# login(theme)
def login(theme):
    """Create the fixture account with its theme; never print its password."""
    global opener, created, user
    # Keep this test separate from other live UI checks on the same host.
    user = ('cloudmin-spa-check' if is_spa_theme(theme) else 'cloudmin-frame-check') + '-' + secrets.token_hex(4)
    password = secrets.token_urlsafe(36)
    subprocess.run(['perl', str(helper), 'create', theme, user],
                   input=password + '\n', text=True, check=True)
    created = True
    time.sleep(1)
    opener = session()
    request('/session_login.cgi')
    status, text = request('/session_login.cgi', {'user': user, 'pass': password, 'page': '/'})
    # Theme language bundles may contain "Login failed" even after success.
    # Verify access to an authenticated endpoint instead of matching that text.
    status, text = request('/server-manager/api.cgi?action=list')
    assert status == 200 and 'result' in json.loads(text), 'Fixture login did not grant module access'


# logout()
def logout():
    """Remove the fixture account together with its per-user theme settings."""
    global created
    subprocess.run(['perl', str(helper), 'delete', '', user], check=True)
    created = False
    time.sleep(1)


# guest_ids(text)
def guest_ids(text):
    """Return the guest UUIDs linked from a rendered Cloudmin menu or page."""
    # Links carry the UUID through urlize, which also encodes its dashes.
    ids = [urllib.parse.unquote(uuid) for uuid in re.findall(r'machine\.cgi\?id=([0-9a-f%A-F-]+)', text)]
    return sorted(set(uuid for uuid in ids if re.fullmatch(r'[0-9a-f-]{36}', uuid)))


try:
    # A clean host has no guests. A stopped diskless fixture exercises inventory
    # and LVM integration without requiring nested guest execution.
    conn = libvirt.open('qemu:///system')
    # Supply an owned stopped domain only when no guest inventory exists.
    if not conn.listAllDomains():
        identity = str(uuidlib.uuid4())
        arch = conn.getInfo()[0]
        machine = 'virt' if arch == 'aarch64' else 'q35'
        fixture = conn.defineXML(
            f'<domain type="kvm"><name>cloudmin-frame-check-{identity}</name>'
            f'<uuid>{identity}</uuid><memory unit="MiB">64</memory><vcpu>1</vcpu>'
            f'<os><type arch="{arch}" machine="{machine}">hvm</type></os></domain>')
    lvm = subprocess.run(['perl', '-e', LVM_CHECK, str(webmin / 'lvm')], capture_output=True, text=True)
    assert lvm.returncode == 0, 'LVM device status failed: ' + lvm.stderr
    guests = int(lvm.stdout.split()[-1])
    assert guests, 'LVM check needs at least one libvirt guest to resolve a host for'
    print('LVM device status resolves guest hosts through get_parent_server (%d guests): PASS' % guests)

    # Frame navigation uses the admin check and available guest list.
    assert not is_spa_theme('gray-theme'), 'Frame fixture declares spa=1'
    check_hooks('gray-theme')
    login('gray-theme')
    left = page('/left.cgi?mode=server-manager')
    assert '/server-manager/machine_form.cgi' in left, 'Frame-based left frame lacks the Cloudmin menu'
    page('/right.cgi')
    edit = page('/edit_right.cgi')
    assert 'name="server"' in edit, 'Frame-based right-frame settings lack the default server list'
    ids = guest_ids(left)
    assert ids, 'Frame-based left frame lists no guests'
    for uuid in ids:
        assert re.search(r'value=[\'"]%s[\'"]' % uuid, edit), 'default server list misses ' + uuid
    print('Frame-based theme frames render with the Cloudmin master admin check (%d guests): PASS' % len(ids))

    # Guest pages select the guest through the theme hook rather than the marker.
    vm = page('/server-manager/machine.cgi?id=' + ids[0])
    assert 'left.cgi?mode=server-manager&sid=' + ids[0] in vm, 'Frame-based theme did not select the guest'
    assert 'theme_select_server=' not in vm, 'Frame-based theme received an SPA marker'
    print('Frame-based theme selects the displayed guest through theme_select_server: PASS')

    # The SPA hook supplies a marker rather than executable JavaScript.
    logout()
    assert is_spa_theme('authentic-theme'), 'SPA fixture does not declare spa=1'
    check_hooks('authentic-theme')
    login('authentic-theme')
    vm = page('/server-manager/machine.cgi?id=' + ids[0])
    assert '<!--\ntheme_select_server=%s\n-->' % ids[0] in vm, 'The SPA theme lost the selection marker'
    assert not re.search(r'<script[^>]*>\s*theme_select_server=', vm), 'SPA hook printed executable selection code'
    print('The SPA theme keeps the guest selection marker: PASS')
finally:
    # Only remove the fixture account after successful account setup.
    if created:
        logout()
    # Remove only the diskless guest created when the host had no inventory.
    if fixture is not None:
        fixture.undefine()
    # Release the fixture's connection even when no guest was needed.
    if conn is not None:
        conn.close()
