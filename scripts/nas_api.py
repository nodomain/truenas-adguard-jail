#!/usr/bin/env python3
"""
Shared client for the TrueNAS CORE REST API.

Reads connection details from the repo `.env` (or the environment):
  TRUENAS_HOST      NAS IP/hostname
  TRUENAS_API_KEY   API key (create one in the TrueNAS UI; keep it in .env)
  JAIL_NAME         target jail name (default: adguard)

The REST API runs as root and needs no sudo, which makes it handy for
non-interactive automation against the jail. `.env` is gitignored, so the key
never lands in version control.
"""
import base64
import json
import os
import ssl
import sys
import time
import urllib.request


def load_env(path=None):
    """Populate os.environ from a KEY=VALUE .env file (without overriding real env)."""
    if path is None:
        path = os.path.join(os.path.dirname(__file__), "..", ".env")
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))
    except FileNotFoundError:
        pass
    return os.environ


class Nas:
    def __init__(self):
        load_env()
        self.host = os.environ.get("TRUENAS_HOST")
        self.key = os.environ.get("TRUENAS_API_KEY")
        self.jail = os.environ.get("JAIL_NAME", "adguard")
        missing = [
            name
            for name, val in (("TRUENAS_HOST", self.host), ("TRUENAS_API_KEY", self.key))
            if not val
        ]
        if missing:
            sys.exit(f"[nas] missing in .env/environment: {', '.join(missing)}")
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE  # TrueNAS uses a self-signed cert

    def api(self, path, payload=None):
        url = f"https://{self.host}/api/v2.0/{path}"
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, context=self.ctx, timeout=60) as resp:
            return json.loads(resp.read().decode())

    def _wait(self, job_id, tries=180, interval=2):
        if not isinstance(job_id, int):
            raise RuntimeError(f"expected a job id, got: {job_id!r}")
        for _ in range(tries):
            job = self.api(f"core/get_jobs?id={job_id}")[0]
            if job["state"] in ("SUCCESS", "FAILED"):
                return job["state"], (job.get("result") or ""), job
            time.sleep(interval)
        raise RuntimeError(f"timeout waiting for job {job_id}")

    def jail_exec(self, cmd):
        """Run `sh -c cmd` inside the jail. Returns (state, result).

        Commands are suffixed with `; true` so a non-zero exit does not mark the
        job FAILED (which would drop the captured output).
        """
        job_id = self.api(
            "jail/exec",
            {"jail": self.jail, "command": ["sh", "-c", cmd + " ; true"]},
        )
        state, result, _ = self._wait(job_id, tries=120, interval=1)
        return state, result

    def put_file(self, local, dest, mode="644"):
        """Copy a local file into the jail (base64-encoded to avoid quoting issues)."""
        b64 = base64.b64encode(open(local, "rb").read()).decode()
        cmd = (
            f"printf '%s' '{b64}' | openssl base64 -d -A > {dest} && "
            f"chmod {mode} {dest} && wc -c {dest}"
        )
        return self.jail_exec(cmd)

    def restart_jail(self):
        """Restart the jail (host-level) and wait for the job."""
        return self._wait(self.api("jail/restart", self.jail))
