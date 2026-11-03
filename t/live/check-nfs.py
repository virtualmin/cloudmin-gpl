#!/usr/bin/python3
"""Exercise NFS registration, guest I/O, copying and backups on a test host."""
import http.cookiejar
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from xml.etree import ElementTree as ET

# This fixture mounts exports and changes policy on an authorized test host.
if sys.platform != 'linux' or os.geteuid():
    raise SystemExit('Run as root on an authorized Linux test host')
import libvirt
# Exceptions report failures; suppress libvirt's duplicate stderr messages.
libvirt.registerErrorHandler(lambda context, error: None, None)
module=Path(__file__).resolve().parents[2]
connection=libvirt.open('qemu:///system')
# Keep the export separate from the mount so cleanup can inspect both sides.
root=Path(tempfile.mkdtemp(prefix='cloudmin-nfs-',dir='/var/tmp'))
root.chmod(0o755)
export=root/'export'
export.mkdir(mode=0o755)
# Libvirt removes QEMU-owned files as that user; both need directory writes.
export.chmod(0o777)
mount=Path('/var/lib/libvirt')/root.name
name=root.name
# Track resources as they are allocated so partial runs can be cleaned up.
pool=guest=None
exported=started=False
alias_mount=root/'alias'
selinux_state=None
# Compare host state after cleanup without changing existing VMs or pools.
initial_domains={d.UUIDString():d.isActive() for d in connection.listAllDomains()}
initial_pools={p.UUIDString():p.isActive() for p in connection.listAllStoragePools()}


def run(*args, timeout=120, **kwargs):
    """run(*args, [timeout], [**kwargs]) runs a command and returns trimmed stdout.

    args supplies the program and arguments. timeout defaults to 120 seconds;
    kwargs passes subprocess options such as input and env.
    """
    result=subprocess.run(args,text=True,capture_output=True,timeout=timeout,**kwargs)
    if result.returncode:
        # Preserve command output when a setup or cleanup step fails.
        raise RuntimeError(' '.join(args)+': '+result.stderr+result.stdout)
    return result.stdout.strip()


def api(action, fields=None, fail=None):
    """api(action, [fields], [fail]) calls the API and returns its result.

    fields defaults to an empty request. fail expects an error containing that
    string instead of a successful response; it is unset by default.
    """
    result=subprocess.run(['perl',str(module/'api.pl'),action],input=json.dumps(fields or {}),
                          text=True,capture_output=True,timeout=120)
    if fail:
        # Negative cases must fail for the expected reason, not another error.
        assert result.returncode and fail in result.stderr, result.stderr+result.stdout
        return
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)['result']


def record():
    """record() retrieves the fixture pool's current revision through the API."""
    return next(p for p in api('storage')['pools'] if p['name']==name)


def ui_register(theme):
    """ui_register(theme) submits the real NFS form with a temporary local user."""
    # Pass the generated password through stdin; never print it or save it here.
    username='cloudmin-ui-check-'+secrets.token_hex(4)
    password=secrets.token_urlsafe(36)
    helper=str(module/'t/live/webmin-user.pl')
    run('perl',helper,'create',theme,username,input=password+'\n')
    try:
        # Let Webmin reload the user; accept the test host's certificate.
        time.sleep(1)
        base='https://127.0.0.1:10000'
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
        # Use a real login session and the storage form's current request token.
        opener.open(base+'/session_login.cgi',timeout=30).read()
        opener.open(base+'/session_login.cgi',urllib.parse.urlencode(
            {'user':username,'pass':password,'page':'/'}).encode(),timeout=30).read()
        opener.addheaders=[('Referer',base+'/server-manager/storage.cgi')]
        html=opener.open(base+'/server-manager/storage.cgi?tab=pools',timeout=90).read().decode()
        token=re.search(r'name="token"[^>]*value="([^"]+)"',html).group(1)
        assert all('name="'+key+'"' in html for key in ('server','export','mount')), 'NFS form is incomplete'
        # Submit the browser's mount field and verify pool activation.
        form={'action':'create','type':'netfs','name':name,'server':'127.0.0.1',
              'export':str(export),'mount':str(mount),'autostart':'1','token':token}
        result=opener.open(base+'/server-manager/storage.cgi',urllib.parse.urlencode(form).encode(),timeout=120).read().decode()
        assert name in result and connection.storagePoolLookupByName(name).isActive(), 'Form did not register NFS'
        print('PASS: NFS form registration in '+theme,flush=True)
    finally:
        # Remove the test login even if submission or validation fails.
        run('perl',helper,'delete',theme,username)


def check_aliased_mount(external):
    """check_aliased_mount(external) tests refusal to forget a lingering mount.

    If external is true, define the pool directly in libvirt with a symlinked
    target ending in a slash. Otherwise register a normal path through the API.
    """
    global pool
    # Seed the NFSv4 superblock with IPv6, then register its IPv4 alias.
    run('exportfs','-i','-o','rw,sync,no_subtree_check,no_root_squash','[::1]:'+str(export))
    alias_mount.mkdir(exist_ok=True)
    run('mount','-t','nfs','[::1]:'+str(export),str(alias_mount))
    link=root/'link'
    if external:
        # Pools defined outside Cloudmin may name the mount through an alias path.
        link.symlink_to(mount)
        pool=connection.storagePoolDefineXML(f'<pool type="netfs"><name>{name}</name><source><host name="127.0.0.1"/>'
            f'<dir path="{export}"/><format type="nfs"/></source><target><path>{link}/</path></target></pool>',0)
        api('pool_start',{'id':pool.UUIDString(),'revision':record()['revision']})
    else:
        # Cloudmin registrations use a canonical target and need the same guard.
        api('register_pool',{'name':name,'type':'netfs','server':'127.0.0.1',
            'export':str(export),'path':str(mount)})
        pool=connection.storagePoolLookupByName(name)
    assert os.path.ismount(mount), 'Pool start did not mount the export'
    source=run('findmnt','-n','-o','SOURCE','--mountpoint',str(mount))
    if source.startswith('[::1]:'):
        # Libvirt matches the configured source, but the kernel reports its alias.
        api('pool_stop',{'id':pool.UUIDString(),'revision':record()['revision']},fail='still mounted')
        assert os.path.ismount(mount), 'Alias mismatch did not leave a mount'
        print('PASS: stop reports a mount left behind by NFSv4 aliasing',flush=True)
    else:
        # Some kernels keep the sources separate. Still test unregistration
        # against a real mount which libvirt considers inactive.
        api('pool_stop',{'id':pool.UUIDString(),'revision':record()['revision']})
        run('mount','-t','nfs','[::1]:'+str(export),str(mount))
        print('SKIP: kernel did not merge NFS server aliases',flush=True)
    # Refuse unregistration while mounted, then allow it after manual recovery.
    review=api('pool_review',{'id':pool.UUIDString(),'stop':1})
    api('unregister_pool',{'id':pool.UUIDString(),'stop':1,'confirm':1,
        'revision':review['revision']},fail='still mounted')
    assert connection.storagePoolLookupByName(name).isPersistent(), 'Registration was lost'
    run('umount',str(mount))
    review=api('pool_review',{'id':pool.UUIDString(),'stop':1})
    api('unregister_pool',{'id':pool.UUIDString(),'stop':1,'confirm':1,'revision':review['revision']})
    pool=None
    run('umount',str(alias_mount))
    if external:
        # Only the externally defined pool uses this extra path alias.
        link.unlink()
    print('PASS: '+('externally defined alias target' if external else 'mounted pool')+
          ' cannot be forgotten; retry succeeds after unmount',flush=True)


try:
    if Path('/sys/fs/selinux/enforce').exists():
        # Save both live and boot policy, then exercise a fresh host's setting.
        state=run('semanage','boolean','-l',env={**os.environ,'LC_ALL':'C'})
        match=re.search(r'^virt_use_nfs\s+\((on|off)\s*,\s*(on|off)\)',state,re.M)
        assert match, 'Cannot read persistent virt_use_nfs state'
        selinux_state=match.groups()
        run('setsebool','-P','virt_use_nfs','off')
    # Export only fixture data to loopback; no LAN share or firewall change.
    if subprocess.run(['systemctl','is-active','--quiet','nfs-server']).returncode:
        # Remember whether cleanup must stop a server started by this test.
        run('systemctl','start','nfs-server')
        started=True
    run('exportfs','-i','-o','rw,sync,no_subtree_check,no_root_squash','127.0.0.1:'+str(export))
    exported=True
    for theme in ('gray-theme','authentic-theme'):
        # Both themes submit the same native form and preserve export contents.
        if not (module.parent/theme).is_dir():
            # A host need not have both optional themes installed.
            continue
        ui_register(theme)
        pool=connection.storagePoolLookupByName(name)
        assert run('stat','-f','-c','%T',str(mount))=='nfs'
        info=record()
        assert info['manageable'] and info['unregisterable'] and info['autostart']
        # Remove each form-created pool before testing the next theme or CLI.
        review=api('pool_review',{'id':pool.UUIDString(),'stop':1})
        api('unregister_pool',{'id':pool.UUIDString(),'stop':1,'confirm':1,'revision':review['revision']})
        pool=None
        assert not os.path.ismount(mount), 'Unregistration left the export mounted'
    # Exercise native CLI argument parsing and the same controller API.
    run('perl',str(module/'cli.pl'), 'create-pool','--name',name,
        '--server','127.0.0.1','--export',str(export),'--path',str(mount),'--no-autostart')
    pool=connection.storagePoolLookupByName(name)
    info=record()
    assert not info['autostart'] and info['type']=='netfs'
    api('pool_autostart',{'id':pool.UUIDString(),'revision':info['revision'],'enabled':1})
    # Copies must flatten raw and QCOW2 chains and survive source deletion.
    print(run('perl',str(module/'t/live/check-clone-storage.pl'),name),flush=True)
    # Boot only a disposable firmware VM to prove real QEMU access to NFS.
    disk=pool.createXML('<volume><name>guest.qcow2</name><capacity unit="MiB">32</capacity>'
        '<target><format type="qcow2"/></target></volume>',0)
    arch=connection.getInfo()[0]
    xml=ET.Element('domain',type='kvm')
    ET.SubElement(xml,'name').text=name
    ET.SubElement(xml,'memory',unit='MiB').text='256'
    ET.SubElement(xml,'vcpu').text='1'
    ET.SubElement(xml,'cpu',mode='host-passthrough')
    ET.SubElement(ET.SubElement(xml,'features'),'acpi')
    osnode=ET.SubElement(xml,'os',firmware='efi')
    ET.SubElement(osnode,'type',arch=arch,machine='virt' if arch=='aarch64' else 'q35').text='hvm'
    # Firmware reads the disk without installing or booting a guest OS.
    devices=ET.SubElement(xml,'devices')
    node=ET.SubElement(devices,'disk',type='file',device='disk')
    ET.SubElement(node,'driver',name='qemu',type='qcow2')
    ET.SubElement(node,'source',file=disk.path())
    ET.SubElement(node,'target',dev='vda',bus='virtio')
    guest=connection.defineXML(ET.tostring(xml,encoding='unicode'))
    guest.create()
    # A running domain alone does not prove QEMU can read the NFS disk.
    deadline=time.monotonic()+45
    while guest.blockStats('vda')[0] <= 0 and time.monotonic()<deadline:
        time.sleep(1)
    assert guest.isActive() and guest.blockStats('vda')[0]>0, 'Firmware did not read the NFS disk'
    if selinux_state:
        # Registration must enable guest access on an initially disabled host.
        assert run('getsebool','virt_use_nfs').endswith(' on'), 'NFS guest access stayed disabled'
        # Check the saved boot setting as well as the active kernel boolean.
        state=run('semanage','boolean','-l',env={**os.environ,'LC_ALL':'C'})
        assert re.search(r'^virt_use_nfs\s+\(on\s*,\s*on\)',state,re.M), 'NFS guest access was not persisted'
        print('PASS: registration enables persistent SELinux NFS access',flush=True)
    # Refuse to unmount a running guest's disk, then release the fixture guest.
    api('pool_stop',{'id':pool.UUIDString(),'revision':record()['revision']},fail='Stop virtual machines')
    print('PASS: QEMU reads NFS disk; active guest prevents unmount',flush=True)
    guest.destroy()
    guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    guest=None
    disk.delete(0)
    # Reuse durable backup, inspection, retention and restore rollback checks.
    print(run('perl',str(module/'t/live/check-backup-jobs.pl'),timeout=900,
        env={**os.environ,'CLOUDMIN_BACKUP_DESTINATION_ROOT':str(mount)}),flush=True)
    # Keep a remote marker while adding local data beneath the stopped mount.
    marker=mount/'preserve.txt'
    marker.write_text('export contents must survive pool lifecycle\n')
    api('pool_stop',{'id':pool.UUIDString(),'revision':record()['revision']})
    assert not os.path.ismount(mount)
    (mount/'local-file').write_text('do not hide me')
    api('pool_start',{'id':pool.UUIDString(),'revision':record()['revision']},fail='empty directory')
    (mount/'local-file').unlink()
    if selinux_state:
        # Exercise start independently of the registration-time policy write.
        run('setsebool','-P','virt_use_nfs','off')
    api('pool_start',{'id':pool.UUIDString(),'revision':record()['revision']})
    if selinux_state:
        # Restarting the pool must restore guest access too.
        assert run('getsebool','virt_use_nfs').endswith(' on'), 'Start did not enable NFS guest access'
    assert marker.read_text()=='export contents must survive pool lifecycle\n'
    # A second registration must never take over an already mounted target.
    api('register_pool',{'type':'netfs','name':name+'-duplicate','server':'127.0.0.1',
        'export':str(export),'path':str(mount)},fail='already mounted')
    # Unregistration must leave the remote marker intact after unmounting.
    review=api('pool_review',{'id':pool.UUIDString(),'stop':1})
    api('unregister_pool',{'id':pool.UUIDString(),'stop':1,'confirm':1,'revision':review['revision']})
    pool=None
    assert (export/'preserve.txt').read_text()=='export contents must survive pool lifecycle\n'
    (export/'preserve.txt').unlink()
    print('PASS: NFS lifecycle, nonempty-target protection and export preservation',flush=True)
    # Cover both Cloudmin registrations and definitions made outside Cloudmin.
    check_aliased_mount(False)
    check_aliased_mount(True)
finally:
    # Remove only this fixture's domain and pool before withdrawing its export.
    if guest:
        # A failed guest-access assertion can leave the domain running.
        if guest.isActive():
            guest.destroy()
        guest.undefineFlags(libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    if pool:
        # Failed lifecycle assertions can leave a pool active or merely defined.
        if pool.isActive():
            # Let libvirt attempt its normal unmount before checking the kernel.
            pool.destroy()
        # The alias regression deliberately leaves a mount behind libvirt.
        if os.path.ismount(mount):
            run('umount',str(mount))
        pool.undefine()
    if os.path.ismount(alias_mount):
        # The alias test also mounts the export outside libvirt.
        run('umount',str(alias_mount))
    assert not os.path.ismount(mount), 'Fixture mount needs manual cleanup: '+str(mount)
    if exported:
        # exportfs may merge both loopback addresses under the same hostname.
        while True:
            entries=[shlex.split(line) for line in run('exportfs','-s').splitlines()]
            entries=[fields for fields in entries if fields and fields[0]==str(export)]
            if not entries:
                # One removal may have cleared both aliases of the same export.
                break
            client=entries[0][1].split('(',1)[0]
            if ':' in client:
                # Keep an IPv6 client distinct from exportfs's path separator.
                client='['+client+']'
            run('exportfs','-u',client+':'+str(export))
    if started:
        # Leave a server that was already running before this fixture alone.
        run('systemctl','stop','nfs-server')
    if selinux_state:
        # Restore the saved boot policy and any separate temporary setting.
        run('setsebool','-P','virt_use_nfs',selinux_state[1])
        run('setsebool','virt_use_nfs',selinux_state[0])
    # Check existing guests and pools before deleting fixture directories.
    assert initial_domains=={d.UUIDString():d.isActive() for d in connection.listAllDomains()}, 'Existing domain state changed'
    assert initial_pools=={p.UUIDString():p.isActive() for p in connection.listAllStoragePools()}, 'Existing pool state changed'
    shutil.rmtree(mount,ignore_errors=True)
    shutil.rmtree(root)
    connection.close()
    print('PASS: fixture cleanup; existing VMs and pools unchanged',flush=True)
