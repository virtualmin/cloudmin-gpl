#!/usr/bin/python3
"""Check clone identity, source recovery and offline Virtualmin preparation."""
import argparse
import json
import os
import secrets
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
from xml.etree import ElementTree as ET

# Snapshot and guest mutations belong on the authorized Linux test host.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt
import libvirt_qemu
libvirt.registerErrorHandler(lambda context, error: None, None)

module = Path(__file__).resolve().parents[2]
# Webmin libraries need their environment and a full script path under the root.
HOSTID_PROBE = ("WEBMIN_CONFIG=/etc/webmin WEBMIN_VAR=/var/webmin REMOTE_USER=root perl -e '"
                "package virtual_server; $main::no_acl_check = 1; "
                "$0 = q(/usr/libexec/webmin/virtual-server/clone-hostid.pl); "
                "chdir q(/usr/libexec/webmin/virtual-server); require q(./virtual-server-lib.pl); "
                "print get_licence_hostid()'")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=Path)
parser.add_argument('--resume-fixture', type=Path, help='Resume an owned source fixture retained before cloning')
parser.add_argument('--capture-faults-only', action='store_true', help='Run only Pro capture failure and recovery scenarios')
parser.add_argument('--capture-images', action='store_true', help='Run the installed Pro image capture scenarios with this source fixture')
parser.add_argument('--identity-only', action='store_true', help='Check a cold prepared clone and a stopped copy')
parser.add_argument('--virtualmin', action='store_true', help='Install and verify Virtualmin GPL in the disposable source')
parser.add_argument('--virtualmin-pro-source', type=Path, help='Pro module source archive for a disposable fake-license fixture')
parser.add_argument('--virtualmin-licence-library', type=Path, help='Offline license API to install in the fixture')
parser.add_argument('--virtualmin-hostname', action='store_true', help='Also test the hostname domain and a hosted website')
parser.add_argument('--network', required=True, help='Existing network for the disposable guest')
parser.add_argument('--allow-host-jobs', action='store_true', help='Allow integration jobs in the host journal')
parser.add_argument('--keep-on-failure', action='store_true', help='Retain owned fixtures for diagnosis after a failed assertion')
parser.add_argument('--snapshot-chain', action='store_true', help='Preserve an existing external snapshot while cloning')
options = parser.parse_args()
options.virtualmin = options.virtualmin or options.virtualmin_hostname or bool(options.virtualmin_pro_source)
# This uses real controller jobs; their audit history remains after cleanup.
if not options.allow_host_jobs:
    parser.error('This integration test requires --allow-host-jobs; its audit history remains on the host')
image = options.image.resolve(strict=True)
connection = libvirt.open('qemu:///system')
network = connection.networkLookupByName(options.network)
# Do not start or alter the existing network selected for the fixture.
if not network.isActive():
    raise SystemExit('The selected fixture network must already be active')
# Escape the existing network name through XML serialization.
network_source = ET.tostring(ET.Element('source', network=network.name()), encoding='unicode')
directory = options.resume_fixture or Path(tempfile.mkdtemp(prefix='cloudmin-clone-test-', dir='/var/lib/libvirt/images'))
# Refuse to reuse or clean up a directory outside this fixture namespace.
if directory.parent != Path('/var/lib/libvirt/images') or not directory.name.startswith('cloudmin-clone-test-'):
    raise SystemExit('Not an owned clone fixture directory')
directory.chmod(0o755)
ident = ((directory/'meta-data').read_text().splitlines()[0].split(': ',1)[1]
         if options.resume_fixture else str(uuid.uuid4()))
name = 'cloudmin-clone-test-' + ident[:8]
pool = guest = source_guest = None
clones = []
jobs = []


# api(action, fields) exercises the production controller and detached worker.
def api(action, fields):
    result = subprocess.run(['perl', str(module / 'api.pl'), action],
                            input=json.dumps(fields), text=True, capture_output=True, timeout=45)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)['result']


# wait_job(job) follows the same public progress contract as the browser.
def wait_job(job):
    deadline = time.monotonic() + 900
    while job['state'] not in ('complete', 'failed', 'cancelled') and time.monotonic() < deadline:
        time.sleep(.5)
        job = api('status', {'job': job['id']})
    assert job['state'] == 'complete', job.get('error', job['state'])
    return job


# agent_ready() waits for the fixture to boot or return from snapshot restore.
def agent_ready():
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        try:
            # A restored guest may need to reconnect its agent channel.
            if guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0):
                return
        except libvirt.libvirtError:
            # Startup and restore can temporarily make the agent unavailable.
            pass
        time.sleep(2)
    raise AssertionError('Fixture QEMU Guest Agent did not respond')


# stop_guest(domain) flushes first-boot writes before reusing a fixture's disks.
def stop_guest(domain):
    domain.shutdown()
    deadline = time.monotonic()+120
    while domain.isActive() and time.monotonic() < deadline:
        time.sleep(1)
    assert not domain.isActive(), 'Fixture did not shut down cleanly'


# guest_command(command, [input_text]) runs root commands in the fixture over SSH.
# Optional text is passed on stdin; commands use a key created on the test host.
def guest_command(command, input_text=None):
    deadline = time.monotonic() + 300
    diagnostic = 'No guest lease reported'
    while time.monotonic() < deadline:
        interfaces = guest.interfaceAddresses(libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE, 0)
        addresses = [address['addr'] for interface in interfaces.values()
                     for address in interface['addrs'] if address['type'] == libvirt.VIR_IP_ADDR_TYPE_IPV4]
        if addresses:
            # Connect only to the fixture address reported by its libvirt lease.
            result = subprocess.run(['ssh', '-F', '/dev/null', '-i', str(key),
                '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                'clonefixture@'+addresses[0], 'sudo -n sh -c '+shlex.quote(command)],
                input=input_text, text=True, capture_output=True, timeout=1800 if 'virtualmin-install' in command else 600 if 'cloud-init status --wait' in command or 'clone-virtualmin-fixture.pl setup' in command else 120)
            # A connection failure can mean SSH is still starting after restore.
            if result.returncode != 255:
                assert result.returncode == 0, result.stderr
                return result.stdout.strip()
            diagnostic = result.stderr.strip()
        time.sleep(2)
    raise AssertionError('Fixture SSH did not become ready: '+diagnostic)


try:
    if not options.resume_fixture:
        # Build a private two-disk source without changing the original image.
        pool = connection.storagePoolDefineXML(f'<pool type="dir"><name>{name}</name><target><path>{directory}</path></target></pool>', 0)
        pool.create(0)
        disk = directory / 'root.qcow2'
        subprocess.run(['qemu-img', 'convert', '-O', 'qcow2', str(image), str(disk)], check=True, timeout=120)
        subprocess.run(['qemu-img', 'resize', str(disk), '20G' if options.virtualmin else '12G'], check=True, timeout=30)
        data_disk = directory / 'data.qcow2'
        subprocess.run(['qemu-img', 'create', '-q', '-f', 'qcow2', str(data_disk), '64M'], check=True)
        subprocess.run(['qemu-io', '-f', 'qcow2', '-c', 'write -P 57 0 4096', str(data_disk)], check=True, stdout=subprocess.DEVNULL)
        pool.refresh(0)
        # Fixture SSH avoids requiring guest-exec in the
        # distribution's agent policy.
        key = directory / 'identity'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        user_data = {'manage_etc_hosts': True, 'package_update': True, 'packages': ['qemu-guest-agent'], 'users': ['default', {
            'name': 'clonefixture', 'sudo': 'ALL=(ALL) NOPASSWD:ALL',
            'ssh_authorized_keys': [key.with_suffix('.pub').read_text().strip()]}],
            'runcmd': [['sh', '-c', 'if command -v systemctl; then systemctl enable --now qemu-guest-agent; '
                       'else rc-update add qemu-guest-agent default; rc-service qemu-guest-agent start; fi']]}
        (directory / 'user-data').write_text('#cloud-config\n'+json.dumps(user_data)+'\n')
        (directory / 'meta-data').write_text(f'instance-id: {ident}\nlocal-hostname: source.example.test\n')
        seed = directory / ('cloudmin-fixture-seed-'+ident.replace('-', '')+'.iso')
        subprocess.run(['xorriso', '-as', 'mkisofs', '-quiet', '-o', str(seed), '-V', 'cidata', '-J', '-r',
                        str(directory / 'user-data'), str(directory / 'meta-data')], check=True, timeout=30)
        arch = connection.getInfo()[0]
        machine = 'virt' if arch == 'aarch64' else 'q35'
        # Leave enough RAM for first-boot package setup on ARM guests.
        guest = connection.defineXML(f'''<domain type="kvm"><name>{name}</name><uuid>{ident}</uuid>
          <metadata><vm xmlns="urn:cloudmin:vm:1"><job>{ident.replace("-", "")}</job></vm></metadata>
          <memory unit="MiB">{3072 if options.virtualmin else 1536}</memory><currentMemory unit="MiB">{3072 if options.virtualmin else 1536}</currentMemory>
          <vcpu current="2">3</vcpu><cpu mode="host-passthrough">
          <topology sockets="3" dies="1" clusters="1" cores="1" threads="1"/></cpu>
          <os firmware="efi"><type arch="{arch}" machine="{machine}">hvm</type></os><features><acpi/></features><devices>
          <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{disk}"/><target dev="vda" bus="virtio"/></disk>
          <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seed}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
          <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{data_disk}"/><target dev="vdc" bus="virtio"/></disk>
          <interface type="network">{network_source}<model type="virtio"/></interface>
          <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
          <serial type="pty"><target port="0"/></serial>
          <memballoon model="virtio"/>
          </devices></domain>''')
        source_guest = guest
        guest.create()
    else:
        # Reuse only the source and private pool named by the retained fixture.
        pool = connection.storagePoolLookupByName(name)
        guest = source_guest = connection.lookupByUUIDString(ident)
        disk, data_disk, key = directory/'root.qcow2', directory/'data.qcow2', directory/'identity'
        if not guest.isActive():
            # Remove diagnostic logging left by an earlier fixture attempt.
            doc = ET.fromstring(guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
            for serial in doc.findall('./devices/serial'):
                for log in serial.findall('log'):
                    serial.remove(log)
            guest = source_guest = connection.defineXML(ET.tostring(doc, encoding='unicode'))
            guest.create()
    deadline = time.monotonic() + 600
    # Wait for the real agent before asking the source to run identity probes.
    responding = False
    guest.agentSetResponseTimeout(2, 0)
    while time.monotonic() < deadline:
        try:
            responding = bool(guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS, 0))
            # Continue only after an actual guest-agent response.
            if responding:
                break
        except libvirt.libvirtError:
            pass
        time.sleep(2)
    assert responding, 'Disposable image did not start QEMU Guest Agent'
    # The unchanged-copy scenario keeps guest networking but gets a new MAC.
    # Make this fixture's Netplan DHCP rule match the stable interface name.
    guest_command("if test -f /etc/netplan/50-cloud-init.yaml; then "
                  "sed -i '/^[[:space:]]*match:/d; /^[[:space:]]*macaddress:/d; "
                  "/^[[:space:]]*set-name:/d' /etc/netplan/50-cloud-init.yaml; fi")
    # Force the fallback host ID to be duplicated unless clone preparation resets it.
    guest_command("printf '\\021\\042\\063\\104' >/etc/hostid")
    source_hostid = guest_command('hostid')
    source_identity = guest_command('cloud-init status --wait >/dev/null; cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub; hostname -f')
    # Accept a short source name when the fixture has no resolvable FQDN.
    assert source_identity.splitlines()[-1] in ('source', 'source.example.test'), source_identity.splitlines()[-1]
    # A clone needs a new identity without rerunning systemd installation units.
    guest_command('cat >/etc/systemd/system/cloudmin-clone-firstboot.service',
                  '[Unit]\nConditionFirstBoot=yes\n[Service]\nType=oneshot\n'
                  'ExecStart=/usr/bin/touch /var/lib/cloudmin-clone-firstboot-ran\n'
                  '[Install]\nWantedBy=multi-user.target\n')
    guest_command('systemctl daemon-reload; systemctl enable cloudmin-clone-firstboot.service')
    if options.virtualmin:
        # Install into the nested source, never the Cloudmin controller itself.
        print('Installing Virtualmin GPL in the disposable source', flush=True)
        guest_command('curl --fail --silent --show-error --proto =https --max-time 180 -o /var/tmp/virtualmin-install https://download.virtualmin.com/virtualmin-install && sh /var/tmp/virtualmin-install --yes --bundle LAMP --type full --no-hostname-ssl >/var/tmp/clone-fixture-install.log 2>&1')
        assert guest_command('test -f /usr/libexec/webmin/virtual-server/virtual-server-lib.pl && echo installed') == 'installed'
        source_tls = guest_command('openssl x509 -in /etc/webmin/miniserv.pem -noout -fingerprint -sha256')
        print('Virtualmin GPL installed', flush=True)
        if options.virtualmin_pro_source:
            # No real license enters this fixture. Install the Pro module files only.
            import base64
            payload = base64.b64encode(options.virtualmin_pro_source.read_bytes()).decode()
            guest_command('base64 -d >/var/tmp/clone-pro.tgz', payload)
            guest_command('tar -xzf /var/tmp/clone-pro.tgz -C /usr/libexec/webmin/virtual-server')
            assert options.virtualmin_licence_library, 'Supply the offline API for this fixture'
            guest_command('cat >/usr/libexec/webmin/virtual-server/virtualmin-licence.pl',
                          options.virtualmin_licence_library.read_text())
            # Set unmistakably fake source credentials locally, without validation.
            guest_command("printf 'SerialNumber=123456789\\nLicenseKey=SOURCE_FIXTURE_KEY\\n' >/etc/virtualmin-license; "
                          "chmod 600 /etc/virtualmin-license; "
                          "printf '[virtualmin]\\nbaseurl=https://123456789:SOURCE_FIXTURE_KEY@download.virtualmin.com/pro/rpm\\nenabled=0\\n' >/etc/yum.repos.d/virtualmin-stable.repo")
            source_license = guest_command('sha256sum /etc/virtualmin-license /etc/yum.repos.d/virtualmin-stable.repo')
            source_license_hostid = guest_command(HOSTID_PROBE)
            assert source_license_hostid, 'Source license host ID is empty'
            print('Pro module with fake license installed; no source license is used', flush=True)
        if options.virtualmin_hostname:
            # Include hostname TLS and an independent hosted site's data and cert.
            guest_command('umask 077; cat >/var/tmp/clone-virtualmin-fixture.pl',
                (module/'t/live/clone-virtualmin-fixture.pl').read_text())
            guest_command('perl /var/tmp/clone-virtualmin-fixture.pl setup')
            source_application = json.loads(guest_command('perl /var/tmp/clone-virtualmin-fixture.pl check'))
            source_hosted_tls = guest_command('openssl x509 -in '+shlex.quote(source_application['hosted_certificate'])+' -noout -fingerprint -sha256')
            print('Hostname domain and hosted website created', flush=True)
    guest.shutdown()
    # Establish stable source bytes before snapshotting or checking cold copies.
    deadline = time.monotonic()+120
    while guest.isActive() and time.monotonic()<deadline:
        time.sleep(1)
    assert not guest.isActive(), 'Source did not shut down'
    if options.snapshot_chain:
        # Start with saved history so temporary clone snapshots must preserve it.
        snapshot = ET.Element('domainsnapshot')
        ET.SubElement(snapshot,'name').text = name+'-history'
        ET.SubElement(snapshot,'memory',snapshot='no')
        snapshot_disks = ET.SubElement(snapshot,'disks')
        for target in ('vda','vdb','vdc'):
            node = ET.SubElement(snapshot_disks,'disk',name=target,snapshot='no' if target=='vdb' else 'external')
            if target != 'vdb':
                # The read-only cloud-init seed does not need an external overlay.
                ET.SubElement(node,'driver',type='qcow2')
                ET.SubElement(node,'source',file=str(directory/(target+'-history.qcow2')))
        guest.snapshotCreateXML(ET.tostring(snapshot,encoding='unicode'),libvirt.VIR_DOMAIN_SNAPSHOT_CREATE_DISK_ONLY|libvirt.VIR_DOMAIN_SNAPSHOT_CREATE_ATOMIC)
        pool.refresh(0)
    source_snapshots = sorted(snap.getName() for snap in guest.listAllSnapshots(0))
    # Capture source state and use a new administrator key for the clones.
    source_xml = guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE)
    source_disk = subprocess.check_output(['sha256sum', str(disk)], text=True).split()[0]
    newkey = directory / 'clone-key'
    # Resumed fixtures must keep the access key used by any existing test clone.
    if not newkey.exists():
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(newkey)], check=True)
    if options.capture_images:
        # Reuse source setup and cleanup for the Pro capture-to-boot scenarios.
        import runpy
        runpy.run_path(str(module/'pro/t/capture-live.py'))['run'](globals())
        raise SystemExit(0)
    for scenario in (('cold',) if options.identity_only else ('cold', 'live', 'shutdown')):
        live = scenario != 'cold'
        if live:
            # Both live-snapshot and clean-shutdown cases begin with a running VM.
            if not guest.isActive():
                # Cold cloning leaves the source stopped; start it for this case.
                guest.create()
            agent_ready()
        choices = api('clone_options', {'id': ident})
        target = name + '-'+scenario
        password = secrets.token_urlsafe(32) if scenario == 'shutdown' else ''
        # Submit real clone jobs, including credential changes and source policy.
        job = api('clone', {'id': ident, 'revision': choices['revision'], 'name': target,
            'hostname': target+'.example.test', 'username': 'clonefixture',
            'auth_type': 'both' if password else 'keys', 'password': password,
            'ssh_keys': newkey.with_suffix('.pub').read_text(), 'start': 1, 'autostart': 0,
            'host_ssh_key': 0, 'pool': pool.UUIDString(), 'network': 'network:'+network.UUIDString(),
            'confirm_license': int(bool(options.virtualmin_pro_source)),
            'shutdown': int(scenario == 'shutdown')})
        jobs.append(job['id'])
        job = wait_job(job)
        clone = connection.lookupByUUIDString(job['uuid'])
        clones.append(clone)
        saved_guest, saved_key = guest, key
        # Probe the clone with its new access key, keeping the source for comparison.
        guest, key = clone, newkey
        cloned_identity = guest_command('cloud-init status --wait >/dev/null; cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub; hostname -f')
        assert guest_command('hostid') != source_hostid, 'hostid duplicated'
        assert cloned_identity.splitlines()[0] != source_identity.splitlines()[0], 'Machine ID duplicated'
        assert cloned_identity.splitlines()[1] != source_identity.splitlines()[1], 'SSH host key duplicated'
        assert cloned_identity.splitlines()[-1] == target+'.example.test', cloned_identity
        assert guest_command('test ! -e /var/lib/cloudmin-clone-firstboot-ran && echo skipped') == 'skipped', 'Clone triggered systemd first-boot units'
        assert saved_key.with_suffix('.pub').read_text().strip() not in guest_command('cat /home/clonefixture/.ssh/authorized_keys')
        if password:
            # Check the existing account's new password without printing secrets.
            shadow = guest_command('getent shadow clonefixture').split(':')[1]
            checked = subprocess.run(['perl', '-e',
                'chomp(my $p=<STDIN>); chomp(my $h=<STDIN>); exit(crypt($p,$h) eq $h ? 0 : 1);'],
                input=password+'\n'+shadow+'\n', text=True)
            assert checked.returncode == 0, 'Cloned administrator password was not replaced'
        if options.virtualmin_pro_source:
            # Neither the license file nor repository may retain source credentials.
            assert set(guest_command('cat /etc/virtualmin-license').replace(chr(34), '').replace(chr(39), '').splitlines()) == {'SerialNumber=CLONE_REQUIRES_LICENSE', 'LicenseKey=CLONE_REQUIRES_LICENSE'}
            assert 'SOURCE_FIXTURE_KEY' not in guest_command('cat /etc/yum.repos.d/virtualmin-stable.repo')
            assert 'CLONE_REQUIRES_LICENSE' in guest_command('cat /etc/yum.repos.d/virtualmin-stable.repo')
            clone_license_hostid = guest_command(HOSTID_PROBE)
            assert clone_license_hostid and clone_license_hostid != source_license_hostid, 'License host ID missing or duplicated'
        if options.virtualmin:
            # Management identity changes must leave hosted certificates intact.
            assert guest_command('postconf -h myhostname') == target+'.example.test'
            cert = '/etc/webmin/miniserv-clone.pem'
            if options.virtualmin_hostname:
                # The managed hostname domain must be renamed without CA renewal.
                application = json.loads(guest_command('perl /var/tmp/clone-virtualmin-fixture.pl check'))
                assert application['domain'] == target+'.example.test', application
                assert not application['renewal'], 'Source hostname certificate renewal retained'
                assert guest_command('openssl x509 -in '+shlex.quote(application['hosted_certificate'])+' -noout -fingerprint -sha256') == source_hosted_tls
                cert = application['webmin_certificate']
            subject = guest_command('openssl x509 -in '+shlex.quote(cert)+' -noout -subject')
            assert target+'.example.test' in subject, 'Management certificate hostname: '+subject
            assert guest_command('openssl x509 -in '+shlex.quote(cert)+' -noout -fingerprint -sha256') != source_tls, 'Management certificate reused'
            assert guest_command('systemctl is-active webmin') == 'active', 'Cloned Webmin is not running'
        if scenario == 'cold':
            # A second boot must retain the generated identity and SSH access.
            stop_guest(clone)
            clone.create()
            assert guest_command('cloud-init status --wait >/dev/null; cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub; hostname -f') == cloned_identity, 'Clone identity changed after reboot'
            if options.virtualmin_pro_source:
                # License identity must remain stable across subsequent clone boots.
                assert guest_command(HOSTID_PROBE) == clone_license_hostid, 'License host ID changed after reboot'
            if options.virtualmin:
                # The copied application must still start after the second boot.
                assert guest_command('systemctl is-active webmin') == 'active', 'Webmin did not survive reboot'
        guest, key = saved_guest, saved_key
        doc = ET.fromstring(clone.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
        # Copies must be standalone and preserve the secondary disk's test sectors.
        for node in doc.findall('./devices/disk'):
            if node.find('readonly') is None:
                # Read-only seed data is checked by the unchanged-copy scenario.
                info = json.loads(subprocess.check_output(['qemu-img', 'info', '-U', '--output=json', node.find('source').get('file')]))
                assert not info.get('backing-filename'), 'Clone has a backing file'
                if node.find('target').get('dev') == 'vdc':
                    # Verify the recognizable bytes written before the source booted.
                    subprocess.run(['qemu-io', '-U', '-f', 'qcow2', '-r', '-c', 'read -P 57 0 4096', node.find('source').get('file')], check=True, stdout=subprocess.DEVNULL)
        assert doc.find('./os/nvram').text != ET.fromstring(source_xml).find('./os/nvram').text
        assert sorted(snap.getName() for snap in guest.listAllSnapshots(0)) == source_snapshots, 'Source snapshot history changed'
        assert bool(guest.isActive()) == live, 'Source power state changed'
        if not live:
            # A stopped source permits an exact disk hash comparison.
            assert subprocess.check_output(['sha256sum', str(disk)], text=True).split()[0] == source_disk
        else:
            # Running sources may write logs, so compare their persistent identity.
            assert guest_command('cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub; hostname -f') == source_identity
        if options.virtualmin_pro_source and live:
            # Preparing the clone must not change the source's license or host ID.
            assert guest_command('sha256sum /etc/virtualmin-license /etc/yum.repos.d/virtualmin-stable.repo') == source_license
            assert guest_command(HOSTID_PROBE) == source_license_hostid, 'Source license host ID changed'
        print(scenario+' prepared clone: identity, boot, multiple disks and source preservation passed', flush=True)
        stop_guest(clone)
    # A mid-copy cancellation must merge its live overlay before unlocking.
    fault_fields = {'id': ident, 'hostname': name+'.example.test', 'username': 'clonefixture',
        'auth_type': 'keys', 'ssh_keys': newkey.with_suffix('.pub').read_text(), 'nvram_mode': 'fresh',
        'pool': pool.UUIDString(), 'network': 'network:'+network.UUIDString(), 'start': 0, 'autostart': 0}
    for fault in (() if options.identity_only else ('cancel', 'fail', 'interrupt')):
        result = subprocess.run(['perl', str(module/'t/live/clone-fixture.pl'), fault],
            input=json.dumps(fault_fields), text=True, capture_output=True, timeout=300)
        assert result.returncode == 0, result.stderr
        failed = json.loads(result.stdout)
        jobs.append(failed['id'])
        if fault != 'cancel':
            # Failed cleanup and interrupted workers must block new source changes.
            assert failed['cleanup_pending'] if fault == 'fail' else failed['state'] == 'running', failed
            refused = subprocess.run(['perl', str(module/'api.pl'), 'shutdown'],
                input=json.dumps({'id': ident}), text=True, capture_output=True, timeout=30)
            assert refused.returncode and 'unfinished' in refused.stderr, refused.stderr
            api('recover', {'job': failed['id']})
            deadline = time.monotonic()+180
            while time.monotonic()<deadline:
                failed = api('status', {'job': failed['id']})
                if failed['state']=='failed' and not failed.get('cleanup_pending'):
                    # Recovery is complete only after source restoration releases it.
                    break
                time.sleep(1)
        else:
            # Cancellation succeeds only when its normal rollback has finished.
            assert failed['state']=='cancelled', failed
        assert not failed.get('cleanup_pending'), failed
        assert guest.isActive() and sorted(snap.getName() for snap in guest.listAllSnapshots(0))==source_snapshots, 'Source not restored'
        assert guest_command('cat /etc/machine-id; cat /etc/ssh/ssh_host_ed25519_key.pub; hostname -f') == source_identity
        print(fault+': source restored and reservations released', flush=True)
    # Unchanged copies keep the seed but must never start automatically.
    choices = api('clone_options', {'id': ident})
    unchanged = api('clone', {'id': ident, 'revision': choices['revision'],
        'confirm_license': int(bool(options.virtualmin_pro_source)),
        'name': name+'-unchanged', 'clone_mode': 'unchanged', 'confirm_unchanged': 1,
        'nvram_mode': 'fresh', 'start': 0, 'autostart': 0, 'pool': pool.UUIDString(),
        'network': 'network:'+network.UUIDString()})
    jobs.append(unchanged['id'])
    unchanged = wait_job(unchanged)
    copy = connection.lookupByUUIDString(unchanged['uuid'])
    clones.append(copy)
    assert not copy.isActive() and not copy.autostart()
    assert len(ET.fromstring(copy.XMLDesc(0)).findall('./devices/disk')) == 3
    # Boot the stopped copy only after checking its API guarantees.
    saved_guest, saved_key = guest, key
    guest, key = copy, directory / 'identity'
    copy.create()
    assert guest_command('hostid') != source_hostid, 'stopped-copy hostid duplicated'
    if options.virtualmin_pro_source:
        # Unchanged copies still erase the license and receive a fresh host ID.
        assert 'SOURCE_FIXTURE_KEY' not in guest_command('cat /etc/virtualmin-license /etc/yum.repos.d/virtualmin-stable.repo')
        assert 'CLONE_REQUIRES_LICENSE' in guest_command('cat /etc/virtualmin-license')
        clone_license_hostid = guest_command(HOSTID_PROBE)
        assert clone_license_hostid and clone_license_hostid != source_license_hostid, 'Stopped-copy license host ID missing or duplicated'
    if options.virtualmin:
        # Keeping guest settings must not stop the copied Webmin service working.
        assert guest_command('systemctl is-active webmin') == 'active', 'Stopped-copy Webmin is not running'
    stop_guest(copy)
    guest, key = saved_guest, saved_key
    print('PASS: prepared and stopped-copy identity checks' if options.identity_only else
          'PASS: prepared, unchanged, cancellation and recovery clones', flush=True)
finally:
    # Never remove volumes while a controller worker may still be using them.
    # Successful Pro-only runs exit before the ordinary clone scenarios.
    failure = sys.exc_info()[1]
    failed = failure is not None and not (isinstance(failure, SystemExit) and failure.code in (None, 0))
    safe = not (options.keep_on_failure and failed)
    for job_id in jobs:
        state = api('status', {'job': job_id})
        if state['state'] not in ('complete', 'failed', 'cancelled') or state.get('cleanup_pending'):
            # Keep resources intact while any job or source recovery still needs them.
            safe = False
    if safe:
        # Remove only this run's guests, firmware, private storage and finished jobs.
        for domain in clones + ([source_guest] if source_guest else []):
            if not domain.name().startswith(name):
                # Ownership checks prevent cleanup from touching an unrelated guest.
                raise RuntimeError('Refusing to remove unrelated guest')
            if domain.isActive():
                # Fixture disks must not be deleted while their QEMU process uses them.
                domain.destroy()
            domain.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM|libvirt.VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA)
        if pool:
            # The pool belongs to this fixture and can be removed with its directory.
            pool.destroy()
            pool.undefine()
        shutil.rmtree(directory)
        # Pro capture and ordinary clones have different owned journal records.
        helper = module/('pro/t/capture-fixture.pl' if options.capture_images else 't/live/clone-fixture.pl')
        subprocess.run(['perl', str(helper), 'cleanup'],
            input=json.dumps({'jobs':jobs}), text=True, capture_output=True, timeout=30, check=True)
    else:
        # Preserve the fixture for recovery rather than hiding an unfinished job.
        print('Retained fixture for recovery: '+str(directory), file=sys.stderr)
    connection.close()
