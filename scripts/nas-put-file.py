#!/usr/bin/env python3
"""Copy a local file into the jail via the TrueNAS CORE REST API (no sudo).

Usage: scripts/nas-put-file.py <local-path> <jail-dest-path> [mode]
Config (TRUENAS_HOST/TRUENAS_API_KEY/JAIL_NAME) comes from .env — see nas_api.py.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nas_api import Nas


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: nas-put-file.py <local-path> <jail-dest-path> [mode]")
    local, dest = sys.argv[1], sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else "644"
    if not os.path.exists(local):
        sys.exit(f"local file not found: {local}")
    state, result = Nas().put_file(local, dest, mode)
    print(result.rstrip())
    if state != "SUCCESS":
        sys.exit(1)
    print(f"[put-file] wrote {dest} (mode {mode})")


if __name__ == "__main__":
    main()
