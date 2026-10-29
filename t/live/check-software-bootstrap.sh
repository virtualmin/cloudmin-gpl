#!/bin/sh
# Run only in a disposable container, with this checkout mounted at /work.
set -eu
test -f /run/.containerenv || {
	echo 'Run this fixture in a disposable Podman container' >&2
	exit 1
}
cd /work
mkdir -p /usr/local/lib/cloudmin
cp guest-software.pl /usr/local/lib/cloudmin/guest-software.pl
sh guest-software-bootstrap.sh
perl -c software-worker.pl
perl t/live/guest-software-smoke.pl

# Python is installed only for the test driver, after production Perl passes.
if command -v apt-get >/dev/null 2>&1; then
	# Debian-family containers need Python only to run the protocol tests.
	apt-get install -y -- python3
elif command -v dnf >/dev/null 2>&1; then
	# Keep Enterprise Linux's test runtime separate from helper dependencies.
	dnf install -y -- python3
else
	# The remaining supported bootstrap target uses zypper.
	zypper --non-interactive install -- python3
fi
PYTHONDONTWRITEBYTECODE=1 python3 t/software-guest.py
