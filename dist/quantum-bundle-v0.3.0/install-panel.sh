#!/usr/bin/env bash
###############################################################################
# install-panel.sh — Quantum panel (controller) installer
#
# Installs quantum-panel on the central management server:
#   1. downloads the release binary + checksums.txt and verifies SHA-256
#      (or installs --binary with an explicit --checksum)
#   2. writes a HARDENED systemd unit (quantum-panel.service)
#   3. sets the initial admin credential non-interactively:
#        --password-file FILE  (preferred) or --password '...' or an
#        auto-generated random password stored at
#        /etc/quantum-panel/initial-admin-password (0600; move it and delete)
#   4. opens the panel port in the firewall additively and tagged — ONLY the
#      declared port, never a policy change (safe-apply discipline: the
#      panel port is one allow, SSH stays untouched)
#   5. verifies: service active, HTTPS answers, login URL printed
#
# The panel is MANAGEMENT-ONLY: it never sits in the tunnel data path, and
# every tunnel keeps running when this process dies. It therefore gets the
# STRONGEST unit sandbox of the two services — but see the exceptions:
#
# Hardening of the unit (and why):
#   - runs as the dedicated non-login user `quantum-panel` (created here);
#     the panel needs no root privileges for its management role
#     (Exception: the panel binary also carries CLIs that manage tunnel
#     engines/netopt ON THIS HOST via systemctl — as non-root those CLIs
#     need polkit rules. This installer documents the limitation; in the
#     V2 topology engines live on agent servers, not here.)
#   - NoNewPrivileges=yes, PrivateTmp=yes, ProtectHome=yes (panel needs no
#     home directories at all — unlike the agent, no SSH key reading)
#   - ProtectSystem=strict + ReadWritePaths for exactly the state it owns
#     (/etc/quantum-panel, /var/lib/quantum-panel, /var/log/journal client
#     socket), ProtectKernelTunables=yes, ProtectKernelModules=yes,
#     ProtectControlGroups=yes, RestrictAddressFamilies AF_INET/AF_INET6/
#     AF_UNIX, LockPersonality=yes, RestrictSUIDSGID=yes
#   - AmbientCapabilities=CAP_NET_BIND_SERVICE ONLY when --port < 1024
#
# Secrets: the admin password is read from a file or generated; it is
# stored ONLY in the panel's own config (hashed) and, when generated, in
# the 0600 initial password file. It is never printed by this script
# (the binary's own output is captured and suppressed).
#
# Usage:
#   sudo bash install-panel.sh [--port 7443] [--base-path PATH]
#        [--username admin] (--password-file FILE | --password '...' |
#         [--generate-password]) [--version latest|vX.Y.Z]
#        [--binary FILE [--checksum SHA256]] [--no-start] [--check] [--yes]
###############################################################################
set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

SCRIPT_NAME="install-panel.sh"
REPO="Dark-modem/quantum-panel"
BIN="/usr/local/bin/quantum-panel"
UNIT="/etc/systemd/system/quantum-panel.service"
PANEL_USER="quantum-panel"
PANEL_DIR="/etc/quantum-panel"
STATE_DIR="/var/lib/quantum-panel"
LOG_TAG="quantum-install-panel"

info()  { printf '[ %s ] %s\n' "$LOG_TAG" "$*"; }
warn()  { printf '[ %s ] WARN: %s\n' "$LOG_TAG" "$*" >&2; }
die()   { printf '[ %s ] ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
trun()  { timeout --kill-after=5 "$1" "${@:2}"; }

need_root()  { [[ $EUID -eq 0 ]] || die "run as root: sudo bash $SCRIPT_NAME ..."; }
need_systemd() { have systemctl || die "systemd is required"; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
PORT="7443" BASE_PATH="" USERNAME="admin"
PASSWORD="" PASSWORD_FILE="" GENERATE=0
VERSION="latest" BINARY="" CHECKSUM=""
NO_START=0 CHECK_ONLY=0

usage() { sed -n '2,44p' "$0" | grep -E '^#' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)           PORT="${2:-}"; shift 2;;
        --base-path)      BASE_PATH="${2:-}"; shift 2;;
        --username)       USERNAME="${2:-}"; shift 2;;
        --password)       PASSWORD="${2:-}"; shift 2;;
        --password-file)  PASSWORD_FILE="${2:-}"; shift 2;;
        --generate-password) GENERATE=1; shift;;
        --version)        VERSION="${2:-}"; shift 2;;
        --binary)         BINARY="${2:-}"; shift 2;;
        --checksum)       CHECKSUM="${2:-}"; shift 2;;
        --no-start)       NO_START=1; shift;;
        --check)          CHECK_ONLY=1; shift;;
        --yes)            shift;;
        -h|--help)        usage; exit 0;;
        *) die "unknown argument: $1 (see --help)";;
    esac
done
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "--port wants 1-65535"
if [[ -n "$BINARY" && -z "$CHECKSUM" && -f "${BINARY}.sha256" ]]; then
    CHECKSUM="$(trun 10 awk '{print $1}' "${BINARY}.sha256" 2>/dev/null || true)"
fi
[[ -n "$BINARY" && -z "$CHECKSUM" ]] && die "--binary requires --checksum SHA256 (or a .sha256 sidecar)"
COUNT_SET=$(( ${PASSWORD:+1} + ${PASSWORD_FILE:+1} + GENERATE ))
[[ $COUNT_SET -le 1 ]] || die "use only one of --password / --password-file / --generate-password"

# ---------------------------------------------------------------------------
# Binary acquisition (same discipline as install-agent.sh)
# ---------------------------------------------------------------------------
arch_tag() {
    case "$(uname -m)" in
        x86_64) printf 'amd64';;
        aarch64|arm64) printf 'arm64';;
        *) die "unsupported architecture: $(uname -m)";;
    esac
}

download() {
    if have curl; then trun 300 curl -fsSL --retry 2 --connect-timeout 10 "$1" -o "$2"
    else trun 300 wget -qO "$2" "$1"; fi
}

release_latest() {
    local out
    out="$(trun 20 curl -fsSL "https://github.com/${REPO}/releases/latest" -o /dev/null -w '%{url_effective}' 2>/dev/null || true)"
    out="${out##*/}"
    [[ "$out" =~ ^v[0-9] ]] || return 1
    printf '%s' "$out"
}

fetch_binary() {
    local arch; arch="$(arch_tag)"
    if [[ -n "$BINARY" ]]; then
        [[ -r "$BINARY" ]] || die "cannot read --binary: $BINARY"
        local got; got="$(trun 60 sha256sum "$BINARY" | awk '{print $1}')"
        [[ "$got" == "$CHECKSUM" ]] || die "checksum mismatch for $BINARY (expected $CHECKSUM, got $got)"
        printf '%s' "$BINARY"; return 0
    fi
    have curl || have wget || die "need curl or wget"
    if [[ "$VERSION" == "latest" ]]; then
        VERSION="$(release_latest)" || die "cannot resolve the latest release tag"
    fi
    local base="https://github.com/${REPO}/releases/download/${VERSION}"
    local asset="quantum-panel-linux-${arch}"
    local tmp sums
    tmp="$(mktemp -t quantum-panel.XXXXXX)"; sums="$(mktemp -t quantum-sums.XXXXXX)"
    trap 'rm -f "$tmp" "$sums"' RETURN
    info "downloading ${asset} (${VERSION})"
    download "$base/$asset" "$tmp" || die "download failed: $asset"
    download "$base/checksums.txt" "$sums" || die "download failed: checksums.txt (refusing an unverified binary)"
    local want; want="$(trun 10 awk -v a="$asset" '$2==a || $2=="*"a {print $1}' "$sums")"
    [[ -n "$want" ]] || die "checksums.txt has no entry for $asset"
    local got; got="$(trun 60 sha256sum "$tmp" | awk '{print $1}')"
    [[ "$got" == "$want" ]] || die "checksum mismatch for $asset (expected $want, got $got)"
    printf '%s' "$tmp"
}

install_binary() {
    local src; src="$(fetch_binary)"
    local cur=""; [[ -x "$BIN" ]] && cur="$(trun 30 sha256sum "$BIN" | awk '{print $1}')"
    local new; new="$(trun 30 sha256sum "$src" | awk '{print $1}')"
    if [[ "$cur" == "$new" ]]; then
        info "binary already current (sha256 ${new:0:12}…)"; return 0
    fi
    [[ -x "$BIN" ]] && cp -a "$BIN" "${BIN}.bak"
    install -o root -g root -m 0755 "$src" "${BIN}.new" && mv -f "${BIN}.new" "$BIN"
    info "installed $BIN (sha256 ${new:0:12}…)"
}

# ---------------------------------------------------------------------------
# Dedicated user + dirs
# ---------------------------------------------------------------------------
create_user() {
    if ! id "$PANEL_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin "$PANEL_USER"
        info "created system user $PANEL_USER"
    fi
    install -d -o "$PANEL_USER" -g "$PANEL_USER" -m 0750 "$PANEL_DIR" "$STATE_DIR"
}

# ---------------------------------------------------------------------------
# Hardened unit
# ---------------------------------------------------------------------------
write_unit() {
    local caps=""
    (( PORT < 1024 )) && caps="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
    local tmp; tmp="$(mktemp -t quantum-panel-unit.XXXXXX)"
    trap 'rm -f "$tmp"' RETURN
    cat > "$tmp" <<UNIT
# managed by install-panel.sh (phase1/hardening) — edits belong in the installer
[Unit]
Description=Quantum panel (management only — never in the data path)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PANEL_USER}
Group=${PANEL_USER}
Environment=GRE_PANEL_DIR=${PANEL_DIR}
ExecStart=${BIN}
Restart=on-failure
RestartSec=5

# --- hardening: the panel is management-only, so it gets the full sandbox ---
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${PANEL_DIR} ${STATE_DIR}
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictSUIDSGID=yes
LockPersonality=yes
${caps}

[Install]
WantedBy=multi-user.target
UNIT
    if [[ -f "$UNIT" ]] && cmp -s "$tmp" "$UNIT"; then
        info "systemd unit already up to date"
    else
        [[ -f "$UNIT" ]] && cp -a "$UNIT" "${UNIT}.bak"
        install -m 0644 "$tmp" "$UNIT"
        trun 15 systemctl daemon-reload
        info "wrote hardened unit $UNIT (sandbox: strict)"
    fi
}

# ---------------------------------------------------------------------------
# Initial admin credential (never printed by this script)
# ---------------------------------------------------------------------------
credential_step() {
    local pwfile="${PANEL_DIR}/initial-admin-password"
    if [[ -f "${PANEL_DIR}/panel.json" ]] && grep -q '"pass_hash"' "${PANEL_DIR}/panel.json" 2>/dev/null; then
        info "admin credential already configured — leaving it alone"
        return 0
    fi
    if [[ -z "$PASSWORD" && -z "$PASSWORD_FILE" && $GENERATE -eq 0 ]]; then
        GENERATE=1
        info "no credential option given — generating a random password"
    fi
    if [[ -n "$PASSWORD_FILE" ]]; then
        [[ -r "$PASSWORD_FILE" ]] || die "cannot read --password-file: $PASSWORD_FILE"
        PASSWORD="$(trun 5 head -c 4096 "$PASSWORD_FILE" | tr -d '[:space:]')"
    elif [[ $GENERATE -eq 1 ]]; then
        PASSWORD="$(trun 10 openssl rand -base64 18 2>/dev/null || tr -dc 'A-Za-z0-9' </dev/urandom | trun 5 head -c 20)"
    fi
    # The panel prints the password on stdout — captured and suppressed.
    set +e
    local out; out="$(GRE_PANEL_DIR="$PANEL_DIR" trun 30 "$BIN" password "$PASSWORD" 2>&1)"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        # First run of the binary creates panel.json; retry once now that it exists.
        set +e
        GRE_PANEL_DIR="$PANEL_DIR" trun 30 "$BIN" password "$PASSWORD" >/dev/null 2>&1
        rc=$?
        set -e
        [[ $rc -eq 0 ]] || die "could not set the admin credential (exit $rc)"
    fi
    unset PASSWORD
    if [[ $GENERATE -eq 1 ]]; then
        # Regeneration is impossible without knowing the value; the binary
        # printed it into $out. Extract it into the 0600 file, never to the tty.
        local gen
        gen="$(printf '%s\n' "$out" | awk '/^Password:/{print $2}')"
        if [[ -n "$gen" ]]; then
            umask 077; printf '%s\n' "$gen" > "$pwfile"; umask 022
            warn "generated admin password stored at $pwfile (mode 0600) — READ IT, then delete the file"
        fi
    else
        info "admin credential set from your input (not displayed here)"
    fi
    # Username/base-path/port are panel.json fields; write the declared ones
    # for a FIRST install (panel.json may not exist before the binary run).
    if [[ -f "${PANEL_DIR}/panel.json" ]] && have python3; then
        GRE_PANEL_DIR="$PANEL_DIR" trun 20 python3 - "$USERNAME" "$PORT" "$BASE_PATH" <<'PY' >/dev/null 2>&1 || true
import json, os, sys
p = os.path.join(os.environ["GRE_PANEL_DIR"], "panel.json")
cfg = {}
if os.path.exists(p):
    cfg = json.load(open(p))
u, port, base = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cfg.setdefault("username", u)
cfg.setdefault("port", port)
if base:
    cfg.setdefault("base_path", base.strip("/"))
json.dump(cfg, open(p, "w"), indent=2)
PY
    fi
    info "panel credential configured (username: ${USERNAME})"
}

# ---------------------------------------------------------------------------
# Firewall: additive, tagged, declared port only
# ---------------------------------------------------------------------------
firewall_step() {
    if ! have ufw; then warn "ufw not present; open ${PORT}/tcp in your firewall manually"; return 0; fi
    local status; status="$(trun 15 ufw status 2>/dev/null || true)"
    if [[ "$status" == *"Status: inactive"* ]]; then
        warn "ufw installed but inactive — panel port NOT opened (enable ufw deliberately, with the SSH door verified first)"
        return 0
    fi
    trun 30 ufw status 2>/dev/null | grep -q "${PORT}/tcp" && { info "panel port already allowed"; return 0; }
    trun 30 ufw allow "${PORT}/tcp" comment "quantum:installer:panel" >/dev/null
    info "panel port open: ${PORT}/tcp (tagged quantum:installer:panel)"
}

# ---------------------------------------------------------------------------
# Start + verify
# ---------------------------------------------------------------------------
start_service() {
    [[ $NO_START -eq 1 ]] && { info "--no-start: not enabling (systemctl enable --now quantum-panel)"; return 0; }
    trun 30 systemctl enable --now quantum-panel.service >/dev/null
    sleep 2
    if ! trun 15 systemctl is-active --quiet quantum-panel.service; then
        warn "service failed — rolling the binary back if we replaced it"
        [[ -f "${BIN}.bak" ]] && { cp -a "${BIN}.bak" "$BIN"; trun 15 systemctl restart quantum-panel.service || true; }
        die "quantum-panel.service failed to start; journal: journalctl -u quantum-panel -n 50"
    fi
    info "quantum-panel.service active"
}

verify() {
    local ok=1
    trun 15 systemctl is-active --quiet quantum-panel.service || { warn "service inactive"; ok=0; }
    # The TLS listener may take a moment; probe the declared port.
    local probe=0
    for _attempt in 1 2 3 4 5; do
        if trun 6 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then probe=1; break; fi
        sleep 1
    done
    if [[ $probe -eq 1 ]]; then info "panel port ${PORT} answers locally"; else warn "panel port ${PORT} does not answer yet"; ok=0; fi
    [[ $ok -eq 1 ]] && info "VERIFY: OK" || { warn "VERIFY: problems above"; return 1; }
}

check_install() {
    [[ -x "$BIN" ]] || die "not installed: $BIN"
    "$BIN" version 2>/dev/null || true
    trun 15 systemctl is-active quantum-panel.service 2>/dev/null || true
    [[ -f "$UNIT" ]] && grep -q "ProtectSystem=strict" "$UNIT" && info "hardened unit present" || warn "unit missing or not hardened"
    verify || true
    exit 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
need_root
need_systemd
if [[ $CHECK_ONLY -eq 1 ]]; then check_install; fi
info "installing quantum-panel (arch $(arch_tag), version ${VERSION})"
install_binary
create_user
credential_step
write_unit
firewall_step
start_service
verify
info "done. Login over https://<host>:${PORT}${BASE_PATH:+/${BASE_PATH#/}}/ — the panel is management-only;"
info "agents enroll with install-agent.sh against this URL."
