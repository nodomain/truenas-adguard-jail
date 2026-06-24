# TrueNAS AdGuard Jail

Deploy [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) (network-wide
DNS ad/tracker blocker) into a FreeBSD VNET jail on **TrueNAS CORE 13.x** — one
command from your workstation, with a working service and config-as-code.

## Why

Running AdGuard Home in a TrueNAS **CORE** jail is more fiddly than it should be:
there is no one-click app (that only exists on TrueNAS SCALE), the official
install script expects `curl`/`wget` that a stock jail doesn't ship, and — the
big one — the service won't stay up because `/usr/sbin/daemon` is broken in
iocage jails (see [the daemon(8) workaround](#important-the-daemon8-workaround)
below). Others keep running into the same wall, e.g.:

- [AdGuardHome#5431 — Installation on FreeBSD/TrueNAS jails](https://github.com/AdguardTeam/AdGuardHome/issues/5431)

This repo packages a working end-to-end setup — jail creation, a daemon-free rc
script, and config-as-code provisioning — so nobody has to rediscover these
workarounds. Sharing it to give back to the community.

> **Note on CORE:** TrueNAS CORE has no Docker; apps run in FreeBSD jails. The
> one-click "AdGuard Home" app exists only on **TrueNAS SCALE**. On CORE the
> robust path is an `iocage` jail with the native AdGuard FreeBSD binary — which
> is exactly what this script automates. (If the NAS is ever migrated to SCALE,
> AdGuard becomes a one-click app.)

## How it works

`setup-adguard-jail.sh create`:

1. Reads config from `.env`.
2. Generates a remote payload and copies it to the NAS via `scp`.
3. Runs it once as root via `ssh -t … sudo sh` (single sudo password prompt).
   The payload:
   - fetches the FreeBSD release if missing,
   - creates a **VNET jail** bridged to `bridge0` with a **static IP** and the
     Fritzbox as gateway/resolver,
   - installs the **`adguardhome` package** (`pkg install adguardhome`),
   - deploys a **daemon(8)-free rc script** (see below) and starts the service.

Because it is a VNET jail with its own IP stack, AdGuard binds port **53** inside
the jail without colliding with the host.

`setup-adguard-jail.sh provision` then applies the **config-as-code** settings
(see [Config as code](#config-as-code)) so you don't have to click through the
AdGuard setup wizard.

### Important: the daemon(8) workaround

In this iocage jail, FreeBSD's `/usr/sbin/daemon` is broken — its output
redirection does nothing and supervised processes don't stay up (even
`daemon -o file echo hi` yields an empty file). **Both** the AdGuard
self-installer rc script *and* the official FreeBSD port rc script rely on
`daemon(8)`, so the service "starts" but never listens. A plain background launch
works fine, so this project ships its own rc script (`freebsd-rc/adguardhome`)
that backgrounds the binary directly and tracks the PID itself. It also creates
the config dir (`/usr/local/etc/adguardhome`) and work dir (`/var/db/adguardhome`)
on start.

## Requirements

- TrueNAS CORE 13.x with `iocage` (already in use on this NAS)
- SSH access to the NAS as a user with `sudo` rights
- A **static IP outside the DHCP pool** (Fritzbox pool is `.20–.200`, so use
  `.2–.19` or `.201–.254`)

## Setup

```bash
cp .env.example .env
$EDITOR .env          # set TRUENAS_HOST, SSH_USER, JAIL_IP, ...
chmod +x setup-adguard-jail.sh
./setup-adguard-jail.sh create
```

### Finding a free IP

`scripts/scan-free-ips.sh` pings the static-safe ranges and lists free,
easy-to-remember addresses:

```bash
bash scripts/scan-free-ips.sh 192.168.10
```

Default in `.env.example` is **192.168.10.11** (right next to the NAS at `.10`).

## Configuration (`.env`)

| Variable | Meaning | Default |
|---|---|---|
| `TRUENAS_HOST` | NAS IP/hostname | `192.168.10.10` |
| `SSH_USER` | SSH user with sudo | `youruser` |
| `JAIL_NAME` | iocage jail name | `adguard` |
| `JAIL_IP` | static jail IP (outside DHCP) | `192.168.10.11` |
| `SUBNET_CIDR` | subnet bits | `24` |
| `DEFAULT_ROUTER` | gateway / Fritzbox | `192.168.10.1` |
| `JAIL_IP6` | static jail IPv6 (optional; empty = IPv4-only) | _(unset)_ |
| `SUBNET6_PREFIX` | IPv6 prefix length | `64` |
| `DEFAULT_ROUTER6` | IPv6 gateway (optional) | _(unset)_ |
| `BRIDGE` | iocage VNET bridge | `bridge0` |
| `JAIL_RELEASE` | FreeBSD release (already fetched) | `13.5-RELEASE` |

> AdGuard Home is installed from the FreeBSD package repo (`pkg install adguardhome`),
> so no download URL is needed.

### IPv6

IPv6 is **optional and off by default** (the jail comes up IPv4-only). To make
AdGuard reachable over IPv6:

1. Set `JAIL_IP6` (and optionally `DEFAULT_ROUTER6`) in `.env` to an address
   **outside** any DHCPv6/SLAAC pool — a GUA from your delegated prefix or a ULA
   (e.g. `fd00:dead:beef::11`).
2. Re-run `./setup-adguard-jail.sh create`. On a fresh jail the address is set at
   create time; on an existing jail it is applied via `iocage set` (takes effect
   after the jail restart the script performs).
3. Point IPv6 clients (or the router's advertised DNS) at the jail's IPv6.

The config template already listens on both `0.0.0.0` and `::`, serves `AAAA`
records, and includes IPv6 bootstrap/fallback resolvers, so DNS works over IPv6
transport as soon as the jail has a v6 address.

> **VNET link-local quirk:** in an iocage VNET jail the LAN interface is
> configured by the host before the jail's sysctls apply, so it can come up
> without an IPv6 link-local (`fe80::`) — which breaks neighbor discovery and
> makes the static address unreachable. `create` deploys
> [`freebsd-rc/rc.local`](freebsd-rc/rc.local), which re-asserts `auto_linklocal`
> at boot to fix this. Nothing to do manually.

### Admin login (for `provision`)

| Variable | Meaning | Default |
|---|---|---|
| `ADGUARD_ADMIN_USER` | web UI admin username | `admin` |
| `ADGUARD_ADMIN_PASSWORD` | admin password; hashed with bcrypt at provision time | _(unset)_ |

If `ADGUARD_ADMIN_PASSWORD` is left unset, `provision` **preserves the password
hash already stored in the jail**, so re-provisioning never locks you out. Set it
only for the first provision (or to rotate the password). The rendered config
with the hash is written to `adguardhome/AdGuardHome.yaml`, which is gitignored.

## Config as code

AdGuard is configured from a YAML template (schema_version 33) instead of the
setup wizard. Two files:

- **`adguardhome/AdGuardHome.yaml.tmpl`** — a sanitized **example** with generic
  placeholders (public upstreams, `example.lan` rewrites, illustrative rules).
  This is the committed, shareable version.
- **`adguardhome/AdGuardHome.local.tmpl`** — your **personal** config, gitignored.
  When present, `provision` uses it instead of the example.

To run your own config:

```bash
cp adguardhome/AdGuardHome.yaml.tmpl adguardhome/AdGuardHome.local.tmpl
$EDITOR adguardhome/AdGuardHome.local.tmpl   # set your upstreams, rules, rewrites
```

The template covers upstreams (incl. conditional/per-domain forwarding),
blocklists (defaults to HaGeZi Multi PRO + a threat-intelligence feed, with
annoyance/anti-bypass/NRD lists included but disabled), custom allow/block
`user_rules`, DNS rewrites, blocked services, DNSSEC, EDNS client subnet,
blocking mode, query-log/stats retention, and a 4 MB DNS cache.

`provision` renders the chosen template (substituting `@@ADMIN_USER@@` /
`@@ADMIN_PWHASH@@`), deploys it to `/usr/local/etc/adguardhome/AdGuardHome.yaml`
inside the jail, backs up the previous config, and restarts the service. Edit
the template and re-run `provision` to change settings.

## Commands

```bash
./setup-adguard-jail.sh create     # create jail + install AdGuard (idempotent)
./setup-adguard-jail.sh provision  # render config template + deploy into the jail
./setup-adguard-jail.sh update     # update the AdGuard package now (pkg + rc restore)
./setup-adguard-jail.sh status     # jail + AdGuard service status
./setup-adguard-jail.sh logs       # tail AdGuard logs
./setup-adguard-jail.sh destroy    # stop + destroy jail (rollback / clean retry)
```

### Optional: REST API helpers (`scripts/nas-*.py`)

`create`/`provision` use SSH + sudo (one password prompt). For non-interactive
automation there are optional Python helpers that talk to the jail through the
TrueNAS REST API instead, which runs as root and needs **no sudo**. They read
`TRUENAS_HOST` / `TRUENAS_API_KEY` / `JAIL_NAME` from `.env` (the key stays out
of git), so set `TRUENAS_API_KEY` first.

```bash
scripts/nas-exec.py '<cmd>'             # run a shell command inside the jail
scripts/nas-put-file.py <local> <dest>  # copy a file into the jail
scripts/nas-deploy-config.py            # render template + deploy config (no-sudo provision)
scripts/nas-jail-restart.py             # restart the jail
```

`nas_api.py` is the shared client used by all of them.

## After `create` — provision and go live

1. Apply the config (sets the admin login from `.env` and all settings):
   ```bash
   ./setup-adguard-jail.sh provision
   ```
   The web UI is then at `http://<JAIL_IP>` (port 80), DNS on `<JAIL_IP>:53`.
2. Point DNS to the jail:
   - **Fritzbox**: Home Network → Network → Network Settings → IPv4, set the
     local DNS server to `<JAIL_IP>` (or hand it out via DHCP), **or** set it
     per-client.
3. **Reserve/keep `<JAIL_IP>` free** in the Fritzbox (it is outside the DHCP
   pool, so just don't hand it to anything else).
4. *(If migrating from the Home Assistant AdGuard add-on:)* remove that add-on
   once the jail is serving, to free its resources.

> Prefer the wizard instead? Skip `provision` and open `http://<JAIL_IP>:3000`
> to configure AdGuard by hand.

## Updating

AdGuard Home is installed from `pkg`, so updates come from the FreeBSD package
repo (which can trail upstream AdGuard releases). The built-in AdGuard updater is
disabled on purpose (`--no-check-update`).

**The catch:** `pkg upgrade adguardhome` overwrites the daemon-free rc script
with the port's `daemon(8)`-based one, which doesn't work in this jail. The
bundled updater (`freebsd-rc/adguardhome-update`, deployed by `create` to
`/usr/local/sbin/adguardhome-update`) handles this: it upgrades the package and,
**only if the version actually changed**, restores the daemon-free rc and
restarts the service.

- **On demand:** `./setup-adguard-jail.sh update`
- **Automatic:** `create` installs a cron job in the jail that runs the updater
  on `AUTO_UPDATE_SCHEDULE` (default weekly, Sunday 04:00; set empty in `.env` to
  disable). Output is logged to `/var/log/adguardhome-update.log` in the jail.

## Self-healing watchdog

The daemon-free rc script launches AdGuard in the background but does **not**
supervise it. If the process dies — e.g. the host's **OOM-killer** reclaims it
under memory pressure (seen on this NAS) — DNS for the whole LAN stays down until
someone restarts it. `create` therefore installs
[`freebsd-rc/adguardhome-watchdog`](freebsd-rc/adguardhome-watchdog) to
`/usr/local/sbin/` and a cron entry that checks every minute and restarts AdGuard
if its PID is gone (logged to `/var/log/adguardhome-watchdog.log`). It is a cheap
no-op while the process is alive.

Schedule via `WATCHDOG_SCHEDULE` in `.env` (default `* * * * *` = every minute;
set empty to disable).

## Reliability note

DNS is critical infrastructure: if the NAS reboots, name resolution for the
whole LAN depends on it. Configure a **secondary DNS** (e.g. the Fritzbox itself
or `1.1.1.1`) as fallback on the router, and back up the AdGuard config
(`/usr/local/etc/adguardhome/AdGuardHome.yaml` inside the jail) occasionally.
`provision` already keeps a timestamped backup of the previous config next to it.

## Rollback

The old setup is untouched. To remove everything:

```bash
./setup-adguard-jail.sh destroy
```

Then point DNS back to your previous resolver (or re-enable the Home Assistant
AdGuard add-on, if that is where you came from).

## License

MIT
