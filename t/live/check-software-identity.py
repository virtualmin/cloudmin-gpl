#!/usr/bin/python3
"""
Boot an isolated guest, verify its public host key and run short Perl setup.
"""

import argparse
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


# run(args, [**options]) captures fixture output with a default
# 60-second timeout.
def run(args, **options):
    return subprocess.run(
        args,
        check=True,
        text=True,
        capture_output=True,
        timeout=options.pop('timeout', 60),
        **options,
    ).stdout


# main() changes only a new guest and its files on the disposable test host.
def main():
    # This fixture allocates a guest and storage only on the selected test host.
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise SystemExit('Run as root on a disposable Linux test host')
    import libvirt

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('--webmin', default='/usr/libexec/webmin')
    parser.add_argument('--apt-lock', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    # Fail before allocating a guest if its scripted setup cannot be seeded.
    if (
        not (root / 'pro/SetupScripts.pm').is_file()
        or not (root / 'pro/guest-scripts.pl').is_file()
    ):
        raise SystemExit(
            'This guest script identity test requires Cloudmin Pro'
        )
    image = args.image.resolve(strict=True)
    connection = libvirt.open('qemu:///system')
    network = connection.networkLookupByName('default')
    assert network.isActive(), 'Requires the existing default test network'
    directory = Path(
        tempfile.mkdtemp(
            prefix='cloudmin-identity-', dir='/var/lib/libvirt/images'
        )
    )
    directory.chmod(0o755)
    identity = str(uuid.uuid4())
    name = 'cloudmin-identity-' + identity[:8]
    console = Path('/var/log/libvirt/qemu') / (name + '-console.log')
    guest = None
    try:
        # Fixture credentials are generated on the test machine and
        # never printed.
        worker = directory / 'worker'
        worker.mkdir(mode=0o700)
        key = worker / 'identity'
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)])
        request = dict(
            username='setupfixture',
            hostname='setup-fixture',
            auth_type='keys',
            mac='52:54:00:33:' + identity[:2] + ':' + identity[2:4],
            address_mode='dhcp',
            host_public_key=key.with_suffix('.pub').read_text(),
            software='none',
            before_script='printf before > /var/lib/cloudmin-install/before.txt',
            packages='tree',
            after_script='test -f /var/lib/cloudmin-install/before.txt\ntree --version',
        )
        # Exercise production seed generation, including its
        # public-key boundary.
        seed_code = r'''
            use WebminCore;
            require "$ARGV[0]/lib/Cloudmin/VMs.pm";
            my $request = convert_from_json(do { local $/; <STDIN> });
            print convert_to_json(Cloudmin::VMs::seed_data($request, $ARGV[1]), 0, 1);
        '''
        data = json.loads(
            run(
                [
                    'perl',
                    '-I' + args.webmin,
                    '-e',
                    seed_code,
                    str(root),
                    identity,
                ],
                input=json.dumps(request),
            )
        )
        assert 'PRIVATE KEY-----' not in data['user-data'], (
            'Private host key leaked into seed'
        )
        assert '"ssh_keys"' not in data['user-data'], (
            'Seed replaces default SSH host key generation'
        )
        for filename, contents in data.items():
            (directory / filename).write_text(contents)
        seed, disk = directory / 'seed.iso', directory / 'root.qcow2'
        # Use a writable overlay so the supplied source image stays unchanged.
        run(
            [
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
                *[str(directory / filename) for filename in data],
            ]
        )
        run(
            [
                'qemu-img',
                'create',
                '-f',
                'qcow2',
                '-F',
                'qcow2',
                '-b',
                str(image),
                str(disk),
                '12G',
            ]
        )
        arch = connection.getInfo()[0]
        machine = 'virt' if arch == 'aarch64' else 'q35'
        console.touch(mode=0o666)
        console.chmod(0o666)
        # Match production firmware settings for cloud images without
        # Secure Boot.
        guest = connection.defineXML(f'''<domain type="kvm"><name>{name}</name><uuid>{identity}</uuid>
          <memory unit="MiB">1024</memory><vcpu>2</vcpu><cpu mode="host-passthrough"/>
          <os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type>
            <firmware><feature enabled="no" name="secure-boot"/><feature enabled="no" name="enrolled-keys"/></firmware>
          </os><features><acpi/></features><devices>
          <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{disk}"/><target dev="vda" bus="virtio"/></disk>
          <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seed}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
          <interface type="network"><source network="default"/><mac address="{request['mac']}"/><model type="virtio"/></interface>
          <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
          <serial type="file"><source path="{console}" append="on"/></serial>
          <memballoon model="virtio"/></devices></domain>''')
        guest.create()
        print('Started isolated guest ' + name, flush=True)
        # Poll through the production libvirt path while cloud-init
        # prepares identity.
        probe = r'''
            use WebminCore;
            $WebminCore::null_file = '/dev/null';
            require "$ARGV[0]/lib/Cloudmin/Libvirt.pm";
            print substr(convert_to_json([ Cloudmin::Libvirt->new(readonly => 0)->get_setup_host_key($ARGV[1]) ], 0, 1), 1, -1);
        '''
        deadline = time.monotonic() + 300
        public = None
        while time.monotonic() < deadline:
            public = json.loads(
                run(
                    [
                        'perl',
                        '-I' + args.webmin,
                        '-e',
                        probe,
                        str(root),
                        identity,
                    ]
                )
            )
            if public:
                # Proceed only after the returned identity matches the
                # guest UUID.
                break
            time.sleep(3)
        if not public:
            # This fixture has no passwords or license inputs in its
            # boot output.
            if console.exists():
                print(console.read_text(errors='replace')[-10000:], flush=True)
            raise AssertionError(
                'Guest did not publish a verified public identity within five minutes'
            )
        # Exercise real libvirt stderr, including final-attempt diagnostics.
        error_probe = r'''
            use WebminCore;
            $WebminCore::null_file = '/dev/null';
            require "$ARGV[0]/lib/Cloudmin/Libvirt.pm";
            my $adapter = Cloudmin::Libvirt->new(readonly => 0);
            for my $case (
                ['guest-file-open', {path => '/var/log/qemu-ga/cloudmin-missing-fixture.json', mode => 'r'},
                 qr/No such file or directory/],
                ['guest-file-read', {handle => 2147483647, count => 1},
                 qr/(?:handle.*has not been found|invalid handle)/i]) {
                my ($command, $arguments, $diagnostic) = @$case;
                my $reply = $adapter->setup_agent_command($ARGV[1], $command, $arguments);
                die "Guest error was not retryable\n" if defined($reply);
                my $ok = eval { $adapter->setup_agent_command($ARGV[1], $command, $arguments, 1); 1 };
                die "Final attempt lost the guest diagnostic: $@\n" if $ok || $@ !~ $diagnostic;
            }
        '''
        run(
            ['perl', '-I' + args.webmin, '-e', error_probe, str(root), identity]
        )
        print(
            'PASS: real missing-file and lost-handle errors retry and retain their final diagnostics',
            flush=True,
        )
        interfaces = guest.interfaceAddresses(
            libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT, 0
        )
        address = next(
            a['addr']
            for interface in interfaces.values()
            for a in interface['addrs']
            if a['type'] == libvirt.VIR_IP_ADDR_TYPE_IPV4
            and not a['addr'].startswith('127.')
        )
        # Use the actual unprivileged monitor with strict
        # known_hosts verification.
        (worker / 'request.json').write_text(
            json.dumps(
                dict(
                    address=address,
                    username='setupfixture',
                    uuid=identity,
                    host_public_key=public,
                )
            )
        )
        nobody = pwd.getpwnam('nobody')
        for path in [worker, *worker.iterdir()]:
            os.chown(path, nobody.pw_uid, nobody.pw_gid)
        output = run(
            [
                'runuser',
                '-u',
                'nobody',
                '--',
                'perl',
                str(root / 'software-worker.pl'),
            ],
            cwd=worker,
            timeout=180,
        )
        result = json.loads(output.splitlines()[-1])
        assert result.get('data', {}).get('stage') == 'complete', output
        print(
            'PASS: seed has no private host key; libvirt public-key verification and Perl setup completed',
            flush=True,
        )
        ssh = [
            'ssh',
            '-F',
            '/dev/null',
            '-i',
            str(key),
            '-o',
            'BatchMode=yes',
            '-o',
            'StrictHostKeyChecking=yes',
            '-o',
            'UserKnownHostsFile=' + str(worker / 'known_hosts'),
            '-o',
            'HostKeyAlias=' + identity,
            '-o',
            'ConnectTimeout=5',
            'setupfixture@' + address,
        ]
        keys = run(
            ssh
            + [
                'sudo -n ls /etc/ssh/ssh_host_rsa_key.pub /etc/ssh/ssh_host_ed25519_key.pub'
            ]
        )
        assert 'ed25519' in keys, 'Guest lost its normal modern SSH host key'
        if args.apt_lock:
            # Hold a real dpkg frontend lock while the production install
            # command runs.
            lock_check = r'''
import fcntl, json, os, subprocess, time
read_fd, write_fd = os.pipe()
pid = os.fork()
# The child holds the package-manager lock for the contention test.
if not pid:
    os.close(read_fd)
    with open('/var/lib/dpkg/lock-frontend', 'w') as lock:
        fcntl.lockf(lock, fcntl.LOCK_EX)
        os.write(write_fd, b'ready')
        time.sleep(4)
    os._exit(0)
os.close(write_fd)
os.read(read_fd, 5)
started = time.monotonic()
try:
    code = 'require "/usr/local/lib/cloudmin/guest-software.pl"; print JSON::PP::encode_json(Cloudmin::GuestSoftware::package_commands("tree"));'
    command = json.loads(subprocess.check_output(['perl', '-e', code]))[-1]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    assert result.returncode == 0, result.stdout.decode()
    assert time.monotonic() - started >= 3, 'APT did not wait for the held package lock'
finally:
    os.waitpid(pid, 0)
print('PASS: production APT command waits for a real package lock')
'''
            result = subprocess.run(
                ssh + ['sudo -n python3 -'],
                input=lock_check,
                text=True,
                capture_output=True,
                timeout=60,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip(), flush=True)
        # Reboot must retain both the seed and the guest-generated
        # host identity.
        guest.reboot(0)
        time.sleep(15)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                answer = run(ssh + ['true'], timeout=15)
                break
            except subprocess.CalledProcessError:
                time.sleep(3)
        else:
            # Exhausted retries must fail instead of claiming reboot
            # preserved trust.
            raise AssertionError('Pinned SSH did not return after reboot')
        print(
            'PASS: normal RSA and Ed25519 host keys retained across reboot',
            flush=True,
        )
    finally:
        # Remove only this fixture's domain, writable files and console output.
        if guest is not None:
            # Release QEMU's file handles before undefining and
            # removing storage.
            if guest.isActive():
                guest.destroy()
            guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
        connection.close()
        shutil.rmtree(directory)
        if console.exists():
            # Boot failure can leave a console file even after domain removal.
            console.unlink()


# Importing helper functions must not allocate a guest.
if __name__ == '__main__':
    main()
