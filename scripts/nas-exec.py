#!/usr/bin/env python3
"""Run a shell command inside the jail via the TrueNAS CORE REST API (no sudo).

Usage: scripts/nas-exec.py '<shell command>'
Config (TRUENAS_HOST/TRUENAS_API_KEY/JAIL_NAME) comes from .env — see nas_api.py.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nas_api import Nas


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: nas-exec.py '<shell command>'")
    state, result = Nas().jail_exec(sys.argv[1])
    sys.stdout.write(result)
    if not result.endswith("\n"):
        sys.stdout.write("\n")
    sys.exit(0 if state == "SUCCESS" else 1)


if __name__ == "__main__":
    main()
