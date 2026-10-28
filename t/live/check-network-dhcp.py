"""Test bridge DHCP identity on an isolated veth pair in a disposable Linux VM."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

# Network namespaces and fixture links require a Linux test guest.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Disposable Linux guest as root only')


# run(*args, [check]) bounds commands and reports fixture failures with stderr.
def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=120)
    # Keep stdout and stderr available when a required fixture command fails.
    if check and result.returncode:
        raise RuntimeError(str(args) + ': ' + result.stdout + result.stderr)
    return result.stdout.strip()


module = sys.argv[1]
suffix = str(os.getpid())
source, peer, bridge = 'cmd' + suffix, 'cmp' + suffix, 'cmb' + suffix
namespace = 'cloudmin-dhcp-' + suffix
profile = 'cloudmin-dhcp-' + suffix
server = None
try:
    with tempfile.TemporaryDirectory(prefix='cloudmin-dhcp-', dir='/var/tmp') as work:
        run('ip', 'netns', 'add', namespace)
        run('ip', 'link', 'add', source, 'type', 'veth', 'peer', 'name', peer)
        run('ip', 'link', 'set', peer, 'netns', namespace)
        run('ip', '-n', namespace, 'link', 'set', 'lo', 'up')
        run('ip', '-n', namespace, 'link', 'set', peer, 'up')
        run('ip', '-n', namespace, 'address', 'add', '192.0.2.1/24', 'dev', peer)
        with open(Path(work) / 'dnsmasq.log', 'w+') as log:
            # No routing or DNS options can affect the host's management network.
            server = subprocess.Popen([
                'ip', 'netns', 'exec', namespace, 'dnsmasq', '--keep-in-foreground',
                '--conf-file=/dev/null', '--port=0', '--bind-interfaces', '--user=root',
                '--interface=' + peer, '--dhcp-range=192.0.2.10,192.0.2.40,255.255.255.0,5m',
                '--dhcp-option=3', '--dhcp-option=6', '--dhcp-authoritative',
                '--dhcp-leasefile=' + work + '/leases', '--pid-file=' + work + '/pid',
            ], stdout=log, stderr=log)
            for mode in ('default', 'duid', 'stable', 'none'):
                run('nmcli', 'connection', 'add', 'type', 'ethernet', 'ifname', source,
                    'con-name', profile, 'connection.autoconnect', 'no',
                    'ipv4.method', 'auto', 'ipv4.never-default', 'yes',
                    'ipv4.ignore-auto-dns', 'yes', 'ipv6.method', 'disabled')
                # Leave the default client ID untouched for the baseline case.
                if mode != 'default':
                    run('nmcli', 'connection', 'modify', profile, 'ipv4.dhcp-client-id', mode)
                run('nmcli', '--wait', '30', 'connection', 'up', profile)
                print(run('perl', str(Path(__file__).with_name('network-dhcp-fixture.pl')),
                          module, source, bridge, mode), flush=True)
                run('nmcli', 'connection', 'delete', profile)
finally:
    # Remove only named fixture profiles and links, even after a failed assertion.
    for name in (profile, 'cloudmin-' + bridge):
        profiles = run('nmcli', '-t', '-f', 'NAME', 'connection', 'show').splitlines()
        # Remove only profiles created by this fixture.
        if name in profiles:
            run('nmcli', 'connection', 'delete', name)
    # Stop the fixture DHCP server before removing its interfaces.
    if server:
        server.terminate()
        server.wait(timeout=5)
    for name in (source, bridge):
        # Delete a fixture link only if it survived earlier cleanup.
        if Path('/sys/class/net/' + name).exists():
            run('ip', 'link', 'delete', name)
    # Remove the private namespace after its processes and links are gone.
    if namespace in run('ip', 'netns', 'list').split():
        run('ip', 'netns', 'delete', namespace)
