#!/usr/bin/python3
"""Boot clones across NAT, routed, isolated and private bridged networks."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from xml.etree import ElementTree as ET

# All host mutations are confined to an authorized Linux test machine.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt

libvirt.registerErrorHandler(lambda context, error: None, None)
module = Path(__file__).resolve().parents[2]


# run(*args, [input_text], [timeout]) captures commands; timeout defaults
# to 120s.
def run(*args, input_text=None, timeout=120):
    result = subprocess.run(
        args, input=input_text, text=True, capture_output=True, timeout=timeout
    )
    if result.returncode:
        # Preserve the failed fixture command's output for diagnosis.
        raise RuntimeError(str(args[:3]) + ': ' + result.stdout + result.stderr)
    return result.stdout.strip()


# The peer returns the sender address, proving NAT versus routed traffic.
if len(sys.argv) == 3 and sys.argv[1] == '--peer':
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from socketserver import TCPServer
    import socket
    import threading

    class Handler(BaseHTTPRequestHandler):
        # do_GET(self) sends only the peer address observed by this test server.
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(self.client_address[0].encode())

        # log_message(self, ...) keeps the fixture log free of request noise.
        def log_message(self, *args):
            pass

    class Server(HTTPServer):
        # server_bind(self) avoids hostname lookups on the isolated
        # test network.
        def server_bind(self):
            TCPServer.server_bind(self)
            self.server_name = 'clone-peer.test'
            self.server_port = self.server_address[1]

    class Server6(Server):
        address_family = socket.AF_INET6

        # server_bind(self) keeps the IPv6 listener separate from IPv4.
        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()

    threading.Thread(
        target=Server(('0.0.0.0', 18080), Handler).serve_forever, daemon=True
    ).start()
    Server6(('::', 18080), Handler).serve_forever()
    raise SystemExit

parser = argparse.ArgumentParser(description=__doc__)
# A retained fixture supplies its recorded IDs; new runs get a unique prefix.
parser.add_argument('image', type=Path)
parser.add_argument('--bootstrap-network', default='default')
parser.add_argument('--keep-on-failure', action='store_true')
parser.add_argument(
    '--resume', type=Path, help='Resume an owned fixture after a failed case'
)
parser.add_argument('--start-case', type=int, default=0)
args = parser.parse_args()
connection = libvirt.open('qemu:///system')
bootstrap = connection.networkLookupByName(args.bootstrap_network)
assert bootstrap.isActive(), 'Bootstrap network must already be active'
image = args.image.resolve(strict=True)
work = args.resume or Path(
    tempfile.mkdtemp(prefix='cm-clone-net-', dir='/var/lib/libvirt/images')
)
assert work.parent == Path('/var/lib/libvirt/images') and work.name.startswith(
    'cm-clone-net-'
)
work.chmod(0o755)
state_file = work / 'fixture.json'
state = (
    json.loads(state_file.read_text())
    if args.resume
    else {
        'prefix': 'cm-clone-net-' + uuid.uuid4().hex[:8],
        'jobs': [],
        'domains': [],
        'networks': [],
        'sysctl': {
            path: Path(path).read_text()
            for path in (
                '/proc/sys/net/ipv4/ip_forward',
                '/proc/sys/net/ipv6/conf/all/forwarding',
            )
        },
    }
)
prefix = state['prefix']
# Private link names and subnets never replace a physical host interface.
short = prefix[-6:]
key = work / 'identity'
peer_ns = 'cmnp' + short
peer_link, peer_end = 'cmnh' + short, 'cmne' + short
bridge, bridge_link, bridge_end = 'cmnb' + short, 'cmnl' + short, 'cmnr' + short
peer4, peer6 = '198.19.254.2', 'fd73:ca11:254::2'
networks = {}
processes = []
pool = None


# save() makes retained fixtures recoverable without guessing object names.
def save():
    state_file.write_text(json.dumps(state, indent=2))
    state_file.chmod(0o600)


# remove_source(domain) releases the previous case's stopped fixture and disks.
def remove_source(domain):
    ident = domain.UUIDString()
    # Require recorded ownership and preserve the source selected for the
    # next case.
    assert ident in state['domains'] and ident != state['source']
    assert domain.name().startswith(prefix + '-') and not domain.isActive()
    doc = ET.fromstring(domain.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
    # Require private disk paths without symlinks and no snapshot history.
    paths = [
        Path(node.get('file')) for node in doc.findall('./devices/disk/source')
    ]
    assert paths and all(
        path.parent == work and not path.is_symlink() for path in paths
    )
    assert not domain.listAllSnapshots(0)
    # A completed clone is independent, so only the previous source is removed.
    domain.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    state['domains'].remove(ident)
    save()
    for path in paths:
        connection.storageVolLookupByPath(str(path)).delete(0)


# helper(action, fields) uses the production network service and
# guarded cleanup.
def helper(action, fields):
    return json.loads(
        run(
            'perl',
            str(module / 't/live/clone-network-fixture.pl'),
            action,
            input_text=json.dumps({'prefix': prefix, **fields}),
        )
    )


# api(action, fields) exercises the same controller as the create/clone pages.
def api(action, fields):
    return json.loads(
        run(
            'perl',
            str(module / 'api.pl'),
            action,
            input_text=json.dumps(fields),
            timeout=60,
        )
    )['result']


# wait_job(job) waits for detached copy/preparation and reports the
# real failure.
def wait_job(job):
    deadline = time.monotonic() + 900
    while (
        job['state'] not in ('complete', 'failed', 'cancelled')
        and time.monotonic() < deadline
    ):
        time.sleep(2)
        job = api('status', {'job': job['id']})
    assert job['state'] == 'complete', job.get('error', job['state'])
    return job


# stop(domain) flushes guest writes before hashing or copying its disks.
def stop(domain):
    if domain.isActive():
        # Inactive fixtures already have stable disks and need no power request.
        domain.shutdown()
        deadline = time.monotonic() + 120
        while domain.isActive() and time.monotonic() < deadline:
            time.sleep(1)
        assert not domain.isActive(), 'Fixture failed to shut down cleanly'


# ssh(address, command, [timeout]) uses the fixture key; timeout defaults
# to 120s.
def ssh(address, command, timeout=120):
    return run(
        'ssh',
        '-F',
        '/dev/null',
        '-i',
        str(key),
        '-o',
        'IdentitiesOnly=yes',
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=3',
        '-o',
        'StrictHostKeyChecking=no',
        '-o',
        'UserKnownHostsFile=/dev/null',
        'clonefixture@' + address,
        'sudo -n sh -c ' + shlex.quote(command),
        timeout=timeout,
    )


# address(domain, [expected]) waits for SSH at a static IP or an
# agent-reported IP.
def address(domain, expected=None):
    deadline = time.monotonic() + 420
    diagnostic = 'No guest address yet'
    while time.monotonic() < deadline:
        try:
            addresses = (
                [expected]
                if expected
                else [
                    item['addr']
                    for nic in domain.interfaceAddresses(
                        libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT, 0
                    ).values()
                    for item in (nic['addrs'] or [])
                    if item['type'] == libvirt.VIR_IP_ADDR_TYPE_IPV4
                    and not item['addr'].startswith('127.')
                ]
            )
            for candidate in addresses:
                if ssh(candidate, 'true', timeout=10) == '':
                    # An advertised address is ready only after fixture
                    # SSH works.
                    return candidate
        except (
            libvirt.libvirtError,
            RuntimeError,
            subprocess.TimeoutExpired,
        ) as error:
            # Retain the last boot-time failure for a useful timeout message.
            diagnostic = str(error)[-400:]
        time.sleep(3)
    raise AssertionError('Guest SSH unavailable: ' + diagnostic)


# digest(domain) detects any offline source-disk changes during
# clone preparation.
def digest(domain):
    result = {}
    for disk in ET.fromstring(
        domain.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)
    ).findall('./devices/disk'):
        source = disk.find('source')
        if (
            source is not None
            and source.get('file')
            and disk.find('readonly') is None
        ):
            # Hash writable file disks; unchanged seeds are checked separately.
            with open(source.get('file'), 'rb') as stream:
                result[source.get('file')] = hashlib.file_digest(
                    stream, 'sha256'
                ).hexdigest()
    return result


# configure_networks() creates private peers without changing
# physical interfaces.
def configure_networks():
    # Reject overlaps with existing host routes and saved libvirt networks.
    proposed = [
        ipaddress.ip_network('198.18.220.0/22'),
        ipaddress.ip_network('198.19.254.0/24'),
        ipaddress.ip_network('fd73:ca11::/32'),
    ]
    existing = []
    for family in ('-4', '-6'):
        for route in json.loads(
            run('ip', '-j', family, 'route', 'show', 'table', 'all')
        ):
            if route.get('dst', 'default') != 'default':
                # Default routes cover everything and are not subnet conflicts.
                existing.append(
                    ipaddress.ip_network(route['dst'], strict=False)
                )
    for net in connection.listAllNetworks():
        for item in ET.fromstring(net.XMLDesc(0)).findall('ip'):
            existing.append(
                ipaddress.ip_network(
                    item.get('address')
                    + '/'
                    + (item.get('prefix') or item.get('netmask', '24')),
                    strict=False,
                )
            )
    assert not any(
        a.version == b.version and a.overlaps(b)
        for a in proposed
        for b in existing
    ), 'Fixture subnet already in use'
    # A namespace is the upstream peer for routing and the bridge's
    # DHCP/DNS server.
    run('ip', 'netns', 'add', peer_ns)
    state['peer'] = True
    save()
    run(
        'ip', 'link', 'add', peer_link, 'type', 'veth', 'peer', 'name', peer_end
    )
    run('ip', 'link', 'set', peer_end, 'netns', peer_ns)
    for interface, ipv4, ipv6, ns in (
        (peer_link, '198.19.254.1', 'fd73:ca11:254::1', []),
        (peer_end, peer4, peer6, ['-n', peer_ns]),
    ):
        run('ip', *ns, 'link', 'set', interface, 'up')
        run('ip', *ns, 'address', 'add', ipv4 + '/24', 'dev', interface)
        run(
            'ip',
            *ns,
            '-6',
            'address',
            'add',
            ipv6 + '/64',
            'dev',
            interface,
            'nodad',
        )
    run('ip', '-n', peer_ns, 'link', 'set', 'lo', 'up')
    run('ip', '-n', peer_ns, 'route', 'add', 'default', 'via', '198.19.254.1')
    run(
        'ip',
        '-n',
        peer_ns,
        '-6',
        'route',
        'add',
        'default',
        'via',
        'fd73:ca11:254::1',
    )
    # Exercise Cloudmin's managed network creation for each forwarding mode.
    for number, mode in enumerate(('nat', 'route', 'isolated'), 220):
        helper(
            'create',
            {
                'network': {
                    'name': 'cn' + short + '-' + mode[0],
                    'mode': mode,
                    'ipv4': f'198.18.{number}.1/24',
                    'ipv6': f'fd73:ca11:{number}::1/64',
                    'dhcp': 1,
                    'dhcp_start': f'198.18.{number}.100',
                    'dhcp_end': f'198.18.{number}.150',
                    'autostart': 0,
                    **({'uplink': peer_link} if mode != 'isolated' else {}),
                }
            },
        )
        net = connection.networkLookupByName('cn' + short + '-' + mode[0])
        state['networks'].append(net.UUIDString())
        save()
        # Serve a test-only DNS record through each network's real dnsmasq.
        net.update(
            libvirt.VIR_NETWORK_UPDATE_COMMAND_ADD_LAST,
            libvirt.VIR_NETWORK_SECTION_DNS_HOST,
            -1,
            f'<host ip="{peer4}"><hostname>clone-peer.test</hostname></host>',
            libvirt.VIR_NETWORK_UPDATE_AFFECT_LIVE
            | libvirt.VIR_NETWORK_UPDATE_AFFECT_CONFIG,
        )
    run('ip', 'link', 'add', bridge, 'type', 'bridge')
    # A separate private bridge models attachment to an existing host bridge.
    state['bridge'] = True
    save()
    run('ip', 'link', 'set', bridge, 'up')
    run('ip', 'address', 'add', '198.18.223.1/24', 'dev', bridge)
    run(
        'ip',
        '-6',
        'address',
        'add',
        'fd73:ca11:223::1/64',
        'dev',
        bridge,
        'nodad',
    )
    run(
        'ip',
        'link',
        'add',
        bridge_link,
        'type',
        'veth',
        'peer',
        'name',
        bridge_end,
    )
    run('ip', 'link', 'set', bridge_link, 'master', bridge)
    run('ip', 'link', 'set', bridge_link, 'up')
    run('ip', 'link', 'set', bridge_end, 'netns', peer_ns)
    # Put the bridge's DHCP/DNS endpoint in the same isolated peer namespace.
    run('ip', '-n', peer_ns, 'link', 'set', bridge_end, 'up')
    run(
        'ip',
        '-n',
        peer_ns,
        'address',
        'add',
        '198.18.223.2/24',
        'dev',
        bridge_end,
    )
    run(
        'ip',
        '-n',
        peer_ns,
        '-6',
        'address',
        'add',
        'fd73:ca11:223::2/64',
        'dev',
        bridge_end,
        'nodad',
    )
    save()


# start_peers() binds DNS, DHCP and HTTP only inside the fixture namespace.
def start_peers():
    log = open(work / 'peer.log', 'a')
    processes.append(
        subprocess.Popen(
            [
                'ip',
                'netns',
                'exec',
                peer_ns,
                'python3',
                str(Path(__file__).resolve()),
                '--peer',
                'serve',
            ],
            stdout=log,
            stderr=log,
        )
    )
    processes.append(
        subprocess.Popen(
            [
                'ip',
                'netns',
                'exec',
                peer_ns,
                'dnsmasq',
                '--keep-in-foreground',
                '--conf-file=/dev/null',
                '--bind-interfaces',
                '--user=root',
                '--interface=' + bridge_end,
                '--dhcp-range=198.18.223.100,198.18.223.150,255.255.255.0,5m',
                '--dhcp-option=3,198.18.223.2',
                '--dhcp-option=6,198.18.223.2',
                '--host-record=clone-peer.test,' + peer4,
                '--no-resolv',
                '--dhcp-authoritative',
                '--dhcp-leasefile=' + str(work / 'leases'),
                '--pid-file=' + str(work / 'dnsmasq.pid'),
            ],
            stdout=log,
            stderr=log,
        )
    )
    time.sleep(2)
    assert all(p.poll() is None for p in processes), (
        work / 'peer.log'
    ).read_text()


# make_source() boots one disposable image on the existing NAT
# bootstrap network.
def make_source():
    global pool
    # Copy the input image into a private pool; the original remains untouched.
    pool = connection.storagePoolDefineXML(
        f'<pool type="dir"><name>{prefix}</name><target><path>{work}</path></target></pool>',
        0,
    )
    pool.create(0)
    disk = work / 'source.qcow2'
    run('qemu-img', 'convert', '-O', 'qcow2', str(image), str(disk))
    run('qemu-img', 'resize', str(disk), '12G')
    run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key))
    # Install the agent once while repositories are reachable on the
    # bootstrap net.
    user_data = {
        'package_update': True,
        'packages': ['qemu-guest-agent'],
        'users': [
            'default',
            {
                'name': 'clonefixture',
                'sudo': 'ALL=(ALL) NOPASSWD:ALL',
                'ssh_authorized_keys': [
                    key.with_suffix('.pub').read_text().strip()
                ],
            },
        ],
        'runcmd': [['systemctl', 'enable', '--now', 'qemu-guest-agent']],
    }
    (work / 'user-data').write_text('#cloud-config\n' + json.dumps(user_data))
    ident = str(uuid.uuid4())
    (work / 'meta-data').write_text(
        f'instance-id: {ident}\nlocal-hostname: source.example.test\n'
    )
    seed = work / ('cloudmin-fixture-seed-' + ident.replace('-', '') + '.iso')
    run(
        'xorriso',
        '-as',
        'mkisofs',
        '-quiet',
        '-o',
        str(seed),
        '-V',
        'cidata',
        '-J',
        '-r',
        str(work / 'user-data'),
        str(work / 'meta-data'),
    )
    pool.refresh(0)
    # Let libvirt choose suitable firmware for the host architecture.
    arch = connection.getInfo()[0]
    guest = connection.defineXML(f'''<domain type="kvm"><name>{prefix}-source</name><uuid>{ident}</uuid>
      <metadata><vm xmlns="urn:cloudmin:vm:1"><job>{ident.replace('-', '')}</job></vm></metadata>
      <memory unit="MiB">1536</memory><vcpu>2</vcpu><cpu mode="host-passthrough"/>
      <os firmware="efi"><type arch="{arch}" machine="{'virt' if arch == 'aarch64' else 'q35'}">hvm</type></os>
      <features><acpi/></features><devices>
      <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{disk}"/><target dev="vda" bus="virtio"/></disk>
      <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seed}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
      <interface type="network"><source network="{bootstrap.name()}"/><model type="virtio"/></interface>
      <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
      <serial type="pty"/><memballoon model="virtio"/></devices></domain>''')
    state['domains'].append(ident)
    # Record ownership before boot so a retained fixture can be resumed safely.
    state['source'] = ident
    save()
    guest.create()
    finish_source(guest)
    return guest


# finish_source(guest) also resumes interrupted first-boot fixture setup.
def finish_source(guest):
    if not guest.isActive():
        # Resume first-boot setup if the retained fixture stopped in
        # between runs.
        guest.create()
    ip = address(guest)
    ssh(ip, 'cloud-init status --wait >/dev/null', timeout=900)
    # Later network cases must not require repositories on isolated networks.
    ssh(
        ip,
        'command -v curl; command -v python3; systemctl is-active qemu-guest-agent',
    )
    state['addresses'] = [
        item['local']
        for link in json.loads(ssh(ip, 'ip -j address'))
        if link['ifname'] != 'lo'
        for item in link['addr_info']
        if item['scope'] == 'global'
    ]
    save()
    stop(guest)
    state['ready'] = True
    save()


# settings(mode, kind, number) assigns unique static addresses to every clone.
def settings(mode, kind, number):
    n = 220 + ('nat', 'route', 'isolated', 'bridge').index(mode)
    gateway = 2 if mode == 'bridge' else 1
    fields = {'network': networks[mode], 'address_mode': 'dhcp'}
    if kind != 'dhcp':
        # Single-family cases omit the other family entirely,
        # exposing fallbacks.
        fields['address_mode'] = 'static'
        if kind != 'ipv4':
            # IPv6-only and dual-stack cases need an explicit IPv6 gateway.
            fields.update(
                ipv6=f'fd73:ca11:{n}::{number}/'
                + ('128' if kind == 'hostroutes' else '64'),
                gateway6=f'fd73:ca11:{n}::{gateway}',
                dns=f'fd73:ca11:{n}::{gateway}',
            )
        if kind != 'ipv6':
            # Prefer IPv4 DNS when this case also configures IPv4.
            fields.update(
                ipv4=f'198.18.{n}.{number}/'
                + ('32' if kind == 'hostroutes' else '24'),
                gateway4=f'198.18.{n}.{gateway}',
                dns=f'198.18.{n}.{gateway}',
            )
    return fields


# verify(domain, fields, mode, old_addresses) checks applied settings
# and traffic.
def verify(domain, fields, mode, old_addresses):
    expected = (fields.get('ipv4') or fields.get('ipv6') or '').split('/')[
        0
    ] or None
    ip = address(domain, expected)
    # Check the guest's applied addresses after cloud-init has finished.
    ssh(ip, 'cloud-init status --wait >/dev/null')
    links = json.loads(ssh(ip, 'ip -j address'))
    addresses = {
        item['local']
        for link in links
        if link['ifname'] != 'lo'
        for item in link['addr_info']
        if item['scope'] == 'global'
    }
    subnet = 220 + ('nat', 'route', 'isolated', 'bridge').index(mode)
    allowed = [
        ipaddress.ip_network(f'198.18.{subnet}.0/24'),
        ipaddress.ip_network(f'fd73:ca11:{subnet}::/64'),
    ]
    assert all(
        any(ipaddress.ip_address(a) in n for n in allowed) for a in addresses
    ), addresses
    # A source lease/static address must never survive in a prepared copy.
    assert not addresses.intersection(old_addresses), (
        'Copied source addresses',
        addresses,
        old_addresses,
    )
    for field in ('ipv4', 'ipv6'):
        if fields.get(field):
            # Every requested static address must be present after boot.
            assert fields[field].split('/')[0] in addresses, (field, addresses)
    if fields['address_mode'] == 'static':
        # DHCP or SLAAC must not add an address in an omitted family.
        assert len(addresses) == len(
            [f for f in ('ipv4', 'ipv6') if fields.get(f)]
        ), ('Unexpected address', addresses)
    for family in ('4', '6'):
        if fields.get('gateway' + family):
            # Verify routes in the guest, not just the supplied seed data.
            routes = json.loads(
                ssh(ip, 'ip -j -' + family + ' route show default')
            )
            assert any(
                r.get('gateway') == fields['gateway' + family] for r in routes
            ), routes
    resolved = ssh(
        ip,
        'python3 -c '
        + shlex.quote(
            'import socket; print(socket.gethostbyname("clone-peer.test"))'
        ),
    )
    # Check both name resolution and which DNS server the guest actually uses.
    assert peer4 in resolved, 'Selected network DNS was not applied'
    dns = ssh(
        ip,
        'if command -v resolvectl >/dev/null && systemctl is-active --quiet systemd-resolved; '
              'then resolvectl dns; else cat /etc/resolv.conf; fi',
    )
    expected_dns = fields.get('dns') or f'198.18.{subnet}.' + (
        '2' if mode == 'bridge' else '1'
    )
    assert expected_dns in dns.split(), (
        'Unexpected DNS servers',
        dns,
        expected_dns,
    )
    for family, endpoint in [('4', peer4)] + (
        [('6', '[' + peer6 + ']')] if fields.get('ipv6') else []
    ):
        # Test traffic only for configured families and their forwarding mode.
        if (
            family == '4'
            and fields.get('address_mode') == 'static'
            and not fields.get('ipv4')
        ):
            # IPv6-only guests have no IPv4 path to probe.
            continue
        command = f'curl --noproxy "*" -{family} -sS --connect-timeout 3 --max-time 5 http://{endpoint}:18080/'
        if mode == 'isolated':
            # The peer lies outside the isolated subnet and must be unreachable.
            assert (
                ssh(
                    ip,
                    'if '
                    + command
                    + ' >/dev/null 2>&1; then exit 1; fi; echo blocked',
                )
                == 'blocked'
            )
        else:
            # NAT changes the observed sender; routing and bridging preserve it.
            seen = ssh(ip, command)
            expected_sender = (
                ('198.19.254.1' if family == '4' else 'fd73:ca11:254::1')
                if mode == 'nat'
                else next(a for a in addresses if (':' in a) == (family == '6'))
            )
            assert ipaddress.ip_address(seen) == ipaddress.ip_address(
                expected_sender
            ), (mode, family, seen, expected_sender)
    return addresses


try:
    save()
    if not args.resume:
        # New runs own all networks, storage and the bootstrap source
        # they create.
        configure_networks()
        source = make_source()
    else:
        # Resume only objects recorded in the retained fixture's state file.
        pool = connection.storagePoolLookupByName(prefix)
        source = connection.lookupByUUIDString(state['source'])
        if not state.get('ready'):
            # A failure before initial shutdown may have left
            # cloud-init running.
            finish_source(source)
    start_peers()
    networks = {
        mode: 'network:'
        + connection.networkLookupByName(
            'cn' + short + '-' + mode[0]
        ).UUIDString()
        for mode in ('nat', 'route', 'isolated')
    }
    networks['bridge'] = 'bridge:' + bridge
    cases = [(m, 'dhcp') for m in ('nat', 'route', 'isolated', 'bridge')]
    # Sequential cloning checks transitions from old static profiles back
    # to DHCP.
    cases += [(m, 'static') for m in ('nat', 'route', 'isolated', 'bridge')]
    cases += [
        ('nat', 'dhcp'),
        ('route', 'ipv6'),
        ('bridge', 'hostroutes'),
        ('bridge', 'static'),
        ('nat', 'ipv4'),
    ]
    old_addresses = set(state.get('addresses', []))
    for number, (mode, kind) in enumerate(cases):
        if number < args.start_case:
            # Explicit resumes can skip previously completed cases.
            continue
        print(f'CASE {number}: {mode} {kind}', flush=True)
        stop(source)
        before = digest(source)
        old_xml = source.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)
        choices = api('clone_options', {'id': source.UUIDString()})
        fields = settings(mode, kind, 30 + number)
        # Submit through the public controller with a fresh source revision.
        job = api(
            'clone',
            {
                'id': source.UUIDString(),
                'revision': choices['revision'],
                'name': prefix + '-' + str(number) + '-' + mode,
                'hostname': f'copy{number}.example.test',
                'username': 'clonefixture',
                'auth_type': 'keys',
                'ssh_keys': key.with_suffix('.pub').read_text(),
                'start': 1,
                'autostart': 0,
                'host_ssh_key': 0,
                'pool': pool.UUIDString(),
                **fields,
            },
        )
        state['jobs'].append(job['id'])
        save()
        job = wait_job(job)
        guest = connection.lookupByUUIDString(job['uuid'])
        state['domains'].append(guest.UUIDString())
        save()
        doc = ET.fromstring(guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
        # Check host attachment and MAC separately from guest network settings.
        old_mac = (
            ET.fromstring(old_xml)
            .find('./devices/interface/mac')
            .get('address')
        )
        assert doc.find('./devices/interface/mac').get('address') != old_mac
        attachment = doc.find('./devices/interface/source')
        assert attachment.get('bridge' if mode == 'bridge' else 'network') == (
            bridge if mode == 'bridge' else 'cn' + short + '-' + mode[0]
        )
        found = verify(guest, fields, mode, old_addresses)
        # A real restart also proves that old network profiles do not reappear.
        stop(guest)
        guest.create()
        verify(guest, fields, mode, old_addresses)
        stop(guest)
        assert source.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE) == old_xml
        assert digest(source) == before, 'Source disks changed during cloning'
        # Deleting the previous source is safe only for independent clone disks.
        for node in doc.findall('./devices/disk'):
            if node.find('readonly') is None:
                # Writable disks must be standalone before deleting
                # their source.
                info = json.loads(
                    run(
                        'qemu-img',
                        'info',
                        '--output=json',
                        node.find('source').get('file'),
                    )
                )
                assert not info.get('backing-filename'), (
                    'Clone still depends on its source disk'
                )
        print(
            f'PASS {number}: {mode} {kind}; addresses, DNS, traffic, reboot, source intact',
            flush=True,
        )
        previous, source = source, guest
        # The next case clones this result to expose stale-profile carryover.
        old_addresses = found
        state['source'] = source.UUIDString()
        state['addresses'] = sorted(found)
        save()
        # Keep just the latest source instead of accumulating thirteen copies.
        remove_source(previous)
    # Prepared copies reject multiple NICs; unchanged copies keep attachments.
    doc = ET.fromstring(source.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
    if len(doc.findall('./devices/interface')) == 1:
        # Add the second NIC once, including when resuming the final check.
        extra = ET.SubElement(doc.find('devices'), 'interface', type='network')
        ET.SubElement(extra, 'source', network='cn' + short + '-i')
        ET.SubElement(extra, 'model', type='virtio')
    source = connection.defineXML(ET.tostring(doc, encoding='unicode'))
    choices = api('clone_options', {'id': source.UUIDString()})
    fields = {
        'id': source.UUIDString(),
        'revision': choices['revision'],
        'name': prefix + '-unchanged',
        'pool': pool.UUIDString(),
        'network': choices['network'],
        'auth_type': 'keys',
        'username': 'clonefixture',
        'ssh_keys': key.with_suffix('.pub').read_text(),
        'start': 0,
        'autostart': 0,
    }
    try:
        api('clone', fields)
    except RuntimeError as error:
        # Prepared copies must reject multiple interfaces before any disk work.
        assert 'requires one network interface' in str(error), str(error)
    else:
        # Successful submission would bypass the supported preparation boundary.
        raise AssertionError('Prepared multi-NIC clone was accepted')
    unchanged = api(
        'clone', {**fields, 'clone_mode': 'unchanged', 'confirm_unchanged': 1}
    )
    # The explicit unchanged path preserves attachments but starts stopped.
    state['jobs'].append(unchanged['id'])
    save()
    unchanged = wait_job(unchanged)
    copy = connection.lookupByUUIDString(unchanged['uuid'])
    state['domains'].append(copy.UUIDString())
    save()
    assert not copy.isActive() and not copy.autostart()
    old = ET.fromstring(source.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
    new = ET.fromstring(copy.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
    assert [
        i.find('source').attrib for i in old.findall('./devices/interface')
    ] == [i.find('source').attrib for i in new.findall('./devices/interface')]
    old_macs = {
        i.get('address') for i in old.findall('./devices/interface/mac')
    }
    # Host identities still change while the copied seed remains byte-identical.
    new_macs = {
        i.get('address') for i in new.findall('./devices/interface/mac')
    }
    assert len(new_macs) == 2 and not old_macs.intersection(new_macs)
    old_seed = next(
        d.find('source').get('file')
        for d in old.findall('./devices/disk')
        if d.find('readonly') is not None
    )
    new_seed = next(
        d.find('source').get('file')
        for d in new.findall('./devices/disk')
        if d.find('readonly') is not None
    )
    assert Path(old_seed).read_bytes() == Path(new_seed).read_bytes(), (
        'Unchanged network seed was rewritten'
    )
    print(
        'PASS: multi-NIC preparation rejected; unchanged copy retains networks/seed and stays stopped',
        flush=True,
    )
    if args.start_case < len(cases):
        # Report the actual range when only a suffix of the matrix
        # was requested.
        print(
            f'PASS: clone network cases {args.start_case} through {len(cases)-1}',
            flush=True,
        )
finally:
    # Stop fixture listeners even when retaining guests for diagnosis.
    for process in processes:
        process.terminate()
        process.wait(timeout=10)
    safe = not (args.keep_on_failure and sys.exc_info()[0])
    # Active workers or incomplete recovery must retain their disks
    # and journals.
    for job_id in state['jobs']:
        job = api('status', {'job': job_id})
        safe = (
            safe
            and job['state'] in ('complete', 'failed', 'cancelled')
            and not job.get('cleanup_pending')
        )
    if safe:
        # Delete only recorded UUIDs and the private pool directory.
        for ident in state['domains']:
            domain = connection.lookupByUUIDString(ident)
            assert domain.name().startswith(prefix + '-')
            if domain.isActive():
                # Stop only a recorded fixture guest before removing
                # its volumes.
                domain.destroy()
            domain.undefineFlags(
                libvirt.VIR_DOMAIN_UNDEFINE_NVRAM
                | libvirt.VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA
            )
        if pool:
            # The private pool owns all copied disks under this
            # fixture directory.
            pool.destroy()
            pool.undefine()
        for ident in reversed(state['networks']):
            net = connection.networkLookupByUUIDString(ident)
            assert net.name().startswith('cn' + short + '-')
            if net.isActive():
                # Remove active fixture networks before undefining
                # their settings.
                net.destroy()
            net.undefine()
        if state.get('peer'):
            # Destroy the private namespace and its paired virtual links.
            run('ip', 'netns', 'delete', peer_ns)
        if state.get('bridge'):
            # This bridge was created by the fixture, never supplied by
            # the host.
            run('ip', 'link', 'delete', bridge)
        for path, value in state['sysctl'].items():
            # Restore forwarding values captured before any network creation.
            Path(path).write_text(value)
        jobs = state['jobs']
        shutil.rmtree(work)
        helper('cleanup', {'jobs': jobs})
        print('Fixture guests, jobs, networks and storage removed', flush=True)
    else:
        # Keep recorded IDs and disks together so recovery can inspect them.
        print('Retained fixture: ' + str(work), flush=True)
    connection.close()
