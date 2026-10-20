#!/usr/bin/python3
"""Pass prepared sockets directly between the controller and isolated relay."""
import array
import os
import socket
import sys

# send count: root supplies listener on fd 0, optional display on fd 1, and
# the private handoff socket on fd 2. No browser data enters this helper.
if sys.argv[1:] in (['send', '1'], ['send', '2']):
    # Only the privileged setup process may hand off authorized sockets.
    if os.getuid() != 0 or os.geteuid() != 0:
        raise SystemExit('Only the controller may send relay sockets')
    count = int(sys.argv[2])
    channel = socket.socket(fileno=2)
    channel.settimeout(15)
    descriptors = array.array('i', range(count))
    channel.sendmsg([b'R'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, descriptors)])
# receive count interpreter script: systemd has already set the service's UID,
# namespaces and capabilities. Replace this bootstrap with a fresh Perl relay.
elif len(sys.argv) >= 5 and sys.argv[1] == 'receive' and sys.argv[2] in ('1', '2'):
    # Refuse to start the browser-facing relay with root privileges.
    if os.getuid() == 0 or os.geteuid() == 0:
        raise SystemExit('Relay sockets must be received without root privileges')
    count = int(sys.argv[2])
    channel = socket.socket(fileno=0)
    channel.settimeout(15)
    descriptors = array.array('i')
    marker, messages, flags, _ = channel.recvmsg(1, socket.CMSG_SPACE(count * descriptors.itemsize),
                                                socket.MSG_CMSG_CLOEXEC)
    for level, kind, data in messages:
        # Ignore ancillary records that do not contain passed descriptors.
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            descriptors.frombytes(data)
    # Reject partial or unexpected handoffs before replacing standard handles.
    if marker != b'R' or flags & socket.MSG_CTRUNC or len(descriptors) != count:
        raise SystemExit('Invalid relay socket handoff')
    channel.close()
    # The received sockets replace stdin and, for a console, stdout. Original
    # descriptor copies are closed; diagnostics remain on fd 2.
    for target, source in enumerate(descriptors):
        os.dup2(source, target, inheritable=True)
        os.close(source)
    os.execv(sys.argv[3], sys.argv[3:])
else:
    # The helper supports only the controller's fixed send and receive forms.
    raise SystemExit('Invalid relay socket operation')
