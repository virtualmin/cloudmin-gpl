"""Private SSH server for browser host-key confirmation and replacement tests."""
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time


# SSHFixture owns an isolated listener, credentials and its resulting trust
# entry.
class SSHFixture:
    # __init__(self, module) owns a loopback listener and temporary
    # public/private keys.
    def __init__(self, module):
        self.module = module
        self.temp = tempfile.TemporaryDirectory(prefix='cloudmin-ssh-ui-', dir='/var/tmp')
        self.work = Path(self.temp.name)
        self.process = None
        self.trust = None
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]

    # __enter__(self) starts only the fixture daemon, leaving the host SSH
    # service alone.
    def __enter__(self):
        try:
            for name in ('host', 'client'):
                self.key(name)
            self.config = self.work/'sshd_config'
            self.config.write_text(f'''Port {self.port}
ListenAddress 127.0.0.1
HostKey {self.work}/host
PidFile {self.work}/pid
AuthorizedKeysFile {self.work}/client.pub
StrictModes no
PermitRootLogin prohibit-password
PasswordAuthentication no
UsePAM no
Subsystem sftp internal-sftp
''')
            # Repeated key scans intentionally disconnect before authentication.
            # Recent OpenSSH versions penalize them; disable this only for the
            # private fixture listener, leaving the system SSH service alone.
            supported = subprocess.run(['/usr/sbin/sshd', '-T', '-f', str(self.config),
                '-o', 'PerSourcePenalties=no'], stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL).returncode == 0
            # Older sshd versions must not receive an unsupported setting.
            if supported:
                with self.config.open('a') as config:
                    config.write('PerSourcePenalties no\n')
            # Discover the real approval path, but never overwrite existing
            # trust.
            request = self.work/'request.json'
            request.write_text(json.dumps({'operation':'trust_path', 'target':{'host':'127.0.0.1','port':self.port}}))
            result = subprocess.run(['perl', str(self.module/'t/live/backup-transfer.pl'), str(request)],
                                    text=True, capture_output=True, check=True)
            trust = Path(result.stdout.strip())
            assert not trust.exists(), 'Fixture endpoint already has saved trust'
            self.trust = trust
            self.start()
            return self
        # Failed setup must release the same resources as a normal context exit.
        except BaseException:
            self.__exit__(None, None, None)
            raise

    # key(self, name) creates a guest-local credential without printing it.
    def key(self, name):
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.work/name)], check=True)

    # start(self) waits for the private listener before browser checks use it.
    def start(self):
        self.process = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(self.config)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', self.port), .2):
                    return
            except OSError:
                time.sleep(.1)
        raise AssertionError('SSH fixture did not start')

    # rotate(self) simulates a legitimate server reinstall without changing its
    # address.
    def rotate(self):
        self.process.terminate()
        self.process.wait(timeout=10)
        (self.work/'host').unlink()
        (self.work/'host.pub').unlink()
        self.key('host')
        self.start()

    # reset(self) removes only the trust entry this fixture created.
    def reset(self):
        self.trust.unlink(missing_ok=True)

    # __exit__(self, *unused) cleans up; context-manager exception arguments are
    # ignored.
    def __exit__(self, *unused):
        # Stop only the daemon owned by this fixture before removing its files.
        if self.process:
            self.process.terminate()
            self.process.wait(timeout=10)
        # Setup may fail before the trust path is known.
        if self.trust:
            self.reset()
        self.temp.cleanup()
