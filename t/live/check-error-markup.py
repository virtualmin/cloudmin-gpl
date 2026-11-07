#!/usr/bin/python3
"""Check error markup in both themes on an authorized Cloudmin test host.

Temporary Webmin users and the rendering fixture are removed after the check.
No virtual machines, storage pools or module settings are changed.
"""
import http.cookiejar
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import os


def request(opener, path, fields=None):
    """request(opener, path, [fields]) reads a page, including HTTP error pages."""
    base = 'https://127.0.0.1:10000'
    body = urllib.parse.urlencode(fields).encode() if fields is not None else None
    headers = {'Referer': base + '/server-manager/index.cgi'}
    # Theme navigation requests content without reloading the surrounding theme.
    if 'navigation=1' in path:
        headers['X-Requested-With'] = 'XMLHttpRequest'
    req = urllib.request.Request(base + path, data=body, headers=headers)
    try:
        response = opener.open(req, timeout=45)
    except urllib.error.HTTPError as error:
        # Error status pages carry the markup this fixture is meant to inspect.
        response = error
    with response:
        page = response.read().decode()
    assert 'Perl execution failed' not in page, path + ' crashed'
    return page


def check_theme(module, theme):
    """check_theme(module, theme) checks real CGI errors and value formatting."""
    helper = module / 't/live/webmin-user.pl'
    suffix = secrets.token_hex(4)
    user = 'cloudmin-ui-check-' + suffix
    probe = module / ('error_markup_' + suffix + '.cgi')
    created = False
    probe_created = False
    # Restrict the temporary CGI to this fixture's user and fixed test values.
    code = '''#!/usr/bin/perl
use strict;
use warnings;
our (%in, $remote_user);
require './server-manager-lib.pl';
error('Access denied') if ($remote_user ne 'FIXTURE_USER');
ReadParse();
if ($in{'mode'} eq 'alert') {
    # Exercise the page alert separately from Webmin's fatal-error renderer.
    require './cloudmin-storage-pages.pl';
    ui_print_header(undef, 'Error markup check', '');
    print show_storage_page({ error => 'Cannot read <source> & metadata' }, '');
    ui_print_footer();
    exit;
}
ui_print_header(undef, 'Error markup check', '') if ($in{'mode'} eq 'late');
error('Cannot read <tt>'.html_escape('/tmp/<source>&.qcow2').
    '</tt> during image inspection');
'''.replace('FIXTURE_USER', user)
    try:
        # Account credentials stay in memory and are never printed.
        password = secrets.token_urlsafe(36)
        subprocess.run(['perl', str(helper), 'create', theme, user],
            input=password + '\n', text=True, check=True, timeout=30)
        created = True
        with probe.open('x') as output:
            probe_created = True
            output.write(code)
        probe.chmod(0o755)
        time.sleep(1)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
        request(opener, '/session_login.cgi')
        request(opener, '/session_login.cgi',
            {'user': user, 'pass': password, 'page': '/'})

        # A real template failure must remain escaped prose in normal and
        # theme navigation, without any teletype wrapper around the sentence.
        for navigation in ('', '&navigation=1'):
            page = request(opener, '/server-manager/edit_tmpl.cgi?id=missing' + navigation)
            heading = re.search(r'<h3\b[^>]*data-fatal-error-text[^>]*>(.*?)</h3>', page, re.S)
            assert heading and 'Invalid template ID' in heading[1], (theme, navigation,
                heading[1] if heading else re.findall(r'<(?:h[1-6]|title)\b[^>]*>(.*?)</(?:h[1-6]|title)>', page, re.S))
            assert '<tt' not in heading[1], heading[1]

        # Backend diagnostics must escape angle brackets and ampersands.
        page = request(opener, '/server-manager/' + probe.name + '?mode=alert')
        assert 'Cannot read &lt;source&gt; &amp; metadata' in page

        # Fatal headings emphasize the path; alerts retain the theme's wrapper.
        message = 'Cannot read <tt>/tmp/&lt;source&gt;&amp;.qcow2</tt> during image inspection'
        for mode in ('early', 'late'):
            # An already-open SPA page receives errors through navigation.
            navigation = '&navigation=1' if mode == 'late' else ''
            page = request(opener, '/server-manager/' + probe.name + '?mode=' + mode + navigation)
            assert message in page, (theme, mode)
            if theme == 'authentic-theme' and mode == 'late':
                # SPA errors reuse the existing alert wrapper.
                assert re.search(r"<tt\b[^>]*class=['\"]font-size-90pf['\"][^>]*>" +
                                 re.escape(message), page), ('Late errors keep the alert wrapper',
                                     page[max(0, page.index(message) - 150):page.index(message) + len(message)])
            else:
                # Full error pages must emphasize only the embedded path.
                assert not re.search(r'<tt\b[^>]*>Cannot read', page), (theme, mode)
        print(theme + ': plain errors, escaped text and formatted paths PASS', flush=True)
    finally:
        # Remove only the files and account created by this invocation.
        if probe_created:
            # Failed exclusive creation must never unlink a pre-existing CGI.
            probe.unlink(missing_ok=True)
        if created:
            # Delete only the temporary user whose creation succeeded.
            subprocess.run(['perl', str(helper), 'delete', theme, user],
                check=True, timeout=30)


# Importing helpers must not install fixture pages or create Webmin users.
if __name__ == '__main__':
    assert sys.platform == 'linux' and os.geteuid() == 0, 'Run on an authorized Linux test host as root'
    module = Path(__file__).resolve().parents[2]
    for theme in ('authentic-theme', 'gray-theme'):
        check_theme(module, theme)
