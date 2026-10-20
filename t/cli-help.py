#!/usr/bin/python3
"""Check CLI help without initializing the installed module or changing guests."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import termios
import time

cli = ['perl', str(Path(__file__).resolve().parents[1] / 'cli.pl')]

# Redirected manuals stay plain; short help and usage errors never open a pager.
manual = subprocess.run([*cli, 'help', 'create-system'], capture_output=True, text=True)
assert manual.returncode == 0 and manual.stdout.startswith('create-system\n')
assert not manual.stderr and '\x1b' not in manual.stdout
short = subprocess.run([*cli, 'create-system', '--help'], capture_output=True, text=True)
assert short.returncode == 0 and 'cloudmin create-system [' in short.stdout
bad = subprocess.run([*cli, 'help', 'not-a-command'], capture_output=True, text=True)
assert bad.returncode == 2 and not bad.stdout and 'Unknown command' in bad.stderr
print('PASS plain manual, short syntax and unknown-command error')

# Exercise a real terminal, including quitting before the full manual is read.
pid, fd = pty.fork()
if pid == 0:
    # Keep the test independent of user settings and do not write pager history.
    os.environ['TERM'] = 'xterm'
    os.environ['LESS'] = ''
    os.environ['LESSHISTFILE'] = '-'
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 20, 80, 0, 0))
    os.execvp(cli[0], [*cli, 'help', 'create-system'])

done = False
output = b''
try:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        # Read only available output so a stalled pager cannot hang the test.
        if select.select([fd], [], [], 0.2)[0]:
            output += os.read(fd, 65536)
            # The temporary filename is the pager prompt, not manual content.
            if b'cloudmin-help-' in output:
                break
    assert b'cloudmin-help-' in output, 'Interactive help did not open a pager'
    assert b'create-system' in output and b'Creates a virtual machine' in output
    os.write(fd, b'q')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        # Drain terminal restoration output so the child cannot block on a PTY.
        if select.select([fd], [], [], 0.1)[0]:
            try:
                output += os.read(fd, 65536)
            # Some PTYs report EIO rather than EOF after the child exits.
            except OSError:
                pass
        child, status = os.waitpid(pid, os.WNOHANG)
        # Reap a completed pager and verify that quitting is a clean exit.
        if child:
            done = True
            assert os.waitstatus_to_exitcode(status) == 0, 'Quitting the pager failed'
            break
        time.sleep(0.1)
    assert done, ('Pager did not exit after q', output)
finally:
    # Clean up this test's process group after a failed assertion or timeout.
    if not done:
        try:
            os.killpg(pid, signal.SIGKILL)
        # The child may have exited between the timeout and group cleanup.
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
    os.close(fd)
print('PASS interactive manual and early pager exit')
