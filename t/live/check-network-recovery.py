#!/usr/bin/python3
"""Exercise Host Overview and its recovery action using a temporary Webmin user.

--fixture creates a temporary libvirt network and removes only its NAT rules.
Use that option on a disposable host. Without it, only existing failures are
repaired. Save rules before recovery and check that running guests stay running.
"""
import http.cookiejar
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

assert sys.platform == 'linux' and os.geteuid() == 0
module = Path(__file__).resolve().parents[2]
helper = module / 't/live/webmin-user.pl'
user = 'cloudmin-ui-check-' + secrets.token_hex(4)
base = 'https://127.0.0.1:10000'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))


def run(*args, **kwargs):
    """run(*args, **kwargs) runs bounded fixture commands without printing secrets."""
    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=60, **kwargs)


def request(path, fields=None):
    """request(path, [fields]) retains ordinary Webmin error pages for assertions."""
    body = urllib.parse.urlencode(fields).encode() if fields is not None else None
    req = urllib.request.Request(base + path, data=body, headers={'Referer': base + '/server-manager/index.cgi'})
    try:
        response = opener.open(req, timeout=90)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        page = response.read().decode()
    assert 'Error - Perl execution failed' not in page, 'CGI crashed'
    return page


class Inputs(HTMLParser):
    """Collect the signed form tokens regardless of attribute quote style."""
    def __init__(self, page):
        """__init__(self, page) collects signed tokens from the form."""
        super().__init__()
        self.tokens = []
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        """handle_starttag(self, tag, attrs) collects only token controls."""
        attrs = dict(attrs)
        # Collect only signed form tokens, not other hidden fields.
        if tag == 'input' and attrs.get('name') == 'token':
            self.tokens.append(attrs.get('value'))


created = False
network_id = None
try:
    # Temporary credentials stay in this test process and are deleted afterward.
    password = secrets.token_urlsafe(36)
    run('perl', str(helper), 'create', 'authentic-theme', user, input=password + '\n')
    created = True
    time.sleep(1)
    request('/session_login.cgi')
    request('/session_login.cgi', {'user': user, 'pass': password, 'page': '/'})
    before = set(run('virsh', 'list', '--uuid').stdout.split())
    if '--fixture' in sys.argv:
        # The fixture has no guests or physical interfaces; existing rules remain.
        name = 'cloudmin-rules-' + secrets.token_hex(4)
        run('virsh', 'net-create', '/dev/stdin', input=f'''<network><name>{name}</name>
          <forward mode="nat"/><bridge name="cmrules0"/>
          <ip address="198.18.250.1" netmask="255.255.255.0"/></network>''')
        network_id = name
        rules = json.loads(run('nft', '-j', '-a', 'list', 'ruleset').stdout)['nftables']
        removed = 0
        for item in rules:
            rule = item.get('rule', {})
            expressions = rule.get('expr', [])
            source = any(e.get('match', {}).get('right') == {'prefix': {'addr': '198.18.250.0', 'len': 24}}
                         and e.get('match', {}).get('left', {}).get('payload', {}).get('field') == 'saddr'
                         for e in expressions)
            nat = any('masquerade' in e or e.get('xt', {}).get('name') == 'MASQUERADE' for e in expressions)
            if source and nat:
                # Delete only the fixture subnet's NAT rules by exact handles.
                run('nft', 'delete', 'rule', rule['family'], rule['table'], rule['chain'], 'handle', str(rule['handle']))
                removed += 1
        assert removed, 'Fixture NAT rules not found'
    page = request('/server-manager/index.cgi')
    tokens = Inputs(page).tokens
    assert tokens, 'Overview did not render a token'
    token = tokens[0]
    # GET, forged tokens and sentence formatting are exercised through real CGI.
    denied = request('/server-manager/index.cgi?action=restore_network_rules&token=' + urllib.parse.quote(token))
    assert 'Use POST for network changes' in denied
    denied = request('/server-manager/index.cgi', {'action': 'restore_network_rules', 'token': 'bad'})
    assert 'This form has expired' in denied
    error = request('/server-manager/setup_machine.cgi', {'vm_operation': 'invalid'})
    message = re.search(r'<h3[^>]*data-fatal-error-text[^>]*>(.*?)</h3>', error, re.S)
    assert message and 'Unknown virtual machine form action' in message[1] and '<tt>' not in message[1]
    if 'value="restore_network_rules"' in page:
        # Retain the pre-recovery state before exercising the real restart.
        assert 'missing IPv4' in page or 'IPv4 forwarding is disabled' in page
        backup = Path(tempfile.mkdtemp(prefix='cloudmin-network-recovery.', dir='/var/tmp'))
        (backup / 'before.nft').write_text(run('nft', 'list', 'ruleset').stdout)
        (backup / 'guests.json').write_text(json.dumps(sorted(before)))
        (backup / 'before-forwarding').write_text(Path('/proc/sys/net/ipv4/ip_forward').read_text())
        restored = request('/server-manager/index.cgi', {'action': 'restore_network_rules', 'token': token})
        if '--fixture' not in sys.argv and 'Wait for virtual machine operations to finish' in restored:
            # Existing user jobs may correctly defer repair of an existing
            # fault.
            assert before == set(run('virsh', 'list', '--uuid').stdout.split())
            print('Overview warning, token checks and running-job protection passed; recovery waits for active jobs')
            sys.exit(0)
        assert 'Network rules restored and verified.' in restored, re.sub('<[^>]+>', '', restored)[-2000:]
        assert 'value="restore_network_rules"' not in restored, 'Failure did not clear'
        assert before == set(run('virsh', 'list', '--uuid').stdout.split()), 'Running guests changed'
        print('Overview warning, token checks, recovery and running-guest preservation passed')
        print('Prior rules saved in', backup)
    else:
        # A healthy host needs no repair, but a planted fault must be visible.
        assert '--fixture' not in sys.argv, 'Overview hid the fixture failure'
        print('Healthy overview, token checks and unquoted validation errors passed')
finally:
    try:
        if network_id is not None:
            # Only the transient network allocated by this run may be destroyed.
            run('virsh', 'net-destroy', network_id)
    finally:
        if created:
            # Delete only the temporary account after the recovery checks.
            run('perl', str(helper), 'delete', 'authentic-theme', user)
