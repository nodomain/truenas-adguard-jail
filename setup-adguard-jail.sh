#!/bin/bash
#
# Set up AdGuard Home in a FreeBSD VNET jail on TrueNAS CORE (13.x).
#
# Runs from your workstation. It pushes a payload to the NAS and executes it
# once via `sudo sh` over SSH (single sudo password prompt). iocage needs root;
# your API key is NOT used for this (the SSH path is more robust on CORE).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env not found at $ENV_FILE — copy .env.example to .env and edit it."
        exit 1
    fi
    set -a; source "$ENV_FILE"; set +a

    : "${TRUENAS_HOST:?set TRUENAS_HOST in .env}"
    : "${SSH_USER:?set SSH_USER in .env}"
    : "${JAIL_NAME:=adguard}"
    : "${JAIL_IP:?set JAIL_IP in .env}"
    : "${SUBNET_CIDR:=24}"
    : "${DEFAULT_ROUTER:=192.168.10.1}"
    # Optional IPv6 for the jail. Leave JAIL_IP6 empty to stay IPv4-only.
    : "${JAIL_IP6:=}"
    : "${SUBNET6_PREFIX:=64}"
    : "${DEFAULT_ROUTER6:=}"
    : "${BRIDGE:=bridge0}"
    : "${JAIL_RELEASE:=13.5-RELEASE}"

    # Web UI admin. If ADGUARD_ADMIN_PASSWORD is unset, `provision` preserves the
    # hash already stored in the jail (so re-provisioning keeps the same login).
    : "${ADGUARD_ADMIN_USER:=admin}"
    : "${ADGUARD_ADMIN_PASSWORD:=}"
}

TEMPLATE_FILE="${SCRIPT_DIR}/adguardhome/AdGuardHome.yaml.tmpl"
LOCAL_TEMPLATE_FILE="${SCRIPT_DIR}/adguardhome/AdGuardHome.local.tmpl"
RENDERED_FILE="${SCRIPT_DIR}/adguardhome/AdGuardHome.yaml"
JAIL_CONFIG_PATH="/usr/local/etc/adguardhome/AdGuardHome.yaml"
PW_PLACEHOLDER="@@ADMIN_PWHASH@@"

# Generate a bcrypt hash for the given password. Prefers htpasswd, falls back to
# python3 + bcrypt. Prints only the hash (e.g. $2y$05$...).
generate_bcrypt_hash() {
    local pw="$1" out
    if command -v htpasswd >/dev/null 2>&1; then
        # htpasswd -nbB prints "user:hash"; keep everything after the first colon.
        out="$(htpasswd -nbB "x" "$pw")" || return 1
        printf '%s' "${out#x:}"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        PW="$pw" python3 -c 'import os,bcrypt; print(bcrypt.hashpw(os.environ["PW"].encode(), bcrypt.gensalt()).decode())' && return 0
    fi
    return 1
}

# Run a one-line command on the NAS as root (TTY for the sudo prompt).
ssh_sudo() {
    ssh -t "${SSH_USER}@${TRUENAS_HOST}" "sudo $1"
}

# Build the remote setup payload (expands local vars now, escapes remote vars with \$).
# Installs the adguardhome package and deploys a daemon(8)-free rc script, because
# /usr/sbin/daemon is broken inside this iocage jail (see freebsd-rc/adguardhome).
generate_payload() {
cat <<REMOTE
set -e
JAIL_NAME="${JAIL_NAME}"
JAIL_IP="${JAIL_IP}"
CIDR="${SUBNET_CIDR}"
ROUTER="${DEFAULT_ROUTER}"
JAIL_IP6="${JAIL_IP6}"
PREFIX6="${SUBNET6_PREFIX}"
ROUTER6="${DEFAULT_ROUTER6}"
BRIDGE="${BRIDGE}"
RELEASE="${JAIL_RELEASE}"
RC_B64="${RC_B64}"
RCLOCAL_B64="${RCLOCAL_B64}"

echo "[remote] iocage release check..."
if ! iocage list -r | grep -q "\${RELEASE}"; then
    echo "[remote] fetching \${RELEASE} (this can take a while)..."
    iocage fetch -r "\${RELEASE}"
fi

# Optional IPv6 jail networking (only when JAIL_IP6 is set). Expanded unquoted in
# the create call below; values contain no spaces so word-splitting is fine.
IP6_CREATE_ARGS=""
if [ -n "\${JAIL_IP6}" ]; then
    IP6_CREATE_ARGS="ip6_addr=vnet0|\${JAIL_IP6}/\${PREFIX6}"
    [ -n "\${ROUTER6}" ] && IP6_CREATE_ARGS="\${IP6_CREATE_ARGS} defaultrouter6=\${ROUTER6}"
fi

if iocage list -H | awk '{print \$2}' | grep -qx "\${JAIL_NAME}"; then
    echo "[remote] jail \${JAIL_NAME} already exists - skipping create."
    if [ -n "\${JAIL_IP6}" ]; then
        echo "[remote] ensuring IPv6 (\${JAIL_IP6}/\${PREFIX6}) on existing jail..."
        iocage set ip6_addr="vnet0|\${JAIL_IP6}/\${PREFIX6}" "\${JAIL_NAME}"
        [ -n "\${ROUTER6}" ] && iocage set defaultrouter6="\${ROUTER6}" "\${JAIL_NAME}"
        # ip6_addr only applies on (re)start; restart if the jail is already up.
        iocage restart "\${JAIL_NAME}" || true
    fi
else
    echo "[remote] creating jail \${JAIL_NAME} (\${JAIL_IP}\${JAIL_IP6:+, \${JAIL_IP6}}) ..."
    iocage create -n "\${JAIL_NAME}" -r "\${RELEASE}" \\
        vnet=1 bpf=1 dhcp=0 boot=1 \\
        allow_raw_sockets=1 \\
        interfaces="vnet0:\${BRIDGE}" \\
        ip4_addr="vnet0|\${JAIL_IP}/\${CIDR}" \\
        defaultrouter="\${ROUTER}" \\
        \${IP6_CREATE_ARGS} \\
        resolver="nameserver \${ROUTER}"
fi

echo "[remote] starting jail..."
iocage start "\${JAIL_NAME}" || true

echo "[remote] installing adguardhome package..."
iocage exec "\${JAIL_NAME}" env ASSUME_ALWAYS_YES=YES pkg bootstrap -y || true
iocage exec "\${JAIL_NAME}" env ASSUME_ALWAYS_YES=YES pkg install -y adguardhome

echo "[remote] deploying daemon(8)-free rc script (iocage daemon workaround)..."
JAIL_ROOT="\$(iocage get -H mountpoint \${JAIL_NAME})/root"
echo "\${RC_B64}" | openssl base64 -d -A > "\${JAIL_ROOT}/usr/local/etc/rc.d/adguardhome"
chmod 555 "\${JAIL_ROOT}/usr/local/etc/rc.d/adguardhome"
mkdir -p "\${JAIL_ROOT}/usr/local/etc/adguardhome" "\${JAIL_ROOT}/var/db/adguardhome"

# Deploy rc.local: ensures the VNET interface gets an IPv6 link-local at boot
# (see freebsd-rc/rc.local). Harmless for IPv4-only jails.
echo "[remote] deploying rc.local (IPv6 link-local fix)..."
echo "\${RCLOCAL_B64}" | openssl base64 -d -A > "\${JAIL_ROOT}/etc/rc.local"
chmod 755 "\${JAIL_ROOT}/etc/rc.local"
iocage exec "\${JAIL_NAME}" sh -c 'grep -q "auto_linklocal=1" /etc/sysctl.conf 2>/dev/null || echo "net.inet6.ip6.auto_linklocal=1" >> /etc/sysctl.conf'
iocage exec "\${JAIL_NAME}" sh /etc/rc.local || true

echo "[remote] enabling + starting service..."
iocage exec "\${JAIL_NAME}" sysrc adguardhome_enable=YES
iocage exec "\${JAIL_NAME}" service adguardhome restart || true
sleep 3
iocage exec "\${JAIL_NAME}" sockstat -4 -l | grep -i adguard || echo "[remote] WARN: not listening yet, check logs"

echo "[remote] DONE. Setup wizard: http://\${JAIL_IP}:3000"
REMOTE
}

cmd_create() {
    log_step "Deploying AdGuard jail '${JAIL_NAME}' (${JAIL_IP}) to ${TRUENAS_HOST}"
    local payload remote_path RC_B64 RCLOCAL_B64
    if [[ ! -f "${SCRIPT_DIR}/freebsd-rc/adguardhome" ]]; then
        log_error "freebsd-rc/adguardhome not found"; exit 1
    fi
    if [[ ! -f "${SCRIPT_DIR}/freebsd-rc/rc.local" ]]; then
        log_error "freebsd-rc/rc.local not found"; exit 1
    fi
    RC_B64="$(base64 < "${SCRIPT_DIR}/freebsd-rc/adguardhome" | tr -d '\n')"
    RCLOCAL_B64="$(base64 < "${SCRIPT_DIR}/freebsd-rc/rc.local" | tr -d '\n')"
    payload="$(mktemp)"
    remote_path="/tmp/adguard-jail-payload.sh"
    generate_payload > "$payload"

    log_info "Copying payload to NAS..."
    scp -q "$payload" "${SSH_USER}@${TRUENAS_HOST}:${remote_path}"
    rm -f "$payload"

    log_info "Running setup as root (enter your sudo password when prompted)..."
    ssh_sudo "sh ${remote_path}; rm -f ${remote_path}"

    echo
    log_info "✓ Jail setup finished."
    log_info "Next steps:"
    echo "    1. Open the wizard:  http://${JAIL_IP}:3000"
    echo "    2. Set admin login, DNS listen = all interfaces : 53, Web UI = e.g. 3000"
    echo "    3. Point the Fritzbox (and/or clients) DNS to ${JAIL_IP}"
    echo "    4. Reserve/exclude ${JAIL_IP} in the Fritzbox (it is outside DHCP .20-.200)"
    echo "    5. Remove the AdGuard add-on from Home Assistant to free RAM"
}

# Build the remote provision payload: decode the rendered config, optionally
# splice the existing admin hash back in, deploy it, and restart the service.
generate_provision_payload() {
cat <<REMOTE
set -e
JAIL_NAME="${JAIL_NAME}"
CONFIG_PATH="${JAIL_CONFIG_PATH}"
PW_PLACEHOLDER="${PW_PLACEHOLDER}"
CFG_B64="${CFG_B64}"

JAIL_ROOT="\$(iocage get -H mountpoint \${JAIL_NAME})/root"
DEST="\${JAIL_ROOT}\${CONFIG_PATH}"
TMP="\$(mktemp)"

mkdir -p "\$(dirname "\${DEST}")" "\${JAIL_ROOT}/var/db/adguardhome"
echo "\${CFG_B64}" | openssl base64 -d -A > "\${TMP}"

# If the rendered config still contains the password placeholder, reuse the hash
# that is already stored in the jail so the existing login keeps working.
if grep -q "\${PW_PLACEHOLDER}" "\${TMP}"; then
    if [ ! -f "\${DEST}" ]; then
        echo "[remote] ERROR: no existing config to preserve the admin hash from." >&2
        echo "[remote] Set ADGUARD_ADMIN_PASSWORD in .env for the first provision." >&2
        rm -f "\${TMP}"; exit 1
    fi
    HASH="\$(awk '/^users:/{u=1} u&&/password:/{print \$2; exit}' "\${DEST}")"
    if [ -z "\${HASH}" ]; then
        echo "[remote] ERROR: could not read existing admin hash from \${DEST}." >&2
        rm -f "\${TMP}"; exit 1
    fi
    # bcrypt hashes contain no '|', so it is a safe sed delimiter here.
    sed "s|\${PW_PLACEHOLDER}|\${HASH}|" "\${TMP}" > "\${DEST}"
    echo "[remote] preserved existing admin password hash."
else
    cp "\${TMP}" "\${DEST}"
    echo "[remote] wrote config with admin hash from .env."
fi
rm -f "\${TMP}"

echo "[remote] restarting service..."
iocage exec "\${JAIL_NAME}" service adguardhome restart || true
sleep 3
iocage exec "\${JAIL_NAME}" sockstat -4 -l | grep -i adguard || echo "[remote] WARN: not listening yet, check logs"
echo "[remote] DONE."
REMOTE
}

cmd_provision() {
    log_step "Provisioning AdGuard config into jail '${JAIL_NAME}' on ${TRUENAS_HOST}"

    # Prefer the personal, gitignored override; fall back to the example template.
    local tmpl
    if [[ -f "${LOCAL_TEMPLATE_FILE}" ]]; then
        tmpl="${LOCAL_TEMPLATE_FILE}"
        log_info "Using local config template: ${tmpl##*/}"
    elif [[ -f "${TEMPLATE_FILE}" ]]; then
        tmpl="${TEMPLATE_FILE}"
        log_warn "No ${LOCAL_TEMPLATE_FILE##*/} found - using the EXAMPLE template ${tmpl##*/}."
        log_warn "Copy it to ${LOCAL_TEMPLATE_FILE##*/} and edit it to deploy your real config."
    else
        log_error "no config template found in ${SCRIPT_DIR}/adguardhome/"; exit 1
    fi

    # Resolve the admin password hash.
    local pw_hash
    if [[ -n "${ADGUARD_ADMIN_PASSWORD}" ]]; then
        log_info "Generating bcrypt hash for admin user '${ADGUARD_ADMIN_USER}'..."
        pw_hash="$(generate_bcrypt_hash "${ADGUARD_ADMIN_PASSWORD}")" || {
            log_error "Could not generate bcrypt hash (need htpasswd or python3+bcrypt)."; exit 1
        }
    else
        log_warn "ADGUARD_ADMIN_PASSWORD not set - will preserve the hash already in the jail."
        pw_hash="${PW_PLACEHOLDER}"
    fi

    # Render the template -> adguardhome/AdGuardHome.yaml (gitignored).
    log_info "Rendering ${tmpl##*/} -> ${RENDERED_FILE##*/}"
    USER_VAL="${ADGUARD_ADMIN_USER}" HASH_VAL="${pw_hash}" \
        awk '{ gsub(/@@ADMIN_USER@@/, ENVIRON["USER_VAL"]); gsub(/@@ADMIN_PWHASH@@/, ENVIRON["HASH_VAL"]); print }' \
        "${tmpl}" > "${RENDERED_FILE}"

    local CFG_B64 payload remote_path
    CFG_B64="$(base64 < "${RENDERED_FILE}" | tr -d '\n')"
    payload="$(mktemp)"
    remote_path="/tmp/adguard-provision-payload.sh"
    generate_provision_payload > "$payload"

    log_info "Copying provision payload to NAS..."
    scp -q "$payload" "${SSH_USER}@${TRUENAS_HOST}:${remote_path}"
    rm -f "$payload"

    log_info "Deploying config as root (enter your sudo password when prompted)..."
    ssh_sudo "sh ${remote_path}; rm -f ${remote_path}"

    echo
    log_info "✓ Provision finished. Web UI: http://${JAIL_IP}  (DNS on ${JAIL_IP}:53)"
}

cmd_status() {
    log_step "Jail status on ${TRUENAS_HOST}"
    ssh_sudo "iocage list"
    echo
    ssh_sudo "iocage exec ${JAIL_NAME} 'service adguardhome status'" || true
}

cmd_logs() {
    ssh_sudo "iocage exec ${JAIL_NAME} 'tail -n 50 /var/log/adguardhome.log 2>/dev/null || echo no-logs-yet'"
}

cmd_destroy() {
    log_warn "This will STOP and DESTROY the jail '${JAIL_NAME}' (AdGuard config is lost)."
    read -r -p "Type the jail name to confirm: " confirm
    [[ "$confirm" == "${JAIL_NAME}" ]] || { log_error "Aborted."; exit 1; }
    ssh_sudo "iocage stop ${JAIL_NAME}; iocage destroy -f ${JAIL_NAME}"
    log_info "Destroyed."
}

usage() {
cat <<EOF
Usage: $0 <command>

Commands:
  create     Create the jail + install AdGuard Home (idempotent)
  provision  Render the config template and deploy it into the jail
  status     Show jail + AdGuard service status
  logs       Tail AdGuard logs inside the jail
  destroy    Stop and destroy the jail (for rollback / clean retry)

Config comes from .env (see .env.example). Requires SSH access to the NAS as
SSH_USER with sudo rights. iocage runs as root via sudo.
EOF
}

main() {
    load_env
    case "${1:-}" in
        create)    cmd_create ;;
        provision) cmd_provision ;;
        status)    cmd_status ;;
        logs)    cmd_logs ;;
        destroy) cmd_destroy ;;
        *)       usage; exit 1 ;;
    esac
}

main "$@"
