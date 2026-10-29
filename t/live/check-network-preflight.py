#!/usr/bin/python3
"""Check live libvirt rules, then simulate failures in a private network namespace.

Existing host rules, networks and virtual machines are never changed.
Run as root on an authorized Linux test host with nftables and iptables.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

module = Path(__file__).resolve().parents[2]
assert sys.platform == 'linux' and os.geteuid() == 0


def run(*args, **kwargs):
    """run(*args, **kwargs) runs a fixture command with a timeout."""
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=30, **kwargs)


def perl(code, *args):
    """perl(code, *args) calls the installed helper with the host's Webmin library."""
    return subprocess.run(['perl', '-I', str(module.parent), '-I', str(module / 'lib'),
                           '-MCloudmin::NetworkPreflight', '-e', code, *args],
                          text=True, capture_output=True, timeout=20)


if '--isolated' not in sys.argv:
    # Read actual network metadata through the production libvirt adapter.
    result = perl('''use Cloudmin::Libvirt;
        my $networks = Cloudmin::Libvirt->new()->list_networks();
        my ($network) = grep { $_->{name} eq 'default' && $_->{active} } @$networks;
        die "No active default network\\n" unless $network;
        $network->{type} = 'network';
        Cloudmin::NetworkPreflight::check($network);
        print "Live network preflight passed\\n";
    ''')
    assert result.returncode == 0, result.stderr
    print(result.stdout, end='', flush=True)
    isolated = run('unshare', '--net', '--', sys.executable, str(Path(__file__).resolve()), '--isolated')
    print(isolated.stdout, end='')
    sys.exit(0)

# Refuse to install or erase rules unless unshare actually isolated this process.
assert os.readlink('/proc/self/ns/net') != os.readlink('/proc/1/ns/net')
run('ip', 'link', 'add', 'virbr0', 'type', 'bridge')
run('sysctl', '-w', 'net.ipv4.ip_forward=1')
network = dict(type='network', name='fixture', forward='nat', bridge='virbr0',
               address='192.168.122.1', netmask='255.255.255.0')


def check(expected=None, mode='nat'):
    """check([expected], [mode]) verifies the result and its time limit."""
    started = time.monotonic()
    result = perl('Cloudmin::NetworkPreflight::check(WebminCore::convert_from_json($ARGV[0]));',
                  json.dumps(dict(network, forward=mode)))
    assert time.monotonic() - started < 15, 'Preflight took too long'
    if expected:
        # A missing prerequisite must fail quickly with the selected diagnosis.
        assert result.returncode != 0 and expected in result.stderr, result.stderr
    else:
        # Complete fixtures must pass without contacting external repositories.
        assert result.returncode == 0, result.stderr


for backend in ('nft', 'iptables'):
    # The host network namespace is unaffected by these fixture rules.
    run('nft', 'flush', 'ruleset')
    if backend == 'nft':
        # Model libvirt's native nft chains and subnet-specific verdicts.
        run('nft', '-f', '-', input='''table ip libvirt_network {
            chain forward { type filter hook forward priority 0; policy accept;
                jump guest_output; jump guest_input; }
            chain guest_output { ip saddr 192.168.122.0/24 iif "virbr0" accept; }
            chain guest_input { oif "virbr0" ip daddr 192.168.122.0/24 ct state established,related accept; }
            chain guest_nat { type nat hook postrouting priority 100; policy accept;
                ip saddr 192.168.122.0/24 ip daddr != 192.168.122.0/24 masquerade; }
        }''')
    else:
        # Model the same topology through the legacy save/restore syntax.
        run('iptables-restore', input='''*filter
:FORWARD ACCEPT [0:0]
:LIBVIRT_FWO - [0:0]
:LIBVIRT_FWI - [0:0]
-A FORWARD -j LIBVIRT_FWO
-A FORWARD -j LIBVIRT_FWI
-A LIBVIRT_FWO -s 192.168.122.0/24 -i virbr0 -j ACCEPT
-A LIBVIRT_FWI -d 192.168.122.0/24 -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
*nat
:POSTROUTING ACCEPT [0:0]
:LIBVIRT_PRT - [0:0]
-A POSTROUTING -j LIBVIRT_PRT
-A LIBVIRT_PRT -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE
COMMIT
''')
    check()
    # Delete only NAT first, then break forwarding while keeping orphan chains.
    if backend == 'nft':
        # Empty the NAT hook while leaving forwarding intact.
        run('nft', 'flush', 'chain', 'ip', 'libvirt_network', 'guest_nat')
    else:
        # Detach the legacy NAT chain without deleting its rules.
        run('iptables', '-t', 'nat', '-F', 'POSTROUTING')
    check('missing IPv4 NAT rules')
    check(mode='route')
    if backend == 'nft':
        # Leave populated child chains unreachable from the forwarding hook.
        run('nft', 'flush', 'chain', 'ip', 'libvirt_network', 'forward')
    else:
        # The legacy backend must also reject detached forwarding rules.
        run('iptables', '-F', 'FORWARD')
    check('missing IPv4 forwarding rules')
    run('sysctl', '-w', 'net.ipv4.ip_forward=0')
    check('IPv4 forwarding is disabled')
    run('sysctl', '-w', 'net.ipv4.ip_forward=1')
    run('nft', 'flush', 'ruleset')
    check('missing IPv4 forwarding rules')
    print(backend, 'failure checks passed')
