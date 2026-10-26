#!/usr/bin/python3
"""Boot a restored full backup and verify source recovery and preserved identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from xml.etree import ElementTree as ET

# These fixtures create real guests and pools; never run on the workstation.
if sys.platform != 'linux' or os.geteuid() != 0:
    raise SystemExit('Run on an authorized Linux test host as root')
import libvirt
libvirt.registerErrorHandler(lambda context, error: None, None)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('image', type=Path)
parser.add_argument('--network', required=True)
parser.add_argument('--uefi', action='store_true')
parser.add_argument('--bios', action='store_true', help='Use only with a BIOS-capable x86 image such as Ubuntu')
parser.add_argument('--snapshot-chain', action='store_true', help='Back up a guest with an existing external snapshot')
args = parser.parse_args()
module = Path(__file__).resolve().parents[2]
conn = libvirt.open('qemu:///system')
network = conn.networkLookupByName(args.network)
assert network.isActive(), 'Select an already active test network'
# Separate pool and archive directories make cleanup specific to this run.
ident = str(uuid.uuid4())
name = 'cloudmin-backup-test-'+ident[:8]
directory = Path(tempfile.mkdtemp(prefix=name+'-', dir='/var/lib/libvirt/images'))
directory.chmod(0o755)
archives = Path(tempfile.mkdtemp(prefix=name+'-', dir='/var/tmp'))
key = directory/'identity'
guest = pool = None
jobs = []
backups = []
token = None


def api(action, fields=None):
    """api(action, [fields]) calls the real Cloudmin controller without HTTP secrets."""
    fields=dict(fields or {})
    # The initial options call obtains the token used by subsequent requests.
    if token: fields['token']=token
    result = subprocess.run(['perl',str(module/'api.pl'),action],input=json.dumps(fields),text=True,capture_output=True,timeout=60)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)['result']


def wait(job):
    """wait(job) requires a durable job to finish successfully."""
    jobs.append(job['id'])
    deadline = time.monotonic()+1200
    while job['state'] not in ('complete','failed','cancelled') and time.monotonic()<deadline:
        time.sleep(1)
        job=api('status',{'job':job['id']})
    assert job['state']=='complete', job
    return job


def command(command):
    """command(command) uses only the nested fixture's libvirt-reported address."""
    deadline=time.monotonic()+480
    diagnostic='No fixture lease'
    while time.monotonic()<deadline:
        ips=[a['addr'] for n in guest.interfaceAddresses(libvirt.VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE,0).values()
             for a in n['addrs'] if a['type']==libvirt.VIR_IP_ADDR_TYPE_IPV4]
        # Connect only to the nested fixture address reported by libvirt.
        if ips:
            result=subprocess.run(['ssh','-F','/dev/null','-i',str(key),'-o','IdentitiesOnly=yes','-o','BatchMode=yes',
                '-o','ConnectTimeout=5','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',
                'backupfixture@'+ips[0], 'sudo -n sh -c '+shlex.quote(command)],capture_output=True,text=True,timeout=600)
            # Retry SSH startup failures, but surface guest command failures.
            if result.returncode != 255:
                assert result.returncode==0,result.stderr
                return result.stdout.strip()
            diagnostic=result.stderr
        time.sleep(2)
    raise AssertionError(diagnostic)


def agent():
    """agent() waits for an actual guest-agent reply before quiescing the source."""
    deadline=time.monotonic()+480
    guest.agentSetResponseTimeout(2,0)
    while time.monotonic()<deadline:
        try:
            # A successful transport alone does not prove the agent is ready.
            if guest.guestInfo(libvirt.VIR_DOMAIN_GUEST_INFO_OS,0): return
        except libvirt.libvirtError: pass
        time.sleep(2)
    raise AssertionError('Guest agent did not respond')


def stop():
    """stop() flushes fixture writes through a normal guest shutdown."""
    guest.shutdown()
    deadline=time.monotonic()+120
    while guest.isActive() and time.monotonic()<deadline: time.sleep(1)
    assert not guest.isActive(),'Clean fixture shutdown failed'


def digest(path):
    """digest(path) hashes large disks without loading them into memory."""
    with path.open('rb') as stream:
        checksum=hashlib.sha256()
        for block in iter(lambda: stream.read(1024*1024), b''): checksum.update(block)
    return checksum.hexdigest()


try:
    # Build a guest with a writable data disk and read-only cloud-init seed.
    token=api('options')['token']
    pool=conn.storagePoolDefineXML(f'<pool type="dir"><name>{name}</name><target><path>{directory}</path></target></pool>',0)
    pool.create(0)
    disk=directory/'root.qcow2'
    subprocess.run(['qemu-img','convert','-O','qcow2',str(args.image.resolve(strict=True)),str(disk)],check=True,timeout=180)
    subprocess.run(['qemu-img','resize',str(disk),'12G'],check=True)
    data=directory/'data.qcow2'
    subprocess.run(['qemu-img','create','-q','-f','qcow2',str(data),'64M'],check=True)
    subprocess.run(['qemu-io','-f','qcow2','-c','write -P 57 0 4096',str(data)],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
    # Guest-local key access and the agent enable boot and live-backup checks.
    user={'package_update':True,'packages':['qemu-guest-agent'],'users':['default',{'name':'backupfixture','sudo':'ALL=(ALL) NOPASSWD:ALL',
        'ssh_authorized_keys':[key.with_suffix('.pub').read_text().strip()]}],
        'runcmd':[['sh','-c','systemctl enable --now qemu-guest-agent']]}
    (directory/'user-data').write_text('#cloud-config\n'+json.dumps(user)+'\n')
    (directory/'meta-data').write_text(f'instance-id: {ident}\nlocal-hostname: backup.example.test\n')
    seed=directory/'seed.iso'
    subprocess.run(['xorriso','-as','mkisofs','-quiet','-o',str(seed),'-V','cidata','-J','-r',str(directory/'user-data'),str(directory/'meta-data')],check=True)
    pool.refresh(0)
    arch=conn.getInfo()[0]
    assert not (args.bios and (args.uefi or arch=='aarch64')), 'BIOS requires an x86 image and cannot be combined with --uefi'
    # Default to UEFI for RHEL 10 images and ARM; BIOS is an explicit opt-in.
    uefi=not args.bios
    machine='virt' if arch=='aarch64' else 'q35'
    os_attr=' firmware="efi"' if uefi else ''
    guest=conn.defineXML(f'''<domain type="kvm"><name>{name}</name><uuid>{ident}</uuid>
    <memory unit="MiB">1536</memory><vcpu>2</vcpu><cpu mode="host-passthrough"/><os{os_attr}><type arch="{arch}" machine="{machine}">hvm</type></os><features><acpi/></features><devices>
    <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{disk}"/><target dev="vda" bus="virtio"/></disk>
    <disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="{seed}"/><target dev="vdb" bus="virtio"/><readonly/></disk>
    <disk type="file" device="disk"><driver name="qemu" type="qcow2"/><source file="{data}"/><target dev="vdc" bus="virtio"/></disk>
    <interface type="network"><source network="{args.network}"/><model type="virtio"/></interface>
    <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel><serial type="pty"><target port="0"/></serial>
    </devices></domain>''')
    # Seed identity and data canaries before capturing the expected restore
    # state.
    guest.create()
    command('cloud-init status --wait >/dev/null')
    agent()
    command("printf 'backup-canary' >/root/backup-canary; printf '\\021\\042\\063\\104' >/etc/hostid; printf 'SerialNumber=123456789\\nLicenseKey=BACKUP_TEST_ONLY\\n' >/etc/virtualmin-license; chmod 600 /etc/virtualmin-license")
    probe="cat /etc/machine-id; hostid; cat /etc/ssh/ssh_host_ed25519_key.pub; hostname; sha256sum /root/backup-canary /etc/virtualmin-license; ip -4 -o addr show scope global | awk '{print $2, $4}'"
    identity=command(probe)
    xml=guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE|libvirt.VIR_DOMAIN_XML_SECURE)
    mac=ET.fromstring(xml).find('./devices/interface/mac').get('address')
    target={'mode':'local','path':str(archives)}
    original_nvram=ET.fromstring(xml).find('./os/nvram')
    nvram_hash=digest(Path(original_nvram.text)) if original_nvram is not None else None
    # Existing snapshots belong to the source and must survive temporary backups.
    expected_snapshots = set()
    # Exercise backup of an existing external snapshot chain when requested.
    if args.snapshot_chain:
        snapshot = 'before-backup'
        guest.snapshotCreateXML(f'''<domainsnapshot><name>{snapshot}</name><disks>
        <disk name="vda" snapshot="external"><source file="{directory}/fixture-root-overlay.qcow2"/></disk>
        <disk name="vdb" snapshot="no"/>
        <disk name="vdc" snapshot="external"><source file="{directory}/fixture-data-overlay.qcow2"/></disk>
        </disks></domainsnapshot>''', libvirt.VIR_DOMAIN_SNAPSHOT_CREATE_DISK_ONLY |
            libvirt.VIR_DOMAIN_SNAPSHOT_CREATE_ATOMIC | libvirt.VIR_DOMAIN_SNAPSHOT_CREATE_QUIESCE)
        expected_snapshots.add(snapshot)
        disk = directory/'fixture-root-overlay.qcow2'
        pool.refresh(0)
    # Exercise live, shutdown/restart and already-stopped source preparation.
    for scenario,shutdown in [('live',0),('shutdown',1),('cold',0)]:
        # The cold case must preserve disk bytes as well as leaving power off.
        if scenario=='cold': stop()
        running=bool(guest.isActive())
        before=digest(disk) if not running else None
        boot_id=command('cat /proc/sys/kernel/random/boot_id') if scenario=='live' else None
        fields={'id':ident,'target':target,'shutdown':shutdown,'compression':int(scenario!='cold'),'attempt':secrets.token_hex(16)}
        result=wait(api('backup',fields)); backups.append(result['id'])
        assert bool(guest.isActive())==running,'Backup changed source power state'
        assert {s.getName() for s in guest.listAllSnapshots(0)}==expected_snapshots,'Backup changed source snapshots'
        assert not list(directory.glob('cloudmin-backup-*')),'Temporary backup volumes remain'
        # A cold disk is byte-stable; running guests are checked from inside.
        if before: assert digest(disk)==before,'Cold source bytes changed'
        # Wait for a restarted shutdown-mode guest before comparing identity.
        else:
            agent()
            actual=command(probe)
            assert actual==identity,('Source identity changed',identity,actual)
            # Live preparation must not reboot the source to achieve
            # consistency.
            if boot_id: assert command('cat /proc/sys/kernel/random/boot_id')==boot_id,'Live backup restarted the source'
        assert api('backup',fields)['id']==result['id'],'Repeated submission duplicated backup'
        print(scenario+': backup complete, source preserved, temporary files removed',flush=True)
        if scenario=='live':
            # Cancel while disk copying still owns the temporary live snapshot.
            pending=api('backup',{**fields,'attempt':secrets.token_hex(16)})
            jobs.append(pending['id'])
            deadline=time.monotonic()+180
            while pending.get('phase')!='backup_disks' and time.monotonic()<deadline:
                assert pending['state'] not in ('complete','failed','cancelled'),pending
                time.sleep(.2); pending=api('status',{'job':pending['id']})
            assert pending.get('phase')=='backup_disks',pending
            api('cancel',{'job':pending['id']})
            while pending['state'] not in ('complete','failed','cancelled') and time.monotonic()<deadline:
                time.sleep(1); pending=api('status',{'job':pending['id']})
            assert pending['state']=='cancelled' and not pending.get('cleanup_pending'),pending
            assert guest.isActive() and {s.getName() for s in guest.listAllSnapshots(0)}==expected_snapshots,'Cancellation changed source snapshots'
            assert not list(directory.glob('cloudmin-backup-*')),'Cancelled backup left temporary volumes'
            agent(); assert command(probe)==identity,'Cancellation changed the source'
            assert command('cat /proc/sys/kernel/random/boot_id')==boot_id,'Live cancellation restarted the source'
            print('live cancellation: source running, identity preserved, overlays removed',flush=True)
    # Boot the live archive, including its stable firmware copy.
    inspection=wait(api('backup_inspect',{'backup':backups[0],'attempt':secrets.token_hex(16)}))
    failed=subprocess.run(['perl',str(module/'api.pl'),'restore'],input=json.dumps({'inspection':inspection['id'],'pool':pool.UUIDString(),'confirm':1}),text=True,capture_output=True)
    assert failed.returncode != 0 and 'already exists' in failed.stderr,'Restore replaced an existing VM'
    guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM|libvirt.VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA)
    guest=None
    restored=wait(api('restore',{'inspection':inspection['id'],'pool':pool.UUIDString(),'confirm':1,'attempt':secrets.token_hex(16)}))
    guest=conn.lookupByUUIDString(ident)
    assert not guest.isActive() and not guest.autostart(),'Restore must stay stopped'
    doc=ET.fromstring(guest.XMLDesc(libvirt.VIR_DOMAIN_XML_INACTIVE))
    assert doc.find('./devices/interface/mac').get('address')==mac,'Restore changed MAC'
    # Firmware bytes must survive backup and restore as well as disk contents.
    if nvram_hash: assert hashlib.sha256(Path(doc.find('./os/nvram').text).read_bytes()).hexdigest()==nvram_hash,'UEFI variables changed'
    for node in doc.findall('./devices/disk'):
        info=json.loads(subprocess.check_output(['qemu-img','info','--output=json','-f',node.find('driver').get('type'),node.find('source').get('file')]))
        assert not info.get('backing-filename'),'Restore retains a backing chain'
        # The secondary disk canary checks data beyond the boot disk.
        if node.find('target').get('dev')=='vdc':
            subprocess.run(['qemu-io','-f','qcow2','-r','-c','read -P 57 0 4096',node.find('source').get('file')],check=True,stdout=subprocess.DEVNULL)
    guest.create(); agent()
    actual=command(probe)
    assert actual==identity,('Restored identity, network, credentials or data changed',identity,actual)
    print('restore: boot, identity, MAC/IP, license bytes, independent disks and data verified',flush=True)
finally:
    # Do not remove source files while cancellation or recovery still needs
    # them.
    safe=True
    for jid in jobs:
        job=api('status',{'job':jid})
        if job['state'] not in ('complete','failed','cancelled') or job.get('cleanup_pending'): safe=False
    # Successful cleanup removes only this run's named guest and private
    # storage.
    if safe:
        # Confirm the guest identity before destroying the remaining fixture.
        if guest:
            assert guest.name()==name
            if guest.isActive(): guest.destroy()
            guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM|libvirt.VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA)
        # Unregister the fixture pool before removing its backing directory.
        if pool: pool.destroy(); pool.undefine()
        shutil.rmtree(directory)
        shutil.rmtree(archives)
        subprocess.run(['perl',str(module/'t/live/backup-fixture-cleanup.pl'),ident],check=True)
    # A recoverable failure keeps the fixture and reports where to find it.
    else:
        print('Retained fixture for recovery: '+str(directory),file=sys.stderr)
    conn.close()
