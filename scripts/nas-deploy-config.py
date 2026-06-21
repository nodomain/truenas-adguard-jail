#!/usr/bin/env python3
"""Render the AdGuard config template and deploy it into the jail via the
TrueNAS CORE REST API (no sudo) — an alternative to `setup-adguard-jail.sh
provision` for when you do not want to type a sudo password.

It prefers adguardhome/AdGuardHome.local.tmpl, falls back to the example
template, renders the admin user/password, writes the rendered file to
adguardhome/AdGuardHome.yaml (gitignored), then backs up the current jail config,
deploys the new one, restarts the service and verifies the listeners.

Admin password:
  - ADGUARD_ADMIN_PASSWORD set  -> hashed with htpasswd or python bcrypt
  - unset                       -> the hash already in the jail is preserved

Usage: scripts/nas-deploy-config.py
Config comes from .env (see nas_api.py): TRUENAS_HOST/TRUENAS_API_KEY/JAIL_NAME
plus ADGUARD_ADMIN_USER / ADGUARD_ADMIN_PASSWORD.
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nas_api import Nas, load_env

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL_TMPL = os.path.join(REPO, "adguardhome", "AdGuardHome.local.tmpl")
EXAMPLE_TMPL = os.path.join(REPO, "adguardhome", "AdGuardHome.yaml.tmpl")
RENDERED = os.path.join(REPO, "adguardhome", "AdGuardHome.yaml")
JAIL_CONFIG = "/usr/local/etc/adguardhome/AdGuardHome.yaml"
PLACEHOLDER = "@@ADMIN_PWHASH@@"


def bcrypt_hash(password):
    """Return a bcrypt hash via htpasswd or python bcrypt, or None if neither works."""
    try:
        out = subprocess.check_output(["htpasswd", "-nbB", "x", password], text=True)
        return out.strip().split(":", 1)[1]
    except (OSError, subprocess.CalledProcessError, IndexError):
        pass
    try:
        import bcrypt

        return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    except Exception:
        return None


def main():
    load_env()
    nas = Nas()

    tmpl = LOCAL_TMPL if os.path.exists(LOCAL_TMPL) else EXAMPLE_TMPL
    if not os.path.exists(tmpl):
        sys.exit(f"no template found in {os.path.join(REPO, 'adguardhome')}")
    print(f"[deploy] template: {os.path.basename(tmpl)}")

    admin_user = os.environ.get("ADGUARD_ADMIN_USER", "admin")
    password = os.environ.get("ADGUARD_ADMIN_PASSWORD", "")
    if password:
        pw_hash = bcrypt_hash(password)
        if not pw_hash:
            sys.exit("could not hash password (need htpasswd or python bcrypt)")
        print(f"[deploy] hashed password for admin '{admin_user}'")
    else:
        # Preserve the hash already stored in the jail.
        state, result = nas.jail_exec(
            f"awk '/^users:/{{u=1}} u&&/password:/{{print $2; exit}}' {JAIL_CONFIG}"
        )
        pw_hash = result.strip()
        if state != "SUCCESS" or not pw_hash:
            sys.exit(
                "ADGUARD_ADMIN_PASSWORD unset and no existing hash found in the jail; "
                "set it for the first deploy."
            )
        print("[deploy] preserving existing admin password hash")

    rendered = (
        open(tmpl)
        .read()
        .replace("@@ADMIN_USER@@", admin_user)
        .replace(PLACEHOLDER, pw_hash)
    )
    with open(RENDERED, "w") as f:
        f.write(rendered)
    print(f"[deploy] rendered -> {os.path.relpath(RENDERED, REPO)}")

    state, result = nas.jail_exec(
        f"[ -f {JAIL_CONFIG} ] && cp {JAIL_CONFIG} {JAIL_CONFIG}.bak-$(date +%Y%m%d-%H%M%S); "
        f"ls -1 {JAIL_CONFIG}.bak-* 2>/dev/null | tail -n1 || echo 'no existing config'"
    )
    print(f"[deploy] backup: {result.strip()}")

    state, result = nas.put_file(RENDERED, JAIL_CONFIG, "644")
    if state != "SUCCESS":
        sys.exit("[deploy] writing config FAILED")
    print(f"[deploy] wrote config ({result.strip()})")

    nas.jail_exec("service adguardhome restart || true")
    time.sleep(3)
    _, result = nas.jail_exec(
        "sockstat -4 -l | grep -i adguard || echo 'NOT LISTENING'"
    )
    print("[deploy] listeners:")
    print(result.rstrip())
    print("[deploy] done.")


if __name__ == "__main__":
    main()
