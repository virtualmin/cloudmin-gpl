#!/usr/bin/python3
"""Run silence worker checks against a loopback-only receiver on a debug VM.

Pass the installed module and an existing /tmp/cloudmin-silences.* directory.
All notification data is private to the fixture and removed afterward.
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading

# Run only as root on Linux, with no data left from an earlier run.
assert sys.platform.startswith('linux') and os.geteuid() == 0
module, task = map(Path, sys.argv[1:3])
assert task.parent == Path('/tmp') and task.name.startswith('cloudmin-silences.')
assert not (task / 'data').exists(), 'Fixture data already exists'
# Messages the loopback receiver accepted, in order.
received = []


class Sink(http.server.BaseHTTPRequestHandler):
    """Accept only this fixture's messages on loopback."""

    def do_POST(self):
        """do_POST(self) records a notification and acknowledges delivery."""
        received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_args):
        """log_message(self, [args...]) keeps requests out of console logs."""


# Serve on a free loopback port while the Perl checks run.
with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Sink) as sink:
    threading.Thread(target=sink.serve_forever, daemon=True).start()
    try:
        # Expect one fresh alert per scope and no muted backlog.
        subprocess.run(['perl', str(module / 't/live/check-notification-silences.pl'),
                        str(module), str(task / 'data'), str(sink.server_port)],
                       check=True, timeout=90)
        assert [event['name'] for event in received] == [
            'Live filesystem', 'Guest mute fixture'], 'Unexpected delivery backlog'
        assert all(event['phase'] == 'firing' for event in received)
        print('PASS real worker, filesystem probe, manual unmute and HTTP delivery', flush=True)
    finally:
        # Remove only this run's private store and stop its receiver.
        sink.shutdown()
        shutil.rmtree(task / 'data', ignore_errors=True)
