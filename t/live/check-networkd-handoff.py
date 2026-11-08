#!/usr/bin/python3
"""Test DHCP bridge handoff and recovery with private networkd and DHCP services.

Run as root on an authorized Linux test host. Mount, network and PID namespaces
keep its management interface, services and configuration outside the fixture.
Requires systemd-networkd, networkctl, dbus-daemon, dnsmasq and unshare.
"""

import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import time


# run(*args) runs a command with a timeout and captures error output.
def run(*args):
    try:
        return subprocess.check_output(
            args, stderr=subprocess.STDOUT, text=True, timeout=25
        ).strip()
    except subprocess.CalledProcessError as error:
        # Keep the worker's diagnostic, not just its nonzero exit status.
        raise RuntimeError(error.output) from error


# write(path, text) saves fixture settings and creates missing directories.
def write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


# lease(interface) waits for a real DHCP address, without adding one manually.
def lease(interface):
    for _ in range(80):
        links = json.loads(run('ip', '-j', 'address', 'show', 'dev', interface))
        addresses = [
            a['local']
            for link in links
            for a in link['addr_info']
            if a['family'] == 'inet'
        ]
        # The fixture uses DHCP alone, so its first IPv4 address is the lease.
        if addresses:
            return addresses[0]
        time.sleep(.25)
    raise RuntimeError('No DHCP lease for ' + interface)


# scenario(module, work, mode) tests DHCP handoff and address recovery.
# module and work are paths. mode is control, fixed, recovery, recovery-bridge
# or refusal; each case runs in its own namespaces.
def scenario(module, work, mode):
    fixed = mode == 'fixed'
    # Refuse mounts unless unshare gave us a new PID and empty
    # network namespace.
    assert os.getpid() == 1, 'Private PID namespace required'
    assert len(json.loads(run('ip', '-j', 'link'))) == 1, (
        'Empty network namespace required'
    )
    run('mount', '--make-rprivate', '/')
    run('mount', '-t', 'tmpfs', 'tmpfs', '/run')
    for name, target in (
        ('network', '/etc/systemd/network'),
        ('empty', '/usr/lib/systemd/network'),
    ):
        (work / name).mkdir()
        run('mount', '--bind', str(work / name), target)
    # Read-only sysfs tells networkd there is no udev managing these
    # private links.
    run('mount', '-t', 'sysfs', '-o', 'ro', 'sysfs', '/sys')
    # Create private service directories; networkd must own its state directory.
    Path('/run/dbus').mkdir()
    Path('/run/systemd/netif').mkdir(parents=True)
    account = pwd.getpwnam('systemd-network')
    os.chown('/run/systemd/netif', account.pw_uid, account.pw_gid)
    # Connect the client to a private DHCP server without using a physical NIC.
    run('ip', 'link', 'set', 'lo', 'up')
    run(
        'ip',
        'link',
        'add',
        'cmport',
        'type',
        'veth',
        'peer',
        'name',
        'cmserver',
    )
    run('ip', 'link', 'set', 'cmport', 'address', '02:11:22:33:44:55')
    # A separate server namespace lets unicast DHCPRELEASE reach the server
    # over Ethernet, rather than being routed through the client's loopback.
    run('ip', 'netns', 'add', 'cmserver')
    run('ip', 'link', 'set', 'cmserver', 'netns', 'cmserver')
    run(
        'ip',
        '-n',
        'cmserver',
        'address',
        'add',
        '192.0.2.1/24',
        'dev',
        'cmserver',
    )
    run('ip', '-n', 'cmserver', 'link', 'set', 'cmserver', 'up')
    run('ip', '-n', 'cmserver', 'link', 'set', 'lo', 'up')

    # Start at .13 with a fixed identity so a changed lease is easy to detect.
    identity = (
        '[DHCPv4]\nClientIdentifier=duid\nIAID=1448103320\n'
                'DUIDType=2\nDUIDRawData=00:00:ab:11:99:dd:4e:25:4d:61:3d:98\n'
    )
    options = 'UseDNS=no\nUseRoutes=no\nUseHostname=no\n'
    port = (
        '[Match]\nName=cmport\n[Network]\nDHCP=ipv4\nLinkLocalAddressing=no\n'
    )
    write(
        '/etc/systemd/network/10-port.network',
        port + identity + options + 'RequestAddress=192.0.2.13\n',
    )
    # Disable DNS and host config loading; keep leases and logs in this fixture.
    server_args = [
        'ip',
        'netns',
        'exec',
        'cmserver',
        'dnsmasq',
        '--keep-in-foreground',
        '--conf-file=/dev/null',
        '--port=0',
        '--bind-interfaces',
        '--user=root',
        '--interface=cmserver',
        '--dhcp-range=192.0.2.12,192.0.2.40,255.255.255.0,5m',
        '--dhcp-sequential-ip',
        '--dhcp-option=3',
        '--dhcp-option=6',
        '--dhcp-authoritative',
        '--log-dhcp',
        '--log-facility=-',
        '--dhcp-leasefile=' + str(work / 'leases'),
        '--pid-file=' + str(work / 'dnsmasq.pid'),
    ]
    processes, logs = [], []
    try:
        # All service sockets and leases are private; no host service
        # is started.
        for name, args in [
            ('dbus', ['dbus-daemon', '--system', '--nofork', '--nopidfile']),
            ('dnsmasq', server_args),
            ('networkd', ['/usr/lib/systemd/systemd-networkd']),
        ]:
            log = open(work / (name + '.log'), 'w')
            logs.append(log)
            processes.append(subprocess.Popen(args, stdout=log, stderr=log))
            time.sleep(.5)
        assert lease('cmport') == '192.0.2.13', 'Initial lease differs'
        # Capture the production-generated identity before moving the address.
        before = json.loads(
            run('networkctl', '--json=short', 'status', 'cmport')
        )
        settings = (
            run(
                'perl',
                str(module / 't/live/networkd-dhcp-settings.pl'),
                str(module),
                'cmport',
                '02:11:22:33:44:55',
            )
            + '\n'
        )
        assert 'RequestAddress=192.0.2.13\n' in settings
        # Control and recovery modes first reproduce the old address handoff.
        if not fixed:
            settings = ''.join(
                line + '\n'
                for line in settings.splitlines()
                if not line.startswith('RequestAddress=')
            )

        # A restarted DHCP server has forgotten the client's previous lease.
        processes[1].terminate()
        processes[1].wait(timeout=5)
        (work / 'leases').unlink()
        processes[1] = subprocess.Popen(
            server_args, stdout=logs[1], stderr=logs[1]
        )
        time.sleep(.5)
        # Move DHCP to the bridge after the server has discarded its lease map.
        write(
            '/etc/systemd/network/10-bridge.netdev',
            '[NetDev]\nName=cmbridge\nKind=bridge\nMACAddress=02:11:22:33:44:55\n'
              '[Bridge]\nSTP=no\n',
        )
        write(
            '/etc/systemd/network/10-bridge.network',
            '[Match]\nName=cmbridge\n[Network]\nDHCP=ipv4\nLinkLocalAddressing=no\n'
            + settings
            + options,
        )
        write(
            '/etc/systemd/network/10-port.network',
            '[Match]\nName=cmport\n[Network]\nBridge=cmbridge\nLinkLocalAddressing=no\n',
        )
        run('networkctl', 'reload')
        # The address request should be the only cause of a different lease.
        expected = '192.0.2.13' if fixed else '192.0.2.12'
        assert lease('cmbridge') == expected, 'Bridge lease differs'
        after = json.loads(
            run('networkctl', '--json=short', 'status', 'cmbridge')
        )
        assert (
            before['DHCPv4Client']['ClientIdentifier']
            == after['DHCPv4Client']['ClientIdentifier']
        )

        target = 'cmbridge' if mode == 'recovery-bridge' else 'cmport'
        if target == 'cmport':
            # Creation rollback restores the source profile without its
            # initial hint.
            Path('/etc/systemd/network/10-bridge.network').unlink()
            Path('/etc/systemd/network/10-bridge.netdev').unlink()
            write(
                '/etc/systemd/network/10-port.network',
                port + identity + options,
            )
            run('networkctl', 'reload')
            run('ip', 'link', 'delete', 'cmbridge')
        # Removal rollback instead recovers a lease on the existing bridge.
        restored = lease(target)
        if mode != 'control':
            # Run production rollback's DHCP recovery after restoring the file.
            # Restoring the file alone can acquire .12 even after a .13 handoff.
            if mode != 'fixed':
                # Prove recovery corrects a wrong lease, not just a missing one.
                assert restored == '192.0.2.12', (
                    'Recovery fixture needs a wrong active lease'
                )
            if mode == 'refusal':
                # Reserve the old address for another client; recovery
                # must fail.
                processes[1].terminate()
                processes[1].wait(timeout=5)
                processes[1] = subprocess.Popen(
                    server_args + ['--dhcp-host=02:99:88:77:66:55,192.0.2.13'],
                    stdout=logs[1],
                    stderr=logs[1],
                )
                time.sleep(.5)
            try:
                run(
                    'perl',
                    str(module / 't/live/networkd-dhcp-settings.pl'),
                    str(module),
                    target,
                    '02:11:22:33:44:55',
                    '192.0.2.13',
                    'remove' if target == 'cmbridge' else 'create',
                )
            except RuntimeError as error:
                # Server refusal must retain the missing-address diagnostic.
                assert mode == 'refusal' and '192.0.2.13/24 is missing' in str(
                    error
                ), str(error)
            else:
                # Claim success only when the server was allowed to return
                # the IP.
                assert mode != 'refusal', (
                    'Recovery falsely accepted a different address'
                )
            expected = '192.0.2.12' if mode == 'refusal' else '192.0.2.13'
            assert lease(target) == expected, (
                'Recovery ended with the wrong address'
            )
            status = json.loads(
                run('networkctl', '--json=short', 'status', target)
            )
            assert (
                status['DHCPv4Client']['ClientIdentifier']
                == before['DHCPv4Client']['ClientIdentifier']
            )
            # The temporary hint must disappear without disturbing the lease.
            assert not list(
                Path('/run/systemd/network').glob(
                    '*.network.d/90-cloudmin-restore-*'
                )
            )
            time.sleep(2)
            assert lease(target) == expected, (
                'Removing the hint changed the lease'
            )
            if mode != 'fixed':
                # A valid release must reach dnsmasq, including its server ID.
                assert (
                    'DHCPRELEASE(cmserver) 192.0.2.12'
                    in (work / 'dnsmasq.log').read_text()
                )
            print(
                mode.capitalize()
                + ': lease, identity and cleanup checks passed',
                flush=True,
            )
            return
        # Without the fix, restoring files alone retains the changed address.
        assert restored == expected, 'Control rollback lease differs'
        print(
            ('Fixed' if fixed else 'Control')
            + ': bridge and rollback use '
            + expected,
            flush=True,
        )
    finally:
        # Namespace teardown also removes every fixture interface and mount.
        for process in reversed(processes):
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Bound cleanup if a fixture daemon ignores termination.
                process.kill()
                process.wait()
        for log in logs:
            log.close()


# main() runs each handoff and recovery case in a separate private namespace.
def main():
    assert sys.platform == 'linux' and os.geteuid() == 0, (
        'Linux test guest as root only'
    )
    module = Path(__file__).resolve().parents[2]
    # The child invocation performs one scenario after unshare isolates it.
    if len(sys.argv) == 4 and sys.argv[1] == '--namespace':
        scenario(module, Path(sys.argv[2]), sys.argv[3])
        return
    # Each scenario gets fresh daemon state and a bounded namespace lifetime.
    for mode in ('control', 'fixed', 'recovery', 'recovery-bridge', 'refusal'):
        with tempfile.TemporaryDirectory(
            prefix='cloudmin-dhcp-handoff-', dir='/var/tmp'
        ) as work:
            result = subprocess.run(
                [
                    'unshare',
                    '--mount',
                    '--net',
                    '--pid',
                    '--fork',
                    '--kill-child=SIGKILL',
                    '--mount-proc',
                    sys.executable,
                    str(Path(__file__).resolve()),
                    '--namespace',
                    work,
                    mode,
                ],
                timeout=90,
            )
            # Preserve useful diagnostics without leaving services or
            # fixtures running.
            if result.returncode:
                for log in Path(work).glob('*.log'):
                    print(
                        log.name + ':\n' + log.read_text()[-6000:],
                        file=sys.stderr,
                    )
                raise SystemExit(result.returncode)
    print('DHCP handoff and rollback tests passed; fixture namespaces removed.')


# Direct execution creates namespaces before any fixture network changes.
if __name__ == '__main__':
    main()
