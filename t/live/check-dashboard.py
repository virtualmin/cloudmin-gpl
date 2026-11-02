#!/usr/bin/python3
"""Run on a disposable Linux VM after installing Cloudmin and a SPA theme.

Uses Webmin's local HTTPS interface. Keep webmin-user.pl beside this script.
Fixture credentials never leave the VM.
"""

import http.cookiejar
import json
import os
import pathlib
import platform
import re
import secrets
import ssl
import subprocess
import time
import urllib.parse
import urllib.request

# This test creates an account and must never run against the workstation.
if platform.system() != 'Linux' or os.geteuid() != 0:
    raise SystemExit('Run only on a disposable Linux VM as root')

# Generate credentials in memory and refuse to reuse an existing fixture account.
helper = pathlib.Path(__file__).resolve().with_name('webmin-user.pl')
password = secrets.token_urlsafe(36)
subprocess.run(['perl', str(helper), 'create'], input=password + '\n',
               text=True, check=True)
try:
    time.sleep(1)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    base = 'https://127.0.0.1:10000'

    # Establish Webmin's cookie check, then use its normal HTTPS login form.
    with opener.open(base + '/session_login.cgi', timeout=30) as response:
        response.read()
    payload = urllib.parse.urlencode({
        'user': 'cloudmin-ui-check', 'pass': password,
        'page': '/server-manager/index.cgi',
    }).encode()
    request = urllib.request.Request(base + '/session_login.cgi', data=payload)
    with opener.open(request, timeout=30) as response:
        page = response.read().decode('utf-8', errors='replace')
        assert response.status == 200, 'Dashboard did not return HTTP 200'
    assert 'Host Readiness' in page, 'Dashboard content missing after login'
    assert 'Error - Perl execution failed' not in page, 'Dashboard CGI failed'

    # The SPA theme loads navigation separately from the module's page body.
    request = urllib.request.Request(
        base + '/xhr.cgi?type=nav&action=get&subtype=cloudmin',
        headers={'Referer': base + '/server-manager/index.cgi'})
    with opener.open(request, timeout=30) as response:
        navigation = json.load(response)['menu']
    nav_links = re.findall(r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
                           navigation, re.S)
    assert any(href == '/server-manager/index.cgi' and 'Host Overview' in body
               for href, body in nav_links), 'host overview navigation missing'
    assert any(href == '/server-manager/storage.cgi' and 'Storage' in body
               for href, body in nav_links), 'Cloudmin storage navigation missing'
    assert any(href == '/server-manager/images.cgi' and 'Image Manager' in body
               for href, body in nav_links), 'Cloudmin images navigation missing'

    # Keep only the header settings link, with no duplicate dashboard button.
    links = re.findall(r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>', page, re.S)
    assert 'Configure Cloudmin' not in page, 'Duplicate settings button remains'
    assert any('/config.cgi?' in href and 'server-manager' in urllib.parse.unquote(href)
               for href, body in links), 'Header configuration link missing'
    print('Navigation and header settings: PASS')

    # Check the live server's widget library, including badges nested in lists.
    badges = re.findall(r'<span\b[^>]*class=["\']([^"\']*\bui_badge\b[^"\']*)', page)
    assert badges and all('ui_badge_small' in badge and 'ui_badge_rounded' in badge
                          for badge in badges), 'Dashboard badge styles missing'

    # Match ui-demo's card-based statistic tiles with icons and their anchors.
    overview = re.search(r'<section\b[^>]*id="cloudmin-overview".*?</section>',
                         page, re.S)
    assert overview, 'Overview card missing'
    overview = overview.group()
    assert 'ui_stats' in overview and overview.count('<svg') == 4, 'Wrong stat layout'
    assert 'ui_stat_desc' not in overview, 'Redundant stat captions remain'
    assert 'ui_card_desc' not in page, 'Redundant card descriptions remain'
    assert re.search(r'<span data-sub_title><br>libvirt version \d+\.\d+\.\d+</span>', page), \
        'Libvirt version must use the original subtitle element'
    assert '<span data-main_title_sub>' not in page, 'Unexpected version header element'
    assert 'KVM virtual machines managed through libvirt' not in page, 'Old subtitle remains'
    for target in ('cloudmin-host', 'cloudmin-machines'):
        assert f'href="#{target}"' in overview, 'Stat link missing: ' + target
        assert f'id="{target}"' in page, 'Stat link target missing: ' + target
    # Follow the tile's real destination, including the SPA theme's POST navigation.
    tiles = re.findall(r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>', overview, re.S)
    jobs_href = next(href for href, body in tiles if 'Active Jobs' in body)
    assert jobs_href == 'jobs.cgi', 'Active jobs routes to an unrelated inventory'
    for data in (None, urllib.parse.urlencode({'navigation': 1}).encode()):
        request = urllib.request.Request(
            urllib.parse.urljoin(base + '/server-manager/index.cgi', jobs_href),
            data=data, headers={'Referer': base + '/server-manager/index.cgi',
                                'X-Requested-With': 'XMLHttpRequest'})
        with opener.open(request, timeout=30) as response:
            jobs_page = response.read().decode('utf-8')
            assert response.status == 200, 'Active jobs page did not return HTTP 200'
        assert 'data-jobs-content=' in jobs_page, 'Live jobs content is missing'
        assert 'jobs.js?' in jobs_page, 'Live jobs client is missing'
        assert 'Manage virtual machine jobs' not in jobs_page, 'Status page has management buttons'
        assert 'Error - Perl execution failed' not in jobs_page, 'Active jobs CGI failed'
        assert 'This form has expired' not in jobs_page, 'Job navigation required a form token'
        recovery = 'Recovery required' in jobs_page
        assert 'No active jobs' in jobs_page or 'role="progressbar"' in jobs_page or recovery, \
            'Job list has no progress, recovery controls or empty state'
    print('Active jobs tile, GET and theme POST destination: PASS')
    assert 'IP addresses' in page or 'No virtual machines yet' in page, \
        'Populated virtual machine overview has no IP address column'
    assert 'Guests currently defined in libvirt.' not in page, 'Old VM text remains'
    print('Overview tiles and VM wording: PASS')

    # The storage page must use the configured libvirt pool inventory.
    request = urllib.request.Request(
        base + '/server-manager/storage.cgi',
        headers={'Referer': base + '/server-manager/index.cgi'})
    with opener.open(request, timeout=30) as response:
        storage_page = response.read().decode('utf-8', errors='replace')
        assert response.status == 200, 'Storage page did not return HTTP 200'
    # Storage now uses three tabs, with the four statistics in its overview.
    for tab in ('overview', 'pools', 'volumes'):
        assert f'data-storage-tab="{tab}"' in storage_page, 'Storage tab missing: ' + tab
    stat_icons = re.findall(r'<span\b[^>]*class=["\'][^"\']*\bui_stat_value\b[^"\']*["\'][^>]*>\s*<svg\b',
                            storage_page)
    assert 'cloudmin-storage-summary' in storage_page and len(stat_icons) == 4, \
        'Storage statistic icons missing'
    badges = re.findall(r'<span\b[^>]*class=["\']([^"\']*\bui_badge\b[^"\']*)', storage_page)
    assert badges and all('ui_badge_small' in badge for badge in badges), \
        'Storage badge styles missing'
    assert 'Error - Perl execution failed' not in storage_page, 'Storage CGI failed'
    assert 'dtable-sortable' in storage_page and \
        'data-sortable="1"' in storage_page, \
        'Storage table did not request DataTables initialization'
    assert '&lt;span data-filesize-bytes' not in storage_page, \
        'Storage statistic escaped size markup'
    assert re.search(r'data-filesize-bytes=["\']\d+["\'][^>]*>'
                     r'[\d.]+ [KMGT]iB</span>', storage_page), \
        'Storage table does not show readable sizes'
    print('Storage navigation and inventory: PASS')

    # The import form exposes functional sources instead of a metadata review.
    request = urllib.request.Request(
        base + '/server-manager/images.cgi',
        headers={'Referer': base + '/server-manager/index.cgi'})
    with opener.open(request, timeout=30) as response:
        images_page = response.read().decode('utf-8', errors='replace')
        assert response.status == 200, 'Images page did not return HTTP 200'
    for expected in ('Add Images', 'Download selected images', 'Image Manager',
                     'Download an OS', 'Upload an image', 'Use an image on this host',
                     'Download from a URL', 'AlmaLinux 10', 'Debian 13',
                     'Rocky Linux 10', 'Ubuntu 24.04 LTS', 'Ubuntu 26.04 LTS',
                     'Alpine Linux 3.24', 'CentOS Stream 10', 'Fedora Cloud 44',
                     'openSUSE Leap 16.0', 'openSUSE Tumbleweed (rolling)'):
        assert expected in images_page, 'Missing import content: ' + expected
    assert 'name="install_type"' in images_page and 'name="pool"' in images_page
    assert 'name="token"' in images_page and 'images.js' in images_page
    assert 'data-ui-multi="id"' in images_page
    assert '--ui-multi-height:420px' in images_page, 'Catalogue list height changed'
    assert 'data-ui-multi-action="all"' not in images_page, 'Image picker still has select-all controls'
    if platform.machine() == 'aarch64':
        # The catalogue tab lists every architecture; only download choices are filtered.
        inputs = re.findall(r'<input\b[^>]*>', images_page)
        assert not any(re.search(r'name=["\']id_item["\']', tag) and
                       re.search(r'value=["\']arch-linux["\']', tag) for tag in inputs), \
            'x86-only OS offered for download on ARM'
    assert 'setup_image.cgi' in images_page
    assert 'Error - Perl execution failed' not in images_page
    assert 'Cloud image details' not in images_page
    descriptions = re.findall(
        r'<div\b[^>]*class=["\'][^"\']*\bvui_ui_block\b[^"\']*["\'][^>]*>'
        r'\s*<p\b[^>]*>(.*?)</p>\s*</div>', images_page, re.S)
    for description in ('Downloaded images and imports in progress.',
                        'Choose a storage pool and image source.'):
        assert any(description in block for block in descriptions), \
            'Tab description is outside vui_ui_block: ' + description
    assert len(re.findall(r'href=["\']image_form\.cgi["\']', images_page)) <= 1, \
        'Duplicate Add images shortcut remains'
    assert 'View progress' not in images_page, 'Image table still has progress links'
    assert 'data-image-progress=' not in images_page, 'Image table has progress controls'
    print('Direct image import form: PASS')

    # Follow same-origin links as a browser does, including its Referer header.
    for path, expected in [
        ('/config.cgi?module=server-manager', 'libvirt_uri'),
        ('/unauthenticated/css/ui-lib.css', 'ui_card'),
        ('/unauthenticated/js/ui-lib.js', 'ui_'),
        ('/help.cgi/server-manager/intro', 'libvirt'),
        ('/help.cgi/server-manager/storage', 'Storage pools'),
        ('/help.cgi/server-manager/images', 'image source'),
    ]:
        request = urllib.request.Request(base + path, headers={
            'Referer': base + '/server-manager/index.cgi',
        })
        with opener.open(request, timeout=30) as response:
            body = response.read().decode('utf-8', errors='replace')
            assert response.status == 200, 'Resource did not return HTTP 200'
            assert expected in body, 'Expected content missing: ' + path
        print('HTTP resource: PASS ' + path)
finally:
    # Delete both the fixture account and its sessions, even if a check failed.
    subprocess.run(['perl', str(helper), 'delete'], check=True)
