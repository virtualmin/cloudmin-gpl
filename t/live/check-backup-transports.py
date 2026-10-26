#!/usr/bin/python3
"""Exercise SSH and S3 transports against private services on a Linux test host."""
import argparse,json,os,pwd,secrets,shutil,socket,subprocess,sys,tempfile,time
from pathlib import Path
# Real daemon and transport tests belong only on an authorized Linux test host.
if sys.platform!='linux' or os.geteuid(): raise SystemExit('Run as root on a Linux test host')
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--moto',type=Path,help='Path to the moto_server executable')
args=parser.parse_args()
module=Path(__file__).resolve().parents[2]
processes=[]
password_user=None

def port():
    """port() selects a loopback-only fixture listener."""
    with socket.socket() as sock: sock.bind(('127.0.0.1',0)); return sock.getsockname()[1]


def ready(number):
    """ready(number) waits for the fixture, without contacting any other address."""
    for _ in range(100):
        try:
            with socket.create_connection(('127.0.0.1',number),.2): return
        except OSError: time.sleep(.1)
    raise AssertionError('Fixture service did not start')

with tempfile.TemporaryDirectory(prefix='cloudmin-backup-transfer-',dir='/var/tmp') as temp:
    work=Path(temp)
    # VM-local fixture keys never leave the test host or appear in output.
    for name in ('host','client'):
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(work/name)],check=True)
    source=work/'input.tar'; source.write_bytes(secrets.token_bytes(17*1024**2))
    destination=work/'destination'; destination.mkdir(mode=0o700)
    request=work/'request.json'
    def transfer(target, operation='', fail=False, **fields):
        """transfer(target, [operation], [fail], **fields) calls the real workers."""
        request.write_text(json.dumps({'target':target,'file':str(source),'directory':str(work),
                                      'operation':operation, **fields})); request.chmod(0o600)
        result=subprocess.run(['perl',str(module/'t/live/backup-transfer.pl'),str(request)],
                              capture_output=True,text=True,timeout=300)
        # Negative cases must fail rather than treating missing trust as
        # success.
        if fail:
            assert result.returncode, 'Untrusted SSH server was accepted'
            return result.stderr
        assert result.returncode == 0, result.stderr
        # Trust probes return JSON; transfer checks return a human-readable
        # result.
        if operation in ('check','approve'): return json.loads(result.stdout)
        print(result.stdout.strip())
    # Start a private SSH service without changing the host's daemon or keys.
    try:
        number=port()
        config=work/'sshd_config'
        config.write_text(f'''Port {number}
ListenAddress 127.0.0.1
HostKey {work}/host
PidFile {work}/sshd.pid
AuthorizedKeysFile {work}/client.pub
StrictModes no
PermitRootLogin prohibit-password
PasswordAuthentication no
UsePAM no
Subsystem sftp internal-sftp
''')
        log=(work/'sshd.log').open('w')
        processes.append(subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log))
        ready(number)
        target={'mode':'ssh','host':'127.0.0.1','port':number,'user':'root','key_file':str(work/'client'),'path':str(destination)}
        # Unknown hosts must fail preflight and transfer until explicitly
        # approved.
        unknown=transfer(target,'check')
        assert unknown['status']=='unknown'
        assert 'is unknown' in transfer(target,'preflight',fail=True)
        assert 'is unknown' in transfer(target,fail=True)
        assert 'changed again' in transfer(target,'approve',fail=True,previous=unknown['previous'],proposed='wrong')
        transfer(target,'approve',previous=unknown['previous'],proposed=unknown['proposed'])
        transfer(target)
        # Rotate only this private fixture server; the host's SSH service is untouched.
        processes[-1].terminate(); processes[-1].wait(timeout=10)
        (work/'host').unlink(); (work/'host.pub').unlink()
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(work/'host')],check=True)
        processes.append(subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log))
        ready(number)
        changed=transfer(target,'check')
        assert changed['status']=='changed' and changed['old']==unknown['current']
        assert 'has changed' in transfer(target,'preflight',fail=True)
        assert 'Host key verification failed' in transfer(target,fail=True)
        transfer(target,'approve',previous=changed['previous'],proposed=changed['proposed'])
        transfer(target)
        # Native hashed known_hosts entries work without copying a raw key into a form.
        shutil.rmtree(work/'trust')
        (work/'known').write_text(f"[127.0.0.1]:{number} "+(work/'host.pub').read_text())
        subprocess.run(['ssh-keygen','-H','-f',str(work/'known')],check=True,capture_output=True)
        assert transfer(target,'check')['status']=='trusted'
        transfer(target)
        print('SSH: unknown, changed, explicit replacement and hashed known_hosts checks passed')
        # A separate account exercises password SFTP without changing root's login.
        username='cloudmin-backup-'+secrets.token_hex(4)
        subprocess.run(['useradd','-M','-d',str(work),'-s','/usr/sbin/nologin',username],check=True)
        password_user=username
        password=secrets.token_urlsafe(32)
        subprocess.run(['chpasswd'],input=username+':'+password+'\n',text=True,check=True)
        account=pwd.getpwnam(username)
        work.chmod(0o711)
        os.chown(destination,account.pw_uid,account.pw_gid)
        processes[-1].terminate(); processes[-1].wait(timeout=10)
        config.write_text(config.read_text().replace('PasswordAuthentication no','PasswordAuthentication yes'))
        processes.append(subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log))
        ready(number)
        password_target={**target,'user':username,'password':password}
        del password_target['key_file']
        transfer(password_target)
        print('SSH: password authentication round trip passed')
        # Optional S3 coverage uses a private TLS emulator, not a public
        # account.
        if args.moto:
            number=port()
            cert,key=work/'cert.pem',work/'key.pem'
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',str(key),'-out',str(cert),'-subj','/CN=localhost','-addext','subjectAltName=IP:127.0.0.1'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            log=(work/'moto.log').open('w')
            processes.append(subprocess.Popen([str(args.moto),'-H','127.0.0.1','-p',str(number),'-c',str(cert),'-k',str(key)],stdout=log,stderr=log))
            ready(number)
            # Scope credentials and CA trust to this fixture service.
            target={'mode':'s3','bucket':'cloudmin-backups','path':'fixture','region':'us-east-1','endpoint':f'https://127.0.0.1:{number}','ca_file':str(cert),'access':secrets.token_hex(10),'secret':secrets.token_hex(20)}
            env={**os.environ,'AWS_ACCESS_KEY_ID':target['access'],'AWS_SECRET_ACCESS_KEY':target['secret'],'AWS_DEFAULT_REGION':'us-east-1','AWS_CA_BUNDLE':str(cert),'AWS_EC2_METADATA_DISABLED':'true'}
            subprocess.run(['aws','--endpoint-url',target['endpoint'],'s3api','create-bucket','--bucket',target['bucket']],check=True,env=env,stdout=subprocess.DEVNULL)
            transfer(target)
        assert not list(destination.iterdir()),'SSH transfer left a partial archive'
    # Stop owned daemons before TemporaryDirectory removes their files.
    finally:
        for process in processes: process.terminate()
        for process in processes:
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        # Remove only the account created by this run, after its sessions close.
        if password_user:
            subprocess.run(['userdel',password_user],check=True)
