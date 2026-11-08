#!/usr/bin/env python3
"""iso-alpine-console.py uuid name phase: install or verify a fixture via serial.

Called by check-iso-install.pl on a disposable Linux Cloudmin host. Only its
named fixture is accessed. Each phase shuts the guest down before returning.
"""

import os
import pty
import re
import select
import shlex
import subprocess
import sys
import time


class Console:
    """Console(uuid): open the fixture's serial console through virsh."""

    def __init__(self, uuid):
        # __init__(self, uuid) connects virsh to a private pseudo-terminal.
        self.master, slave = pty.openpty()
        self.child = subprocess.Popen(
            ["virsh", "-c", "qemu:///system", "console", uuid],
            stdin=slave,
            stdout=slave,
            stderr=slave,
        )
        os.close(slave)
        self.buffer = ""

    def send(self, value):
        """send(value): write text to the guest's serial terminal."""
        os.write(self.master, value.encode())

    def expect(self, pattern, timeout=180):
        """expect(pattern, [timeout]): consume output through a regex match."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = re.search(pattern, self.buffer)
            if match:
                # Keep unread output for the next prompt or command result.
                self.buffer = self.buffer[match.end() :]
                return match
            if select.select([self.master], [], [], 1)[0]:
                # Stream diagnostics without keeping an unbounded transcript.
                data = os.read(self.master, 65536).decode(errors="replace")
                # Treat a closed terminal as a failure instead of waiting
                # until timeout.
                if not data:
                    raise RuntimeError("Serial console closed")
                sys.stdout.write(data)
                sys.stdout.flush()
                self.buffer = (self.buffer + data)[-131072:]
        raise RuntimeError(f"Timed out waiting for {pattern}")

    def run(self, command, timeout=120):
        """
        run(command, [timeout]): execute a guest command and require success.
        """
        self.send(
            "sh -c "
            + shlex.quote("set -e; " + command)
            + "; printf '\\n%s:%s\\n' CLOUDMIN_COMPLETE $?\n"
        )
        match = self.expect(r"\r?\nCLOUDMIN_COMPLETE:(\d+)\r?\n", timeout)
        if match.group(1) != "0":
            # Report the failed phase instead of continuing on a
            # partial install.
            raise RuntimeError("Guest command failed: " + match.group(1))
        self.expect(r"[^\r\n]*[~/#] ?# ")

    def close(self):
        """close(): release virsh and the host pseudo-terminal."""
        self.child.terminate()
        try:
            self.child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # Kill only this fixture's console client if it ignores termination.
            self.child.kill()
            self.child.wait()
        os.close(self.master)


def main():
    """main(): validate ownership, run one console phase and await shutdown."""
    # Serial-console installation belongs on a privileged Linux test guest.
    if sys.platform != "linux" or os.getuid() != 0 or len(sys.argv) != 4:
        raise SystemExit(
            "Run as root on a disposable Linux host: uuid name install|verify"
        )
    uuid, name, phase = sys.argv[1:]
    actual = subprocess.check_output(
        ["virsh", "-c", "qemu:///system", "domname", uuid], text=True
    ).strip()
    # Verify the UUID still belongs to the named disposable guest.
    if not name.startswith("cloudmin-iso-check-") or actual != name:
        raise SystemExit("Fixture guest ownership changed")
    # Reject unknown phases before sending any guest commands.
    if phase not in ("install", "verify"):
        raise SystemExit("Unknown console phase")

    console = Console(uuid)
    try:
        # Alpine's live ISO and this short-lived installation use console login.
        console.expect("Escape character is")
        console.send("\n")
        console.expect(r"login: ")
        console.send("root\n")
        console.expect(r"[^\r\n]*[~/#] ?# ")
        if phase == "install":
            # Partition only the new guest disk, using Alpine's own installer.
            console.run(
                "test -b /dev/vda; test -f /etc/alpine-release; "
                "setup-hostname cloudmin-iso-installed; "
                "printf '%s\\n' 'auto lo' 'iface lo inet loopback' 'auto eth0' "
                "'iface eth0 inet dhcp' > /etc/network/interfaces; "
                "rc-update add networking boot; rc-service networking restart; "
                "release=$(cut -d. -f1,2 /etc/alpine-release); "
                "printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/main\\n' "
                '"$release" > /etc/apk/repositories; '
                "apk update; touch /etc/cloudmin-iso-install-check; "
                "printf 'y\\n' | setup-disk -m sys -s 0 /dev/vda",
                480,
            )
        else:
            # A persisted marker and block-backed root prove this is
            # the install.
            console.run(
                "test -f /etc/cloudmin-iso-install-check; "
                "test $(hostname) = cloudmin-iso-installed; "
                "awk '$2 == \"/\" && $1 ~ /^\\/dev\\// { found=1; print } "
                "END { exit !found }' /proc/mounts; cat /etc/alpine-release"
            )
        console.send("poweroff\n")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            state = subprocess.check_output(
                ["virsh", "-c", "qemu:///system", "domstate", uuid],
                text=True,
                env={**os.environ, "LC_ALL": "C"},
            ).strip()
            if state == "shut off":
                # The caller can now change media and cold-boot the guest.
                print(f"PASS: Alpine {phase} and clean shutdown", flush=True)
                return
            time.sleep(1)
        raise RuntimeError("Alpine did not shut down")
    finally:
        console.close()


# Run the requested console phase when invoked directly.
if __name__ == "__main__":
    main()
