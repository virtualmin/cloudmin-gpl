"""Inspect the actual isolated relay while a fixture connection is active."""
import os
from pathlib import Path
import re
import subprocess


# check_relay(kind, [port]) verifies the service identity and filesystem view.
# A proxy port selects this fixture's relay when other browser sessions are open.
# Returns (unit, pid, uid); kind is console or terminal.
# Without port, exactly one running relay of that kind must exist.
def check_relay(kind, port=None):
    assert kind in ('console', 'terminal')
    units = subprocess.check_output(['systemctl', 'list-units', '--plain', '--no-legend',
                                    '--state=running', 'cloudmin-' + kind + '-*.service'], text=True).splitlines()
    candidates = []
    # The inherited listener belongs to the host network namespace, even when
    # the relay has PrivateNetwork=yes. Its inode identifies the fixture's relay.
    inodes = set()
    if port is not None:
        # Read the host-side listener table, not the relay's private namespace.
        for line in Path('/proc/net/tcp').read_text().splitlines()[1:]:
            fields = line.split()
            if fields[1] == '0100007F:%04X' % int(port) and fields[3] == '0A':
                # Match loopback LISTEN sockets, excluding client sockets.
                inodes.add('socket:[' + fields[9] + ']')
    # Match the inherited listener descriptor to the selected fixture route.
    for row in units:
        unit = row.split()[0]
        pid = subprocess.check_output(['systemctl', 'show', unit, '-p', 'MainPID', '--value'], text=True).strip()
        try:
            if port is None or os.readlink('/proc/' + pid + '/fd/0') in inodes:
                # With no port, retain every candidate so ambiguity still fails.
                candidates.append((unit, pid))
        except FileNotFoundError:
            # Another session may close between listing and descriptor lookup.
            continue
    assert len(candidates) == 1, 'Expected one fixture relay service'
    unit, pid = candidates[0]
    proc = Path('/proc') / pid
    # Check actual process credentials and capabilities, not just unit settings.
    status = proc.joinpath('status').read_text()
    uid = int(re.search(r'^Uid:\s+(\d+)', status, re.M)[1])
    gid = int(re.search(r'^Gid:\s+(\d+)', status, re.M)[1])
    assert uid > 0 and gid > 0, 'Browser relay still runs as root'
    assert all(int(value) == uid for value in re.search(r'^Uid:\s+(.+)', status, re.M)[1].split())
    assert int(re.search(r'^CapEff:\s+(\w+)', status, re.M)[1], 16) == 0
    assert int(re.search(r'^CapBnd:\s+(\w+)', status, re.M)[1], 16) == 0
    assert re.search(r'^NoNewPrivs:\s+1$', status, re.M)
    # The service must execute the relay without inheriting the CGI environment.
    command = proc.joinpath('cmdline').read_bytes().split(b'\0')
    assert any(arg.endswith((kind + '-relay.pl').encode()) for arg in command)
    environment = proc.joinpath('environ').read_bytes().split(b'\0')
    assert not any(item.startswith((b'SESSION_ID=', b'HTTP_COOKIE=', b'WEBMIN_CONFIG=')) for item in environment)
    # Enter the service's mount namespace as its UID and test credential access.
    probe = '''import os
from pathlib import Path
assert not os.access('/etc/webmin',os.R_OK)
assert not os.access('/var/webmin',os.R_OK)
assert not os.access('/run/libvirt/libvirt-sock',os.R_OK)
assert not os.access('/run/systemd/private',os.R_OK)
p=Path('/run/credentials') / %r / 'session'
assert p.is_file() and os.access(p,os.R_OK)
''' % unit
    subprocess.run(['nsenter', '-t', pid, '-m', '--', 'setpriv', '--reuid', str(uid),
                    '--regid', str(gid), '--clear-groups', 'python3', '-c', probe], check=True)
    # The console accepts its inherited socket but cannot open host-network ones.
    if kind == 'console':
        assert os.readlink(proc / 'ns/net') != os.readlink('/proc/1/ns/net')
    print('PASS: non-root ' + kind + ' relay, no capabilities, private credentials and no host control sockets', flush=True)
    return unit, pid, uid
