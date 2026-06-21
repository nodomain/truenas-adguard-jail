#!/usr/bin/env python3
"""Restart the jail (host-level) via the TrueNAS CORE REST API (no sudo).

Usage: scripts/nas-jail-restart.py
Config (TRUENAS_HOST/TRUENAS_API_KEY/JAIL_NAME) comes from .env — see nas_api.py.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nas_api import Nas


def main():
    print("[restart] submitting jail.restart ...")
    state, _, job = Nas().restart_jail()
    print(f"[restart] {state}")
    if state != "SUCCESS":
        print(job.get("error") or job, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
