"""
Exercise SLAAC on an isolated Ethernet/bridge pair in a disposable Linux VM.
"""

import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time

# Network namespaces and profiles belong on the disposable Linux guest.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Disposable Linux guest as root only')

# Run the advertisement child only on its explicitly supplied interface.
if len(sys.argv) == 3 and sys.argv[1] == '--ra':
    interface = sys.argv[2]
    index = socket.if_nametoindex(interface)
    sock = socket.socket(
        socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6
    )
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    # Advertise only a documentation prefix, without a default route or DNS.
    packet = struct.pack('!BBHBBHII', 134, 0, 0, 64, 0, 0, 0, 0)
    packet += struct.pack(
        '!BBBBIII16s',
        3,
        4,
        64,
        0xc0,
        600,
        300,
        0,
        ipaddress.IPv6Address('2001:db8:ca11::').packed,
    )
    while True:
        sock.sendto(packet, ('ff02::1', 0, 0, index))
        time.sleep(0.5)


# run(*args, [check]) bounds fixture commands to 90 seconds.
# By default, reject failures and report stderr; cleanup can disable checking.
def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=90)
    # Surface a checked command failure with its fixture arguments and output.
    if check and result.returncode:
        raise RuntimeError(
            str(args) + ': ' + result.stdout + ' ' + result.stderr
        )
    # Keep native warnings visible even when the command succeeds.
    if check and result.stderr:
        print(result.stderr.strip(), file=sys.stderr)
    return result.stdout.strip()


mode = sys.argv[2] if len(sys.argv) > 2 else 'stable-privacy'
# Reject unsupported address-generation modes before allocating fixtures.
if mode not in ('stable-privacy', 'eui64', 'token'):
    raise SystemExit('Choose stable-privacy, eui64 or token')
suffix = str(os.getpid())
source, peer, bridge = 'cmi' + suffix, 'cmp' + suffix, 'cmb' + suffix
namespace = 'cm-review-' + suffix
profile = 'cloudmin-review-' + suffix
ra = None
try:
    run('ip', 'netns', 'add', namespace)
    run('ip', 'link', 'add', source, 'type', 'veth', 'peer', 'name', peer)
    run('ip', 'link', 'set', peer, 'netns', namespace)
    run('ip', '-n', namespace, 'link', 'set', 'lo', 'up')
    run('ip', '-n', namespace, 'link', 'set', peer, 'up')
    run('ip', 'link', 'set', source, 'up')
    run(
        'ip',
        '-n',
        namespace,
        '-6',
        'address',
        'add',
        'fe80::1/64',
        'dev',
        peer,
        'nodad',
    )
    run(
        'nmcli',
        'connection',
        'add',
        'type',
        'ethernet',
        'ifname',
        source,
        'con-name',
        profile,
        'connection.autoconnect',
        'no',
        'ipv4.method',
        'disabled',
        'ipv6.method',
        'auto',
        'ipv6.addr-gen-mode',
        'stable-privacy' if mode == 'stable-privacy' else 'eui64',
        'ipv6.never-default',
        'yes',
    )
    # A supplied token must survive conversion independently of the MAC.
    if mode == 'token':
        run(
            'nmcli',
            'connection',
            'modify',
            profile,
            'ipv6.token',
            '::abcd:1234:5678:9abc',
        )
    time.sleep(2)
    ra = subprocess.Popen(
        [
            'ip',
            'netns',
            'exec',
            namespace,
            'python3',
            str(Path(__file__).resolve()),
            '--ra',
            peer,
        ]
    )
    run('nmcli', '--wait', '30', 'connection', 'up', profile)
    print(
        run(
            'perl',
            str(Path(__file__).with_name('network-ipv6-fixture.pl')),
            sys.argv[1],
            source,
            bridge,
            mode,
        )
    )
finally:
    # Stop advertisements before removing their namespace.
    if ra:
        ra.terminate()
        ra.wait(timeout=5)
    errors = []
    for name in (profile, 'cloudmin-' + bridge):
        profiles = run(
            'nmcli', '-t', '-f', 'NAME', 'connection', 'show'
        ).splitlines()
        # Delete only the fixture profiles that still exist.
        if name in profiles:
            try:
                run('nmcli', 'connection', 'delete', name)
            except Exception as error:
                errors.append(str(error))
    for name in (source, bridge):
        # An earlier cleanup step may already have removed a virtual interface.
        if Path('/sys/class/net/' + name).exists():
            run('ip', 'link', 'delete', name)
    # Remove the private namespace if setup reached its creation.
    if namespace in run('ip', 'netns', 'list').split():
        run('ip', 'netns', 'delete', namespace)
    # Report profile cleanup failures rather than claiming a clean test run.
    if errors:
        raise RuntimeError('Fixture cleanup failed: ' + str(errors))
