#!/usr/bin/python3
"""Keep the guest-health check entry point after replacing HTTP polling."""
import runpy
from pathlib import Path

runpy.run_path(str(Path(__file__).with_name('check-status-socket.py')), run_name='__main__')
